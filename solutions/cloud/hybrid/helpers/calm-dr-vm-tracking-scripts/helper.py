# -*- coding: utf-8 -*-
"""Shared runtime helpers for the NCM Self-Service (Calm) DR VM-tracking scripts."""

# Stdlib only up to the `import calm` / `import aplos` block below. calm and
# aplos configure logging (and, on some versions, call logging.basicConfig())
# as a side effect of being imported, and basicConfig() is a no-op once the
# root logger already has a handler. So configure_logging() must run, and
# install its handlers, before those imports happen -- that ordering is what
# keeps the console quiet without losing anything to the log file.
import os
import sys
import csv
import time
import socket
import logging
import warnings
from collections import OrderedDict

# Aplos defaults to a PCVM path that does not exist inside nucalm. The
# file is bind-mounted at /home/calm/conf/aplos.cfg and AplosConfig honors
# APLOS_CONFIG. Set it before any calm/aplos import or the first import
# logs a console ERROR and the singleton keeps the failed read.
def _ensure_aplos_config():
    if os.environ.get("APLOS_CONFIG"):
        return
    candidate = "/home/calm/conf/aplos.cfg"
    if os.path.isfile(candidate):
        os.environ["APLOS_CONFIG"] = candidate


_ensure_aplos_config()

NOISY_LOGGER_NAMES = [
    "urllib3", "requests", "calm", "aplos", "session", "idf_session",
    "db_interface_client_sets", "db_interface", "domain_manager_interface",
    "calm_project_util", "config",
]

LOG_FILE_PATH = None
_FILE_HANDLER = None


def _script_name():
    base = os.path.basename(sys.argv[0] or "helper")
    if base.endswith(".py"):
        base = base[:-3]
    return base or "helper"


