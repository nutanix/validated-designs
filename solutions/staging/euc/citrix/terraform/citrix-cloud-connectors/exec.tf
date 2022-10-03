resource "null_resource" "scale_nodes" {
  count = length(var.citrix_cloud_connector_vm_name)

  triggers = {
    connector_ip                      = "${element(nutanix_virtual_machine.citrix_cloud_connector.*.nic_list_status.0.ip_endpoint_list.0.ip, count.index)}"
    ad_username                       = var.ad_username
    ad_password                       = var.ad_password
    ad_domain                         = var.ad_domain
    citrix_cloud_api_location         = var.citrix_cloud_api_location
    citrix_cloud_customer_id          = var.citrix_cloud_customer_id
    citrix_cloud_client_id            = var.citrix_cloud_client_id
    citrix_cloud_client_secret        = var.citrix_cloud_client_secret
    citrix_cloud_resource_location_id = var.citrix_cloud_resource_location_id
  }

  connection {
    type            = "winrm"
    user            = "${self.triggers.ad_domain}\\${self.triggers.ad_username}"
    password        = self.triggers.ad_password
    host            = self.triggers.connector_ip
    port            = 5986
    target_platform = "windows"
    https           = true
    insecure        = true
    use_ntlm        = true
  }

  lifecycle {
    create_before_destroy = true
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      ansible-playbook -i '${self.triggers.connector_ip},' \
      -e "ad_domain=$AD_DOMAIN \
      ad_username=$AD_USERNAME \
      ad_password=$AD_PASSWORD \
      citrix_cloud_api_location=$CTX_API_LOCATION \
      citrix_cloud_customer_id=$CTX_CUSTOMER_ID \
      citrix_cloud_client_id=$CTX_CLIENT_ID \
      citrix_cloud_client_secret=$CTX_CLIENT_SECRET \
      citrix_cloud_resource_location_id=$CTX_RESOURCE_LOCATION" \
      --tags destroy ansible/site.yaml
    EOT
    environment = {
      AD_DOMAIN             = "${self.triggers.ad_domain}"
      AD_USERNAME           = "${self.triggers.ad_username}"
      AD_PASSWORD           = "${self.triggers.ad_password}"
      CTX_API_LOCATION      = "${self.triggers.citrix_cloud_api_location}"
      CTX_CUSTOMER_ID       = "${self.triggers.citrix_cloud_customer_id}"
      CTX_CLIENT_ID         = "${self.triggers.citrix_cloud_client_id}"
      CTX_CLIENT_SECRET     = "${self.triggers.citrix_cloud_client_secret}"
      CTX_RESOURCE_LOCATION = "${self.triggers.citrix_cloud_resource_location_id}"
    }
  }
}