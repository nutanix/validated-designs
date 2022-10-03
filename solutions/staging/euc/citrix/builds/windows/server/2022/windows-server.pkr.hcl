packer {
  required_version = ">= 1.8.3"
  required_plugins {
    nutanix = {
      version = ">= 0.1.3"
      source  = "github.com/nutanix-cloud-native/nutanix"
    }
  }
  required_plugins {
    windows-update = {
      version = ">= 0.14.1"
      source  = "github.com/rgl/windows-update"
    }
  }
}

locals {
  os_version              = "Windows Server 2022"
  os_family               = "windows"
  os_iso_uuid             = "${var.win2022_os_iso_uuid}"
  virtio_iso_uuid         = "${var.nutanix_virtio_iso_uuid}"
  build_by                = "Built by: HashiCorp Packer ${packer.version}"
  build_date              = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
  build_name              = "${var.ref_prefix}WinSvr2022-{{isotime `2006.01.02_03-04-05`}}"
  manifest_date           = formatdate("YYYY-MM-DD hh:mm:ss", timestamp())
  manifest_path           = "${path.cwd}/manifests/"
  manifest_output         = "${local.manifest_path}${local.manifest_date}.json"
  citrix_cloud_connectors = join(",", var.citrix_cloud_connector_vm_name)
}

source "nutanix" "windows-server-datacenter-gui" {

  // Prism Central Endpoint Settings and Credentials
  nutanix_username = var.nutanix_username
  nutanix_password = var.nutanix_password
  nutanix_endpoint = var.nutanix_endpoint
  nutanix_port     = var.nutanix_port
  nutanix_insecure = var.nutanix_insecure

  // Prism Element Cluster
  cluster_name = var.nutanix_cluster

  // Virtual Machine Settings
  cpu       = var.nutanix_vm_cpu
  os_type   = local.os_family
  memory_mb = var.nutanix_vm_memory_mb
  boot_type = var.nutanix_vm_boot_type
  vm_disks {
    image_type   = "DISK"
    disk_size_gb = var.nutanix_vm_disk_size_gb
  }
  vm_disks {
    image_type        = "ISO_IMAGE"
    source_image_uuid = local.os_iso_uuid
  }
  vm_disks {
    image_type        = "ISO_IMAGE"
    source_image_uuid = local.virtio_iso_uuid
  }
  vm_nics {
    subnet_name = var.nutanix_subnet
  }

  cd_files = [
    "${path.cwd}/scripts/${local.os_family}/"
  ]
  // Generate Autounattend.xml Temp Disc
  cd_content = {
    "Autounattend.xml" = templatefile("${abspath(path.root)}/data/autounattend.pkrtpl.hcl", {
      os_installer_language = var.os_installer_language
      os_installer_keyboard = var.os_installer_keyboard
      os_installer_image    = "Windows Server 2022 SERVERDATACENTER"
      os_installer_kms_key  = var.win2022_kms_key_datacenter
      os_user_language      = var.os_user_language
      os_user_keyboard      = var.os_user_keyboard
      os_user_timezone      = var.os_user_timezone
      os_version            = local.os_version
      build_username        = var.build_username
      build_password        = var.build_password
    })
  }

  // Virtual Machine Connection
  communicator   = "winrm"
  winrm_port     = 5986
  winrm_insecure = true
  winrm_use_ssl  = true
  winrm_timeout  = "6h"
  winrm_password = var.build_password
  winrm_username = var.build_username

  // AHV Disk Image Creation
  image_name       = "${local.build_name}"
  shutdown_command = "%SystemRoot%\\System32\\Sysprep\\sysprep.exe /quiet /generalize /oobe /shutdown /mode:vm"
  shutdown_timeout = "5m"
}
source "nutanix" "windows-server-datacenter-gui-vda" {

  // Prism Central Endpoint Settings and Credentials
  nutanix_username = var.nutanix_username
  nutanix_password = var.nutanix_password
  nutanix_endpoint = var.nutanix_endpoint
  nutanix_port     = var.nutanix_port
  nutanix_insecure = var.nutanix_insecure

  // Prism Element Cluster
  cluster_name = var.nutanix_cluster

  // Virtual Machine Settings
  cpu       = var.nutanix_vm_cpu
  os_type   = local.os_family
  memory_mb = var.nutanix_vm_memory_mb
  boot_type = var.nutanix_vm_boot_type
  vm_disks {
    image_type   = "DISK"
    disk_size_gb = var.nutanix_vm_disk_size_gb
  }
  vm_disks {
    image_type        = "ISO_IMAGE"
    source_image_uuid = local.os_iso_uuid
  }
  vm_disks {
    image_type        = "ISO_IMAGE"
    source_image_uuid = local.virtio_iso_uuid
  }
  vm_nics {
    subnet_name = var.nutanix_subnet
  }

  cd_files = [
    "${path.cwd}/scripts/${local.os_family}/"
  ]
  // Generate Autounattend.xml Temp Disc
  cd_content = {
    "Autounattend.xml" = templatefile("${abspath(path.root)}/data/autounattend.pkrtpl.hcl", {
      os_installer_language = var.os_installer_language
      os_installer_keyboard = var.os_installer_keyboard
      os_installer_image    = "Windows Server 2022 SERVERDATACENTER"
      os_installer_kms_key  = var.win2022_kms_key_datacenter
      os_user_language      = var.os_user_language
      os_user_keyboard      = var.os_user_keyboard
      os_user_timezone      = var.os_user_timezone
      os_version            = local.os_version
      build_username        = var.build_username
      build_password        = var.build_password
    })
  }

  // Virtual Machine Connection
  communicator   = "winrm"
  winrm_port     = 5986
  winrm_insecure = true
  winrm_use_ssl  = true
  winrm_timeout  = "6h"
  winrm_password = var.build_password
  winrm_username = var.build_username

  // AHV Disk Image Creation
  image_name       = "${local.build_name}"
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Shutdown by Packer\""
  shutdown_timeout = "5m"
}

