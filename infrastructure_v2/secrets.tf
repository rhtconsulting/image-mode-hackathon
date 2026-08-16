############################################################
# Generated SSH Key
############################################################

resource "tls_private_key" "lab_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "lab" {
  key_name   = "${var.environment_name}-ssh-key"
  public_key = tls_private_key.lab_ssh.public_key_openssh

  depends_on = [
    terraform_data.preflight_cleanup
  ]

  tags = {
    Name        = "${var.environment_name}-ssh-key"
    Environment = var.environment_name
  }
}

resource "local_sensitive_file" "lab_ssh_private_key" {
  filename        = local.lab_ssh_private_key_filename
  content         = tls_private_key.lab_ssh.private_key_pem
  file_permission = "0600"
}

############################################################
# AWS Secrets Manager
############################################################

locals {
  generated_secret_names = toset([
    "aap/postgresql_admin_password",
    "aap/gateway_admin_password",
    "aap/gateway_pg_password",
    "aap/controller_admin_password",
    "aap/controller_pg_password",
    "aap/hub_admin_password",
    "aap/hub_pg_password",
    "aap/eda_admin_password",
    "aap/eda_pg_password",
    "aap/automationmetrics_pg_password",
    "aap/automationmetrics_controller_read_pg_password",
    "aap/vault_password",
    "idm/admin_password",
    "idm/directory_manager_password",
    "satellite/admin_password",
    "quay/db_password",
    "quay/secret_key",
    "quay/database_secret_key",
    "quay/superuser_password",
    "quay/redis_password",
    "gitlab/root_password",
    "gitlab/postgresql_password",
    "gitlab/redis_password",
    "gitlab/runner_registration_token",
    "gitlab/initial_shared_runner_token",
    "gitlab/rails_secret",
    "gitlab/otp_key_base",
    "gitlab/db_key_base",
    "gitlab/openid_connect_client_secret",
    "keycloak/admin_password",
    "rhtas/fulcio_ca_passphrase",
    "rhtas/ctlog_ca_passphrase",
    "rhtas/rekor_ca_passphrase",
    "rhtas/tsa_ca_passphrase"

  ])

  static_secret_values = {
    "aap/gateway_admin_username" = "admin"
    "quay/superuser"             = "quayadmin"
    "quay/admin_access_token"    = "CHANGE_ME_AFTER_QUAY_DEPLOYMENT"
    "idm/default_user_password"  = var.idm_default_user_password
    # GitLab
    "gitlab/root_username"    = "root"
    "keycloak/admin_username" = "admin"

  }

  redhat_secret_values = {
    "redhat/org_id"             = var.redhat_org_id
    "redhat/aap_activation_key" = var.redhat_aap_activation_key
    "redhat/registry_username"  = var.redhat_registry_username
    "redhat/registry_password"  = var.redhat_registry_password
  }

  all_lab_secret_names = concat(
    [
      for secret_name in local.generated_secret_names :
      "${var.secret_prefix}/${secret_name}"
    ],
    [
      for secret_name, secret_value in local.static_secret_values :
      "${var.secret_prefix}/${secret_name}"
    ],
    [
      for secret_name, secret_value in local.redhat_secret_values :
      "${var.secret_prefix}/${secret_name}"
    ],
    [
      local.lab_ssh_private_key_secret_name,
      "${var.secret_prefix}/satellite/aws_access_key_id",
      "${var.secret_prefix}/satellite/aws_secret_access_key",
      "${var.secret_prefix}/aws/rhel-iam"
    ]
  )
}

############################################################
# Generated Secrets
############################################################

resource "random_password" "generated" {
  for_each = local.generated_secret_names

  length           = 32
  special          = true
  override_special = "_%@"
}

resource "aws_secretsmanager_secret" "generated" {
  for_each = local.generated_secret_names

  depends_on = [
    terraform_data.preflight_cleanup
  ]

  name                    = "${var.secret_prefix}/${each.value}"
  recovery_window_in_days = 0

  tags = {
    Name        = "${var.secret_prefix}/${each.value}"
    Environment = var.environment_name
  }
}

resource "aws_secretsmanager_secret_version" "generated" {
  for_each = local.generated_secret_names

  secret_id     = aws_secretsmanager_secret.generated[each.key].id
  secret_string = random_password.generated[each.key].result

  depends_on = [
    aws_secretsmanager_secret.generated
  ]
}

resource "aws_secretsmanager_secret" "static" {
  for_each = local.static_secret_values

  depends_on = [
    terraform_data.preflight_cleanup
  ]

  name                    = "${var.secret_prefix}/${each.key}"
  recovery_window_in_days = 0

  tags = {
    Name        = "${var.secret_prefix}/${each.key}"
    Environment = var.environment_name
  }
}

resource "aws_secretsmanager_secret_version" "static" {
  for_each = local.static_secret_values

  secret_id     = aws_secretsmanager_secret.static[each.key].id
  secret_string = each.value

  depends_on = [
    aws_secretsmanager_secret.static
  ]
}

resource "aws_secretsmanager_secret" "redhat" {
  for_each = local.redhat_secret_values

  depends_on = [
    terraform_data.preflight_cleanup
  ]

  name                    = "${var.secret_prefix}/${each.key}"
  recovery_window_in_days = 0

  tags = {
    Name        = "${var.secret_prefix}/${each.key}"
    Environment = var.environment_name
  }
}

resource "aws_secretsmanager_secret_version" "redhat" {
  for_each = local.redhat_secret_values

  secret_id     = aws_secretsmanager_secret.redhat[each.key].id
  secret_string = each.value

  depends_on = [
    aws_secretsmanager_secret.redhat
  ]
}

resource "aws_secretsmanager_secret" "ssh_private_key" {
  depends_on = [
    terraform_data.preflight_cleanup
  ]

  name                    = local.lab_ssh_private_key_secret_name
  recovery_window_in_days = 0

  tags = {
    Name        = local.lab_ssh_private_key_secret_name
    Environment = var.environment_name
  }
}

resource "aws_secretsmanager_secret_version" "ssh_private_key" {
  secret_id     = aws_secretsmanager_secret.ssh_private_key.id
  secret_string = tls_private_key.lab_ssh.private_key_pem

  depends_on = [
    aws_secretsmanager_secret.ssh_private_key
  ]
}

############################################################
