terraform {
  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = ">= 1.56.0"
    }
  }
}

# Configure the IBM Provider
provider "ibm" {
  region = var.region
}

data "ibm_resource_group" "group" {
  name = var.resource_group
}
