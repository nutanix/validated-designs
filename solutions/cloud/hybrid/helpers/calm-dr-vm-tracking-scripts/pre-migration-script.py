#!/usr/bin/env python
# -*- coding: utf-8 -*-

import os
import requests
import json
import time

from calm.common.flags import gflags
from helper import init_contexts, log, DRY_RUN
from calm.lib.model.store.idf.db import get_insights_db
from calm.lib.proto import AbacEntityCapability
from calm.common.project_util import ProjectUtil
import calm.lib.model as model

# Validate environment variables
required_env = ['DEST_PC_IP', 'DEST_PC_USER', 'DEST_PC_PASS', 'SOURCE_PROJECT_NAME']
missing_env = [var for var in required_env if var not in os.environ]
if missing_env:
    raise Exception(f"Please export required environment variables: {', '.join(missing_env)}")

dest_categorie_map = {}

DEST_PC_IP = os.environ['DEST_PC_IP']
PC_PORT = 9440
LENGTH = 100
DELETED_STATE = 'deleted'
NUTANIX_VM = 'AHV_VM'
SOURCE_PROJECT = os.environ['SOURCE_PROJECT_NAME']

dest_base_url = "https://{}:{}/api/nutanix/v3".format(DEST_PC_IP, str(PC_PORT))
dest_pc_auth = {"username": os.environ['DEST_PC_USER'], "password": os.environ['DEST_PC_PASS']}

SYS_DEFINED_CATEGORY_KEY_LIST = [
    "ADGroup",
    "AnalyticsExclusions",
    "AppFamily",
    "AppTier",
    "AppType",
    "CalmApplication",
    "CalmClusterUuid",
    "CalmDeployment",
    "CalmPackage",
    "CalmProject",
    "CalmService",
    "CalmUsername",
    "Environment",
    "OSType",
    "Quaratine",
    "CalmVmUniqueIdentifier",
    "CalmUser",
    "account_uuid",
    "SharedService",
    "Storage",
    "TemplateType",
    "VirtualNetworkType"
]

headers = {'content-type': 'application/json', 'Accept': 'application/json'}

def create_category_key(base_url, auth, key):
    if DRY_RUN:
        log.info("[DRY RUN] Would create category key '%s'", key)
        return True
    method = 'PUT'
    url = base_url + "/categories/{}".format(key)
    payload = {
        "name": key
    }
    resp = requests.request(
        method,
        url,
        data=json.dumps(payload),
        headers=headers,
        auth=(auth["username"], auth["password"]),
        verify=False
    )
    if resp.ok:
        log.info(f"Successfully created category key '{key}'.")
        return True
    else:
        log.warning("Failed to create category key '{}'.".format(key))
        log.warning('Status code: {}'.format(resp.status_code))
        log.warning('Response: {}'.format(json.dumps(json.loads(resp.content), indent=4)))
        raise Exception("Failed to create category key '{}'.".format(key))

def is_category_key_present(base_url, auth, key):
    method = 'GET'
    url = base_url + "/categories/{}".format(key)
    resp = requests.request(
        method,
        url,
        headers=headers,
        auth=(auth["username"], auth["password"]),
        verify=False
    )
    if resp.ok:
        return True
    else:
        return False

def create_category_value(base_url, auth, key, value):
    if DRY_RUN:
        log.info("[DRY RUN] Would create category value '%s' for key '%s'", value, key)
        return True
    method = 'PUT'
    url = base_url + "/categories/{}/{}".format(key, value)
    payload = {
        "value": value,
        "description": ""
    }
    resp = requests.request(
        method,
        url,
        data=json.dumps(payload),
        headers=headers,
        auth=(auth["username"], auth["password"]),
        verify=False
    )
    if resp.ok:
        log.info(f"Successfully created category value '{value}' for key '{key}'.")
        return True
    else:
        log.warning("Failed to create category value '{}' for key '{}'.".format(value, key))
        log.warning('Status code: {}'.format(resp.status_code))
        log.warning('Response: {}'.format(json.dumps(json.loads(resp.content), indent=4)))
        raise Exception("Failed to create category value '{}' for key '{}'.".format(value, key))

