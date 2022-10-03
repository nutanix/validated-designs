terraform {
  required_providers {
    nutanix = {
      source  = "nutanix/nutanix"
      version = "1.7.1"
    }
  }
  required_version = ">= 0.13"
}