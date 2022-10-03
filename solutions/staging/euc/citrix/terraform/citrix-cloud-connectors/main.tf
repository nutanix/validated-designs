provider "nutanix" {
  endpoint     = var.nutanix_endpoint
  username     = var.nutanix_username
  password     = var.nutanix_password
  wait_timeout = var.nutanix_wait
  insecure     = var.nutanix_insecure
  port         = var.nutanix_port
}

resource "nutanix_virtual_machine" "citrix_cloud_connector" {
  count                = length(var.citrix_cloud_connector_vm_name)
  name                 = element(var.citrix_cloud_connector_vm_name, count.index)
  cluster_uuid         = data.nutanix_subnet.vlan.cluster_uuid
  num_vcpus_per_socket = var.citrix_cloud_connector_vm_config.num_vcpus_per_socket
  num_sockets          = var.citrix_cloud_connector_vm_config.num_sockets
  memory_size_mib      = var.citrix_cloud_connector_vm_config.memory_size_mib
  disk_list {
    data_source_reference = {
      kind = "image"
      uuid = data.nutanix_image.image.id
    }
    device_properties {
      device_type = "DISK"
      disk_address = {
        device_index = 0
        adapter_type = "SCSI"
      }
    }
    disk_size_bytes = var.citrix_cloud_connector_vm_config.disk_size_mib * 1024 * 1024
  }

  guest_customization_sysprep = {
    install_type = "PREPARED"
    unattend_xml = base64encode(data.template_file.citrix_cloud_connector_sysprep[count.index].rendered)
  }
  nic_list {
    subnet_uuid = data.nutanix_subnet.vlan.id
  }

  connection {
    type            = "winrm"
    user            = "${var.ad_domain}\\${var.ad_username}"
    password        = var.ad_password
    host            = self.nic_list_status[0].ip_endpoint_list[0].ip
    port            = 5986
    target_platform = "windows"
    https           = true
    insecure        = true
    use_ntlm        = true
  }

  // Required by the next local-exec since it doesn't wait for connection to be ready
  provisioner "remote-exec" {
    inline = [
      "echo Connection ready"
    ]
  }

  provisioner "local-exec" {
    command = <<-EOT
      ansible-playbook -i '${self.nic_list_status[0].ip_endpoint_list[0].ip},' \
      -e "ad_domain=$AD_DOMAIN \
      ad_username=$AD_USERNAME \
      ad_password=$AD_PASSWORD \
      citrix_cloud_api_location=$CTX_API_LOCATION \
      citrix_cloud_customer_id=$CTX_CUSTOMER_ID \
      citrix_cloud_client_id=$CTX_CLIENT_ID \
      citrix_cloud_client_secret=$CTX_CLIENT_SECRET \
      citrix_cloud_resource_location_id=$CTX_RESOURCE_LOCATION \
      nutanix_citrix_plugin_url=$NTNX_CTX_PLUGIN_URL" \
      --tags create ansible/site.yaml
    EOT
    environment = {
      AD_DOMAIN             = "${var.ad_domain}"
      AD_USERNAME           = "${var.ad_username}"
      AD_PASSWORD           = "${var.ad_password}"
      CTX_API_LOCATION      = "${var.citrix_cloud_api_location}"
      CTX_CUSTOMER_ID       = "${var.citrix_cloud_customer_id}"
      CTX_CLIENT_ID         = "${var.citrix_cloud_client_id}"
      CTX_CLIENT_SECRET     = "${var.citrix_cloud_client_secret}"
      CTX_RESOURCE_LOCATION = "${var.citrix_cloud_resource_location_id}"
      NTNX_CTX_PLUGIN_URL   = "${var.nutanix_citrix_plugin_url}"
    }
  }
}
