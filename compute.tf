# lookup SSH public keys by name
data "ibm_is_ssh_key" "ssh_pub_key" {
  name = var.ssh_key_name
}

# lookup compute profile by name
data "ibm_is_instance_profile" "instance_profile" {
  name = var.instance_profile
}

# create a random password if we need it
resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "_%@"
}

locals {
  do_byol_license = <<EOD

    schemaVersion: 1.0.0
    class: Device
    async: true
    label: Cloudinit Onboarding
    Common:
      class: Tenant
      byoLicense:
        class: License
        licenseType: regKey
        regKey: ${var.byol_license_basekey}
EOD
  do_regekypool   = <<EOD

    schemaVersion: 1.0.0
    class: Device
    async: true
    label: Cloudinit Onboarding
    Common:
      class: Tenant
      poolLicense:
        class: License
        licenseType: licensePool
        bigIqHost: ${var.license_host}
        bigIqUsername: ${var.license_username}
        bigIqPassword: ${var.license_password}
        licensePool: ${var.license_pool}
        reachable: false
        hypervisor: kvm
EOD
  do_utilitypool  = <<EOD

    schemaVersion: 1.0.0
    class: Device
    async: true
    label: Cloudinit Onboarding
    Common:
      class: Tenant
      utilityLicense:
        class: License
        licenseType: licensePool
        bigIqHost: ${var.license_host}
        bigIqUsername: ${var.license_username}
        bigIqPassword: ${var.license_password}
        licensePool: ${var.license_pool}
        skuKeyword1: ${var.license_sku_keyword_1}
        skuKeyword2: ${var.license_sku_keyword_2}
        unitOfMeasure: ${var.license_unit_of_measure}
        reachable: false
        hypervisor: kvm
EOD
}

locals {
  template_file = file("${path.module}/user_data.yaml")
  # user admin_password if supplied, else set a random password
  admin_password = var.tmos_admin_password == "" ? random_password.password.result : var.tmos_admin_password
  # set user_data YAML values or else set them to null for templating
  do_declaration_url   = var.do_declaration_url == "" ? "null" : var.do_declaration_url
  as3_declaration_url  = var.as3_declaration_url == "" ? "null" : var.as3_declaration_url
  ts_declaration_url   = var.ts_declaration_url == "" ? "null" : var.ts_declaration_url
  phone_home_url       = var.phone_home_url == "" ? "null" : var.phone_home_url
  tgactive_url         = var.tgactive_url == "" ? "null" : var.tgactive_url
  tgstandby_url        = var.tgstandby_url == "" ? "null" : var.tgstandby_url
  tgrefresh_url        = var.tgrefresh_url == "" ? "null" : var.tgrefresh_url
  do_dec1              = var.license_type == "byol" ? chomp(local.do_byol_license) : "null"
  do_dec2              = var.license_type == "regkeypool" ? chomp(local.do_regekypool) : local.do_dec1
  do_local_declaration = var.license_type == "utilitypool" ? chomp(local.do_utilitypool) : local.do_dec2
  # default_route_interface
  default_route_interface = var.default_route_interface == "" ? "1.${length(local.secondary_subnets)}" : var.default_route_interface
}

# discovery the 1st address on the default route subnet because IBM does not
# supply the DHCPv4 routers option correctly on non-primary interfaces. This
# is a bug in IBM they need to fix.
data "ibm_is_subnet" "default_route_subnet" {
  identifier = element(local.secondary_subnets, length(local.secondary_subnets) - 1)
}
# IBM does not tell you what the default gateway address for each subnet should
# be, but by undocumented convention we will use the 1st host address in the subnet
locals {
  default_gateway_ipv4_address = cidrhost(data.ibm_is_subnet.default_route_subnet.ipv4_cidr_block, 1)
}

data "template_file" "user_data" {
  template = local.template_file
  vars = {
    tmos_admin_password     = local.admin_password
    configsync_interface    = "1.1"
    hostname                = var.hostname
    domain                  = var.domain
    default_route_interface = local.default_route_interface
    default_route_gateway   = local.default_gateway_ipv4_address
    do_local_declaration    = local.do_local_declaration
    do_declaration_url      = local.do_declaration_url
    as3_declaration_url     = local.as3_declaration_url
    ts_declaration_url      = local.ts_declaration_url
    phone_home_url          = local.phone_home_url
    tgactive_url            = local.tgactive_url
    tgstandby_url           = local.tgstandby_url
    tgrefresh_url           = local.tgrefresh_url
    template_source         = var.template_source
    template_version        = var.template_version
    zone                    = data.ibm_is_subnet.f5_management_subnet.zone
    vpc                     = data.ibm_is_subnet.f5_management_subnet.vpc
    app_id                  = var.app_id
  }
}

