# Nutanix Citrix DaaS Validated Design

## Introduction
This repo for your Nutanix Citrix DaaS Validated Design helps you to automate the creation and maintenance of:

* Windows Server 2022 and Windows 10 golden images

* Create and auto-register a highly available Citrix Cloud Connectors

* Scale out/in the number of Citrix Cloud Connectors machines based on your user demand

## Prerequisite
Before you start, make sure to:

* Environment with Nutanix Prism Central amd at least one with Prism cluster

* [Docker Desktop](https://www.docker.com/products/docker-desktop/) This approach simplifies the process of not having to install tools directly in the base operating system

* [Microsoft Visual Studio Code](https://code.visualstudio.com/) This is needed if following the Docker approach

* [Remote Development VS Code Extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.vscode-remote-extensionpack) Extension needed to operate inside of the container

* Software images

    * Nutanix VirtIO 1.1.7+ [Download](https://portal.nutanix.com/page/downloads?product=ahv&bit=VirtIO)

    * Nutanix AHV Plugin for Citrix 2.7.1.0+ [Download](https://portal.nutanix.com/page/downloads?product=ahv&bit=Citrix)

    * Microsoft Windows Server 2022

    * Microsoft Windows 10

    * Citrix Virtual Delivery Agent (VDA) for server and desktop

* For UEFI, a Windows machine to recreate the Windows ISO files to automatically start without needing to press a key. [more details](https://taylor.dev/removing-press-any-key-prompts-for-windows-install-automation/)

* Host all the images and packages in a web repository

## Steps

1. Clone this repository

    ```
    git clone https://github.com/nutanix/validated-designs.git
    ```

1. Move to the configs directory

    ```
    cd validated-designs/solutions/staging/euc/citrix/configs
    ```

1. Change the git branch to `dev-daas`

    ```
    git checkout dev-daas
    ```

1. Create a copy of the `secret.pkrvars.hcl.example` file and make sure the file is not part of your source code control

    ```
    cp secret.pkrvars.hcl.example secret.pkrvars.hcl
    ```

1. Update the `secret.pkrvars.hcl` file with your values

    ```
    // All the values are mandatory

    // Nutanix credentials
    nutanix_username = "admin"
    nutanix_password = "*****"

    // Packer credentials
    build_username   = "packer"
    build_password   = "*****"

    // Microsoft AD credentials
    ad_username = "administrator"
    ad_password = "*****"

    // Microsoft Windows Server 2022 KMS key
    win2022_kms_key_datacenter = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"

    // Microsoft Windows 10 KMS key
    win10_kms_key_enterprise = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"

    // Citrix Cloud API client
    citrix_cloud_customer_id = "<citrix_cloud_customer_id>"
    citrix_cloud_client_id = "<citrix_cloud_client_id>"
    citrix_cloud_client_secret = "<citrix_cloud_client_secret>"
    citrix_cloud_resource_location_id = "<citrix_cloud_resource_location_id>"
    ```

1. Create a copy of the `production.pkr.hcl.example` file

    ```
    cp production.pkr.hcl.example production.pkr.hcl
    ```

1. Update the `production.pkr.hcl` file with your values

    ```
    // All the values are mandatory

    // Nutanix Citrix DaaS Validated Design - Reference prefix for tracking resources
    ref_prefix = "NVD_CITRIX_"

    // Nutanix Prism Central and Prism Element cluster connection
    nutanix_endpoint = "pc.domain.local" # Prism Central address (fqdn|IP)
    nutanix_cluster  = "Cluster001" # Prism Element cluster name
    nutanix_subnet   = "Primary" # Prism cluster subnet name
    nutanix_insecure = "false" # Ignore insecure certificates (true|false)

    // Microsoft AD 
    ad_domain = "domain.local"

    // Citrix Cloud Connectors
    citrix_cloud_connector_vm_name = [
        "ctx-cc-01",
        "ctx-cc-02"
    ]

    // ISO images to add into AHV Image Service using Terraform
    nutanix_virtio_iso = {
        name = "Nutanix_VirtIO-1.1.7"
        description = "Nutanix VirtIO for Windows (iso) ( Version: 1.1.7 )"
        source_uri = "https://download.nutanix.com/virtIO/1.1.7/Nutanix-VirtIO-1.1.7.iso"
    }

    nutanix_server_os_iso = {
        name = "Windows_Server_2022"
        description = "Microsoft Windows Server 2022"
        source_uri = "<ISO_URL_HERE>"
    }

    nutanix_desktop_os_iso = {
        name = "Windows_10"
        description = "Microsoft Windows 10"
        source_uri = "<ISO_URL_HERE>"
    }

    // Packages to install in Windows golden images using Packer and Ansible
    citrix_vda_desktop_installer_url = "http://<HOST>/VDAWorkstationSetup_2203_1100.exe"
    citrix_vda_server_installer_url = "http://<HOST>/VDAServerSetup_2203_1100.exe"

    // ISO UUIDs after adding with Terraform and to be used by Packer with Autounattend.xml
    nutanix_virtio_iso_uuid = "<UUID_OUTPUT_FROM_TERRAFORM_ADD_BUILD_ISOS>"
    win10_os_iso_uuid = "<UUID_OUTPUT_FROM_TERRAFORM_ADD_BUILD_ISOS>"
    win2022_os_iso_uuid = "<UUID_OUTPUT_FROM_TERRAFORM_ADD_BUILD_ISOS>"

    // AHV disk image built by Packer and to use for Citrix Cloud Connector machines with Terraform
    packer_win2022_disk_image_name = "<DISK_IMAGE_NAME_FROM_PACKER_BUILD>"
    ```

1. Move to the `add-build-isos` Terraform directory to add the ISO images into the AHV Image Service using Terraform

    ```
    cd ../terraform/add-build-isos/
    ```

1. Initialize Terraform to install the Nutanix plugin

    ```
    terraform init
    ```

1. Create a Terraform plan for the ISO images using the two variable files available in the `configs` directory

    ```
    terraform plan \
    -var-file="../../configs/secret.pkrvars.hcl" \
    -var-file="../../configs/production.pkr.hcl" \
    -out tfplan
    ```

1. Confirm the Terraform plan will create three resources and ignore the variable warnings

    ```
    Plan: 3 to add, 0 to change, 0 to destroy.

    Changes to Outputs:
    + desktop_os_iso_uuid = (known after apply)
    + server_os_iso_uuid  = (known after apply)
    + virtio_iso_uuid     = (known after apply)
    ```

1. Apply the Terraform plan to add the ISO images into AHV Image Service

    ```
    terraform apply tfplan
    ```

1. Copy the three ISO image UUIDs to update the variable files in `configs`

    ```
    Apply complete! Resources: 3 added, 0 changed, 0 destroyed.

    Outputs:

    win10_os_iso_uuid = "33363057-8d74-4e7a-bc46-708f2c6b23c9"
    win2022_os_iso_uuid = "e8e268a9-e5d0-4ac2-b567-e5e822d9c056"
    nutanix_virtio_iso_uuid = "4f422c45-6ad8-4a0d-9c72-c24fbf9c1d6b"
    ```

1. Update the ISO values for the file `configs/production.pkr.hcl` with the output values from previous step

    ```
    // ISO UUIDs after adding with Terraform and to be used by Packer with Autounattend.xml
    nutanix_virtio_iso_uuid = "4f422c45-6ad8-4a0d-9c72-c24fbf9c1d6b"
    win10_os_iso_uuid = "33363057-8d74-4e7a-bc46-708f2c6b23c9"
    win2022_os_iso_uuid = "e8e268a9-e5d0-4ac2-b567-e5e822d9c056"
    ```

1. Move to the `citrix` directory for performing the next Packer commands

    ```
    cd ../../../citrix/
    ```

1. Initialize Packer to install the required plugins

    ```
    packer init builds/windows/server/2022/
    ```

1. Build the Windows Server 2022 golden image

    ```
    packer build \
    -var-file="configs/secret.pkrvars.hcl" \
    -var-file="configs/production.pkr.hcl" \
    builds/windows/server/2022
    ```

1. In another console, build the Windows 10 golden image

    ```
    packer build \
    -var-file="configs/secret.pkrvars.hcl" \
    -var-file="configs/production.pkr.hcl" \
    builds/windows/desktop/10
    ```

1. When Windows Server 2022 build finishes, check the `manifests` directory to retrieve the image name

    ```
    "build_name": "NVD_CITRIX_WinSvr2022-2022.10.03_10-01-50"
    ```

1. Update the variable `packer_win2022_disk_image_name` in the file `configs/production.pkr.hcl` with the `build_name` value from the previous step

    ```
    packer_win2022_disk_image_name = "NVD_CITRIX_WinSvr2022-2022.10.03_10-01-50"
    ```

1. Move to the `citrix-cloud-connectors` Terraform directory to create the Citrix Cloud Connectors using Terraform with the image built by Packer

    ```
    cd terraform/citrix-cloud-connectors/
    ```

1. Initialize Terraform to install the Nutanix plugin

    ```
    terraform init
    ```

1. Create a Terraform plan for the Citrix Cloud Connector virtual machines using the two variable files available in the `configs` directory

    ```
    terraform plan \
    -var-file="../../configs/secret.pkrvars.hcl" \
    -var-file="../../configs/production.pkr.hcl" \
    -out tfplan
    ```

1. Confirm the Terraform plan will create four resources (2x VMs + 2x null resources for day-2 operations) and ignore the variable warnings

    ```
    Plan: 4 to add, 0 to change, 0 to destroy.

    Changes to Outputs:
    + connector_vm_ips = [
        + (known after apply),
        + (known after apply),
        ]
    ```

1. Apply the Terraform plan to create the Citrix Cloud Connector virtual machines

    ```
    terraform apply tfplan
    ```

1. The output of a successful deployment will show the IP addresses for the Citrix Cloud Connector machines. They are also visible in the Citrix Cloud portal

    ```
    Apply complete! Resources: 4 added, 0 changed, 0 destroyed.

    Outputs:

    connector_vm_ips = [
    "10.38.38.97",
    "10.38.38.115",
    ]
    ```