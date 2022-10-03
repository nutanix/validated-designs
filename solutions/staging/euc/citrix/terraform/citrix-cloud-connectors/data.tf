data "nutanix_subnet" "vlan" {
  subnet_name = var.nutanix_subnet
}

data "nutanix_cluster" "cluster" {
  name = var.nutanix_cluster
}

data "nutanix_image" "image" {
  image_name = var.packer_win2022_disk_image_name
}

data "template_file" "citrix_cloud_connector_sysprep" {
  count    = length(var.citrix_cloud_connector_vm_name)
  template = file("${path.module}/data/unattend.tftpl")
  vars = {
    vm_name          = "${element(var.citrix_cloud_connector_vm_name, count.index)}"
    ad_domain        = var.ad_domain
    ad_username      = var.ad_username
    ad_password      = var.ad_password
    os_user_language = var.os_user_language
    os_user_keyboard = var.os_user_keyboard
    os_user_timezone = var.os_user_timezone
    os_organization  = var.os_organization
    os_owner         = var.os_owner
  }
}