# create compute instance
resource "ibm_is_instance" "f5_ve_instance" {
  placement_group = var.placement_group_id
  name           = var.instance_name
  resource_group = data.ibm_resource_group.group.id
  image          = local.image_id
  profile        = data.ibm_is_instance_profile.instance_profile.id
  primary_network_interface {
    name            = "management"
    subnet          = data.ibm_is_subnet.f5_management_subnet.id
    security_groups = [ibm_is_security_group.f5_open_sg.id]
  }
  dynamic "network_interfaces" {
    for_each = local.secondary_subnets
    content {
      name              = format("data-1-%d", (network_interfaces.key + 1))
      subnet            = network_interfaces.value
      security_groups   = [ibm_is_security_group.f5_open_sg.id]
      allow_ip_spoofing = true
    }
  }
# 2. Assign IP to Management / Primary Interface
  primary_network_interface {
    subnet          = var.management_subnet_id
    security_groups = var.management_security_groups

    dynamic "primary_ip" {
      for_each = var.mgmt_primary_ip != null ? [var.mgmt_primary_ip] : []
      content {
        address = primary_ip.value
      }
    }
  }

  # 3. Data Interface 1 (External Subnet)
  dynamic "network_interfaces" {
    for_each = var.external_subnet_id != null && var.external_subnet_id != "" ? [var.external_subnet_id] : []
    content {
      name   = "eth1-external"
      subnet = network_interfaces.value

      dynamic "primary_ip" {
        for_each = length(var.data_interface_ips) > 0 ? [var.data_interface_ips[0]] : []
        content {
          address = primary_ip.value
        }
      }
    }
  }

  # 4. Data Interface 2 (Internal Subnet)
  dynamic "network_interfaces" {
    for_each = var.internal_subnet_id != null && var.internal_subnet_id != "" ? [var.internal_subnet_id] : []
    content {
      name   = "eth2-internal"
      subnet = network_interfaces.value

      dynamic "primary_ip" {
        for_each = length(var.data_interface_ips) > 1 ? [var.data_interface_ips[1]] : []
        content {
          address = primary_ip.value
        }
      }
    }
  }

  # 5. Data Interface 3 (Cluster Subnet)
  dynamic "network_interfaces" {
    for_each = var.cluster_subnet_id != null && var.cluster_subnet_id != "" ? [var.cluster_subnet_id] : []
    content {
      name   = "eth3-cluster"
      subnet = network_interfaces.value

      dynamic "primary_ip" {
        for_each = length(var.data_interface_ips) > 2 ? [var.data_interface_ips[2]] : []
        content {
          address = primary_ip.value
        }
      }
    }
  }
}
  boot_volume {
    encryption = var.encryption_key_crn == "" ? null : var.encryption_key_crn 
  }
  vpc        = data.ibm_is_subnet.f5_management_subnet.vpc
  zone       = data.ibm_is_subnet.f5_management_subnet.zone
  keys       = [data.ibm_is_ssh_key.ssh_pub_key.id]
  user_data  = data.template_file.user_data.rendered
  depends_on = [ibm_is_security_group_rule.f5_allow_outbound]
  timeouts {
    create = "60m"
    delete = "120m"
  }
}

locals {
  vs_interface_index   = length(ibm_is_instance.f5_ve_instance.network_interfaces) - 1
  snat_interface_index = length(ibm_is_instance.f5_ve_instance.network_interfaces) < 3 ? 0 : 1
}

resource "ibm_is_floating_ip" "f5_management_floating_ip" {
  name           = "fmgmt-${random_uuid.namer.result}"
  resource_group = data.ibm_resource_group.group.id
  count          = var.bigip_management_floating_ip ? 1 : 0
  target         = ibm_is_instance.f5_ve_instance.primary_network_interface.0.id
}

resource "ibm_is_floating_ip" "f5_external_floating_ip" {
  name           = "fext-${random_uuid.namer.result}"
  resource_group = data.ibm_resource_group.group.id
  count          = local.external_floating_ip ? 1 : 0
  target         = element(ibm_is_instance.f5_ve_instance.network_interfaces.*.id, local.vs_interface_index)
}