def configure_logging():
    """Install root + 'eylog' handlers. Must run before calm/aplos import.

    Console stays quiet at LOG_LEVEL (default INFO); the log file always
    gets everything at DEBUG. LOG_LEVEL=DEBUG restores full console chatter.
    Never fatal: if LOG_DIR is not writable, log a warning and continue
    console-only.
    """
    global LOG_FILE_PATH, _FILE_HANDLER

    log_level_name = os.environ.get("LOG_LEVEL", "INFO").upper()
    console_level = getattr(logging, log_level_name, logging.INFO)

    try:
        warnings.filterwarnings("ignore", category=FutureWarning)
        warnings.filterwarnings("ignore", category=UserWarning)
    except Exception:
        pass
    try:
        import urllib3
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    except Exception:
        pass
    try:
        from cryptography.utils import CryptographyDeprecationWarning
        warnings.filterwarnings("ignore", category=CryptographyDeprecationWarning)
    except Exception:
        pass

    root = logging.getLogger()
    root.setLevel(logging.DEBUG)

    console_handler = logging.StreamHandler(sys.stdout)
    # Third-party loggers (calm, aplos, urllib3, idf_session, ...) propagate
    # here. Quiet for them at the default LOG_LEVEL; DEBUG detail is always
    # captured by the file handler below regardless. LOG_LEVEL=DEBUG is the
    # one setting that restores full console chatter, per the compatibility
    # contract, so only that value lowers this handler below WARNING.
    console_handler.setLevel(logging.DEBUG if console_level <= logging.DEBUG else logging.WARNING)
    console_handler.setFormatter(logging.Formatter("[%(levelname)s] %(name)s: %(message)s"))
    root.addHandler(console_handler)

    log_dir = os.environ.get("LOG_DIR", "/tmp")
    try:
        if not os.path.isdir(log_dir):
            os.makedirs(log_dir)
        log_path = os.path.join(log_dir, "{0}-{1}.log".format(_script_name(), time.strftime("%Y%m%d-%H%M%S")))
        file_handler = logging.FileHandler(log_path)
        file_handler.setLevel(logging.DEBUG)
        file_handler.setFormatter(
            logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
        )
        root.addHandler(file_handler)
        _FILE_HANDLER = file_handler
        LOG_FILE_PATH = log_path
    except Exception as exc:
        logging.getLogger("eylog").warning(
            "Could not create a log file under LOG_DIR=%s (%s); continuing console-only.", log_dir, exc
        )

    eylog = logging.getLogger("eylog")
    eylog.setLevel(logging.DEBUG)
    eylog.propagate = False
    if eylog.hasHandlers():
        eylog.handlers.clear()
    # Today the banner is print()ed to stdout while logging goes to stderr,
    # so `python post-migration-script.py > run.log` silently drops every
    # log line. Move eylog's console handler to stdout to fix that.
    eylog_console = logging.StreamHandler(sys.stdout)
    eylog_console.setLevel(console_level)
    eylog_console.setFormatter(
        logging.Formatter("[%(levelname)s] %(asctime)s.%(msecs)03d - %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
    )
    eylog.addHandler(eylog_console)
    if _FILE_HANDLER is not None:
        eylog.addHandler(_FILE_HANDLER)

    return eylog


log = configure_logging()

DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"


def insecure():
    """Skip TLS verify when INSECURE is true (the default).

    Unset matches the original scripts (verify=False). INSECURE=false
    verifies Prism Central certificates. Re-read on every call so tests
    can toggle the env without reimporting helper.
    """
    return os.environ.get("INSECURE", "true").lower() == "true"


def tls_verify():
    return not insecure()


def clean_pc_host(text):
    """Turn a pasted IP/FQDN into a URL-safe hostname. Drops surrogate-escaped
    bytes from a mismatched terminal locale (the \\udcc2 prefix that breaks
    requests). Empty string if nothing usable remains. Never raises."""
    if not text:
        return ""
    try:
        text = text.encode("utf-8", "surrogateescape").decode("utf-8", "ignore")
    except Exception:
        try:
            text = "".join(c for c in text if ord(c) < 128)
        except Exception:
            return ""
    text = text.strip().strip("\ufeff")
    if "://" in text:
        text = text.split("://", 1)[-1]
    text = text.split("/")[0]
    parts = text.split(":")
    if len(parts) == 2 and parts[1].isdigit():
        text = parts[0]
    return "".join(c for c in text if c.isalnum() or c in ".-")


# ---------------------------------------------------------------------------
# Task 4: recovery-plan job selection. Pure, stdlib-only, no calm import, so
# tests can reach them with calm/aplos stubbed into sys.modules.
# ---------------------------------------------------------------------------

USABLE_ACTION_TYPES = ("MIGRATE", "FAILOVER")
USABLE_STATUSES = ("COMPLETED", "COMPLETED_WITH_WARNING")


def is_usable_job(entity):
    """True for a completed MIGRATE/FAILOVER recovery-plan job. Never raises."""
    try:
        action_type = entity["status"]["resources"]["execution_parameters"]["action_type"]
        status = entity["status"]["execution_status"]["status"]
    except (KeyError, TypeError):
        return False
    return action_type in USABLE_ACTION_TYPES and status in USABLE_STATUSES


def job_sort_key(entity):
    """Best available "when did this run" key, oldest-sortable first. Never raises."""
    try:
        status = entity.get("status") or {}
        execution_status = status.get("execution_status") or {}
        metadata = entity.get("metadata") or {}
        return (
            execution_status.get("end_time")
            or execution_status.get("start_time")
            or metadata.get("last_update_time")
            or metadata.get("creation_time")
            or ""
        )
    except AttributeError:
        return ""


def _recovery_plan_reference(entity):
    """The recovery_plan_reference dict from status.resources or
    spec.resources ({} if absent). A v3-style reference carries both `uuid`
    and `name`, so plan_uuid() and job_plan_name() share this lookup.

    The payload shape is unverified against a live capture (response bodies
    were not logged). Callers using this for latest_per_plan grouping must
    treat a missing uuid specially rather than silently degenerating to `all`.
    """
    for section in ("status", "spec"):
        try:
            resources = (entity.get(section) or {}).get("resources") or {}
            ref = resources.get("recovery_plan_reference")
            if ref:
                return ref
        except AttributeError:
            continue
    return {}


def plan_uuid(entity):
    return _recovery_plan_reference(entity).get("uuid")


def job_uuid(entity):
    try:
        return entity["metadata"]["uuid"]
    except (KeyError, TypeError):
        return None


def job_plan_name(entity):
    return _recovery_plan_reference(entity).get("name")


def job_action_and_status(entity):
    try:
        resources = entity["status"]["resources"]
        return (
            resources.get("execution_parameters", {}).get("action_type"),
            entity["status"]["execution_status"].get("status"),
        )
    except (KeyError, TypeError):
        return None, None


def select_recovery_plan_jobs(entities, scope="all", plan_name=None, job_uuid_filter=None):
    """Filter+select usable recovery-plan jobs per RP_JOB_SCOPE.

    scope: "all" (every completed MIGRATE/FAILOVER job), "latest_per_plan"
    (newest completed FAILOVER job per plan; MIGRATE excluded), or "job"
    (requires job_uuid_filter).
    plan_name: optional comma-separated list of plan names to restrict to.
    """
    usable = [e for e in entities if is_usable_job(e)]

    if plan_name:
        wanted = set(n.strip() for n in plan_name.split(",") if n.strip())
        usable = [e for e in usable if job_plan_name(e) in wanted]

    if scope == "job":
        if not job_uuid_filter:
            raise ValueError("RP_JOB_SCOPE=job requires RP_JOB_UUID to be set.")
        selected = [e for e in usable if job_uuid(e) == job_uuid_filter]
    elif scope == "latest_per_plan":
        failover = [e for e in usable if job_action_and_status(e)[0] == "FAILOVER"]
        by_plan = OrderedDict()
        for entity in sorted(failover, key=job_sort_key):
            key = plan_uuid(entity)
            if key is None:
                log.warning(
                    "Job %s has no recovery_plan_reference; cannot group it by plan for "
                    "latest_per_plan, keeping it as its own group.",
                    job_uuid(entity),
                )
                key = ("__no_plan_ref__", job_uuid(entity))
            by_plan[key] = entity  # ascending sort => last write is the latest
        selected = list(by_plan.values())
    else:
        selected = usable

    log.info(
        "Listed %d completed MIGRATE/FAILOVER job(s); selected %d (scope=%s).",
        len(usable), len(selected), scope,
    )
    for entity in selected:
        action_type, status = job_action_and_status(entity)
        log.info(
            "  job=%s plan='%s' action=%s status=%s",
            job_uuid(entity), job_plan_name(entity), action_type, status,
        )
    return selected


def parse_plan_selection(text, count):
    """Parse a plan-picker line into 1-based indexes. Duplicates dropped, order kept."""
    stripped = (text or "").strip()
    if not stripped:
        raise ValueError("empty selection")
    if stripped.lower() == "all":
        return tuple(range(1, count + 1))
    seen = set()
    indexes = []
    for part in stripped.split(","):
        token = part.strip()
        try:
            index = int(token)
        except (TypeError, ValueError):
            raise ValueError("invalid plan selection")
        if index < 1 or index > count:
            raise ValueError("plan index out of range")
        if index not in seen:
            seen.add(index)
            indexes.append(index)
    if not indexes:
        raise ValueError("empty selection")
    return tuple(indexes)


def parse_job_selection(text, count):
    """Parse a job-picker line. Empty input means 1 (newest)."""
    stripped = (text or "").strip()
    if not stripped:
        return 1
    try:
        index = int(stripped)
    except (TypeError, ValueError):
        raise ValueError("invalid job selection")
    if index < 1 or index > count:
        raise ValueError("job index out of range")
    return index


def unplanned_failover_jobs(entities, plan_uuid):
    """Completed FAILOVER jobs for one plan, newest first.

    The plan_uuid argument shadows the accessor of the same name; the plan
    is read via _recovery_plan_reference.
    """
    matched = []
    for entity in entities:
        if _recovery_plan_reference(entity).get("uuid") != plan_uuid:
            continue
        action_type, status = job_action_and_status(entity)
        if action_type == "FAILOVER" and status in USABLE_STATUSES:
            matched.append(entity)
    matched.sort(key=job_sort_key, reverse=True)
    return matched


def _job_time_label(entity):
    key = job_sort_key(entity) or "-"
    return key.replace("T", " ").replace("Z", "")[:16]


def prompt_recovery_plan_selection(plans, jobs_by_plan, input_fn=None, dest_pc_ip=""):
    """TTY wizard: pick plans, then exactly one unplanned-failover job per plan.

    A single plan or a single job is auto-selected (no prompt). input_fn
    defaults to builtin input (not called at import). dest_pc_ip is only
    used in the listing header.
    """
    if input_fn is None:
        input_fn = input
    if not plans:
        raise Exception("No recovery plans found on the destination Prism Central.")

    jobs_by_plan = jobs_by_plan or {}
    if len(plans) == 1:
        selected_indexes = (1,)
        print("Recovery plan '{0}' on {1} (only plan; selected).".format(
            plans[0]["name"], dest_pc_ip or "destination Prism Central",
        ))
    else:
        while True:
            print("Recovery plans on {0}:".format(dest_pc_ip or "destination Prism Central"))
            for i, plan in enumerate(plans, 1):
                n = len(jobs_by_plan.get(plan["uuid"]) or [])
                noun = "job" if n == 1 else "jobs"
                print("  [{0}] {1}  ({2} unplanned failover {3})".format(i, plan["name"], n, noun))
            try:
                selected_indexes = parse_plan_selection(
                    input_fn("Select plan(s) by number (comma-separated, or 'all'): "),
                    len(plans),
                )
                break
            except ValueError:
                print("Invalid selection. Enter comma-separated numbers or 'all'.")

    selected_jobs = []
    for index in selected_indexes:
        plan = plans[index - 1]
        jobs = jobs_by_plan.get(plan["uuid"]) or []
        if not jobs:
            log.warning(
                "Recovery plan '%s' has no completed unplanned failover jobs; skipping.",
                plan["name"],
            )
            continue
        if len(jobs) == 1:
            job_index = 1
            print("Unplanned failover job for '{0}' (only job; selected): {1}".format(
                plan["name"], job_uuid(jobs[0]),
            ))
        else:
            while True:
                print("Unplanned failover jobs for '{0}' (newest first):".format(plan["name"]))
                for i, job in enumerate(jobs, 1):
                    _action, status = job_action_and_status(job)
                    print("  [{0}] {1}  {2:<22} {3}".format(
                        i, _job_time_label(job), status or "-", job_uuid(job) or "-",
                    ))
                try:
                    job_index = parse_job_selection(
                        input_fn("Select one job [1]: "),
                        len(jobs),
                    )
                    break
                except ValueError:
                    print("Invalid selection. Enter a single job number.")
        chosen = jobs[job_index - 1]
        selected_jobs.append(chosen)
        action_type, status = job_action_and_status(chosen)
        log.info(
            "  job=%s plan='%s' action=%s status=%s",
            job_uuid(chosen), plan["name"], action_type, status,
        )

    if not selected_jobs:
        raise Exception(
            "None of the selected recovery plans have a completed unplanned failover job."
        )
    return selected_jobs


def merge_entity_recovery_map(execution_statuses):
    """Build one src->dest VM uuid map from one or more execution_status payloads.

    Returns (mapping, skipped, names). `names` is src_uuid -> VM name from the
    recovery-plan step when Prism included one. Steps with an empty any_entity_reference_list
    or recovered_entity_info_list, or a missing uuid on either side, are
    skipped and counted rather than producing a lookup for `None`. Every
    overwrite of an existing src key is logged so last-writer-wins is visible.
    """
    mapping = {}
    names = {}
    skipped = 0
    for job_execution_status in execution_statuses:
        try:
            steps = job_execution_status["operation_status"]["step_execution_status_list"]
        except (KeyError, TypeError):
            continue
        for step in steps:
            if not isinstance(step, dict) or step.get("operation_type") != "ENTITY_RECOVERY":
                continue
            any_entity_list = step.get("any_entity_reference_list") or []
            recovered_list = step.get("recovered_entity_info_list") or []
            if not any_entity_list or not recovered_list:
                skipped += 1
                continue
            src_ref = any_entity_list[0] or {}
            recovered_info = recovered_list[0].get("recovered_entity_info") or {}
            src_uuid = src_ref.get("uuid")
            dest_uuid = recovered_info.get("entity_uuid")
            if not src_uuid or not dest_uuid:
                skipped += 1
                continue
            if src_uuid in mapping and mapping[src_uuid] != dest_uuid:
                log.warning(
                    "Overwriting existing mapping for src %s: dest %s -> %s",
                    src_uuid, mapping[src_uuid], dest_uuid,
                )
            mapping[src_uuid] = dest_uuid
            vm_name = src_ref.get("name") or recovered_info.get("entity_name") or recovered_info.get("name")
            if vm_name:
                names[src_uuid] = vm_name
    return mapping, skipped, names


def count_self_mapped(vm_uuid_map):
    """Count mappings where dest_uuid == src_uuid: stale completed jobs, not
    "this failover". Reported as its own outcome class by the caller."""
    return sum(1 for src, dest in vm_uuid_map.items() if src == dest)


# ---------------------------------------------------------------------------
# Task 2: pooled REST session, VM fetch/classification, run report, preflight.
# Stdlib + requests only, so these are also usable/testable without calm.
# ---------------------------------------------------------------------------

import requests
import ujson  # noqa: F401  -- kept for update_vm_in_remote_pc below (Task 3)


def pc_session(username, password):
    session = requests.Session()
    session.auth = (username, password)
    session.headers.update({"content-type": "application/json", "Accept": "application/json"})
    if insecure():
        # trust_env=False stops REQUESTS_CA_BUNDLE / SSL_CERT_FILE / CURL_CA_BUNDLE
        # in the nucalm environment from turning verification back on.
        session.verify = False
        session.trust_env = False
    else:
        session.verify = True
        session.trust_env = True
    return session


def request_with_retry(session, method, url, **kwargs):
    """One manual retry on requests.exceptions.ConnectionError.

    That is the failure mode a pooled/persistent session introduces (the
    server closing an idle connection). No urllib3 Retry/HTTPAdapter tuning:
    the Retry import path and kwargs differ between urllib3 1.x and 2.x.
    """
    if "verify" not in kwargs:
        kwargs["verify"] = tls_verify()
    try:
        return session.request(method, url, **kwargs)
    except requests.exceptions.ConnectionError:
        log.debug("Connection error on %s %s; retrying once.", method, url)
        return session.request(method, url, **kwargs)


def fetch_vm(session, base_url, uuid):
    """GET a VM and classify the result. The caller decides the log level:
    a 404 is not a script error. Returns (vm_json_or_None, outcome) where
    outcome is one of "ok", "missing", "error"."""
    try:
        resp = request_with_retry(session, "GET", "{0}/vms/{1}".format(base_url, uuid))
    except requests.exceptions.RequestException as exc:
        log.debug("VM %s GET failed: %s", uuid, exc)
        return None, "error"
    if resp.ok:
        return resp.json(), "ok"
    if resp.status_code == 404:
        log.debug("VM %s not found. Response: %s", uuid, resp.text)
        return None, "missing"
    log.debug("VM %s GET failed with status %s. Response: %s", uuid, resp.status_code, resp.text)
    return None, "error"


def substrate_in_sync(instance_id, dest_uuid, vm, account_map, stored_account_uuids, stored_cluster_uuid):
    """True when the app already points at dest_uuid on the account/cluster of this VM.

    instance_id == dest is not enough. Power Off uses spec.resources.account_uuid,
    which must be the Nutanix account for the PC that actually has the VM.
    """
    if not dest_uuid or instance_id != dest_uuid:
        return False
    try:
        cluster_uuid = vm["status"]["cluster_reference"]["uuid"]
    except (KeyError, TypeError, AttributeError):
        return False
    needed = (account_map or {}).get(cluster_uuid)
    if not needed:
        return False
    if stored_cluster_uuid and str(stored_cluster_uuid) != str(cluster_uuid):
        return False
    if not stored_account_uuids:
        return False
    needed_s = str(needed)
    for acc in stored_account_uuids:
        if acc is None or str(acc) != needed_s:
            return False
    return True


class RunReport(object):
    """One row per entity, written best-effort to a CSV under LOG_DIR.

    A plain class, not a dataclass (3.6 floor). A write failure is a
    warning, never fatal -- this is an audit convenience, not a dependency
    of the migration itself.
    """

    def __init__(self, script_name, fieldnames):
        self.fieldnames = fieldnames
        self.rows = []
        log_dir = os.environ.get("LOG_DIR", "/tmp")
        self.path = os.path.join(
            log_dir, "{0}-report-{1}.csv".format(script_name, time.strftime("%Y%m%d-%H%M%S"))
        )

    def add(self, row):
        self.rows.append(row)

    def write(self):
        try:
            log_dir = os.path.dirname(self.path)
            if log_dir and not os.path.isdir(log_dir):
                os.makedirs(log_dir)
            with open(self.path, "w") as fh:
                writer = csv.DictWriter(fh, fieldnames=self.fieldnames)
                writer.writeheader()
                for row in self.rows:
                    writer.writerow(row)
            return self.path
        except Exception as exc:
            log.warning("Could not write report to %s: %s", self.path, exc)
            return None


_ENV_HINTS = {
    "SOURCE_PROJECT_NAME": (
        "NCM Self-Service project whose live apps to scan for categories (pre-migration only). "
        "Example: export SOURCE_PROJECT_NAME=<project>"
    ),
    "DEST_PC_IP": "Destination Prism Central FQDN or IP.",
    "DEST_PC_USER": "Prism Central username.",
    "DEST_PC_PASS": "Prism Central password. Use: read -rs DEST_PC_PASS; export DEST_PC_PASS",
    "DEST_PROJECT_NAME": "Required only when UPDATE_APP_PROJECT=true.",
}


def require_env(names):
    """Validate required env vars are present and log the effective config
    with password-shaped values masked. Missing vars exit with a hint, not a
    traceback. The 'Please export required environment variables:' prefix is
    kept so existing greps still match.
    """
    missing = [name for name in names if not os.environ.get(name)]
    if missing:
        msg = "Please export required environment variables: {0}".format(", ".join(missing))
        log.error("%s", msg)
        for name in missing:
            hint = _ENV_HINTS.get(name)
            if hint:
                log.error("  %s: %s", name, hint)
        raise SystemExit(msg)
    parts = []
    for name in names:
        value = os.environ[name]
        if "PASS" in name.upper():
            value = "***"
        parts.append("{0}={1}".format(name, value))
    log.info("Effective configuration: %s", ", ".join(parts))


def preflight():
    """Log facts that make cross-version triage possible. Best-effort only;
    nothing here may raise."""
    try:
        log.info(
            "preflight: python=%s requests=%s host=%s",
            sys.version.split()[0], getattr(requests, "__version__", "unknown"), socket.gethostname(),
        )
    except Exception as exc:
        log.debug("preflight: could not collect python/requests/host info: %s", exc)

    try:
        # Standalone NCM Self-Service (4.2.x and 4.3.x) runs inside the
        # nucalm container. That container also has /home/calm/venv3, so
        # dockerenv must be checked first or we mislabel it as SMSP-on-PC.
        if os.path.exists("/.dockerenv"):
            layout = "nucalm container"
        elif os.path.isdir("/home/calm/venv3"):
            layout = "SMSP on PCVM (host venv3)"
        else:
            layout = "unknown"
        log.info("preflight: detected layout=%s", layout)
        log.info("preflight: insecure=%s tls_verify=%s", insecure(), tls_verify())
    except Exception as exc:
        log.debug("preflight: could not detect layout: %s", exc)


def print_summary(title, stats):
    """Render an ordered dict of counters in the operator-facing summary format."""
    line = "=" * 60
    print(line)
    print(title)
    for label, value in stats.items():
        print("  {0}: {1}".format(label, value))
    print(line)


# ---------------------------------------------------------------------------
# Task 3 / Task 1: calm + aplos imports. Everything above this line is
# stdlib/requests only and safe to import with calm/aplos stubbed out.
# ---------------------------------------------------------------------------

from calm.common.config import init_config, get_config
from calm.common.flags import gflags  # noqa: F401  -- importing calm models needs Flags initialized first; this import is what does it.
from calm.common.project_util import ProjectUtil
from calm.lib.model import Application, Account
from calm.lib.constants import SUBSTRATE
from calm.lib.model.store.idf.db import create_db_connection
from calm.lib.model.store.db_session import create_session, set_session_type
from calm.pkg.common.scramble import init_scramble

init_config()


def _quiet_third_party_loggers():
    """Best-effort: if calm/aplos attached their own handler(s) directly to
    one of these loggers (bypassing basicConfig), strip them so records
    route through the root handlers configured above instead of straight to
    the terminal. Never touch a logger's *level* here: that would stop
    records reaching the file handler too, and the file must keep everything.
    """
    for name in NOISY_LOGGER_NAMES:
        logger = logging.getLogger(name)
        logger.handlers = []
        logger.propagate = True


_quiet_third_party_loggers()


def init_contexts():
    """initiate context"""
    cfg = get_config()
    keyfile = cfg.get('security', 'keyfile')
    init_scramble(keyfile)
    set_session_type('green', cfg.get('store', 'flush_parallelisation_factor'), cfg.get('store', 'bulk_size'))
    create_db_connection(register_entities=False)
    create_session()


def change_project(application_name, new_project_name):
    """
    change_project method for the file
    Raises:
        Exception: when command line args are not exepcted
    Returns:
        None
    """
    from aplos.insights.entity_capability import EntityCapability
    from aplos.lib.tenant.tenant_utils import TenantUtils

    tenant_uuid = TenantUtils.get_logged_in_tenant()
    project_handle = ProjectUtil()
    app_name = application_name
    new_project_name = new_project_name

    app_kind = "app"

    # Verify if supplied project name is valid
    project_proto = project_handle.get_project_by_name(new_project_name)
    if not project_proto:
        raise Exception("No project in system with name '{}'".format(new_project_name))
    new_project_uuid = str(project_proto.uuid)

    # Verify if supplied application name is valid
    apps = Application.query(name=app_name, deleted=False)
    if not apps:
        raise Exception("No app in system with name '{}'".format(app_name))
    app = apps[0]

    entity_cap = EntityCapability(kind_name=app_kind, kind_id=str(app.uuid))

    if entity_cap.project_name == new_project_name:
        log.info("Application '{}' is already in same project : '{}'".format(app_name, new_project_name))
        return

    # make sure app contains vms of type AHV or existing machine only
    pe_account_uuids = set()
    app_substratecfgs = []
    for deploy in app.active_app_profile_instance.deployments:
        if deploy.substrate.config.type not in [SUBSTRATE.KIND.NUTANIX, SUBSTRATE.KIND.Existing]:
            raise Exception("This script not supported to migrate app's containing VM's other than AHV and Existing Machine")
        else:
            app_substratecfgs.append(deploy.substrate.config)
            if deploy.substrate.config.type == SUBSTRATE.KIND.NUTANIX:
                pe_account_uuids.add(str(deploy.substrate.config.spec.resources.account_uuid))
    pc_account_uuid_object_map = {}
    pe_account_pc_account_uuid_map = {}
    for pe_account_uuid in pe_account_uuids:
        pe_account = Account.get_object(str(pe_account_uuid))
        pc_account_uuid = str(pe_account.data.pc_account_uuid)
        pe_account_pc_account_uuid_map[str(pe_account_uuid)] = pc_account_uuid
        pc_account_uuid_object_map[pc_account_uuid] = Account.get_object(str(pc_account_uuid))

    for substratecfg in app_substratecfgs:
        if substratecfg.type == SUBSTRATE.KIND.Existing:
            continue
        pc_account_uuid = pe_account_pc_account_uuid_map[str(substratecfg.spec.resources.account_uuid)]
        is_host_pc_subcfg = pc_account_uuid_object_map[pc_account_uuid].data.host_pc
        if is_host_pc_subcfg:

            # host pc networks are stored under network_id_list attribute
            project_nics_to_consider = project_proto.network_id_list
        else:

            # remote pc networks are stored under external_network_id_list attribute
            project_nics_to_consider = [network.uuid for network in project_proto.external_network_list]
        for nic in substratecfg.spec.resources.nic_list:
            if nic.subnet_reference and nic.subnet_reference.uuid:
                nic_uuid = str(nic.subnet_reference.uuid)
                if nic_uuid not in project_nics_to_consider:
                    msg = ("'{}' subnet used by '{}' application not present under '{}' project, please "
                           "consider whitelisting all subnets in new project which are white listed in old project".format(nic_uuid, app.name, new_project_name))
                    log.warning(msg)

    log.info("Moving '{}' application to new  project : '{}'".format(app_name, new_project_name))

    # To change ownership of an app to new project, we need to below things

    # 1. Find category uuid  corresponding to app's EC for {"Project", "old project name"} category
    # 2. Then remove category uuid found in step 1 from EC's category_id_list attribute
    # 3. Create a New category with key 'Project' and value as new_project_name and then add category uuid to EC's category_id_list attribute
    # 4. Then we need to update EC's project_name and project_reference to New Project
    # 5. Save EC

    # Step 1 to 3 are needed as API's populate project_reference under metadata based Project Category

    handle_entity_project_change("app", str(app.uuid), tenant_uuid, new_project_name, new_project_uuid)
    log.info("Successfully changed '{}' application's ownership to new project '{}'".format(app_name, new_project_name))
    log.info("Now moving '{}' app's VM to new project '{}'".format(app_name, new_project_name))

    if app.app_blueprint_config.source_marketplace_name:
        log.info("Moving Markeplace BP of application '{}' to '{}' project".format(app_name, new_project_name))
        handle_entity_project_change("blueprint", str(app.app_blueprint_config.uuid), tenant_uuid, new_project_name, new_project_uuid)
        log.info("Successfully moved Markeplace BP of application '{}' to '{}' project".format(app_name, new_project_name))

    if not pc_account_uuid_object_map:
        log.info("There are no AHV vm's in the app, hence no vm belonging to this app needs any change")
        log.info("Successfully moved '{}' application to  '{}' project ".format(app_name, new_project_name))
        return

    # Find out UUIDs of the all the AHV VM's from application
    vm_uuids = []
    for deploy in app.active_app_profile_instance.deployments:
        for de in deploy.elements:
            sub_el = de.substrate_element
            if sub_el.type == "AHV_VM":
                vm_uuids.append(str(sub_el.instance_id))

    # pc_account_uuid_object_map suppose to have just one entry as we just support one account of type in project
    pc_account_obj = list(pc_account_uuid_object_map.values())[0]
    is_app_remote_pc = not pc_account_obj.data.host_pc
    if is_app_remote_pc:
        pc_ip = pc_account_obj.data.server
        password = pc_account_obj.data.password.blob
        pc_username = pc_account_obj.data.username
    log.info("Application's vms are '{}', is app on remote pc {}".format(vm_uuids, is_app_remote_pc))

    # Change ownership of all vm's to New project
    # Same step mentioned for app need to follow for vm
    for vm_uuid in vm_uuids:

        # Based on whether vm reside on local pc or remote pc we need to take action here

        # 1. for remote pc vm, we needd to update CalmProject category to hold new project name as value
        # 2. For local pc vm, we need to update vm's EC to point to new project, for local pc vm we don't
        # see CalmProject, hence there is no need to update CalmProject category value
        if is_app_remote_pc:
            update_vm_in_remote_pc(pc_ip, pc_username, password, vm_uuid, new_project_name)
            log.info("Successfully updated remote pc  '{}' vm's categories to hold new project name".format(vm_uuid))
        else:
            handle_entity_project_change("vm", vm_uuid, tenant_uuid, new_project_name, new_project_uuid)
            log.info("Successfully moved '{}' vm which is part of '{}' application to new project '{}'".format(vm_uuid, app_name, new_project_name))
    log.info("Successfully moved all vm's of '{}' application to '{}' project".format(app_name, new_project_name))
    log.info("Successfully moved '{}' application to  '{}' project ".format(app_name, new_project_name))


def change_project_vmware(application_name, new_project_name):
    """
    change_project method for the file
    Raises:
        Exception: when command line args are not exepcted
    Returns:
        None
    """
    from aplos.insights.entity_capability import EntityCapability
    from aplos.lib.tenant.tenant_utils import TenantUtils

    tenant_uuid = TenantUtils.get_logged_in_tenant()
    project_handle = ProjectUtil()
    app_name = application_name
    new_project_name = new_project_name

    app_kind = "app"

    # Verify if supplied project name is valid
    project_proto = project_handle.get_project_by_name(new_project_name)
    if not project_proto:
        raise Exception("No project in system with name '{}'".format(new_project_name))
    new_project_uuid = str(project_proto.uuid)

    # Verify if supplied application name is valid
    apps = Application.query(name=app_name, deleted=False)
    if not apps:
        raise Exception("No app in system with name '{}'".format(app_name))
    app = apps[0]

    entity_cap = EntityCapability(kind_name=app_kind, kind_id=str(app.uuid))

    if entity_cap.project_name == new_project_name:
        log.info("Application '{}' is already in same project : '{}'".format(app_name, new_project_name))
        return

    log.info("Moving '{}' application to new  project : '{}'".format(app_name, new_project_name))

    handle_entity_project_change("app", str(app.uuid), tenant_uuid, new_project_name, new_project_uuid)
    log.info("Successfully changed '{}' application's ownership to new project '{}'".format(app_name, new_project_name))
    log.info("Now moving '{}' app's VM to new project '{}'".format(app_name, new_project_name))

    if app.app_blueprint_config.source_marketplace_name:
        log.info("Moving Markeplace BP of application '{}' to '{}' project".format(app_name, new_project_name))
        handle_entity_project_change("blueprint", str(app.app_blueprint_config.uuid), tenant_uuid, new_project_name, new_project_uuid)
        log.info("Successfully moved Markeplace BP of application '{}' to '{}' project".format(app_name, new_project_name))

    # Find out UUIDs of the all the AHV VM's from application
    vm_uuids = []
    for deploy in app.active_app_profile_instance.deployments:
        for de in deploy.elements:
            sub_el = de.substrate_element
            if sub_el.type == "VMWARE_VM":
                vm_uuids.append(str(sub_el.instance_id))
    # Change ownership of all vm's to New project
    # Same step mentioned for app need to follow for vm
    for vm_uuid in vm_uuids:
        handle_entity_project_change("vm", vm_uuid, tenant_uuid, new_project_name, new_project_uuid)
        log.info("Successfully moved '{}' vm which is part of '{}' application to new project '{}'".format(vm_uuid, app_name, new_project_name))
    log.info("Successfully moved all vm's of '{}' application to '{}' project".format(app_name, new_project_name))
    log.info("Successfully moved '{}' application to  '{}' project ".format(app_name, new_project_name))


def handle_entity_project_change(entity_kind, entity_uuid, tenant_uuid, new_project_name, new_project_uuid):
    """
    Handles entity project change
    Args:
        entity_kind(str): Entity kind
        entity_uuid(str): Entity uuid
        tenant_uuid(str): Tenent uuid
        new_project_name(str): new project's name for the entity
        new_project_uuid(str): new project's uuid for the entity
    """
    from aplos.categories.category import Category, CategoryKey
    from aplos.insights.entity_capability import EntityCapability

    # 1. Find category uuid  corresponding to entity's EC for {"Project", "old project name"} category
    entity_cap = EntityCapability(kind_name=entity_kind, kind_id=str(entity_uuid))
    project_category_uuid = None
    for c_uuid in entity_cap.category_id_list:
        category_obj = Category(uuid=c_uuid)
        project_category_key_uuid = str(category_obj.abac_category_key)
        category_key_obj = CategoryKey(uuid=project_category_key_uuid)
        if category_key_obj.name == "Project":
            project_category_uuid = str(c_uuid)
            break

    # 2. Then remove category uuid found in step 1 from EC's category_id_list attribute
    entity_cap.remove_categories([project_category_uuid])

    # 3. Create a New category with key 'Project' and value as new_project_name and then add category uuid to EC's category_id_list attribute
    category_obj = get_or_create_category("Project", new_project_name, tenant_uuid)
    entity_cap.add_categories([str(category_obj.uuid)])

    # 4. Then we need to update EC's project_name and project_reference attrs with  New Project
    entity_cap.change_project_reference(new_project_uuid, new_project_name)

    # 5. Save EC
    if DRY_RUN:
        log.info("[DRY RUN] Would update entity '%s' (%s) to project '%s' (%s)", entity_kind, entity_uuid, new_project_name, new_project_uuid)
        return
    entity_cap.save()


def update_vm_in_remote_pc(pc_ip, pc_username, pc_password, vm_uuid, new_project_name):
    """
    Update vm with new category, key for category is Project and value is param new_project_name
    Args:
        pc_ip(str): PC ip
        pc_username(str): PC username
        pc_password(str): PC password
        vm_uuid(str): VM uuid
        new_project_name(str): value for Project category
    Raises:
        Exception when some operation fails
    """
    headers = {'content-type': 'application/json'}
    auth = (pc_username, pc_password)
    category_url = "https://{}:9440/api/nutanix/v3/categories/CalmProject/{}".format(pc_ip, new_project_name)
    verify = tls_verify()
    response = requests.get(category_url, auth=auth, headers=headers, verify=verify)
    if response.status_code == 404:
        log.info("Needed category (key: value) ({}, {}) does not exist on remote PC, need to create one".format("CalmProject", new_project_name))
        category_create_paylod = {"description": "Created by CALM", "value": new_project_name}
        response = requests.put(category_url, auth=auth, data=ujson.dumps(category_create_paylod), headers=headers, verify=verify)
        if response.status_code not in [200, 202]:
            log.warning("Response status code {}, response content {}".format(response.status_code, response.content))
            raise Exception("Failed to create category, please contact Nutanix-calm team")

    vm_api_url = "https://{}:9440/api/nutanix/v3/vms/{}".format(pc_ip, vm_uuid)
    log.debug("VM GET URL: '{}'".format(vm_api_url))
    response = requests.get(vm_api_url, auth=auth, headers=headers, verify=verify)
    if response.status_code not in [200, 202]:
        log.warning("Response status code {}, response content {}".format(response.status_code, response.content))
        raise Exception("Failed to get VM from a remote PC, please contact Nutanix-calm team")
    vm_get_response_str = response.content
    vm_get_response = ujson.loads(vm_get_response_str)
    vm_get_response.pop('status')
    categories = vm_get_response.get('metadata', {}).get('categories', {})
    categories['CalmProject'] = new_project_name
    if DRY_RUN:
        log.info("[DRY RUN] Would update VM '%s' on remote PC '%s' to project '%s'", vm_uuid, pc_ip, new_project_name)
        return
    response = requests.put(vm_api_url, auth=auth, data=ujson.dumps(vm_get_response), headers=headers, verify=verify)
    if response.status_code not in [200, 202]:
        log.warning("Response status code {}, response content {}".format(response.status_code, response.content))
        raise Exception("Failed to update VM on remote PC, please contact Nutanix-calm team")


def get_or_create_category(name, value, tenant_uuid):
    """
    Get or create catgory for given arguments
    Args:
        name(str): Category key
        value(str): Category value
        tenant_uuid(str): Tenant uuid
    Returns:
        object: category object
    """
    from aplos.categories.category import Category

    category_obj = Category()
    category_obj.lookup_category_by_name_value(name, value)
    if hasattr(category_obj, "value") and category_obj.value == value:
        log.info("category with name '{}' and value '{}', already exists , hence no need to create".format(name, value))
        return category_obj
    category_obj.tenant_uuid = tenant_uuid
    category_obj.initialize(name, value, "Created by CALM", None, True)
    if DRY_RUN:
        log.info("[DRY RUN] Would create category with name '%s' and value '%s'", name, value)
        return category_obj  # or None, depending on your logic
    category_obj.save()
    return category_obj
