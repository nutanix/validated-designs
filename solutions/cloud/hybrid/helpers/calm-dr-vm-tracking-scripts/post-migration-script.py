#!/usr/bin/env python
# -*- coding: utf-8 -*-

import os
import requests
import json
import ujson
import copy
import time
from itertools import islice
import gc

from calm.common.flags import gflags
from calm.lib.model.store.db_session import flush_session
from aplos.insights.entity_capability import EntityCapability
import calm.lib.model as model
from helper import change_project, init_contexts, log, DRY_RUN

# Validate environment variables
required_env = ['DEST_PC_IP', 'DEST_PROJECT_NAME', 'SOURCE_PROJECT_NAME', 'DEST_PC_USER', 'DEST_PC_PASS']
missing_env = [var for var in required_env if var not in os.environ]
if missing_env:
    raise Exception(f"Please export required environment variables: {', '.join(missing_env)}")

DEST_PC_IP = os.environ['DEST_PC_IP']
PC_PORT = 9440
LENGTH = 100

dest_base_url = f"https://{DEST_PC_IP}:{PC_PORT}/api/nutanix/v3"
dest_pc_auth = { "username": os.environ['DEST_PC_USER'], "password": os.environ['DEST_PC_PASS']}

DEST_PROJECT = os.environ['DEST_PROJECT_NAME']
SRC_PROJECT = os.environ['SOURCE_PROJECT_NAME']
headers = {'content-type': 'application/json', 'Accept': 'application/json'}

