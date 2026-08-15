# main.tf

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_route53_zones" "public" {}

data "aws_route53_zone" "all_public" {
  for_each = toset(data.aws_route53_zones.public.ids)

  zone_id = each.value
}

locals {
  all_public_zones = {
    for zone_id, zone in data.aws_route53_zone.all_public :
    zone_id => trimsuffix(zone.name, ".")
    if zone.private_zone == false
  }

  discovered_opentlc_zone_ids = [
    for zone_id, zone_name in local.all_public_zones :
    zone_id
    if can(
      regex(
        "^sandbox[0-9]+\\.${replace(var.opentlc_domain_suffix, ".", "\\.")}$",
        zone_name
      )
    )
  ]

  discovered_domain_name = (
    length(local.discovered_opentlc_zone_ids) == 1
    ? local.all_public_zones[local.discovered_opentlc_zone_ids[0]]
    : ""
  )

  discovered_route53_zone_id = (
    length(local.discovered_opentlc_zone_ids) == 1
    ? local.discovered_opentlc_zone_ids[0]
    : ""
  )

  effective_domain_name = (
    trimspace(var.domain_name) != ""
    ? trimsuffix(var.domain_name, ".")
    : local.discovered_domain_name
  )

  public_route53_zone_id = (
    trimspace(var.route53_zone_id) != ""
    ? trimspace(var.route53_zone_id)
    : local.discovered_route53_zone_id
  )

  parent_domain_name = local.effective_domain_name

  idm_dns_subdomain = "lab"
  idm_domain_name   = "${local.idm_dns_subdomain}.${local.parent_domain_name}"
  idm_realm_name    = upper(local.idm_domain_name)
}

resource "terraform_data" "validate_dns_discovery" {
  input = local.effective_domain_name

  lifecycle {
    precondition {
      condition = (
        !var.create_public_dns_records ||
        trimspace(var.domain_name) != "" ||
        length(local.discovered_opentlc_zone_ids) == 1
      )

      error_message = "Unable to auto-discover exactly one public sandbox*.opentlc.com Route53 hosted zone. Set domain_name explicitly."
    }

    precondition {
      condition = (
        !var.create_public_dns_records ||
        local.effective_domain_name != ""
      )

      error_message = "domain_name is blank and no usable public hosted zone was discovered."
    }

    precondition {
      condition = (
        !var.create_public_dns_records ||
        trimspace(var.route53_zone_id) != "" ||
        local.public_route53_zone_id != ""
      )

      error_message = "No public Route53 zone ID could be resolved. Set route53_zone_id explicitly."
    }
  }
}

locals {
  flattened_servers = merge([
    for role, cfg in var.servers : {
      for i in range(cfg.count) :
      "${role}-${i + 1}" => {
        role          = role
        index         = i + 1
        hostname      = "${role}-${i + 1}.${local.idm_domain_name}"
        instance_type = cfg.instance_type
        root_volume   = cfg.root_volume
        extra_volume  = cfg.extra_volume
      }
    }
  ]...)

  ##########################################################
  # Public server selection
  ##########################################################

  public_servers = {
    for name, server in local.flattened_servers :
    name => server
    if contains(var.public_server_names, name)
  }

  private_servers = {
    for name, server in local.flattened_servers :
    name => server
    if !contains(var.public_server_names, name)
  }

  invalid_public_server_names = setsubtract(
    var.public_server_names,
    toset(keys(local.flattened_servers))
  )

  idm_server_keys = sort([
    for name, server in local.flattened_servers :
    name
    if server.role == "idm"
  ])

  primary_idm_key = try(
    local.idm_server_keys[0],
    null
  )

  primary_idm_hostname = (
    local.primary_idm_key != null
    ? local.flattened_servers[local.primary_idm_key].hostname
    : null
  )
}

resource "terraform_data" "validate_idm_server" {
  input = local.idm_server_keys

  lifecycle {
    precondition {
      condition     = length(local.idm_server_keys) >= 1
      error_message = "var.servers must include an idm role with count >= 1 so Route53 Resolver can forward lab DNS queries to the selected primary IdM server."
    }
  }
}

data "aws_ami" "rhel9" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["309956199498"]

  filter {
    name   = "name"
    values = ["RHEL-9*_HVM-*-x86_64-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  selected_ami = (
    var.ami_id != ""
    ? var.ami_id
    : data.aws_ami.rhel9[0].id
  )

  aws_dns_resolver = cidrhost(
    aws_vpc.lab.cidr_block,
    2
  )

  lab_ssh_private_key_filename = (
    "${path.module}/image-mode-lab-key.pem"
  )

  ansible_ssh_private_key_file = abspath(
    local.lab_ssh_private_key_filename
  )

  lab_ssh_private_key_secret_name = (
    "${var.secret_prefix}/aws/ssh_private_key"
  )
}

############################################################
