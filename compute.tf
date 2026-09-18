# create compute instance
resource "ibm_is_instance" "f5_ve_instance" {
  name           = var.instance_name
  profile        = data.ibm_is_instance_profile.instance_profile.id
  resource_group = data.ibm_resource_group.group.id
  image          = local.image_id
  vpc            = data.ibm_is_subnet.f5_management_subnet.vpc
  zone           = data.ibm_is_subnet.f5_management_subnet.zone
  keys           = [data.ibm_is_ssh_key.ssh_pub_key.id]
  user_data      = data.template_file.user_data.rendered

  # Optional Placement Group support (if supported by v1.30.2)
  placement_group = var.placement_group_id != "" ? var.placement_group_id : null

  # 1. Management / Primary Interface
  primary_network_interface {
    name                 = "management"
    subnet               = data.ibm_is_subnet.f5_management_subnet.id
    security_groups      = [ibm_is_security_group.f5_open_sg.id]
    primary_ipv4_address = var.mgmt_primary_ip != "" ? var.mgmt_primary_ip : null
  }

  # 2. Data Interface 1 (External Subnet)
  dynamic "network_interfaces" {
    for_each = var.external_subnet_id != null && var.external_subnet_id != "" ? [var.external_subnet_id] : []
    content {
      name                 = "eth1-external"
      subnet               = network_interfaces.value
      security_groups      = [ibm_is_security_group.f5_open_sg.id]
      allow_ip_spoofing    = true
      primary_ipv4_address = length(var.data_interface_ips) > 0 ? var.data_interface_ips[0] : null
    }
  }

  # 3. Data Interface 2 (Internal Subnet)
  dynamic "network_interfaces" {
    for_each = var.internal_subnet_id != null && var.internal_subnet_id != "" ? [var.internal_subnet_id] : []
    content {
      name                 = "eth2-internal"
      subnet               = network_interfaces.value
      security_groups      = [ibm_is_security_group.f5_open_sg.id]
      allow_ip_spoofing    = true
      primary_ipv4_address = length(var.data_interface_ips) > 1 ? var.data_interface_ips[1] : null
    }
  }

  # 4. Data Interface 3 (Cluster Subnet)
  dynamic "network_interfaces" {
    for_each = var.cluster_subnet_id != null && var.cluster_subnet_id != "" ? [var.cluster_subnet_id] : []
    content {
      name                 = "eth3-cluster"
      subnet               = network_interfaces.value
      security_groups      = [ibm_is_security_group.f5_open_sg.id]
      allow_ip_spoofing    = true
      primary_ipv4_address = length(var.data_interface_ips) > 2 ? var.data_interface_ips[2] : null
    }
  }

  boot_volume {
    encryption = var.encryption_key_crn == "" ? null : var.encryption_key_crn 
  }

  depends_on = [ibm_is_security_group_rule.f5_allow_outbound]

  timeouts {
    create = "60m"
    delete = "120m"
  }
}
