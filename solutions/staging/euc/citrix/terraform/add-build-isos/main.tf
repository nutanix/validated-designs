provider "nutanix" {
  endpoint     = var.nutanix_endpoint
  username     = var.nutanix_username
  password     = var.nutanix_password
  wait_timeout = var.nutanix_wait
  insecure     = var.nutanix_insecure
  port         = var.nutanix_port
}

resource "nutanix_image" "virtio_iso" {
  name        = "${var.ref_prefix}${var.nutanix_virtio_iso.name}"
  description = var.nutanix_virtio_iso.description
  source_uri  = var.nutanix_virtio_iso.source_uri
  image_type  = "ISO_IMAGE"
}

output "nutanix_virtio_iso_uuid" {
  value = nutanix_image.virtio_iso.id
}

resource "nutanix_image" "server_os_iso" {
  name        = "${var.ref_prefix}${var.nutanix_server_os_iso.name}"
  description = var.nutanix_server_os_iso.description
  source_uri  = var.nutanix_server_os_iso.source_uri
  image_type  = "ISO_IMAGE"
}

output "win2022_os_iso_uuid" {
  value = nutanix_image.server_os_iso.id
}

resource "nutanix_image" "desktop_os_iso" {
  name        = "${var.ref_prefix}${var.nutanix_desktop_os_iso.name}"
  description = var.nutanix_desktop_os_iso.description
  source_uri  = var.nutanix_desktop_os_iso.source_uri
  image_type  = "ISO_IMAGE"
}

output "win10_os_iso_uuid" {
  value = nutanix_image.desktop_os_iso.id
}

