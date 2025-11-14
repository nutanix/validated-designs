# Script to track DR Failover of UVM from PC -> PC and relink NCM Self-Service Apps

This solution helps customers relink NCM Self-Service Apps to UVMs in a DR site or vice-versa.

---

## Pre-requisites

- **NCM Self-Service 4.2.0** (tested)
- Python environment inside the NCM Self-Service VM (typically inside the `nucalm` container)

---

## Script Overview

- **`pre-migration-script.py`**  
  Takes `DEST_PC_IP`, `DEST_PC_USER`, `DEST_PC_PASS`, and `SOURCE_PROJECT_NAME` as environment variables.  
  Recreates categories at the DR site based on source project applications.

- **`post-migration-script.py`**  
  Takes `DEST_PC_IP`, `DEST_PC_USER`, `DEST_PC_PASS`, and `DEST_PROJECT_NAME` as environment variables.  
  Relinks NCM Self-Service Apps with failover VMs and updates the App's project.  
  **Now includes VPC support**: Automatically detects and updates VPC tunnel VM references for apps deployed in VPC networks.

- **`helper.py`**  
  Contains shared helper functions.  
  **Do not execute this file directly.**

---

## Required Environment Variables

```shell
export DEST_PROJECT_NAME="<DEST_PROJECT_NAME>"
export DEST_PC_IP="<PC_IP>"
export DEST_PC_USER="<PC_USERNAME>"
export DEST_PC_PASS="<PC_PASSWORD>"
export SOURCE_PROJECT_NAME="<SOURCE_PROJECT_NAME>"
export DRY_RUN=true/false
```

---

## Steps to execute
```shell
# SSH to NCM Self-Service VM
# Docker exec to nucalm container
docker exec -it nucalm bash
cd /tmp
activate

# Copy the files 'helper.py', 'pre-migration-script.py' & 'post-migration-script.py'

# export required variables
export DEST_PROJECT_NAME="<DEST_PROJECT_NAME>"
export DEST_PC_IP="<PC_IP>"
export DEST_PC_USER="<PC_USERNAME>"
export DEST_PC_PASS="<PC_PASSWORD>"
export SOURCE_PROJECT_NAME="<SOURCE_PROJECT_NAME>"
export DRY_RUN=true/false

python pre-migration-script.py
python post-migration-script.py
```

---

## VPC Network Support

The post-migration script now includes **automatic VPC tunnel VM support** for applications deployed in VPC networks:

- **Automatic Detection**: The script queries each subnet to determine if it's part of a VPC
- **Safe Handling**: Works with both VPC-based subnets and regular VLAN-backed subnets
- **Comprehensive Updates**: Updates VPC references across all app components:
  - Substrate elements (NSE)
  - Replica groups (NS) 
  - Substrate configs (NSC)
  - Action create tasks
  - Clone blueprints
  - Patch configurations
- **No Manual Intervention**: VPC tunnel VM UUIDs are automatically updated after failover

### Technical Details

For VPC-based subnets, the script:
1. Extracts subnet UUIDs from VM NIC configurations
2. Queries the Prism Central API to get VPC references
3. Updates `vpc_reference` fields alongside `subnet_reference` fields
4. Skips VPC updates for non-VPC subnets (no errors thrown)

---

## Notes

- These scripts have been tested with **NCM Self-Service 4.2.0**.
- Set the environment variable `DRY_RUN=true` to perform a dry run (no changes will be made).
- Review the logs for any warnings or errors after execution.
- Do **not** run `helper.py` directly.
- **VPC Support**: The script automatically handles both VPC and non-VPC subnets without requiring configuration.
