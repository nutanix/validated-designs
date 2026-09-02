# Operator Workflow: Relink NCM Self-Service Applications After Disaster Recovery

These scripts do not fail over workloads and do not run recovery plans. They repair Nutanix Cloud Manager (NCM) Self-Service (formerly Calm) records after an unplanned failover so applications point at the recovered virtual machines (VMs).

Keep this file on your laptop. Copy only the three runtime scripts onto the NCM Self-Service VM: `helper.py`, `pre-migration-script.py`, and `post-migration-script.py`.

Short copy and run steps: [README.md](README.md). What changed: [CHANGELOG.md](CHANGELOG.md).

## Topology

Two Prism Central instances (one per availability zone) and **one** standalone NCM Self-Service VM that owns the applications. SSH to that Self-Service VM and run inside `nucalm`. The container prompt may still show a Prism Central VM host name. That is expected.

`DEST_PC_IP` is the Prism Central instance that hosts the recovered VMs (the target availability zone), not the SSH host.

## End-to-End

1. Copy the three `.py` files into `nucalm` (`docker cp`, then `docker exec -it nucalm bash`). The `-it` interactive terminal is required for the post-migration wizard.
2. Run `activate` (NCM Self-Service virtual environment inside the container). Confirm `(venv3)` and `python -V`.
3. Export environment variables. Never paste `DEST_PC_PASS` into a log.

   ```shell
   export DRY_RUN=true
   export INSECURE=true
   export DEST_PC_IP="<destination Prism Central>"
   export DEST_PC_USER="<user>"
   read -rs DEST_PC_PASS
   export DEST_PC_PASS
   export SOURCE_PROJECT_NAME="<source project>"
   ```

   Unset `RP_JOB_SCOPE` (or set `prompt`) to run the wizard. `INSECURE=true` is the default (lab self-signed certificates). `DRY_RUN=true` still runs the wizard. It does not write application records.
4. **Pre-migration** (before failover): `python pre-migration-script.py` recreates categories on the destination Prism Central instance. It lists values that already exist there, then creates the missing ones. It skips deleted applications.
5. Wait until the recovery-plan job is `COMPLETED` or `COMPLETED_WITH_WARNING`. Do not run post-migration while the job is still running.
6. **Post-migration wizard:** `python post-migration-script.py`

   - Lists every recovery plan on the destination Prism Central instance, not a subset inferred from jobs.
   - Auto-selects a plan or one completed failover job when only one exists. Prompts only when there are several.
   - Skips a plan that has no such jobs. If every selected plan is skipped, the script exits before it writes to the destination.
   - If a VM is not on the destination Prism Central instance, the script asks once for the Prism Central instance in the other availability zone (AZ).
   - Lookup order: destination UUID on the other AZ, then source UUID on both Prism Central instances.
   - The script sets the Nutanix account on the application (the Self-Service cloud account) to the Prism Central instance that hosts the VM.
   - The script raises an error only when both the destination UUID and the source UUID are missing on both Prism Central instances. The log includes the application name and VM name when they are known.
   - Set `OTHER_PC_IP` to skip the prompt. Progress is logged every 25 VMs.
7. Read the summary and CSV. If the result is correct, re-run with `DRY_RUN=false`.

## Picking the Job (Failback Caveat)

The Prism Central v3 API has no separate unplanned enum. Unplanned failover and failback are both `FAILOVER`. The list shows time, status, and UUID. Pick the job whose destination VMs are where the workloads run now.

## Recovery Plan Job Scope

Default `RP_JOB_SCOPE` is `prompt` (or unset). The post-migration script does not read every historical job unless you set `all`.

| Value | Prompt? | What It Selects |
|---|---|---|
| `prompt` / unset | Yes (interactive terminal required) | You pick plans, then one completed failover job (`FAILOVER`) per plan. Auto-selects when only one plan or job exists. |
| `latest_per_plan` | No | Newest completed `FAILOVER` job per plan (`MIGRATE` excluded) |
| `all` | No | Every completed `MIGRATE` and `FAILOVER` job |
| `job` | No | Exactly `RP_JOB_UUID` |

Without an interactive terminal, `prompt` exits before destination writes. Set `RP_JOB_SCOPE=latest_per_plan` (or `all` / `job`). Optional `RP_PLAN_NAME` (comma-separated) filters plan names.

## Optional Environment Variables

| Variable | Default | Meaning |
|---|---|---|
| `DRY_RUN` | `false` | `true`: classify only; no writes |
| `INSECURE` | `true` | Skip TLS verification (lab self-signed certificates) |
| `LOG_DIR` | `/tmp` | Log file and CSV |
| `LOG_LEVEL` | `INFO` | Console verbosity. The log file stays at DEBUG. |
| `OTHER_PC_IP` | (none) | Prism Central instance in the other AZ when a VM is missing on the destination |
| `UPDATE_APP_PROJECT` | `false` | If `true`, also requires `DEST_PROJECT_NAME` and `SOURCE_PROJECT_NAME` |
| `APP_FILTER` | `auto` | Pre-migration: `auto` queries live applications first; `none` uses the legacy unfiltered query |

## How to Read the Summary

- `relinked (substrate written)` — application VM records the script wrote. A dry run labels this row `relinked (would write; DRY_RUN)`.
- `already relinked (idempotent skip)` — UUID and Nutanix account already match the Prism Central instance that hosts the VM.
- `no matching substrate (not a Self-Service VM)` — recovery-plan VMs that NCM Self-Service never owned.
- `dest VM not on DEST_PC (stale mapping)` — usually a stale completed job, not leftover source VMs.
- CSV under `LOG_DIR` (default `/tmp`) is one row per mapping. The log file is DEBUG. The console stays at `LOG_LEVEL` (default INFO).

## Troubleshooting

| Symptom | Cause |
|---|---|
| `python: command not found` | You are inside `nucalm`, but you have not run `activate`. |
| `No module named 'calm'` | You ran host Python. Enter `nucalm`, run `activate`, then `python`. |
| `which: command not found` | Expected. Use `python -V`. |
| `Please export required environment variables` | `docker exec` does not inherit the host environment. Export variables in this `(venv3)` shell. Pre-migration requires `SOURCE_PROJECT_NAME`. |
| `aplos.cfg` ERROR on the console | Stale copy, or Self-Service libraries imported before helper. Copy the three files in again. |
| `CERTIFICATE_VERIFY_FAILED` | `export INSECURE=true` (default). |
| Prompt still says `ntnx-…-pcvm` | Expected. Look for `(venv3)` after `activate`. |
| Power Off: `VM not found` | The VM UUID may already be correct, but the Nutanix account still points at the other AZ. Re-run post-migration so the account follows the Prism Central instance that hosts the VM. |