def print_header():
    print("="*60)
    print("      NCM Self-Service Post-Migration Script Started")
    print(f"      Timestamp: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print("="*60)

def get_vm(base_url, auth, uuid):
    method = 'GET'
    url = base_url + f"/vms/{uuid}"
    resp = requests.request(
            method,
            url,
            headers=headers,
            auth=(auth["username"], auth["password"]),
            verify=False
    )
    if resp.ok:
        return resp.json()
    else:
        log.error("Failed to get vm '%s'. Status: %s, Response: %s", uuid, resp.status_code, resp.text)
        raise Exception(f"Failed to get vm '{uuid}'.")

def get_account_uuid_map():
    nutanix_pc_accounts = model.NutanixPCAccount.query(deleted=False)
    dest_account_uuid_map = {}
    pc_account = None
    for account in nutanix_pc_accounts:
        if account.data.server == DEST_PC_IP:
            pc_account = account
            break

    if not pc_account:
        raise Exception(f"Unable to find destination PC account '{DEST_PC_IP}'")

    for pe in pc_account.data.nutanix_account:
        dest_account_uuid_map[pe.data.cluster_uuid] = str(pe.uuid)
    return dest_account_uuid_map

def update_substrate_info(vm_uuid, vm, dest_account_uuid_map, vm_uuid_map):
    instance_id = vm_uuid
    vm_name = vm["status"]["name"]
    cluster_uuid = vm["status"]["cluster_reference"]["uuid"]
    NSE = model.NutanixSubstrateElement.query(instance_id=instance_id, deleted=False)
    app_name = None
    if NSE:
        NSE = NSE[0]
        try:
            application = model.AppProfileInstance.get_object(NSE.app_profile_instance_reference).application
            app_name = application.name
        except Exception as e:
            log.warning("Could not find application for AppProfileInstance reference '%s': %s", NSE.app_profile_instance_reference, e)
            app_name = "UNKNOWN_APP"

        prefix = f"[App: {app_name}] "

        log.info(prefix + "Updating VM substrate element for '%s' with instance_id '%s'.", vm_name, instance_id)
        if instance_id != vm_uuid_map[instance_id]:
            log.info(prefix + "Updating instance_id of '%s' from '%s' to '%s'.", vm_name, instance_id, vm_uuid_map[instance_id])
            if DRY_RUN:
                log.info(prefix + "[DRY RUN] Would update instance_id of '%s' from '%s' to '%s'.", vm_name, instance_id, vm_uuid_map[instance_id])
            else:
                NSE.instance_id = vm_uuid_map[instance_id]
                instance_id = vm_uuid_map[instance_id]

        if DRY_RUN:
            log.info(prefix + "[DRY RUN] Would update substrate/account/cluster/platform data for VM '%s'", vm_name)
        else:
            NSE.spec.resources.account_uuid = dest_account_uuid_map[cluster_uuid]
            NSE.spec.resources.cluster_uuid = cluster_uuid
            NSE.platform_data = json.dumps(vm)
            for i in range(len(NSE.spec.resources.nic_list)):
                NSE.spec.resources.nic_list[i].nic_type = vm["status"]["resources"]["nic_list"][i]["nic_type"]
                NSE.spec.resources.nic_list[i].subnet_reference = vm["status"]["resources"]["nic_list"][i]["subnet_reference"]
                ip_endpoint_list = vm["spec"]["resources"]["nic_list"][i]["ip_endpoint_list"]
                for ip_endpoint in ip_endpoint_list:
                    if "ip_type" in ip_endpoint:
                        del ip_endpoint["ip_type"]
                    if "gateway_address_list" in ip_endpoint:
                        del ip_endpoint["gateway_address_list"]
                    if "prefix_length" in ip_endpoint:
                        del ip_endpoint["prefix_length"]
                NSE.spec.resources.nic_list[i].ip_endpoint_list = ip_endpoint_list
            for i in range(len(NSE.spec.resources.disk_list)):
                NSE.spec.resources.disk_list[i].device_properties = vm["spec"]["resources"]["disk_list"][i]["device_properties"]
                if "disk_size_mib" in vm["spec"]["resources"]["disk_list"][i]:
                    NSE.spec.resources.disk_list[i].disk_size_mib = vm["spec"]["resources"]["disk_list"][i]["disk_size_mib"]
                if NSE.spec.resources.disk_list[i].data_source_reference:
                    if "data_source_reference" in vm["spec"]["resources"]["disk_list"][i]:
                        NSE.spec.resources.disk_list[i].data_source_reference = vm["spec"]["resources"]["disk_list"][i]["data_source_reference"]
                    else:
                        NSE.spec.resources.disk_list[i].data_source_reference = None
            if not DRY_RUN:
                NSE.save()
                log.info(prefix + "Saved updated NutanixSubstrateElement for VM '%s'.", vm_name)

        log.info(prefix + "Updating VM substrate for '%s' with instance_id '%s'.", vm_name, instance_id)
        NS = NSE.replica_group
        if DRY_RUN:
            log.info(prefix + "[DRY RUN] Would update replica_group substrate for VM '%s'", vm_name)
        else:
            NS.spec.resources.account_uuid = dest_account_uuid_map[cluster_uuid]
            for i in range(len(NS.spec.resources.nic_list)):
                NS.spec.resources.nic_list[i].nic_type = vm["status"]["resources"]["nic_list"][i]["nic_type"]
                NS.spec.resources.nic_list[i].subnet_reference = vm["status"]["resources"]["nic_list"][i]["subnet_reference"]
                ip_endpoint_list = vm["spec"]["resources"]["nic_list"][i]["ip_endpoint_list"]
                for ip_endpoint in ip_endpoint_list:
                    if "ip_type" in ip_endpoint:
                        del ip_endpoint["ip_type"]
                    if "gateway_address_list" in ip_endpoint:
                        del ip_endpoint["gateway_address_list"]
                    if "prefix_length" in ip_endpoint:
                        del ip_endpoint["prefix_length"]
                NS.spec.resources.nic_list[i].ip_endpoint_list = ip_endpoint_list

            log.info(prefix + "Updating 'create_Action' under substrate for '%s' with instance_id '%s'.", vm_name, instance_id)
            for action in NS.actions:
                if action.name == "action_create":
                    for task in action.runbook.get_all_tasks():
                        if task.type == "PROVISION_NUTANIX":
                            for i, nic in enumerate(task.attrs.resources.nic_list):
                                nic.subnet_reference.uuid = vm["status"]["resources"]["nic_list"][i]["subnet_reference"]["uuid"]
                        task.save()
            NS.save()
            log.info(prefix + "Saved updated replica_group for VM '%s'.", vm_name)

        log.info(prefix + "Updating VM substrate cfg for '%s' with instance_id '%s'.", vm_name, instance_id)
        NSC = NS.config
        if DRY_RUN:
            log.info(prefix + "[DRY RUN] Would update substrate config for VM '%s'", vm_name)
        else:
            NSC.spec.resources.account_uuid = dest_account_uuid_map[cluster_uuid]
            for i in range(len(NSC.spec.resources.nic_list)):
                NSC.spec.resources.nic_list[i].nic_type = vm["status"]["resources"]["nic_list"][i]["nic_type"]
                NSC.spec.resources.nic_list[i].subnet_reference = vm["status"]["resources"]["nic_list"][i]["subnet_reference"]
                ip_endpoint_list = vm["spec"]["resources"]["nic_list"][i]["ip_endpoint_list"]
                for ip_endpoint in ip_endpoint_list:
                    if "ip_type" in ip_endpoint:
                        del ip_endpoint["ip_type"]
                    if "gateway_address_list" in ip_endpoint:
                        del ip_endpoint["gateway_address_list"]
                    if "prefix_length" in ip_endpoint:
                        del ip_endpoint["prefix_length"]
                NSC.spec.resources.nic_list[i].ip_endpoint_list = ip_endpoint_list

            for i in range(len(NSC.spec.resources.disk_list)):
                NSC.spec.resources.disk_list[i].device_properties = vm["spec"]["resources"]["disk_list"][i]["device_properties"]
                if "disk_size_mib" in vm["spec"]["resources"]["disk_list"][i]:
                    NSC.spec.resources.disk_list[i].disk_size_mib = vm["spec"]["resources"]["disk_list"][i]["disk_size_mib"]
                if NSC.spec.resources.disk_list[i].data_source_reference:
                    if "data_source_reference" in vm["spec"]["resources"]["disk_list"][i]:
                        NSC.spec.resources.disk_list[i].data_source_reference = vm["spec"]["resources"]["disk_list"][i]["data_source_reference"]
                    else:
                        NSC.spec.resources.disk_list[i].data_source_reference = None
            if len(vm["spec"]["resources"]["disk_list"]) > len(NSC.spec.resources.disk_list):
                diff_length = len(vm["spec"]["resources"]["disk_list"]) - len(NSC.spec.resources.disk_list)
                diff_disk_list = vm["spec"]["resources"]["disk_list"][-diff_length:]
                ref_disk = copy.deepcopy(NSC.spec.resources.disk_list[0])
                for disk in diff_disk_list:
                    ref_disk.device_properties = disk["device_properties"]
                    if "disk_size_mib" in disk:
                        ref_disk.disk_size_mib = disk["disk_size_mib"]
                    if "data_source_reference" in disk:
                        ref_disk.data_source_reference = disk["data_source_reference"]
                    else:
                        if ref_disk.data_source_reference:
                            ref_disk.data_source_reference = None
                    NSC.spec.resources.disk_list.append(ref_disk)
            if not DRY_RUN:
                NSC.save()
                log.info(prefix + "Saved updated substrate config for VM '%s'.", vm_name)

        log.info(prefix + "Updating VM clone blueprint for '%s' with instance_id '%s'.", vm_name, instance_id)
        try:
            application = model.AppProfileInstance.get_object(NSE.app_profile_instance_reference).application
        except Exception as e:
            log.warning("Could not find application for AppProfileInstance reference '%s': %s", NSE.app_profile_instance_reference, e)
            return
        if DRY_RUN:
            log.info(prefix + "[DRY RUN] Would update clone blueprint and patch config for VM '%s'", vm_name)
            return
        clone_bp = application.app_blueprint_config
        clone_bp_intent_spec_dict = json.loads(clone_bp.intent_spec)
        for substrate_cfg in clone_bp_intent_spec_dict.get("resources").get("substrate_definition_list"):
            nic_list = substrate_cfg.get("create_spec").get("resources").get("nic_list")
            for i, nic in enumerate(nic_list):
                nic["subnet_reference"] = vm["status"]["resources"]["nic_list"][i]["subnet_reference"]
            substrate_cfg["create_spec"]["resources"]["account_uuid"] = dest_account_uuid_map[cluster_uuid]

        clone_bp.intent_spec = json.dumps(clone_bp_intent_spec_dict)
        clone_bp.save()

        log.info(prefix + "Updating patch config action for '%s' with instance_id '%s'.", vm_name, instance_id)
        vm_first_nic_subnet_uuid = ""
        if len(vm["status"]["resources"]["nic_list"]) >= 0:
            vm_first_nic_subnet_uuid = vm["status"]["resources"]["nic_list"][0]["subnet_reference"]["uuid"]
        for patch in application.active_app_profile_instance.patches:
            patch_attr_list = patch.attrs_list[0]
            patch_data = patch_attr_list.data
            for i in range(len(patch_data.pre_defined_nic_list)):
                if patch_data.pre_defined_nic_list[i].operation == "add":
                    patch_data.pre_defined_nic_list[i].subnet_reference.uuid=vm_first_nic_subnet_uuid
                else:
                    if len(vm["status"]["resources"]["nic_list"]) >= i + 1:
                        patch_data.pre_defined_nic_list[i].subnet_reference.uuid=vm["status"]["resources"]["nic_list"][i]["subnet_reference"]["uuid"]
                    else:
                        patch_data.pre_defined_nic_list[i].subnet_reference.uuid = vm_first_nic_subnet_uuid
            patch.save()
            application.active_app_profile_instance.save()
            application.save()
        app_intent_spec = application.active_app_profile_instance.intent_spec
        app_intent_spec_dict = ujson.loads(app_intent_spec)
        log.info(prefix + "Updating patch active app profile instance for '%s' with instance_id '%s'.", vm_name, instance_id)
        for patch in app_intent_spec_dict["resources"]["patch_list"]:
            patch_data = patch["attrs_list"][0]["data"]
            for i in range(len(patch_data["pre_defined_nic_list"])):
                if patch_data["pre_defined_nic_list"][i]["operation"] == "add":
                    patch_data["pre_defined_nic_list"][i]["subnet_reference"]["uuid"]=vm_first_nic_subnet_uuid
                else:
                    if len(vm["status"]["resources"]["nic_list"]) >= i + 1:
                        patch_data["pre_defined_nic_list"][i]["subnet_reference"]["uuid"]=vm["status"]["resources"]["nic_list"][i]["subnet_reference"]["uuid"]
                    else:
                        patch_data["pre_defined_nic_list"][i]["subnet_reference"]["uuid"] = vm_first_nic_subnet_uuid
        application.active_app_profile_instance.intent_spec = ujson.dumps(app_intent_spec_dict)
        application.active_app_profile_instance.save()
        application.save()

def chunked_iterable(iterable, size):
    """Yield successive chunks from an iterable."""
    it = iter(iterable)
    while True:
        chunk = list(islice(it, size))
        if not chunk:
            break
        yield chunk

def update_substrates(vm_uuid_map, batch_size=100):
    dest_account_uuid_map = get_account_uuid_map()
    total = len(vm_uuid_map)
    processed = 0
    updated = 0
    failed = 0
    log.info("Starting substrate update for %d VMs.", total)

    for batch_num, batch in enumerate(chunked_iterable(vm_uuid_map.items(), batch_size), 1):
        log.info("=== Starting batch %d (%d VMs) ===", batch_num, len(batch))
        batch_updated = 0
        batch_failed = 0

        start_index = (batch_num - 1) * batch_size
        for idx, (vm_uuid, mapped_uuid) in enumerate(batch, 1):
            global_index = start_index + idx
            log.info("Processing VM %d of %d (batch %d, item %d): %s", global_index, total, batch_num, idx, vm_uuid)
            processed += 1
            try:
                vm = get_vm(dest_base_url, dest_pc_auth, mapped_uuid)
            except Exception as e:
                log.warning("Failed to get VM %s: %s", vm_uuid, e)
                failed += 1
                batch_failed += 1
                continue

            if DRY_RUN:
                log.info("[DRY RUN] Would update substrate info for VM '%s'", vm_uuid)
                updated += 1
                batch_updated += 1
            else:
                try:
                    update_substrate_info(vm_uuid, vm, dest_account_uuid_map, vm_uuid_map)
                    updated += 1
                    batch_updated += 1
                except Exception as e:
                    log.warning("Failed to update substrate of %s: %s", vm_uuid, e)
                    failed += 1
                    batch_failed += 1

        if not DRY_RUN:
            flush_session()  # ✅ flush after each batch

        log.info("=== Finished batch %d: %d updated, %d failed ===", batch_num, batch_updated, batch_failed)
        time.sleep(0.1)  # optional throttle
        gc.collect()     # optional memory cleanup

    log.info("Done with updating substrates")
    return processed, updated, failed


def update_app_project(vm_uuid_map):
    app_names = set()
    app_kind = "app"
    missing_app_uuids = []
    for instance_id in vm_uuid_map.keys():
        try:
            NSE = model.NutanixSubstrateElement.query(instance_id=vm_uuid_map[instance_id], deleted=False)
            if NSE:
                NSE = NSE[0]
                try:
                    app_profile_instance = model.AppProfileInstance.get_object(NSE.app_profile_instance_reference)
                    application = app_profile_instance.application
                except Exception as e:
                    log.warning("Could not find application for AppProfileInstance reference '%s': %s", NSE.app_profile_instance_reference, e)
                    missing_app_uuids.append(NSE.app_profile_instance_reference)
                    continue
                app_name = application.name
                app_uuid = application.uuid
                entity_cap = EntityCapability(kind_name=app_kind, kind_id=str(app_uuid))
                if entity_cap.project_name == SRC_PROJECT:
                    app_names.add(app_name)
        except Exception as e:
            log.warning("Error processing instance_id %s: %s", instance_id, e)
            continue

    for app_name in app_names:
        if DRY_RUN:
            log.info("[DRY RUN] Would change project for app '%s' to '%s'", app_name, DEST_PROJECT)
        else:
            change_project(app_name, DEST_PROJECT)
    if missing_app_uuids:
        log.warning("The following AppProfileInstance references could not be processed (missing or error): %s", missing_app_uuids)

def get_recovery_plan_jobs_list(base_url, auth, offset):
    method = 'POST'
    url = base_url + "/recovery_plan_jobs/list"
    payload = {"length": LENGTH, "offset": offset}
    resp = requests.request(
            method,
            url,
            data=json.dumps(payload),
            headers=headers,
            auth=(auth["username"], auth["password"]),
            verify=False
    )
    if resp.ok:
        resp_json = resp.json()
        return resp_json["entities"], resp_json["metadata"]["total_matches"]
    else:
        log.info("Failed to get recovery plan jobs list.")
        log.info('Status code: {}'.format(resp.status_code))
        log.info('Response: {}'.format(json.dumps(json.loads(resp.content), indent=4)))
        raise Exception("Failed to get recovery plan jobs list.")

def get_recovery_plan_job_execution_status(base_url, auth, job_uuid):
    method = 'GET'
    url = base_url + "/recovery_plan_jobs/{0}/execution_status".format(job_uuid)
    resp = requests.request(
            method,
            url,
            headers=headers,
            auth=(auth["username"], auth["password"]),
            verify=False
    )
    if resp.ok:
        resp_json = resp.json()
        return resp_json
    else:
        log.info("Failed to get recovery plan jobs {0} exucution status.".format(job_uuid))
        log.info('Status code: {}'.format(resp.status_code))
        log.info('Response: {}'.format(json.dumps(json.loads(resp.content), indent=4)))
        raise Exception("Failed to get recovery plan jobs {0} exucution status.".format(job_uuid))

def get_vm_source_dest_uuid_map():
    vm_source_dest_uuid_map = {}
    recovery_plan_jobs_list = []
    total_matches = 1
    offset = 0
    while offset < total_matches:
        entities, total_matches = get_recovery_plan_jobs_list(dest_base_url, dest_pc_auth, offset)
        for entity in entities:
            if (
                entity["status"]["resources"]["execution_parameters"]["action_type"] in ["MIGRATE", "FAILOVER"] and
                (
                    entity["status"]["execution_status"]["status"] == "COMPLETED" or
                    entity["status"]["execution_status"]["status"] == "COMPLETED_WITH_WARNING"
                )
            ):
                recovery_plan_jobs_list.append(entity["metadata"]["uuid"])
        offset += LENGTH

    for recovery_plan_job in recovery_plan_jobs_list:
        job_execution_status = get_recovery_plan_job_execution_status(dest_base_url, dest_pc_auth, recovery_plan_job)
        step_execution_status_list = job_execution_status["operation_status"]["step_execution_status_list"]
        for step_execution_status_src in step_execution_status_list:
            if step_execution_status_src["operation_type"] == "ENTITY_RECOVERY" :
                step_uuid = step_execution_status_src["step_uuid"]
                src_vm_uuid = step_execution_status_src["any_entity_reference_list"][0]["uuid"]
                dest_vm_uuid = step_execution_status_src["recovered_entity_info_list"][0]["recovered_entity_info"].get("entity_uuid")
                vm_source_dest_uuid_map[src_vm_uuid] = dest_vm_uuid

    return vm_source_dest_uuid_map

# Uncomment if you want to test the script for a specific set of VMs
#def main():
#    start_time = time.strftime('%Y-%m-%d %H:%M:%S')
#    try:
#        vm_uuid_map = get_vm_source_dest_uuid_map()
#        log.info("Full VM UUID map: %s", vm_uuid_map)  # Uncomment for debugging
#        TEST_VM_UUIDS = ["74ae0b29-bf44-4496-bbc9-1722912cadc4"]
#        vm_uuid_map = {k: v for k, v in vm_uuid_map.items() if k in TEST_VM_UUIDS}
#        log.info("Filtered VM UUID map: %s", vm_uuid_map)
#        if not vm_uuid_map:
#            log.info("No VMs to process after filtering.")
#        init_contexts()
#        processed, updated, failed = update_substrates(vm_uuid_map)
#        # update_app_project(vm_uuid_map)  # Uncomment if you want to update app projects too
#    except Exception as e:
#        log.error("Exception: %s", e)
#        raise
#    end_time = time.strftime('%Y-%m-%d %H:%M:%S')
#    print("="*60)
#    print("Summary:")
#    print(f"  Start time: {start_time}")
#    print(f"  End time:   {end_time}")
#    print(f"  Total VMs processed: {processed}")
#    print(f"  VMs updated:         {updated}")
#    print(f"  VMs failed:          {failed}")
#    print("="*60)

def main():
    start_time = time.strftime('%Y-%m-%d %H:%M:%S')
    try:
        vm_uuid_map = get_vm_source_dest_uuid_map()
        # log.info("VM UUID map: %s", vm_uuid_map)  # Uncomment for debugging
        if not vm_uuid_map:
            log.info("No VMs to process.")
            return
        init_contexts()
        processed, updated, failed = update_substrates(vm_uuid_map)
        # update_substrates(vm_uuid_map)
        # update_app_project(vm_uuid_map)  # Uncomment if you want to update app projects too
    except Exception as e:
        log.error("Exception: %s", e)
        raise
    end_time = time.strftime('%Y-%m-%d %H:%M:%S')
    print("="*60)
    print("Summary:")
    print(f"  Start time: {start_time}")
    print(f"  End time:   {end_time}")
    print(f"  Total VMs processed: {processed}")
    print(f"  VMs updated:         {updated}")
    print(f"  VMs failed:          {failed}")
    print("="*60)

if __name__ == "__main__":
    print_header()
    main()