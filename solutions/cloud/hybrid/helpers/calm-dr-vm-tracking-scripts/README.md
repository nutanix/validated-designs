# Relink NCM Self-Service Applications After Disaster Recovery

Relink Nutanix Cloud Manager (NCM) Self-Service (formerly Calm) applications to recovered user virtual machines (VMs) after a disaster recovery (DR) failover or migrate between Prism Central instances.

These scripts do not fail over workloads and do not run recovery plans. They repair Self-Service records so applications point at the recovered VMs.

**Operator walkthrough:** [WORKFLOW.md](WORKFLOW.md)

**What changed:** [CHANGELOG.md](CHANGELOG.md)

## Prerequisites

- Standalone NCM Self-Service VM. Run inside `nucalm` after `activate`.
- **Tested:** 4.3.1
- **Also supported:** 4.2.0 on the same `nucalm` layout (Python 3.6 or later). Start with `DRY_RUN=true`.

## Scripts

- `pre-migration-script.py` — recreate categories on the destination Prism Central instance from `SOURCE_PROJECT_NAME`
- `post-migration-script.py` — relink applications to recovered VMs (interactive wizard by default)
- `helper.py` — shared helpers. Do not run this file.

Copy only those three files onto the NCM Self-Service VM. Do not copy `WORKFLOW.md` or `_archive/`.

## Environment

```shell
export DEST_PC_IP="<destination Prism Central>"
export DEST_PC_USER="<user>"
read -rs DEST_PC_PASS
export DEST_PC_PASS
export SOURCE_PROJECT_NAME="<source project>"   # pre-migration
export DRY_RUN=true                             # classify only; no writes
```

Do not paste `DEST_PC_PASS` on one line. `docker exec` does not inherit environment variables from the SSH host. Export them inside the container after `activate` (the prompt shows `(venv3)`).

Optional: `INSECURE` (default `true`), `RP_JOB_SCOPE` (default `prompt` — wizard, not every historical job), `RP_PLAN_NAME`, `RP_JOB_UUID`, `OTHER_PC_IP`. See [WORKFLOW.md](WORKFLOW.md).

## Steps

```shell
# SSH to the standalone NCM Self-Service VM, then:
docker cp helper.py nucalm:/tmp/
docker cp pre-migration-script.py nucalm:/tmp/
docker cp post-migration-script.py nucalm:/tmp/

docker exec -it nucalm bash
cd /tmp
activate

# export variables (above), then:
python pre-migration-script.py    # before failover
python post-migration-script.py   # after the job is COMPLETED or COMPLETED_WITH_WARNING
```

Run first with `DRY_RUN=true`. Re-run with `DRY_RUN=false` only when the summary is correct.

## Example Runs

<details>
<summary>Pre-Migration</summary>

Categories on the destination Prism Central instance.

<video controls playsinline preload="metadata" width="954" src="pre-migration.mp4">
<a href="pre-migration.mp4">Download the pre-migration recording</a>
</video>

</details>

<details>
<summary>Post-Migration</summary>

Relink wizard.

<video controls playsinline preload="metadata" width="954" src="post-migration.mp4">
<a href="post-migration.mp4">Download the post-migration recording</a>
</video>

</details>

## Notes

- Default `RP_JOB_SCOPE` is `prompt`. The wizard auto-selects a plan or job when only one exists. Otherwise you pick recovery plans, then one completed failover job per plan. Unplanned failover and failback both appear as `FAILOVER`. The post-migration script does not read every historical job unless you set `all`. Without an interactive terminal, set `RP_JOB_SCOPE=latest_per_plan` (or `all` / `job`).
- Virtual private cloud (VPC) subnets: the script updates `vpc_reference` when Prism Central returns it. VLAN-only subnets stay unchanged.
