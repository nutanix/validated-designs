output "connector_vm_ips" {
  value = nutanix_virtual_machine.citrix_cloud_connector.*.nic_list_status.0.ip_endpoint_list.0.ip
}