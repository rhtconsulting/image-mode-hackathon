############################################################
# EC2 Instances
############################################################

locals {
  # Role-specific infrastructure belongs here. A role that is not listed uses
  # the shared default profile and common lab security group automatically.
  # This keeps aws_instance.server generic as new server roles are introduced.
  instance_profile_by_role = {
    aap           = aws_iam_instance_profile.aap.name
    satellite     = aws_iam_instance_profile.satellite.name
    gitlab        = aws_iam_instance_profile.gitlab_runtime.name
    image-builder = aws_iam_instance_profile.image_builder.name

    # Keycloak deliberately uses the same default profile as the other common
    # lab nodes. That role already has the shared artifact-bucket policy, so
    # Ansible can copy the configured installer ZIP without another IAM policy.
    keycloak = aws_iam_instance_profile.lab_ec2_default.name

    # RHTAS uses the shared/default profile. Add a dedicated profile only if
    # future backup or KMS requirements need workload-specific permissions.
    rhtas = aws_iam_instance_profile.lab_ec2_default.name
  }

  additional_security_groups_by_role = {
    gitlab        = [aws_security_group.gitlab.id]
    image-builder = [aws_security_group.image_builder.id]

    # Keycloak uses aws_security_group.lab, which is always attached below.
    # Add a Keycloak-specific security group here if nonstandard ports are
    # exposed in network.tf later.
    keycloak = []

    # Public RHTAS services are exposed through HTTPS on the common lab group.
    rhtas = []
  }
}

