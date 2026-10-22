# Changelog

Notable changes to the Nutanix Cloud Manager (NCM) Self-Service disaster recovery VM-tracking scripts: `pre-migration-script.py`, `post-migration-script.py`, and `helper.py`. Version numbers match the NCM Self-Service release that we tested the scripts against.

## 4.3.1 — August 28, 2026

Tested with NCM Self-Service 4.3.1. Also supported on 4.2.0.

### Added

- Interactive post-migration wizard. Default `RP_JOB_SCOPE` is `prompt`. The wizard lists recovery plans on the destination Prism Central instance, auto-selects a plan or job when only one exists, and otherwise asks you to pick plans, then one completed failover job per plan. Unplanned failover and failback both appear as `FAILOVER`; pick the job whose destination VMs are where the workloads run now. The post-migration script does not read every historical recovery-plan job unless you set `all`.
- Non-interactive job selection with `RP_JOB_SCOPE`: `latest_per_plan` (newest completed failover per plan), `all` (every completed migrate and failover job), or `job` (exactly `RP_JOB_UUID`). Optional `RP_PLAN_NAME` (comma-separated) filters plan names.
- Lookup on the other availability zone (AZ) when a virtual machine (VM) is not on the destination Prism Central instance. Set `OTHER_PC_IP`, or answer a one-time prompt. Order: destination UUID on the other AZ, then source UUID on both Prism Central instances.
- The script sets the Nutanix account on the application (the Self-Service cloud account) to the Prism Central instance that hosts the VM, not only the destination you exported.
- Operator walkthrough in `WORKFLOW.md`. Example pre-migration and post-migration recordings in `README.md`.
- Log file and CSV report under `LOG_DIR` (default `/tmp`). The console summary groups each mapping: relinked (or would write in a dry run), already relinked, no matching substrate, or destination VM not on destination Prism Central.
- `APP_FILTER` on pre-migration (`auto` or `none`). Default `auto` queries live applications first and falls back to the legacy unfiltered query. Either path skips deleted applications.

### Changed

- Post-migration no longer requires `DEST_PROJECT_NAME` or `SOURCE_PROJECT_NAME` unless you set `UPDATE_APP_PROJECT=true`.
- Console output stays at `LOG_LEVEL` (default INFO). The log file still captures DEBUG. The script no longer prints noisy Self-Service library errors on the console.
- README documents the standalone NCM Self-Service VM path: copy the three scripts into `nucalm` with `docker cp`, run `activate`, and export variables inside the container. The SSH host does not pass them through.

### Fixed

- If the VM UUID is already correct but the Nutanix account still points at the other availability zone, the script updates the account. Power Off no longer fails with `VM not found`. If both already match, the script skips the write.
- Account matching accepts a Prism Central IP address or host name. If the match fails, the script lists the registered account servers.
- Pre-migration lists category values that already exist on the destination Prism Central instance before it creates missing ones.

## 4.2.0 — September 2, 2025

Tested with NCM Self-Service 4.2.0. Earlier scripts are under `_archive/`.

### Added

- `DRY_RUN=true` classifies only. It does not write changes.
- Console logging at INFO.
- Post-migration updates virtual private cloud (VPC) subnet references when Prism Central returns them (November 13, 2025). VLAN-only subnets stay unchanged.

## June 6, 2024

### Fixed

- Compatibility with standalone NCM Self-Service VM image 380 (formerly Calm VM): Insights database imports, recovered-entity UUID mapping, and extra system category keys. See [pull request 4](https://github.com/nutanix/validated-designs/pull/4).

## August 15, 2022

### Changed

- Pre-migration runtime for large estates: about 4 hours to 15 minutes for 3800 VMs and applications. See [pull request 2](https://github.com/nutanix/validated-designs/pull/2).

## November 1, 2021

### Added

- First release of the pre-migration, post-migration, and helper scripts. See [pull request 1](https://github.com/nutanix/validated-designs/pull/1).
