// Nutanix Validated Design Prefix

variable "ref_prefix" {
  type        = string
  description = "Prefix to include at the start of a resource name"
  default     = "Nutanix_NVD_DaaS_"
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

// ISO details

variable "nutanix_virtio_iso" {
  type = object({
    name        = string
    description = string
    source_uri  = string
  })
  description = "Nutanix VirtIO URL for importing the ISO into AHV Image Service. Required by Packer to build image"
}

variable "nutanix_server_os_iso" {
  type = object({
    name        = string
    description = string
    source_uri  = string
  })
  description = "Microsoft Windows Server URL for importing the ISO into AHV Image Service. Required by Packer to build image"
}

variable "nutanix_desktop_os_iso" {
  type = object({
    name        = string
    description = string
    source_uri  = string
  })
  description = "Microsoft Windows Desktop URL for importing the ISO into AHV Image Service. Required by Packer to build image"

}
