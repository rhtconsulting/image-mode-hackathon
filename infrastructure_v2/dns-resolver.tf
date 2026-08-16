############################################################
# Route53 Resolver Forwarding To IdM DNS
############################################################

resource "aws_route53_resolver_endpoint" "outbound" {
  name      = "${var.environment_name}-idm-outbound-resolver"
  direction = "OUTBOUND"

  security_group_ids = [
    aws_security_group.lab.id
  ]

  ip_address {
    subnet_id = aws_subnet.public.id
  }

  ip_address {
    subnet_id = aws_subnet.resolver.id
  }

  tags = {
    Name        = "${var.environment_name}-idm-outbound-resolver"
    Environment = var.environment_name
  }
}

resource "aws_route53_resolver_rule" "idm_forward" {
  domain_name          = local.idm_domain_name
  name                 = "${var.environment_name}-idm-forward-rule"
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.outbound.id

  target_ip {
    ip = local.primary_idm_private_ip
  }

  tags = {
    Name        = "${var.environment_name}-idm-forward-rule"
    Environment = var.environment_name
  }

  depends_on = [
    aws_instance.server,
    terraform_data.validate_idm_server
  ]
}

resource "terraform_data" "validate_public_servers" {
  input = {
    requested = sort(tolist(var.public_server_names))
    available = sort(keys(local.flattened_servers))
  }

  lifecycle {
    precondition {
      condition = (
        length(local.invalid_public_server_names) == 0
      )

      error_message = format(
        "public_server_names contains unknown server names: %s. Available names are: %s.",
        join(", ", sort(tolist(local.invalid_public_server_names))),
        join(", ", sort(keys(local.flattened_servers)))
      )
    }

    precondition {
      condition = (
        length(local.public_servers) <= 5
      )

      error_message = format(
        "This AWS environment permits no more than five Elastic IP addresses, but %d public servers were selected.",
        length(local.public_servers)
      )
    }
  }
}


resource "aws_route53_resolver_rule_association" "idm_forward" {
  resolver_rule_id = aws_route53_resolver_rule.idm_forward.id
  vpc_id           = aws_vpc.lab.id
  name             = "${var.environment_name}-idm-forward-association"
}

############################################################