resource "aws_instance" "server" {
  # local.flattened_servers contains keycloak-1 and rhtas-1 because those roles
  # are defined in var.servers. Increasing a role count creates the subsequent
  # numbered instances through this same generic resource.
  for_each = local.flattened_servers

  ami           = local.selected_ami
  instance_type = each.value.instance_type
  subnet_id     = aws_subnet.public.id

  vpc_security_group_ids = concat(
    # aws_security_group.lab permits HTTPS on TCP/443. Keycloak and RHTAS receive
    # this group automatically, so no workload-only security group is required.
    [aws_security_group.lab.id],
    lookup(local.additional_security_groups_by_role, each.value.role, [])
  )

  key_name                    = aws_key_pair.lab.key_name
  associate_public_ip_address = true

  iam_instance_profile = lookup(
    local.instance_profile_by_role,
    each.value.role,
    aws_iam_instance_profile.lab_ec2_default.name
  )

  root_block_device {
    volume_size = each.value.root_volume
    volume_type = "gp3"
    encrypted   = true

    tags = {
      Name        = "${each.value.hostname}-root"
      Role        = each.value.role
      Environment = var.environment_name
    }
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    hostnamectl set-hostname "${each.value.hostname}"

    cat > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg <<'CLOUD_CFG'
    preserve_hostname: true
    CLOUD_CFG
  EOF

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tags = {
    Name        = each.value.hostname
    Role        = each.value.role
    Environment = var.environment_name
  }

  depends_on = [
    terraform_data.validate_dns_discovery,
    terraform_data.validate_idm_server,

    aws_key_pair.lab,
    local_sensitive_file.lab_ssh_private_key,

    aws_iam_instance_profile.aap,
    aws_iam_role_policy.aap_secrets_read,
    aws_iam_role_policy.aap_s3_read,
    aws_iam_instance_profile.lab_ec2_default,

    aws_iam_instance_profile.satellite,
    aws_iam_role_policy.satellite_secrets_read,
    aws_iam_role_policy.satellite_s3_read,
    aws_iam_role_policy_attachment.satellite_ec2_discovery,

    aws_iam_instance_profile.gitlab_runtime,

    aws_security_group.lab,
    aws_security_group.image_builder,
    aws_security_group.gitlab,

    aws_secretsmanager_secret_version.ssh_private_key,
    aws_secretsmanager_secret_version.generated,
    aws_secretsmanager_secret_version.static,
    aws_secretsmanager_secret_version.redhat,

    aws_secretsmanager_secret_version.satellite_aws_access_key_id,
    aws_secretsmanager_secret_version.satellite_aws_secret_access_key
  ]
}

locals {
  primary_idm_private_ip = try(
    aws_instance.server[local.primary_idm_key].private_ip,
    null
  )
}

resource "aws_ebs_volume" "extra" {
  for_each = {
    for name, server in local.flattened_servers :
    name => server
    if server.extra_volume > 0
  }

  availability_zone = aws_subnet.public.availability_zone
  size              = each.value.extra_volume
  type              = "gp3"
  encrypted         = true

  tags = {
    Name        = "${each.value.hostname}-data"
    Role        = each.value.role
    Environment = var.environment_name
  }
}

resource "aws_volume_attachment" "extra" {
  for_each = aws_ebs_volume.extra

  device_name = "/dev/sdf"
  volume_id   = each.value.id
  instance_id = aws_instance.server[each.key].id
}

############################################################
# Elastic IPs For Selected Public Servers
############################################################

resource "aws_eip" "server" {
  for_each = {
    for name, instance in aws_instance.server :
    name => instance
    if contains(var.public_server_names, name)
  }

  domain = "vpc"

  tags = {
    Name        = "${each.value.tags.Name}-eip"
    ServerName  = each.key
    Environment = var.environment_name
    ManagedBy   = "Terraform"
  }

  depends_on = [
    terraform_data.validate_public_servers
  ]
}

resource "aws_eip_association" "server" {
  for_each = aws_eip.server

  instance_id   = aws_instance.server[each.key].id
  allocation_id = each.value.id
}

############################################################
# Public DNS Records
############################################################

resource "aws_route53_record" "public_dns" {
  for_each = (
    var.create_public_dns_records
    ? local.flattened_servers
    : {}
  )

  zone_id = local.public_route53_zone_id
  name    = each.value.hostname
  type    = "A"

  ttl             = 300
  allow_overwrite = true

  records = [
    try(
      aws_eip.server[each.key].public_ip,
      aws_instance.server[each.key].public_ip
    )
  ]

  depends_on = [
    aws_eip_association.server,
    terraform_data.validate_dns_discovery
  ]
}

############################################################
# RHTAS Public Service DNS Records
############################################################

locals {
  rhtas_service_dns_records = merge(
    {},
    [
      for server_name, server in local.flattened_servers : {
        for service_name in var.rhtas_service_subdomains :
        "${server_name}-${service_name}" => {
          server_name = server_name
          service     = service_name
          fqdn        = "${service_name}.${server.hostname}"
        }
      }
      if server.role == "rhtas"
    ]...
  )
}

resource "aws_route53_record" "rhtas_service" {
  for_each = (
    var.create_public_dns_records
    ? local.rhtas_service_dns_records
    : {}
  )

  zone_id = local.public_route53_zone_id
  name    = each.value.fqdn
  type    = "A"

  ttl             = 300
  allow_overwrite = true

  records = [
    try(
      aws_eip.server[each.value.server_name].public_ip,
      aws_instance.server[each.value.server_name].public_ip
    )
  ]

  depends_on = [
    aws_eip_association.server,
    terraform_data.validate_dns_discovery
  ]
}

############################################################
# Publicly Trusted TLS Certificates
############################################################

resource "aws_acm_certificate" "server" {
  # This iterates over every configured server. RHTAS receives a wildcard SAN
  # covering fulcio, rekor, tuf, cli-server, and future service subdomains.
  for_each = (
    var.create_public_dns_records
    ? local.flattened_servers
    : {}
  )

  domain_name       = each.value.hostname
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

  subject_alternative_names = (
    each.value.role == "rhtas"
    ? ["*.${each.value.hostname}"]
    : []
  )

  options {
    certificate_transparency_logging_preference = "ENABLED"

    # Allows the certificate, certificate chain, and encrypted
    # private key to be exported and installed directly on EC2.
    export = "ENABLED"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${each.value.hostname}-public-tls"
    Hostname    = each.value.hostname
    Role        = each.value.role
    Environment = var.environment_name
  }

  depends_on = [
    aws_route53_record.public_dns,
    terraform_data.validate_dns_discovery
  ]
}

############################################################
# ACM DNS Validation Records
############################################################

locals {
  # These keys are derived entirely from configuration known during planning.
  # The key format also preserves the existing validation-record addresses for
  # servers that had certificates before the RHTAS wildcard SAN was added.
  acm_validation_servers = {
    for server_name, server in local.flattened_servers :
    "${server_name}-${server.hostname}" => {
      server_name = server_name
    }
    if var.create_public_dns_records
  }
}

resource "aws_route53_record" "server_certificate_validation" {
  for_each = local.acm_validation_servers

  # ACM uses the same DNS validation token for an exact hostname and its
  # wildcard SAN, so one CNAME validates both names on the RHTAS certificate.
  zone_id = local.public_route53_zone_id
  name = tolist(
    aws_acm_certificate.server[each.value.server_name].domain_validation_options
  )[0].resource_record_name
  type = tolist(
    aws_acm_certificate.server[each.value.server_name].domain_validation_options
  )[0].resource_record_type
  ttl = 60

  records = [
    tolist(
      aws_acm_certificate.server[each.value.server_name].domain_validation_options
    )[0].resource_record_value
  ]

  allow_overwrite = true

  depends_on = [
    terraform_data.validate_dns_discovery
  ]
}

############################################################
# Wait For ACM Certificate Issuance
############################################################

resource "aws_acm_certificate_validation" "server" {
  for_each = aws_acm_certificate.server

  certificate_arn = each.value.arn

  validation_record_fqdns = [
    aws_route53_record.server_certificate_validation[
      "${each.key}-${local.flattened_servers[each.key].hostname}"
    ].fqdn
  ]
}
