// Nutanix Validated Design Prefix

variable "ref_prefix" {
  type    = string
  description = "Prefix to include at the start of a resource name"
  default = "Nutanix_NVD_DaaS_"
}

// Prism Central credentials

variable "nutanix_username" {
  type        = string
  description = "This is the username for the Prism Central instance. Required for provider"
}

variable "nutanix_password" {
  type        = string
  description = "This is the password for the Prism Central instance. Required for provider"
  sensitive   = true
}

variable "nutanix_endpoint" {
  type        = string
  description = "This is the IP address or FQDN for the Prism Central instance. Required for provider"
}

variable "nutanix_port" {
  type        = number
  description = "This is the port for the Prism Central instance. Required for provider"
  default     = 9440
}

variable "nutanix_insecure" {
  type        = bool
  description = "This specifies whether to allow verify ssl certificates. Required for provider"
  default     = false
}

variable "nutanix_wait" {
  type        = number
  description = "This specifies the timeout on all resource operations in the provider in minutes. Required for provider"
  default     = 1
}

// Prism settings

variable "nutanix_cluster" {
  type = string
  description = "This is the Prism Element cluster name. Required for building the image"
}

variable "nutanix_subnet" {
  type = string
  description = "This is the Prism Element subnet name. Required for building the image"
}

// Virtual machine settings

variable "nutanix_vm_cpu" {
  type    = number
  description = "Number of virtual CPUs. Required for building the image"
  default = 4
}

variable "nutanix_vm_memory_mb" {
  type    = number
  description = "Virtual machine memory. Required for building the image"
  default = 8192
}

variable "nutanix_vm_boot_type" {
  type    = string
  description = "Virtual machine boot type. Required for building the image"
  default = "legacy" # Options: legacy / uefi
}

variable "nutanix_vm_disk_size_gb" {
  type    = number
  description = "Virtual machine disk size (GB). Required for building the image"
  default = 60
}

variable "win10_os_iso_name" {
  type    = string
  description = "Operating system ISO name in AHV Image Service. Required for building the image"
}

variable "nutanix_virtio_iso_name" {
  type    = string
  description = "Nutanix VirtIO ISO name in AHV Image Service. Required for building the image"
}

// OS installer settings for Autounattend.xml

variable "os_installer_language" {
  type    = string
  description = "Operating system installer language. Required by Sysprep for building the image"
  default = "en-US"
}

variable "os_installer_keyboard" {
  type    = string
  description = "Operating system installer keyboard. Required by Sysprep for building the image"
  default = "en-US"
}

variable "win10_kms_key_pro" {
  type = string
  description = "Operating system KMS Windows 10 Pro. Required by Sysprep for building the image"
}

variable "win10_kms_key_enterprise" {
  type = string
  description = "Operating system KMS Windows 10 Enterprise. Required by Sysprep for building the image"
}

variable "win10_image_pro" {
  type    = string
  description = "Selects Windows 10 Pro in the editions menu. Required by Sysprep for building the image"
  default = "Windows 10 Pro" # DO NOT CHANGE
}

// OS user settings for Autounattend.xml

variable "os_user_language" {
  type    = string
  description = "Windows user language. Required by Sysprep for building the image"
  default = "en-US"
}

variable "os_user_keyboard" {
  type    = string
  description = "Windows user keyboard. Required by Sysprep for building the image"
  default = "en-US"
}

variable "os_user_timezone" {
  type    = string
  description = "Windows user timezone. Required by Sysprep for building the image"
  default = "UTC"
}

// Packer connection settings

variable "build_username" {
  type    = string
  description = "Packer username. Required by Packer for connecting to the guest OS"
}

variable "build_password" {
  type      = string
  description = "Packer password. Required by Packer for connecting to the guest OS"
  sensitive = true
}

// Citrix

variable "citrix_cloud_connectors" {
  type = string
  description = "Citrix Cloud Connector machine IP addresses or FQDN separated by commas, ie: citrix1.domain.local,citrix2.domain.local. Required by Citrix VDA"
}

variable "citrix_vda_desktop_installer_url" {
  type = string
  description = "This is the URL to download the Citrix VDA agent for Windows desktop"
}