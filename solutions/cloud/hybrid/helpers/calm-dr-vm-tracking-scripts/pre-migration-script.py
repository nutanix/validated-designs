#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Recreate categories at the destination PC from live apps in SOURCE_PROJECT_NAME.

See README.md / WORKFLOW.md for when to run this.
"""

import os
import json
import time
from collections import OrderedDict
from urllib.parse import quote

# Import helper before other calm modules: it sets APLOS_CONFIG and
# installs logging handlers before calm/aplos start talking.
from helper import (
    init_contexts,
    log,
    DRY_RUN,
    insecure,
    pc_session,
    request_with_retry,
    RunReport,
    require_env,
    preflight,
    print_summary,
)
from calm.common.flags import gflags  # noqa: F401  -- see helper.py for why this stays
from calm.lib.model.store.idf.db import get_insights_db
from calm.lib.proto import AbacEntityCapability
from calm.common.project_util import ProjectUtil
import calm.lib.model as model

require_env(['DEST_PC_IP', 'DEST_PC_USER', 'DEST_PC_PASS', 'SOURCE_PROJECT_NAME'])

dest_categorie_map = {}

DEST_PC_IP = os.environ['DEST_PC_IP']
PC_PORT = 9440
DELETED_STATES = ('deleted', 'deleting')
NUTANIX_VM = 'AHV_VM'
SOURCE_PROJECT = os.environ['SOURCE_PROJECT_NAME']
# "auto" tries the IDF deleted=False filter and falls back to the legacy
# unfiltered query on error or on a suspicious empty result. "none" forces
# the legacy path -- use this if the filter's behavior on a given NCM Self-Service
# version is ever in doubt.
APP_FILTER = os.environ.get("APP_FILTER", "auto").lower()

dest_base_url = "https://{0}:{1}/api/nutanix/v3".format(DEST_PC_IP, PC_PORT)
session = pc_session(os.environ['DEST_PC_USER'], os.environ['DEST_PC_PASS'])

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
PAGE_LENGTH = 100


def _log_failed_response(action, resp):
    log.warning("Failed to %s. Status: %s", action, resp.status_code)
    try:
        log.debug("Response body: %s", json.dumps(resp.json(), indent=2))
    except ValueError:
        log.debug("Response body (not JSON): %s", resp.text)


def _category_get(url, action):
    """True if the category key exists on dest PC, False on 404."""
    resp = request_with_retry(session, "GET", url, headers=headers)
    if resp.ok:
        return True
    if resp.status_code == 404:
        return False
    _log_failed_response(action, resp)
    raise Exception("Failed to {0} (status {1}).".format(action, resp.status_code))


def list_category_values(key):
    """Values already on dest PC for this key. Empty if the key does not exist."""
    values = []
    offset = 0
    url = dest_base_url + "/categories/{0}/list".format(quote(key, safe=""))
    while True:
        payload = {"kind": "category", "length": PAGE_LENGTH, "offset": offset}
        resp = request_with_retry(session, "POST", url, data=json.dumps(payload), headers=headers)
        if resp.status_code == 404:
            return values
        if not resp.ok:
            _log_failed_response("list category values for '{0}'".format(key), resp)
            raise Exception(
                "Failed to list category values for '{0}' (status {1}).".format(key, resp.status_code)
            )
        body = resp.json()
        entities = body.get("entities") or []
        for entity in entities:
            value = entity.get("value") if isinstance(entity, dict) else None
            if value:
                values.append(value)
        total_matches = (body.get("metadata") or {}).get("total_matches")
        offset += len(entities)
        if not entities:
            break
        if total_matches is not None and offset >= total_matches:
            break
        if len(entities) < PAGE_LENGTH:
            break
    return values


def create_category_key(key):
    """Create the key on dest PC if missing. True if created, False if already there."""
    url = dest_base_url + "/categories/{0}".format(quote(key, safe=""))
    if _category_get(url, "get category key '{0}'".format(key)):
        return False
    if DRY_RUN:
        log.info("[DRY RUN] Would create category key '%s'", key)
        return True
    resp = request_with_retry(session, "PUT", url, data=json.dumps({"name": key}), headers=headers)
    if resp.ok:
        log.info("Created category key '%s'.", key)
        return True
    _log_failed_response("create category key '{0}'".format(key), resp)
    raise Exception("Failed to create category key '{0}'.".format(key))


def create_category_value(key, value):
    """PUT a value that dest PC does not already have (caller checked the dest list)."""
    url = dest_base_url + "/categories/{0}/{1}".format(quote(key, safe=""), quote(value, safe=""))
    if DRY_RUN:
        log.info("[DRY RUN] Would create category value '%s' for key '%s'", value, key)
        return True
    resp = request_with_retry(session, "PUT", url, data=json.dumps({"value": value, "description": ""}), headers=headers)
    if resp.ok:
        return True
    _log_failed_response("create category value '{0}' for key '{1}'".format(value, key), resp)
    raise Exception("Failed to create category value '{0}' for key '{1}'.".format(value, key))


def get_application_uuids(project_name):
    project_handle = ProjectUtil()
    project_proto = project_handle.get_project_by_name(project_name)
    if not project_proto:
        raise Exception("No project in system with name '{0}'".format(project_name))
    project_uuid = str(project_proto.uuid)
    db_handle = get_insights_db()

    def _unfiltered():
        applications = db_handle.fetch_many(
            AbacEntityCapability, kind="app", project_reference=project_uuid,
            select=['kind_id', '_created_timestamp_usecs_'],
        )
        return [application[1][0] for application in applications]

    if APP_FILTER == "none":
        log.info("APP_FILTER=none: using legacy unfiltered query.")
        return _unfiltered()

    try:
        applications = db_handle.fetch_many(
            AbacEntityCapability, kind="app", project_reference=project_uuid, deleted=False,
            select=['kind_id', '_created_timestamp_usecs_'],
        )
        filtered_uuids = [application[1][0] for application in applications]
    except Exception as exc:
        log.warning("IDF deleted=False filter raised %s; falling back to legacy unfiltered query.", exc)
        return _unfiltered()

    unfiltered_uuids = _unfiltered()
    if filtered_uuids or not unfiltered_uuids:
        log.info("Using IDF deleted=False filter (%d app(s)).", len(filtered_uuids))
        return filtered_uuids

    log.info(
        "IDF deleted=False filter returned 0 of %d row(s); treating that as unverified and "
        "falling back to the legacy unfiltered query.",
        len(unfiltered_uuids),
    )
    return unfiltered_uuids


def create_categories(report):
    log.info("Creating categories/values")
    init_contexts()
    application_uuid_list = get_application_uuids(SOURCE_PROJECT)
    total = len(application_uuid_list)
    log.info("Retrieved %d application UUID(s) from project '%s'.", total, SOURCE_PROJECT)

    counters = OrderedDict([
        ("live_scanned", 0), ("deleted_skipped", 0), ("missing", 0),
        ("keys_created", 0), ("values_created", 0), ("values_present", 0), ("errors", 0),
    ])

    for idx, app_uuid in enumerate(application_uuid_list, start=1):
        log.debug("Processing application %d of %d: UUID %s", idx, total, app_uuid)
        try:
            application = model.Application.get_object(app_uuid)
        except Exception as exc:
            log.debug("Could not load application %s: %s", app_uuid, exc)
            application = None

        if not application:
            counters["missing"] += 1
            report.add({"app_uuid": app_uuid, "app_name": "", "outcome": "missing", "categories_created": 0, "detail": ""})
            continue

        if getattr(application, "deleted", False) or str(getattr(application, "state", "")).lower() in DELETED_STATES:
            counters["deleted_skipped"] += 1
            continue

        counters["live_scanned"] += 1
        if counters["live_scanned"] % 100 == 0:
            log.info(
                "Live apps scanned %d/%d (deleted skipped %d).",
                counters["live_scanned"], total, counters["deleted_skipped"],
            )

        app_name = getattr(application, "name", "")
        created_here = 0
        try:
            for dep in application.active_app_profile_instance.deployments:
                if dep.substrate.type != NUTANIX_VM:
                    continue
                for element in dep.substrate.elements:
                    if not element.spec.categories:
                        continue
                    try:
                        categories = json.loads(element.spec.categories)
                    except (ValueError, TypeError) as exc:
                        log.warning("App %s has unparseable categories on a substrate element: %s", app_uuid, exc)
                        continue
                    for key, value in categories.items():
                        if key not in dest_categorie_map:
                            existing = list_category_values(key)
                            dest_categorie_map[key] = existing
                            if existing:
                                log.info(
                                    "Dest PC already has %d value(s) for '%s'.",
                                    len(existing), key,
                                )
                            if key not in SYS_DEFINED_CATEGORY_KEY_LIST:
                                try:
                                    if create_category_key(key):
                                        counters["keys_created"] += 1
                                        created_here += 1
                                except Exception as exc:
                                    log.error("Failed to create category key %s: %s", key, exc)
                                    counters["errors"] += 1
                        if value not in dest_categorie_map[key]:
                            dest_categorie_map[key].append(value)
                            try:
                                if create_category_value(key, value):
                                    counters["values_created"] += 1
                                    created_here += 1
                                    log.info("Created category %s=%s", key, value)
                            except Exception as exc:
                                log.error("Failed to create category value %s for key %s: %s", value, key, exc)
                                counters["errors"] += 1
                        else:
                            counters["values_present"] += 1
            report.add({
                "app_uuid": app_uuid, "app_name": app_name, "outcome": "ok",
                "categories_created": created_here, "detail": "",
            })
        except Exception as exc:
            log.warning("Could not process application '%s' (%s): %s", app_name, app_uuid, exc)
            counters["errors"] += 1
            report.add({
                "app_uuid": app_uuid, "app_name": app_name, "outcome": "error",
                "categories_created": created_here, "detail": str(exc),
            })

    log.info(
        "Live apps scanned %d/%d (deleted skipped %d).",
        counters["live_scanned"], total, counters["deleted_skipped"],
    )
    log.info("Done with creating categories and values")
    return total, counters


def print_header(report_path):
    print("=" * 60)
    print("  NCM Self-Service (Calm) Pre-Migration Script")
    print("  dest PC:        {0}:{1}".format(DEST_PC_IP, PC_PORT))
    print("  source project: {0}".format(SOURCE_PROJECT))
    print("  dry_run:        {0}".format(str(DRY_RUN).lower()))
    print("  insecure:       {0}".format(str(insecure()).lower()))
    print("  app_filter:     {0}".format(APP_FILTER))
    print("  report:         {0}".format(report_path))
    print("  Timestamp:      {0}".format(time.strftime('%Y-%m-%d %H:%M:%S')))
    print("=" * 60)


def main():
    start_time = time.strftime('%Y-%m-%d %H:%M:%S')
    start = time.time()
    total = 0
    counters = OrderedDict([
        ("live_scanned", 0), ("deleted_skipped", 0), ("missing", 0),
        ("keys_created", 0), ("values_created", 0), ("values_present", 0), ("errors", 0),
    ])
    report = RunReport("pre-migration", ["app_uuid", "app_name", "outcome", "categories_created", "detail"])
    report_path = None
    try:
        preflight()
        print_header(report.path)
        total, counters = create_categories(report)
    except Exception as exc:
        log.error("pre-migration-script failed: %s", exc)
        raise
    finally:
        report_path = report.write()
        stats = OrderedDict()
        stats["start / end / elapsed"] = "{0} / {1} / {2:.0f}s".format(
            start_time, time.strftime('%Y-%m-%d %H:%M:%S'), time.time() - start
        )
        stats["inventory (Abac app rows)"] = total
        stats["live apps walked"] = counters["live_scanned"]
        stats["deleted / skipped"] = counters["deleted_skipped"]
        stats["missing"] = counters["missing"]
        stats["category keys created"] = counters["keys_created"]
        stats["category values created"] = counters["values_created"]
        stats["values already present"] = counters["values_present"]
        stats["errors"] = counters["errors"]
        stats["report written to"] = report_path or "(not written)"
        print_summary("Summary", stats)


if __name__ == '__main__':
    main()