build {
  name = "win2022_fresh"

  sources = [
    "source.nutanix.windows-server-datacenter-gui"
  ]

  provisioner "windows-update" {
    pause_before    = "30s"
    search_criteria = "IsInstalled=0"
    filters = [
      "exclude:$_.Title -like '*Preview*'",
      "exclude:$_.Title -like '*Defender*'",
      "exclude:$_.InstallationBehavior.CanRequestUserInput",
      "include:$true"
    ]
    restart_timeout = "120m"
  }

  post-processor "manifest" {
    output     = local.manifest_output
    strip_path = true
    strip_time = true

    custom_data = {
      build_by          = local.build_by
      build_username    = var.build_username
      build_date        = local.build_date
      build_name        = local.build_name
      vm_cpu            = var.nutanix_vm_cpu
      vm_disk_size      = var.nutanix_vm_disk_size_gb
      vm_mem_size       = var.nutanix_vm_memory_mb
      nutanix_cluster   = var.nutanix_cluster
      nutanix_endpoint  = var.nutanix_endpoint
    }
  }
}
build {
  name = "win2022_vda"

  sources = [
    "source.nutanix.windows-server-datacenter-gui-vda"
  ]

  provisioner "windows-update" {
    pause_before    = "30s"
    search_criteria = "IsInstalled=0"
    filters = [
      "exclude:$_.Title -like '*Preview*'",
      "exclude:$_.Title -like '*Defender*'",
      "exclude:$_.InstallationBehavior.CanRequestUserInput",
      "include:$true"
    ]
    restart_timeout = "120m"
  }

  provisioner "ansible" {
    user          = "${build.User}"
    use_proxy     = false
    playbook_file = "${abspath(path.root)}/ansible/site.yaml"
    extra_arguments = [
      "--extra-vars",
      "ansible_winrm_server_cert_validation=ignore",
      "--extra-vars",
      "winrm_password=${build.Password}",
      "--extra-vars",
      "ansible_shell_type=powershell",
      "--extra-vars",
      "ansible_shell_executable=None",
      "--extra-vars",
      "citrix_cloud_connectors=${local.citrix_cloud_connectors}",
      "--extra-vars",
      "citrix_vda_server_installer_url=${var.citrix_vda_server_installer_url}"
    ]
  }

  post-processor "manifest" {
    output     = local.manifest_output
    strip_path = true
    strip_time = true

    custom_data = {
      build_by          = local.build_by
      build_username    = var.build_username
      build_date        = local.build_date
      build_name        = local.build_name
      vm_cpu            = var.nutanix_vm_cpu
      vm_disk_size      = var.nutanix_vm_disk_size_gb
      vm_mem_size       = var.nutanix_vm_memory_mb
      nutanix_cluster   = var.nutanix_cluster
      nutanix_endpoint  = var.nutanix_endpoint
    }
  }
}