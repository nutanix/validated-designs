#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Relink NCM Self-Service (Calm) apps to recovered UVMs after a Nutanix DR
(Disaster Recovery) job.

See README.md / WORKFLOW.md for when to run this.
"""

import os
import copy
import json
import ujson
import socket
import sys
import time
import getpass
from collections import OrderedDict
from itertools import islice

# Import helper before other calm modules: it sets APLOS_CONFIG and
# installs logging handlers before calm/aplos start talking.
from helper import (
    change_project,
    init_contexts,
    log,
    DRY_RUN,
    insecure,
    pc_session,
    request_with_retry,
    fetch_vm,
    substrate_in_sync,
    RunReport,
    require_env,
    preflight,
    print_summary,
    select_recovery_plan_jobs,
    merge_entity_recovery_map,
    count_self_mapped,
    job_uuid,
    unplanned_failover_jobs,
    prompt_recovery_plan_selection,
    clean_pc_host,
    LOG_FILE_PATH,
)
from calm.common.flags import gflags  # noqa: F401  -- see helper.py for why this stays
from calm.lib.model.store.db_session import flush_session
import calm.lib.model as model

PC_PORT = 9440
PAGE_LENGTH = 100
HEADERS = {'content-type': 'application/json', 'Accept': 'application/json'}

UPDATE_APP_PROJECT = os.environ.get("UPDATE_APP_PROJECT", "false").lower() == "true"

# DEST_PC_IP/USER/PASS are always required. DEST_PROJECT_NAME/SOURCE_PROJECT_NAME
# are only needed when the (opt-in, off-by-default) project move runs -- see
# Task 7 Step 5. This is a relaxation from the old always-required list, so it
# cannot break an existing runbook.
required_env = ['DEST_PC_IP', 'DEST_PC_USER', 'DEST_PC_PASS']
if UPDATE_APP_PROJECT:
    required_env += ['DEST_PROJECT_NAME', 'SOURCE_PROJECT_NAME']
require_env(required_env)

DEST_PC_IP = os.environ['DEST_PC_IP']
DEST_PROJECT = os.environ.get('DEST_PROJECT_NAME')
SRC_PROJECT = os.environ.get('SOURCE_PROJECT_NAME')

dest_base_url = "https://{0}:{1}/api/nutanix/v3".format(DEST_PC_IP, PC_PORT)

_SUBNET_VPC_CACHE = {}


class AccountMappingError(Exception):
    """Raised when a recovered VM's cluster has no matching Nutanix account
    under the destination PC -- named instead of a bare KeyError."""


def print_header(report_path):
    print("=" * 60)
    print("  NCM Self-Service (Calm) Post-Migration Script")
    print("  dest PC:      {0}:{1}".format(DEST_PC_IP, PC_PORT))
    print("  dry_run:      {0}".format(str(DRY_RUN).lower()))
    print("  insecure:     {0}".format(str(insecure()).lower()))
    print("  rp_job_scope: {0}".format((os.environ.get("RP_JOB_SCOPE") or "prompt").strip() or "prompt"))
    print("  log file:     {0}".format(LOG_FILE_PATH or "(console only)"))
    print("  report:       {0}".format(report_path))
    print("  Timestamp:    {0}".format(time.strftime('%Y-%m-%d %H:%M:%S')))
    print("=" * 60)


def get_account_uuid_map(pc_ip=None):
    """FQDN-tolerant match: compares the PC IP/FQDN and its resolved address
    against each registered account's server. On failure, lists the candidate
    servers instead of a bare "unable to find"."""
    if pc_ip is None:
        pc_ip = DEST_PC_IP
    nutanix_pc_accounts = model.NutanixPCAccount.query(deleted=False)
    dest_account_uuid_map = {}
    pc_account = None
    candidates = []
    for account in nutanix_pc_accounts:
        candidates.append(account.data.server)
        if _hosts_match(account.data.server, pc_ip):
            pc_account = account
            break

    if not pc_account:
        raise Exception(
            "Unable to find destination PC account matching '{0}'. Registered account server(s): {1}".format(
                pc_ip, ", ".join(candidates) if candidates else "(none)"
            )
        )

    for pe in pc_account.data.nutanix_account:
        dest_account_uuid_map[pe.data.cluster_uuid] = str(pe.uuid)
    return dest_account_uuid_map


def _hosts_match(a, b):
    if not a or not b:
        return False
    if a == b:
        return True
    try:
        return socket.gethostbyname(a) == socket.gethostbyname(b)
    except socket.error:
        return False


def _account_uuid_for_cluster(dest_account_uuid_map, cluster_uuid):
    if cluster_uuid not in dest_account_uuid_map:
        raise AccountMappingError(
            "cluster '{0}' is not registered under any Nutanix account on DEST_PC".format(cluster_uuid)
        )
    return dest_account_uuid_map[cluster_uuid]


def get_vpc_reference(session, base_url, subnet_uuid):
    """VPC reference for a subnet, memoised for the life of the process.
    Returns None for non-VPC (plain VLAN-backed) subnets or on any error."""
    if subnet_uuid in _SUBNET_VPC_CACHE:
        return _SUBNET_VPC_CACHE[subnet_uuid]
    vpc_uuid = None
    try:
        resp = request_with_retry(session, "GET", "{0}/subnets/{1}".format(base_url, subnet_uuid), headers=HEADERS)
        if resp.ok:
            vpc_ref = resp.json().get("status", {}).get("resources", {}).get("vpc_reference")
            if vpc_ref:
                vpc_uuid = vpc_ref.get("uuid")
        else:
            log.debug("GET /subnets/%s failed with status %s", subnet_uuid, resp.status_code)
    except Exception as exc:
        log.debug("Error getting VPC reference for subnet '%s': %s", subnet_uuid, exc)
    _SUBNET_VPC_CACHE[subnet_uuid] = vpc_uuid
    return vpc_uuid


def _safe_range(have, want, what, vm_name):
    """range() bounded by the shorter of two lists, with a named, logged,
    non-fatal skip of the extra items instead of an IndexError. This is a
    bounds check, not a rewrite of the copy logic below it."""
    if have != want:
        log.debug(
            "%s count mismatch for VM '%s': substrate has %d, recovered VM has %d; using the shorter length.",
            what, vm_name, have, want,
        )
    return range(min(have, want))


def _copy_nic_fields(resources, vm, vm_name):
    dest_nics = vm["status"]["resources"]["nic_list"]
    dest_nics_ip = vm["spec"]["resources"]["nic_list"]
    for i in _safe_range(len(resources.nic_list), len(dest_nics), "NIC", vm_name):
        resources.nic_list[i].nic_type = dest_nics[i]["nic_type"]
        resources.nic_list[i].subnet_reference = dest_nics[i]["subnet_reference"]
        if dest_nics[i].get("vpc_reference"):
            resources.nic_list[i].vpc_reference = dest_nics[i]["vpc_reference"]
        ip_endpoint_list = dest_nics_ip[i]["ip_endpoint_list"] if i < len(dest_nics_ip) else []
        for ip_endpoint in ip_endpoint_list:
            for stale_key in ("ip_type", "gateway_address_list", "prefix_length"):
                if stale_key in ip_endpoint:
                    del ip_endpoint[stale_key]
        resources.nic_list[i].ip_endpoint_list = ip_endpoint_list


def _copy_disk_fields(resources, vm, vm_name):
    dest_disks = vm["spec"]["resources"]["disk_list"]
    for i in _safe_range(len(resources.disk_list), len(dest_disks), "disk", vm_name):
        resources.disk_list[i].device_properties = dest_disks[i]["device_properties"]
        if "disk_size_mib" in dest_disks[i]:
            resources.disk_list[i].disk_size_mib = dest_disks[i]["disk_size_mib"]
        if resources.disk_list[i].data_source_reference:
            resources.disk_list[i].data_source_reference = dest_disks[i].get("data_source_reference")


def _append_extra_disks(resources, vm):
    """The recovered VM can have more disks than the substrate cfg on record
    (e.g. a disk added post-clone). Clone the first disk entry as a template
    for each extra one."""
    dest_disks = vm["spec"]["resources"]["disk_list"]
    if not resources.disk_list or len(dest_disks) <= len(resources.disk_list):
        return
    diff_length = len(dest_disks) - len(resources.disk_list)
    for disk in dest_disks[-diff_length:]:
        ref_disk = copy.deepcopy(resources.disk_list[0])
        ref_disk.device_properties = disk["device_properties"]
        if "disk_size_mib" in disk:
            ref_disk.disk_size_mib = disk["disk_size_mib"]
        ref_disk.data_source_reference = disk.get("data_source_reference")
        resources.disk_list.append(ref_disk)


def _patch_nic_references(nic_entries, dest_nics, first_subnet_uuid, first_vpc_uuid):
    """attrs_list[0].data.pre_defined_nic_list is an ORM object; entries use attribute access."""
    for i in range(len(nic_entries)):
        entry = nic_entries[i]
        if entry.operation == "add":
            entry.subnet_reference.uuid = first_subnet_uuid
            if first_vpc_uuid:
                entry.vpc_reference = {"kind": "vpc", "uuid": first_vpc_uuid}
        elif i < len(dest_nics):
            entry.subnet_reference.uuid = dest_nics[i]["subnet_reference"]["uuid"]
            if dest_nics[i].get("vpc_reference"):
                entry.vpc_reference.uuid = dest_nics[i]["vpc_reference"].get("uuid", "")
        else:
            entry.subnet_reference.uuid = first_subnet_uuid
            if first_vpc_uuid:
                entry.vpc_reference.uuid = first_vpc_uuid


def _patch_nic_references_dict(nic_entries, dest_nics, first_subnet_uuid, first_vpc_uuid):
    """Same as _patch_nic_references, but for the plain-dict copy of the
    same structure stored in active_app_profile_instance.intent_spec."""
    for i in range(len(nic_entries)):
        entry = nic_entries[i]
        if entry["operation"] == "add":
            entry["subnet_reference"]["uuid"] = first_subnet_uuid
            if first_vpc_uuid:
                entry["vpc_reference"] = {"kind": "vpc", "uuid": first_vpc_uuid}
        elif i < len(dest_nics):
            entry["subnet_reference"]["uuid"] = dest_nics[i]["subnet_reference"]["uuid"]
            if dest_nics[i].get("vpc_reference"):
                entry["vpc_reference"]["uuid"] = dest_nics[i]["vpc_reference"].get("uuid", "")
        else:
            entry["subnet_reference"]["uuid"] = first_subnet_uuid
            if first_vpc_uuid:
                entry["vpc_reference"]["uuid"] = first_vpc_uuid


def _update_clone_blueprint_and_patches(NSE, vm, vm_name, account_uuid):
    try:
        application = model.AppProfileInstance.get_object(NSE.app_profile_instance_reference).application
    except Exception as exc:
        log.warning("Could not find application for AppProfileInstance reference '%s': %s", NSE.app_profile_instance_reference, exc)
        return

    dest_nics = vm["status"]["resources"]["nic_list"]

    clone_bp = application.app_blueprint_config
    clone_bp_spec = json.loads(clone_bp.intent_spec)
    for substrate_cfg in clone_bp_spec.get("resources", {}).get("substrate_definition_list", []):
        nic_list = substrate_cfg.get("create_spec", {}).get("resources", {}).get("nic_list", [])
        for i in _safe_range(len(nic_list), len(dest_nics), "NIC", vm_name):
            nic_list[i]["subnet_reference"] = dest_nics[i]["subnet_reference"]
            if dest_nics[i].get("vpc_reference"):
                nic_list[i]["vpc_reference"] = dest_nics[i]["vpc_reference"]
        substrate_cfg["create_spec"]["resources"]["account_uuid"] = account_uuid
    clone_bp.intent_spec = json.dumps(clone_bp_spec)
    clone_bp.save()

    first_subnet_uuid = dest_nics[0]["subnet_reference"]["uuid"] if dest_nics else ""
    first_vpc_uuid = (dest_nics[0].get("vpc_reference") or {}).get("uuid", "") if dest_nics else ""

    # Task 7 Step 4: application.save() / active_app_profile_instance.save()
    # moved out of this loop -- they only need to happen once, not per patch.
    for patch in application.active_app_profile_instance.patches:
        _patch_nic_references(patch.attrs_list[0].data.pre_defined_nic_list, dest_nics, first_subnet_uuid, first_vpc_uuid)
        patch.save()
    application.active_app_profile_instance.save()
    application.save()

    app_intent_spec = ujson.loads(application.active_app_profile_instance.intent_spec)
    for patch in app_intent_spec.get("resources", {}).get("patch_list", []):
        _patch_nic_references_dict(patch["attrs_list"][0]["data"]["pre_defined_nic_list"], dest_nics, first_subnet_uuid, first_vpc_uuid)
    application.active_app_profile_instance.intent_spec = ujson.dumps(app_intent_spec)
    application.active_app_profile_instance.save()
    application.save()


def _write_substrate_update(session, NSE, dest_uuid, vm, dest_account_uuid_map, base_url):
    vm_name = vm["status"]["name"]
    cluster_uuid = vm["status"]["cluster_reference"]["uuid"]
    account_uuid = _account_uuid_for_cluster(dest_account_uuid_map, cluster_uuid)

    # Query and attach VPC references to NICs, if any (cached per subnet).
    for nic in vm["status"]["resources"]["nic_list"]:
        subnet_uuid = nic["subnet_reference"]["uuid"]
        vpc_uuid = get_vpc_reference(session, base_url, subnet_uuid)
        if vpc_uuid:
            nic["vpc_reference"] = {"kind": "vpc", "uuid": vpc_uuid}

    if NSE.instance_id != dest_uuid:
        NSE.instance_id = dest_uuid
    NSE.spec.resources.account_uuid = account_uuid
    NSE.spec.resources.cluster_uuid = cluster_uuid
    NSE.platform_data = json.dumps(vm)
    _copy_nic_fields(NSE.spec.resources, vm, vm_name)
    _copy_disk_fields(NSE.spec.resources, vm, vm_name)
    NSE.save()

    NS = NSE.replica_group
    NS.spec.resources.account_uuid = account_uuid
    _copy_nic_fields(NS.spec.resources, vm, vm_name)
    for action in NS.actions:
        if action.name == "action_create":
            for task in action.runbook.get_all_tasks():
                if task.type == "PROVISION_NUTANIX":
                    dest_nics = vm["status"]["resources"]["nic_list"]
                    for i in _safe_range(len(task.attrs.resources.nic_list), len(dest_nics), "NIC", vm_name):
                        nic = task.attrs.resources.nic_list[i]
                        nic.subnet_reference.uuid = dest_nics[i]["subnet_reference"]["uuid"]
                        if dest_nics[i].get("vpc_reference"):
                            nic.vpc_reference = dest_nics[i]["vpc_reference"]
                    task.save()
    NS.save()

    NSC = NS.config
    NSC.spec.resources.account_uuid = account_uuid
    _copy_nic_fields(NSC.spec.resources, vm, vm_name)
    _copy_disk_fields(NSC.spec.resources, vm, vm_name)
    _append_extra_disks(NSC.spec.resources, vm)
    NSC.save()

    _update_clone_blueprint_and_patches(NSE, vm, vm_name, account_uuid)


def _app_name_for_nse(NSE):
    try:
        return model.AppProfileInstance.get_object(NSE.app_profile_instance_reference).application.name
    except Exception:
        return "UNKNOWN_APP"


def _vm_name_from_nse(NSE):
    name = getattr(NSE, "name", None)
    if name:
        return name
    raw = getattr(NSE, "platform_data", None)
    if not raw:
        return None
    try:
        if not isinstance(raw, dict):
            raw = json.loads(raw)
        return (raw.get("status") or {}).get("name") or (raw.get("spec") or {}).get("name")
    except Exception:
        return None


def _names_from_nse(NSE):
    return _vm_name_from_nse(NSE), _app_name_for_nse(NSE)


def _entity_label(vm_name, app_name):
    parts = []
    if app_name and app_name != "UNKNOWN_APP":
        parts.append("app={0}".format(app_name))
    if vm_name:
        parts.append("vm={0}".format(vm_name))
    return " ".join(parts) if parts else "unnamed"


def _process_one_vm(session, src_uuid, dest_uuid, dest_account_uuid_map, base_url):
    """Classify+act on one (src, dest) mapping. Returns (outcome, detail, vm_name, app_name).

    Cheap-check-first: the local IDF substrate lookup happens before any
    REST call, so the ~700 VMs with no NCM Self-Service substrate never trigger a
    GET /vms or subnet lookup at all.
    """
    if not dest_uuid:
        return "skipped_incomplete", "RP job mapping had no dest uuid", None, None

    nse_list = model.NutanixSubstrateElement.query(instance_id=src_uuid, deleted=False)
    if not nse_list:
        nse_list = model.NutanixSubstrateElement.query(instance_id=dest_uuid, deleted=False)
    if not nse_list:
        log.debug("No NCM Self-Service substrate for src=%s dest=%s.", src_uuid, dest_uuid)
        return "no_substrate", "no NCM Self-Service substrate element for src or dest uuid", None, None
    NSE = nse_list[0]
    nse_vm_name, app_name = _names_from_nse(NSE)

    vm, status = fetch_vm(session, base_url, dest_uuid)
    if status == "missing":
        return "dest_missing", "dest VM not present on this PC", nse_vm_name, app_name
    if status == "error":
        log.warning("GET /vms/%s failed; see debug log for details.", dest_uuid)
        return "errors", "GET /vms/{0} failed".format(dest_uuid), nse_vm_name, app_name

    vm_name = vm.get("status", {}).get("name") or nse_vm_name

    stored_accounts = [NSE.spec.resources.account_uuid]
    try:
        replica = NSE.replica_group
        stored_accounts.append(replica.spec.resources.account_uuid)
        stored_accounts.append(replica.config.spec.resources.account_uuid)
    except Exception:
        pass
    if substrate_in_sync(
        NSE.instance_id, dest_uuid, vm, dest_account_uuid_map,
        stored_accounts, NSE.spec.resources.cluster_uuid,
    ):
        log.debug("Already relinked %s %s %s -> %s", app_name, vm_name, src_uuid, dest_uuid)
        return "already_relinked", "substrate already points at dest VM", vm_name, app_name

    account_only = NSE.instance_id == dest_uuid
    if DRY_RUN:
        log.debug("[DRY RUN] Would relink %s %s %s -> %s", app_name, vm_name, src_uuid, dest_uuid)
        detail = "[DRY RUN] would relink (no write)"
        if account_only:
            detail = "[DRY RUN] would set account to the PC that has the VM (uuid already dest)"
        return "relinked", detail, vm_name, app_name

    try:
        _write_substrate_update(session, NSE, dest_uuid, vm, dest_account_uuid_map, base_url)
        log.debug("Relinked %s %s %s -> %s", app_name, vm_name, src_uuid, dest_uuid)
        detail = "set account to the PC that has the VM (uuid already dest)" if account_only else ""
        return "relinked", detail, vm_name, app_name
    except AccountMappingError as exc:
        log.warning("Account mapping miss for VM '%s' (%s): %s", vm_name, dest_uuid, exc)
        return "errors", str(exc), vm_name, app_name
    except Exception as exc:
        log.warning("Failed to update substrate of %s (%s): %s", dest_uuid, vm_name, exc)
        return "errors", str(exc), vm_name, app_name


def chunked_iterable(iterable, size):
    """Yield successive chunks from an iterable."""
    it = iter(iterable)
    while True:
        chunk = list(islice(it, size))
        if not chunk:
            break
        yield chunk


def _format_eta(elapsed, done, total):
    if done <= 0 or total <= 0:
        return "unknown"
    remaining = elapsed * (total - done) / float(done)
    minutes, seconds = divmod(int(remaining), 60)
    hours, minutes = divmod(minutes, 60)
    return "{0:02d}:{1:02d}:{2:02d}".format(hours, minutes, seconds)


OUTCOME_KEYS = ("relinked", "already_relinked", "no_substrate", "dest_missing", "errors", "skipped_incomplete")


_OTHER_PC = {"asked": False, "ctx": None}


def _ensure_other_pc():
    """Prompt once (or use OTHER_PC_IP) for the other AZ Prism Central.

    Returns (session, base_url, account_map, ip) or None if declined / no TTY.
    """
    if _OTHER_PC["asked"]:
        return _OTHER_PC["ctx"]
    _OTHER_PC["asked"] = True

    ip = clean_pc_host(os.environ.get("OTHER_PC_IP") or "")
    user = (os.environ.get("OTHER_PC_USER") or os.environ.get("DEST_PC_USER") or "").strip()
    password = os.environ.get("OTHER_PC_PASS") or os.environ.get("DEST_PC_PASS") or ""
    if not ip:
        if not sys.stdin.isatty():
            log.warning(
                "VMs missing on %s; no TTY to ask for the other AZ PC. "
                "Set OTHER_PC_IP or re-run with docker exec -it.",
                DEST_PC_IP,
            )
            return None
        print("Some VMs were not found on {0}.".format(DEST_PC_IP))
        while True:
            raw = input("Other AZ Prism Central IP: ") or ""
            if not raw.strip():
                log.warning("No other AZ PC given; remaining misses stay dest_missing.")
                return None
            ip = clean_pc_host(raw)
            if ip:
                break
            print("Invalid host. Enter an IP or FQDN, for example az02pc01.nvd.local.")
        typed_user = (input("Other AZ username [{0}]: ".format(user)) or "").strip()
        if typed_user:
            user = typed_user
        typed_pass = getpass.getpass("Other AZ password (empty = DEST_PC_PASS): ")
        if typed_pass:
            password = typed_pass

    other_session = pc_session(user, password)
    other_base = "https://{0}:{1}/api/nutanix/v3".format(ip, PC_PORT)
    log.info("Resolving Nutanix account map for %s ...", ip)
    try:
        other_map = get_account_uuid_map(ip)
    except Exception as exc:
        log.warning("%s", exc)
        other_map = {}
    log.info(
        "Looking up missing VMs on other AZ PC %s (GET /vms; progress every %d).",
        ip, 25,
    )
    _OTHER_PC["ctx"] = (other_session, other_base, other_map, ip)
    return _OTHER_PC["ctx"]


def _found_on(outcome, detail, vm_name, app_name, where):
    if DRY_RUN and outcome == "relinked":
        if detail and "account" in detail:
            return outcome, "{0}; found on {1}".format(detail, where), vm_name, app_name
        return outcome, "[DRY RUN] would relink (no write; found on {0})".format(where), vm_name, app_name
    if not detail:
        return outcome, "found on {0}".format(where), vm_name, app_name
    return outcome, "{0}; found on {1}".format(detail, where), vm_name, app_name


def _resolve_one_vm(src_uuid, dest_uuid, dest_session, dest_map, rp_names=None):
    """Dest PC first, then other AZ dest uuid, then src uuid on both. Error only if all miss."""
    rp_hint = (rp_names or {}).get(src_uuid)

    def _pack(outcome, detail, vm_name, app_name):
        return outcome, detail, vm_name or rp_hint, app_name

    outcome, detail, vm_name, app_name = _process_one_vm(
        dest_session, src_uuid, dest_uuid, dest_map, dest_base_url,
    )
    if outcome != "dest_missing":
        return _pack(outcome, detail, vm_name, app_name)

    other = _ensure_other_pc()
    if other:
        other_session, other_base, other_map, other_ip = other
        outcome, detail, vm_name, app_name = _process_one_vm(
            other_session, src_uuid, dest_uuid, other_map, other_base,
        )
        if outcome != "dest_missing":
            return _pack(*_found_on(outcome, detail, vm_name, app_name, other_ip))

    # Dest uuid gone (on dest, and other if given). Try the original src uuid.
    outcome, detail, vm_name, app_name = _process_one_vm(
        dest_session, src_uuid, src_uuid, dest_map, dest_base_url,
    )
    if outcome != "dest_missing":
        note = "dest {0} gone; used src on {1}".format(dest_uuid, DEST_PC_IP)
        if DRY_RUN and outcome == "relinked":
            detail = "[DRY RUN] would relink (no write; {0})".format(note)
        else:
            detail = note
        return _pack(outcome, detail, vm_name, app_name)

    if other:
        other_session, other_base, other_map, other_ip = other
        outcome, detail, vm_name, app_name = _process_one_vm(
            other_session, src_uuid, src_uuid, other_map, other_base,
        )
        if outcome != "dest_missing":
            note = "dest {0} gone; used src on {1}".format(dest_uuid, other_ip)
            if DRY_RUN and outcome == "relinked":
                detail = "[DRY RUN] would relink (no write; {0})".format(note)
            else:
                detail = note
            return _pack(outcome, detail, vm_name, app_name)
        vm_name = vm_name or rp_hint
        label = _entity_label(vm_name, app_name)
        log.error(
            "%s dest=%s src=%s not found on %s or %s",
            label, dest_uuid, src_uuid, DEST_PC_IP, other_ip,
        )
        return (
            "errors",
            "{0}: dest and src not found on {1} or {2}".format(label, DEST_PC_IP, other_ip),
            vm_name, app_name,
        )

    return _pack("dest_missing", "dest and src not on DEST_PC (no other AZ given)", vm_name, app_name)


def update_substrates(session, vm_uuid_map, report, batch_size=100, rp_names=None):
    dest_account_uuid_map = get_account_uuid_map(DEST_PC_IP)
    total = len(vm_uuid_map)
    counters = OrderedDict((key, 0) for key in OUTCOME_KEYS)
    batch_count = max(1, (total + batch_size - 1) // batch_size)
    progress_every = 25
    if DRY_RUN:
        log.info("DRY_RUN=true: classifying only, no substrate writes.")
    log.info(
        "Substrate update: %d VMs in %d batch(es); progress every %d.",
        total, batch_count, progress_every,
    )

    start = time.time()
    done = 0
    for batch_num, batch in enumerate(chunked_iterable(vm_uuid_map.items(), batch_size), 1):
        for src_uuid, dest_uuid in batch:
            outcome, detail, vm_name, app_name = _resolve_one_vm(
                src_uuid, dest_uuid, session, dest_account_uuid_map, rp_names,
            )
            counters[outcome] += 1
            if not vm_name and rp_names:
                vm_name = rp_names.get(src_uuid) or ""
            report.add({
                "src_uuid": src_uuid,
                "dest_uuid": dest_uuid or "",
                "vm_name": vm_name or "",
                "app_name": app_name or "",
                "outcome": outcome,
                "detail": detail,
            })
            done += 1
            if done % progress_every == 0 or done == total:
                elapsed = time.time() - start
                log.info(
                    "%sProgress %d/%d (%d%%, ETA %s): %s",
                    "[DRY RUN] " if DRY_RUN else "",
                    done, total,
                    int(done * 100 / total) if total else 100,
                    _format_eta(elapsed, done, total),
                    " ".join("{0}={1}".format(k, v) for k, v in counters.items()),
                )

        if not DRY_RUN:
            flush_session()
            log.debug("Flushed batch %d/%d.", batch_num, batch_count)

    log.info("Done with %s substrates", "classifying" if DRY_RUN else "updating")
    return counters


def update_app_project(vm_uuid_map):
    from aplos.insights.entity_capability import EntityCapability

    app_names = set()
    app_kind = "app"
    missing_app_uuids = []
    for src_uuid, dest_uuid in vm_uuid_map.items():
        try:
            nse_list = model.NutanixSubstrateElement.query(instance_id=dest_uuid, deleted=False)
            if not nse_list:
                continue
            NSE = nse_list[0]
            try:
                application = model.AppProfileInstance.get_object(NSE.app_profile_instance_reference).application
            except Exception as exc:
                log.warning("Could not find application for AppProfileInstance reference '%s': %s", NSE.app_profile_instance_reference, exc)
                missing_app_uuids.append(NSE.app_profile_instance_reference)
                continue
            app_name = application.name
            app_uuid = application.uuid
            entity_cap = EntityCapability(kind_name=app_kind, kind_id=str(app_uuid))
            if entity_cap.project_name == SRC_PROJECT:
                app_names.add(app_name)
        except Exception as exc:
            log.warning("Error processing src uuid %s: %s", src_uuid, exc)
            continue

    for app_name in app_names:
        if DRY_RUN:
            log.info("[DRY RUN] Would change project for app '%s' to '%s'", app_name, DEST_PROJECT)
        else:
            change_project(app_name, DEST_PROJECT)
    if missing_app_uuids:
        log.warning("The following AppProfileInstance references could not be processed (missing or error): %s", missing_app_uuids)


def list_recovery_plan_jobs(session):
    entities = []
    offset = 0
    total_matches = 1
    while offset < total_matches:
        payload = {"length": PAGE_LENGTH, "offset": offset}
        resp = request_with_retry(
            session, "POST", dest_base_url + "/recovery_plan_jobs/list", data=json.dumps(payload), headers=HEADERS
        )
        if not resp.ok:
            log.warning("Failed to list recovery plan jobs at offset %d: status %s", offset, resp.status_code)
            raise Exception("Failed to get recovery plan jobs list (status {0}).".format(resp.status_code))
        resp_json = resp.json()
        entities.extend(resp_json.get("entities", []))
        total_matches = resp_json.get("metadata", {}).get("total_matches", len(entities))
        offset += PAGE_LENGTH
    return entities


def list_recovery_plans(session):
    entities = []
    offset = 0
    total_matches = 1
    while offset < total_matches:
        payload = {"length": PAGE_LENGTH, "offset": offset}
        resp = request_with_retry(
            session, "POST", dest_base_url + "/recovery_plans/list", data=json.dumps(payload), headers=HEADERS
        )
        if not resp.ok:
            log.warning("Failed to list recovery plans at offset %d: status %s", offset, resp.status_code)
            raise Exception("Failed to get recovery plans list (status {0}).".format(resp.status_code))
        resp_json = resp.json()
        entities.extend(resp_json.get("entities", []))
        total_matches = resp_json.get("metadata", {}).get("total_matches", len(entities))
        offset += PAGE_LENGTH
    return entities


def _plans_for_wizard(plan_entities):
    plans = []
    for entity in plan_entities:
        uuid = (entity.get("metadata") or {}).get("uuid")
        if not uuid:
            continue
        name = (entity.get("status") or {}).get("name") or (entity.get("spec") or {}).get("name") or uuid
        plans.append({"uuid": uuid, "name": name})
    plans.sort(key=lambda p: (p["name"] or "").lower())
    plan_name = os.environ.get("RP_PLAN_NAME")
    if plan_name:
        wanted = set(n.strip() for n in plan_name.split(",") if n.strip())
        plans = [p for p in plans if p["name"] in wanted]
    return plans


def _select_jobs_for_scope(session, scope):
    """Return (listed_count, selected_job_entities). Wizard runs for scope=prompt."""
    if scope == "prompt":
        plans = _plans_for_wizard(list_recovery_plans(session))
        if not plans:
            raise Exception("No recovery plans found on destination Prism Central '{0}'.".format(DEST_PC_IP))
        job_entities = list_recovery_plan_jobs(session)
        jobs_by_plan = {}
        for plan in plans:
            jobs_by_plan[plan["uuid"]] = unplanned_failover_jobs(job_entities, plan["uuid"])
        needs_prompt = len(plans) > 1 or any(
            len(jobs_by_plan.get(plan["uuid"]) or []) > 1 for plan in plans
        )
        if needs_prompt and not sys.stdin.isatty():
            raise SystemExit(
                "RP_JOB_SCOPE=prompt needs an interactive TTY (docker exec -it nucalm bash). "
                "Set RP_JOB_SCOPE=latest_per_plan (or all / job) for non-interactive runs. "
                "No destination writes were made."
            )
        selected = prompt_recovery_plan_selection(plans, jobs_by_plan, dest_pc_ip=DEST_PC_IP)
        return len(job_entities), selected

    entities = list_recovery_plan_jobs(session)
    selected = select_recovery_plan_jobs(
        entities,
        scope=scope,
        plan_name=os.environ.get("RP_PLAN_NAME"),
        job_uuid_filter=os.environ.get("RP_JOB_UUID"),
    )
    return len(entities), selected


def get_recovery_plan_job_execution_status(session, rp_job_uuid):
    resp = request_with_retry(
        session, "GET", dest_base_url + "/recovery_plan_jobs/{0}/execution_status".format(rp_job_uuid), headers=HEADERS
    )
    if not resp.ok:
        log.warning("Failed to get execution_status for job %s: status %s", rp_job_uuid, resp.status_code)
        raise Exception("Failed to get recovery plan job {0} execution status (status {1}).".format(rp_job_uuid, resp.status_code))
    return resp.json()


def main():
    start_time = time.strftime('%Y-%m-%d %H:%M:%S')
    start = time.time()

    session = pc_session(os.environ['DEST_PC_USER'], os.environ['DEST_PC_PASS'])
    report = RunReport("post-migration", ["src_uuid", "dest_uuid", "vm_name", "app_name", "outcome", "detail"])
    print_header(report.path)

    counters = OrderedDict((key, 0) for key in OUTCOME_KEYS)
    listed_count = 0
    selected_count = 0
    mapping_count = 0
    skipped_count = 0
    self_mapped_count = 0

    try:
        preflight()
        init_contexts()

        listed_count, selected = _select_jobs_for_scope(
            session, (os.environ.get("RP_JOB_SCOPE") or "prompt").strip().lower() or "prompt"
        )
        selected_count = len(selected)

        execution_statuses = [get_recovery_plan_job_execution_status(session, job_uuid(e)) for e in selected]
        vm_uuid_map, skipped_count, rp_names = merge_entity_recovery_map(execution_statuses)
        mapping_count = len(vm_uuid_map)
        self_mapped_count = count_self_mapped(vm_uuid_map)
        log.info("Built %d src->dest VM mapping(s) (%d skipped: incomplete step data).", mapping_count, skipped_count)
        if self_mapped_count:
            log.info(
                "%d mapping(s) have dest_uuid == src_uuid (stale completed job, not this failover).",
                self_mapped_count,
            )

        if vm_uuid_map:
            counters = update_substrates(session, vm_uuid_map, report, rp_names=rp_names)

        if UPDATE_APP_PROJECT:
            update_app_project(vm_uuid_map)
    except Exception as exc:
        log.error("post-migration-script failed: %s", exc)
        raise
    finally:
        report_path = report.write()
        stats = OrderedDict()
        stats["start / end / elapsed"] = "{0} / {1} / {2:.0f}s".format(
            start_time, time.strftime('%Y-%m-%d %H:%M:%S'), time.time() - start
        )
        stats["rp jobs listed / selected"] = "{0} / {1}".format(listed_count, selected_count)
        stats["mappings built / skipped"] = "{0} / {1}".format(mapping_count, skipped_count)
        stats["relinked (would write; DRY_RUN)" if DRY_RUN else "relinked (substrate written)"] = counters["relinked"]
        stats["already relinked (idempotent skip)"] = counters["already_relinked"]
        stats["no matching substrate (not a Self-Service VM)"] = counters["no_substrate"]
        stats["dest VM not on DEST_PC (stale mapping)"] = counters["dest_missing"]
        stats["skipped (incomplete mapping)"] = counters["skipped_incomplete"]
        stats["errors"] = counters["errors"]
        stats["report written to"] = report_path or "(not written)"
        print_summary("Summary (DRY_RUN, no writes)" if DRY_RUN else "Summary", stats)


if __name__ == "__main__":
    main()