def get_application_uuids(project_name):
    project_handle = ProjectUtil()
    project_proto = project_handle.get_project_by_name(project_name)
    if not project_proto:
        raise Exception("No project in system with name '{}'".format(project_name))
    project_uuid = str(project_proto.uuid)
    application_uuid_list = []
    db_handle = get_insights_db()
    applications = db_handle.fetch_many(AbacEntityCapability,kind="app",project_reference=project_uuid,select=['kind_id', '_created_timestamp_usecs_'])
    for application in applications:
        application_uuid_list.append(application[1][0])
    return application_uuid_list

def create_categories():
    log.info("Creating categories/values")
    init_contexts()
    application_uuid_list = get_application_uuids(SOURCE_PROJECT)
    log.info("Retrieved %d application UUIDs from project '%s'", len(application_uuid_list), SOURCE_PROJECT)
    missing_uuids = []
    processed = 0
    for idx, app_uuid in enumerate(application_uuid_list, start=1):
        log.info("Processing application %d of %d: UUID %s", idx, len(application_uuid_list), app_uuid)
        processed += 1
        try:
            application = model.Application.get_object(app_uuid)
            if not application:
                log.warning("Application with UUID %s does not exist.", app_uuid)
                missing_uuids.append(app_uuid)
                continue
            if application.state != DELETED_STATE:
                for dep in application.active_app_profile_instance.deployments:
                    if dep.substrate.type == NUTANIX_VM:
                        for element in dep.substrate.elements:
                            if element.spec.categories != "":
                                category = json.loads(element.spec.categories)
                                for key in category.keys():
                                    value = category[key]
                                    if key not in dest_categorie_map.keys():
                                        dest_categorie_map[key] = []
                                        if key not in SYS_DEFINED_CATEGORY_KEY_LIST:
                                            if DRY_RUN:
                                                log.info("[DRY RUN] Would create category key '%s'", key)
                                            else:
                                                log.info("Category with key %s not present on pc, creating one", key)
                                                try:
                                                    create_category_key(dest_base_url, dest_pc_auth, key)
                                                except Exception as e:
                                                    log.error("Failed to create category key %s: %s", key, e)
                                    if value not in dest_categorie_map[key]:
                                        dest_categorie_map[key].append(value)
                                        if DRY_RUN:
                                            log.info("[DRY RUN] Would create category value '%s' for key '%s'", value, key)
                                        else:
                                            log.info("Creating key: %s - value: %s", key, value)
                                            try:
                                                create_category_value(dest_base_url, dest_pc_auth, key, value)
                                            except Exception as e:
                                                log.error("Failed to create category value %s for key %s: %s", value, key, e)
            else:
                log.info("Application %s is in deleted state, skipping.", app_uuid)
        except Exception as e:
            log.warning("Could not process application UUID %s: %s", app_uuid, e)
            missing_uuids.append(app_uuid)
            continue
    if missing_uuids:
        log.warning("The following application UUIDs could not be processed (missing or error): %s", missing_uuids)
    log.info("Done with creating categories and values")
    return processed

def print_header():
    print("="*60)
    print("      NCM Self-Service Pre-Migration Script Started")
    print(f"      Timestamp: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print("="*60)

def main():
    start_time = time.strftime('%Y-%m-%d %H:%M:%S')
    try:
        print_header()
        #create_categories()
        processed = create_categories()
    except Exception as e:
        log.error("Exception: %s", e)
        raise
    end_time = time.strftime('%Y-%m-%d %H:%M:%S')
    print("="*60)
    print("Summary:")
    print(f"  Start time: {start_time}")
    print(f"  End time:   {end_time}")
    print(f"  Total Apps processed:    {processed}")
    print("="*60)

if __name__ == '__main__':
    main()
