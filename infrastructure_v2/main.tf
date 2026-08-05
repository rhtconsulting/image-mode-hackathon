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
    "gitlab/openid_connect_client_secret"

  ])

  static_secret_values = {
    "aap/gateway_admin_username" = "admin"
    "quay/superuser"             = "quayadmin"
    "quay/admin_access_token"    = "CHANGE_ME_AFTER_QUAY_DEPLOYMENT"
    "idm/default_user_password"  = var.idm_default_user_password
    # GitLab
    "gitlab/root_username" = "root"

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
############################################################
# Preflight Cleanup For Lab Rebuilds
############################################################

resource "terraform_data" "preflight_cleanup" {
  input = {
    cleanup_version  = 5
    environment_name = var.environment_name
    secret_prefix    = var.secret_prefix
    aws_region       = var.aws_region
    aws_profile      = var.aws_profile
    key_pair_name    = "${var.environment_name}-ssh-key"

    aap_role_name    = "${var.environment_name}-aap-role"
    aap_profile_name = "${var.environment_name}-aap-instance-profile"

    satellite_role_name    = "${var.environment_name}-satellite-role"
    satellite_profile_name = "${var.environment_name}-satellite-instance-profile"

    gitlab_role_name    = "${var.environment_name}-gitlab-runtime-role"
    gitlab_profile_name = "${var.environment_name}-gitlab-instance-profile"

    satellite_provisioner_user_name = (
      "${var.environment_name}-satellite-provisioner"
    )

    rhel_iam_user_name = "rhel-iam"

    lab_default_role_name = (
      "${var.environment_name}-ec2-default-role"
    )

    lab_default_profile_name = (
      "${var.environment_name}-ec2-default-instance-profile"
    )

    image_builder_role_name = (
      "${var.environment_name}-image-builder-role"
    )

    image_builder_profile_name = (
      "${var.environment_name}-image-builder-instance-profile"
    )

    vmimport_role_name = "vmimport"

    image_mode_artifact_policy_name = (
      "${var.environment_name}-image-mode-artifact-bucket-rw"
    )

    bootc_ami_import_policy_name = (
      "${var.environment_name}-bootc-ami-import-caller"
    )

    ec2_discovery_policy_name = (
      "${var.environment_name}-ec2-discovery"
    )

    secrets = local.all_lab_secret_names
  }

  provisioner "local-exec" {
    working_dir = path.module

    command = <<-EOT
      set -euo pipefail

      export AWS_REGION="${var.aws_region}"
      export AWS_DEFAULT_REGION="${var.aws_region}"

      if [ -n "${var.aws_profile}" ]; then
        export AWS_PROFILE="${var.aws_profile}"
      fi

      KEY_PAIR_NAME="${var.environment_name}-ssh-key"

      AAP_ROLE_NAME="${var.environment_name}-aap-role"
      AAP_PROFILE_NAME="${var.environment_name}-aap-instance-profile"

      SATELLITE_ROLE_NAME="${var.environment_name}-satellite-role"
      SATELLITE_PROFILE_NAME="${var.environment_name}-satellite-instance-profile"

      GITLAB_ROLE_NAME="${var.environment_name}-gitlab-runtime-role"
      GITLAB_PROFILE_NAME="${var.environment_name}-gitlab-instance-profile"

      LAB_DEFAULT_ROLE_NAME="${var.environment_name}-ec2-default-role"
      LAB_DEFAULT_PROFILE_NAME="${var.environment_name}-ec2-default-instance-profile"

      IMAGE_BUILDER_ROLE_NAME="${var.environment_name}-image-builder-role"
      IMAGE_BUILDER_PROFILE_NAME="${var.environment_name}-image-builder-instance-profile"

      VMIMPORT_ROLE_NAME="vmimport"
      VMIMPORT_POLICY_NAME="${var.environment_name}-vmimport"

      SATELLITE_PROVISIONER_USER_NAME="${var.environment_name}-satellite-provisioner"
      SATELLITE_PROVISIONER_POLICY_NAME="${var.environment_name}-satellite-ec2-provisioning"

      RHEL_IAM_USER_NAME="rhel-iam"

      IMAGE_MODE_ARTIFACT_POLICY_NAME="${var.environment_name}-image-mode-artifact-bucket-rw"
      BOOTC_AMI_IMPORT_POLICY_NAME="${var.environment_name}-bootc-ami-import-caller"
      EC2_DISCOVERY_POLICY_NAME="${var.environment_name}-ec2-discovery"

      echo "Preflight cleanup: duplicate-prone unmanaged lab resources"

      #########################################################################
      # Terraform state helpers
      #########################################################################

      state_has() {
        terraform state list 2>/dev/null | grep -Fqx "$1"
      }

      #########################################################################
      # IAM instance profile cleanup
      #########################################################################

      cleanup_instance_profile() {
        local state_address="$1"
        local profile_name="$2"
        local role_name="$3"

        if state_has "$state_address"; then
          echo "Skipping $profile_name because it is managed by Terraform state."
          return
        fi

        echo "Removing unmanaged role $role_name from instance profile $profile_name"

        aws iam remove-role-from-instance-profile \
          --instance-profile-name "$profile_name" \
          --role-name "$role_name" \
          >/dev/null 2>&1 || true

        echo "Deleting unmanaged instance profile: $profile_name"

        aws iam delete-instance-profile \
          --instance-profile-name "$profile_name" \
          >/dev/null 2>&1 || true
      }

      #########################################################################
      # IAM inline role policy cleanup
      #########################################################################

      cleanup_inline_role_policy() {
        local state_address="$1"
        local role_name="$2"
        local policy_name="$3"

        if state_has "$state_address"; then
          echo "Skipping $policy_name because it is managed by Terraform state."
          return
        fi

        echo "Deleting unmanaged inline role policy: $policy_name"

        aws iam delete-role-policy \
          --role-name "$role_name" \
          --policy-name "$policy_name" \
          >/dev/null 2>&1 || true
      }

      #########################################################################
      # IAM managed policy attachment cleanup
      #########################################################################

      cleanup_all_role_policy_attachments() {
        local role_name="$1"

        POLICY_ARNS=$(aws iam list-attached-role-policies \
          --role-name "$role_name" \
          --query 'AttachedPolicies[].PolicyArn' \
          --output text 2>/dev/null || true)

        for POLICY_ARN in $POLICY_ARNS; do
          [ -n "$POLICY_ARN" ] || continue
          [ "$POLICY_ARN" != "None" ] || continue

          echo "Detaching policy $POLICY_ARN from role $role_name"

          aws iam detach-role-policy \
            --role-name "$role_name" \
            --policy-arn "$POLICY_ARN" \
            >/dev/null 2>&1 || true
        done
      }

      cleanup_all_user_policy_attachments() {
        local user_name="$1"

        POLICY_ARNS=$(aws iam list-attached-user-policies \
          --user-name "$user_name" \
          --query 'AttachedPolicies[].PolicyArn' \
          --output text 2>/dev/null || true)

        for POLICY_ARN in $POLICY_ARNS; do
          [ -n "$POLICY_ARN" ] || continue
          [ "$POLICY_ARN" != "None" ] || continue

          echo "Detaching policy $POLICY_ARN from user $user_name"

          aws iam detach-user-policy \
            --user-name "$user_name" \
            --policy-arn "$POLICY_ARN" \
            >/dev/null 2>&1 || true
        done
      }

      #########################################################################
      # IAM role cleanup
      #########################################################################

      cleanup_role() {
        local state_address="$1"
        local role_name="$2"

        if state_has "$state_address"; then
          echo "Skipping $role_name because it is managed by Terraform state."
          return
        fi

        cleanup_all_role_policy_attachments "$role_name"

        INLINE_POLICY_NAMES=$(aws iam list-role-policies \
          --role-name "$role_name" \
          --query 'PolicyNames[]' \
          --output text 2>/dev/null || true)

        for POLICY_NAME in $INLINE_POLICY_NAMES; do
          [ -n "$POLICY_NAME" ] || continue
          [ "$POLICY_NAME" != "None" ] || continue

          echo "Deleting inline policy $POLICY_NAME from role $role_name"

          aws iam delete-role-policy \
            --role-name "$role_name" \
            --policy-name "$POLICY_NAME" \
            >/dev/null 2>&1 || true
        done

        echo "Deleting unmanaged IAM role: $role_name"

        aws iam delete-role \
          --role-name "$role_name" \
          >/dev/null 2>&1 || true
      }

      #########################################################################
      # Customer-managed IAM policy cleanup
      #########################################################################

      cleanup_managed_policy() {
        local state_address="$1"
        local policy_name="$2"

        if state_has "$state_address"; then
          echo "Skipping $policy_name because it is managed by Terraform state."
          return
        fi

        POLICY_ARN=$(aws iam list-policies \
          --scope Local \
          --query "Policies[?PolicyName=='$policy_name'].Arn | [0]" \
          --output text 2>/dev/null || true)

        if [ -z "$POLICY_ARN" ] || [ "$POLICY_ARN" = "None" ]; then
          return
        fi

        echo "Cleaning unmanaged customer-managed policy: $policy_name"

        ROLE_NAMES=$(aws iam list-entities-for-policy \
          --policy-arn "$POLICY_ARN" \
          --query 'PolicyRoles[].RoleName' \
          --output text 2>/dev/null || true)

        for ROLE_NAME in $ROLE_NAMES; do
          [ -n "$ROLE_NAME" ] || continue
          [ "$ROLE_NAME" != "None" ] || continue

          aws iam detach-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-arn "$POLICY_ARN" \
            >/dev/null 2>&1 || true
        done

        USER_NAMES=$(aws iam list-entities-for-policy \
          --policy-arn "$POLICY_ARN" \
          --query 'PolicyUsers[].UserName' \
          --output text 2>/dev/null || true)

        for USER_NAME in $USER_NAMES; do
          [ -n "$USER_NAME" ] || continue
          [ "$USER_NAME" != "None" ] || continue

          aws iam detach-user-policy \
            --user-name "$USER_NAME" \
            --policy-arn "$POLICY_ARN" \
            >/dev/null 2>&1 || true
        done

        GROUP_NAMES=$(aws iam list-entities-for-policy \
          --policy-arn "$POLICY_ARN" \
          --query 'PolicyGroups[].GroupName' \
          --output text 2>/dev/null || true)

        for GROUP_NAME in $GROUP_NAMES; do
          [ -n "$GROUP_NAME" ] || continue
          [ "$GROUP_NAME" != "None" ] || continue

          aws iam detach-group-policy \
            --group-name "$GROUP_NAME" \
            --policy-arn "$POLICY_ARN" \
            >/dev/null 2>&1 || true
        done

        POLICY_VERSIONS=$(aws iam list-policy-versions \
          --policy-arn "$POLICY_ARN" \
          --query 'Versions[?IsDefaultVersion==`false`].VersionId' \
          --output text 2>/dev/null || true)

        for VERSION_ID in $POLICY_VERSIONS; do
          [ -n "$VERSION_ID" ] || continue
          [ "$VERSION_ID" != "None" ] || continue

          aws iam delete-policy-version \
            --policy-arn "$POLICY_ARN" \
            --version-id "$VERSION_ID" \
            >/dev/null 2>&1 || true
        done

        aws iam delete-policy \
          --policy-arn "$POLICY_ARN" \
          >/dev/null 2>&1 || true
      }

      #########################################################################
      # EC2 key pair cleanup
      #########################################################################

      echo "Checking EC2 key pair: $KEY_PAIR_NAME"

      if state_has 'aws_key_pair.lab'; then
        echo "Skipping key pair cleanup because aws_key_pair.lab is managed by Terraform state."
      else
        aws ec2 delete-key-pair \
          --key-name "$KEY_PAIR_NAME" \
          >/dev/null 2>&1 || true
      fi

      #########################################################################
      # Secrets Manager cleanup
      #########################################################################

      echo "Checking Secrets Manager secrets"

      cat > /tmp/image-mode-lab-secret-names.txt <<'EOF_SECRETS'
%{ for secret_name in local.all_lab_secret_names ~}
${secret_name}
%{ endfor ~}
EOF_SECRETS

      while IFS= read -r SECRET_NAME; do
        [ -n "$SECRET_NAME" ] || continue

        case "$SECRET_NAME" in
          "${var.secret_prefix}/satellite/aws_access_key_id")
            SECRET_STATE_ADDRESS='aws_secretsmanager_secret.satellite_aws_access_key_id'
            ;;

          "${var.secret_prefix}/satellite/aws_secret_access_key")
            SECRET_STATE_ADDRESS='aws_secretsmanager_secret.satellite_aws_secret_access_key'
            ;;

          "${var.secret_prefix}/aws/rhel-iam")
            SECRET_STATE_ADDRESS='aws_secretsmanager_secret.rhel_iam_credentials'
            ;;

          "${local.lab_ssh_private_key_secret_name}")
            SECRET_STATE_ADDRESS='aws_secretsmanager_secret.ssh_private_key'
            ;;

          *)
            # Generated, static, and Red Hat secrets are managed through
            # for_each resources. If any collection is in state, Terraform
            # owns those secrets and preflight must not remove them.
            if terraform state list 2>/dev/null |
              grep -Eq '^aws_secretsmanager_secret\.(generated|static|redhat)\['; then
              continue
            fi

            SECRET_STATE_ADDRESS=''
            ;;
        esac

        if [ -n "$SECRET_STATE_ADDRESS" ] &&
          state_has "$SECRET_STATE_ADDRESS"; then
          echo "Skipping managed secret: $SECRET_NAME"
          continue
        fi

        echo "Deleting unmanaged secret if it exists: $SECRET_NAME"

        aws secretsmanager delete-secret \
          --secret-id "$SECRET_NAME" \
          --force-delete-without-recovery \
          >/dev/null 2>&1 || true

        for i in $(seq 1 30); do
          if aws secretsmanager describe-secret \
            --secret-id "$SECRET_NAME" \
            >/dev/null 2>&1; then
            sleep 2
          else
            break
          fi
        done
      done < /tmp/image-mode-lab-secret-names.txt

      rm -f /tmp/image-mode-lab-secret-names.txt

      #########################################################################
      # AAP IAM resources
      #########################################################################

      echo "Checking AAP IAM resources"

      cleanup_instance_profile \
        'aws_iam_instance_profile.aap' \
        "$AAP_PROFILE_NAME" \
        "$AAP_ROLE_NAME"

      cleanup_inline_role_policy \
        'aws_iam_role_policy.aap_secrets_read' \
        "$AAP_ROLE_NAME" \
        "${var.environment_name}-aap-secrets-read"

      cleanup_inline_role_policy \
        'aws_iam_role_policy.aap_s3_read' \
        "$AAP_ROLE_NAME" \
        "${var.environment_name}-aap-s3-read"

      if ! state_has 'aws_iam_role.aap'; then
        cleanup_all_role_policy_attachments \
          "$AAP_ROLE_NAME"
      fi

      cleanup_role \
        'aws_iam_role.aap' \
        "$AAP_ROLE_NAME"

      #########################################################################
      # Satellite host IAM resources
      #########################################################################

      echo "Checking Satellite host IAM resources"

      cleanup_instance_profile \
        'aws_iam_instance_profile.satellite' \
        "$SATELLITE_PROFILE_NAME" \
        "$SATELLITE_ROLE_NAME"

      cleanup_inline_role_policy \
        'aws_iam_role_policy.satellite_secrets_read' \
        "$SATELLITE_ROLE_NAME" \
        "${var.environment_name}-satellite-secrets-read"

      cleanup_inline_role_policy \
        'aws_iam_role_policy.satellite_s3_read' \
        "$SATELLITE_ROLE_NAME" \
        "${var.environment_name}-satellite-s3-read"

      if ! state_has 'aws_iam_role.satellite'; then
        cleanup_all_role_policy_attachments \
          "$SATELLITE_ROLE_NAME"
      fi

      cleanup_role \
        'aws_iam_role.satellite' \
        "$SATELLITE_ROLE_NAME"

      #########################################################################
      # GitLab IAM resources
      #########################################################################

      echo "Checking GitLab runtime IAM resources"

      cleanup_instance_profile \
        'aws_iam_instance_profile.gitlab_runtime' \
        "$GITLAB_PROFILE_NAME" \
        "$GITLAB_ROLE_NAME"

      cleanup_inline_role_policy \
        'aws_iam_role_policy.gitlab_runtime' \
        "$GITLAB_ROLE_NAME" \
        "${var.environment_name}-gitlab-runtime"

      if ! state_has 'aws_iam_role.gitlab_runtime'; then
        cleanup_all_role_policy_attachments \
          "$GITLAB_ROLE_NAME"
      fi

      cleanup_role \
        'aws_iam_role.gitlab_runtime' \
        "$GITLAB_ROLE_NAME"

      #########################################################################
      # Default lab EC2 IAM resources
      #########################################################################

      echo "Checking default lab EC2 IAM resources"

      cleanup_instance_profile \
        'aws_iam_instance_profile.lab_ec2_default' \
        "$LAB_DEFAULT_PROFILE_NAME" \
        "$LAB_DEFAULT_ROLE_NAME"

      if ! state_has 'aws_iam_role.lab_ec2_default'; then
        cleanup_all_role_policy_attachments \
          "$LAB_DEFAULT_ROLE_NAME"
      fi

      cleanup_role \
        'aws_iam_role.lab_ec2_default' \
        "$LAB_DEFAULT_ROLE_NAME"

      #########################################################################
      # Image Builder IAM resources
      #########################################################################

      echo "Checking Image Builder IAM resources"

      cleanup_instance_profile \
        'aws_iam_instance_profile.image_builder' \
        "$IMAGE_BUILDER_PROFILE_NAME" \
        "$IMAGE_BUILDER_ROLE_NAME"

      if ! state_has 'aws_iam_role.image_builder'; then
        cleanup_all_role_policy_attachments \
          "$IMAGE_BUILDER_ROLE_NAME"
      fi

      cleanup_role \
        'aws_iam_role.image_builder' \
        "$IMAGE_BUILDER_ROLE_NAME"

      #########################################################################
      # VM Import/Export IAM resources
      #########################################################################

      echo "Checking VM Import/Export IAM resources"

      cleanup_inline_role_policy \
        'aws_iam_role_policy.vmimport' \
        "$VMIMPORT_ROLE_NAME" \
        "$VMIMPORT_POLICY_NAME"

      cleanup_role \
        'aws_iam_role.vmimport' \
        "$VMIMPORT_ROLE_NAME"

      #########################################################################
      # Satellite provisioning IAM user
      #########################################################################

      echo "Checking Satellite provisioning IAM user"

      if state_has 'aws_iam_user.satellite_provisioner'; then
        echo "Skipping Satellite provisioner user because it is managed by Terraform state."
      else
        ACCESS_KEY_IDS=$(aws iam list-access-keys \
          --user-name "$SATELLITE_PROVISIONER_USER_NAME" \
          --query 'AccessKeyMetadata[].AccessKeyId' \
          --output text 2>/dev/null || true)

        for ACCESS_KEY_ID in $ACCESS_KEY_IDS; do
          [ -n "$ACCESS_KEY_ID" ] || continue
          [ "$ACCESS_KEY_ID" != "None" ] || continue

          aws iam delete-access-key \
            --user-name "$SATELLITE_PROVISIONER_USER_NAME" \
            --access-key-id "$ACCESS_KEY_ID" \
            >/dev/null 2>&1 || true
        done

        cleanup_all_user_policy_attachments \
          "$SATELLITE_PROVISIONER_USER_NAME"

        INLINE_POLICY_NAMES=$(aws iam list-user-policies \
          --user-name "$SATELLITE_PROVISIONER_USER_NAME" \
          --query 'PolicyNames[]' \
          --output text 2>/dev/null || true)

        for POLICY_NAME in $INLINE_POLICY_NAMES; do
          [ -n "$POLICY_NAME" ] || continue
          [ "$POLICY_NAME" != "None" ] || continue

          aws iam delete-user-policy \
            --user-name "$SATELLITE_PROVISIONER_USER_NAME" \
            --policy-name "$POLICY_NAME" \
            >/dev/null 2>&1 || true
        done

        aws iam delete-login-profile \
          --user-name "$SATELLITE_PROVISIONER_USER_NAME" \
          >/dev/null 2>&1 || true

        aws iam delete-user \
          --user-name "$SATELLITE_PROVISIONER_USER_NAME" \
          >/dev/null 2>&1 || true
      fi

      #########################################################################
      # rhel-iam automation user
      #########################################################################

      echo "Checking rhel-iam automation user"

      if state_has 'aws_iam_user.rhel_iam'; then
        echo "Skipping rhel-iam because it is managed by Terraform state."
      else
        RHEL_IAM_ACCESS_KEY_IDS=$(aws iam list-access-keys \
          --user-name "$RHEL_IAM_USER_NAME" \
          --query 'AccessKeyMetadata[].AccessKeyId' \
          --output text 2>/dev/null || true)

        for ACCESS_KEY_ID in $RHEL_IAM_ACCESS_KEY_IDS; do
          [ -n "$ACCESS_KEY_ID" ] || continue
          [ "$ACCESS_KEY_ID" != "None" ] || continue

          aws iam delete-access-key \
            --user-name "$RHEL_IAM_USER_NAME" \
            --access-key-id "$ACCESS_KEY_ID" \
            >/dev/null 2>&1 || true
        done

        cleanup_all_user_policy_attachments \
          "$RHEL_IAM_USER_NAME"

        INLINE_POLICY_NAMES=$(aws iam list-user-policies \
          --user-name "$RHEL_IAM_USER_NAME" \
          --query 'PolicyNames[]' \
          --output text 2>/dev/null || true)

        for POLICY_NAME in $INLINE_POLICY_NAMES; do
          [ -n "$POLICY_NAME" ] || continue
          [ "$POLICY_NAME" != "None" ] || continue

          aws iam delete-user-policy \
            --user-name "$RHEL_IAM_USER_NAME" \
            --policy-name "$POLICY_NAME" \
            >/dev/null 2>&1 || true
        done

        aws iam delete-login-profile \
          --user-name "$RHEL_IAM_USER_NAME" \
          >/dev/null 2>&1 || true

        aws iam delete-user \
          --user-name "$RHEL_IAM_USER_NAME" \
          >/dev/null 2>&1 || true
      fi

      #########################################################################
      # Shared customer-managed IAM policies
      #########################################################################

      echo "Checking shared Image Mode managed policies"

      cleanup_managed_policy \
        'aws_iam_policy.image_mode_artifact_bucket_rw' \
        "$IMAGE_MODE_ARTIFACT_POLICY_NAME"

      cleanup_managed_policy \
        'aws_iam_policy.bootc_ami_import_caller' \
        "$BOOTC_AMI_IMPORT_POLICY_NAME"

      cleanup_managed_policy \
        'aws_iam_policy.ec2_discovery' \
        "$EC2_DISCOVERY_POLICY_NAME"

      echo "Preflight cleanup complete"
    EOT
  }
}


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
# AAP IAM Role For Reading Lab Secrets
############################################################

resource "aws_iam_role" "aap" {
  name = "${var.environment_name}-aap-role"

  depends_on = [
    terraform_data.preflight_cleanup
  ]

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "${var.environment_name}-aap-role"
    Environment = var.environment_name
  }
}

resource "aws_iam_role_policy" "aap_secrets_read" {
  name = "${var.environment_name}-aap-secrets-read"
  role = aws_iam_role.aap.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]

        Resource = (
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.secret_prefix}/*"
        )
      }
    ]
  })
}

resource "aws_iam_instance_profile" "aap" {
  name = "${var.environment_name}-aap-instance-profile"
  role = aws_iam_role.aap.name

  depends_on = [
    aws_iam_role.aap
  ]
}

resource "aws_iam_role_policy" "aap_s3_read" {
  name = "${var.environment_name}-aap-s3-read"
  role = aws_iam_role.aap.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "ReadInstallationArtifacts"
        Effect = "Allow"

        Action = [
          "s3:GetObject"
        ]

        Resource = distinct([
          "arn:aws:s3:::aap-containerized-installers/2.7/ansible-automation-platform-containerized-setup-bundle-2.7-1.2-x86_64.tar.gz",
          "arn:aws:s3:::aap-containerized-installers/2.7/manifest_AAP.zip",
          "arn:aws:s3:::${var.satellite_iso_s3_bucket}/${var.satellite_iso_s3_key}",
          "arn:aws:s3:::${var.satellite_manifest_s3_bucket}/${var.satellite_manifest_s3_key}"
        ])
      },
      {
        Sid    = "ReadArtifactBucketMetadata"
        Effect = "Allow"

        Action = [
          "s3:GetBucketLocation"
        ]

        Resource = distinct([
          "arn:aws:s3:::aap-containerized-installers",
          "arn:aws:s3:::${var.satellite_iso_s3_bucket}",
          "arn:aws:s3:::${var.satellite_manifest_s3_bucket}"
        ])
      },
      {
        Sid    = "ListSatelliteArtifactKeys"
        Effect = "Allow"

        Action = [
          "s3:ListBucket"
        ]

        Resource = distinct([
          "arn:aws:s3:::${var.satellite_iso_s3_bucket}",
          "arn:aws:s3:::${var.satellite_manifest_s3_bucket}"
        ])

        Condition = {
          StringLike = {
            "s3:prefix" = distinct([
              var.satellite_iso_s3_key,
              var.satellite_manifest_s3_key
            ])
          }
        }
      }
    ]
  })
}

############################################################
# Shared AWS EC2 Discovery Policy
############################################################

resource "aws_iam_policy" "ec2_discovery" {
  name = "${var.environment_name}-ec2-discovery"
  description = (

    "Allow Image Mode automation identities to discover AWS EC2 networking, images, instances, and related resources."
  )

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DiscoverEC2Resources"
        Effect = "Allow"
        Action = [

          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeIamInstanceProfileAssociations",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceAttribute",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeKeyPairs",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeRegions",
          "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSnapshots",
          "ec2:DescribeSubnets",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumeStatus",
          "ec2:DescribeVpcAttribute",
          "ec2:DescribeVpcEndpoints",
          "ec2:DescribeVpcs"

        ]

        Resource = "*"
      }
    ]
  })

  depends_on = [
    terraform_data.preflight_cleanup,
     aws_iam_role.aap

  ]

  tags = {

    Name        = "${var.environment_name}-ec2-discovery"
    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "Shared EC2 resource discovery"
  }
}


############################################################
# Satellite EC2 Host Role
############################################################

resource "aws_iam_role" "satellite" {
  name = "${var.environment_name}-satellite-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "AllowEC2AssumeRole"
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "${var.environment_name}-satellite-role"
    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "Satellite server runtime access"
  }

  depends_on = [
    terraform_data.preflight_cleanup
  ]
}


############################################################
# Satellite Host EC2 Discovery
#
# Allows AWS CLI and Ansible commands running directly on the
# Satellite EC2 instance to discover AWS networking, images,
# instances, security groups, and related EC2 resources.
############################################################

resource "aws_iam_role_policy_attachment" "satellite_ec2_discovery" {
  role       = aws_iam_role.satellite.name
  policy_arn = aws_iam_policy.ec2_discovery.arn
}


############################################################
# Satellite EC2 Host Secrets Manager Permissions
############################################################

resource "aws_iam_role_policy" "satellite_secrets_read" {
  name = "${var.environment_name}-satellite-secrets-read"
  role = aws_iam_role.satellite.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "ReadLabSecrets"
        Effect = "Allow"

        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue"
        ]

        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.secret_prefix}/*"
        ]
      }
    ]
  })
}


############################################################
# Satellite EC2 Host S3 Permissions
############################################################

resource "aws_iam_role_policy" "satellite_s3_read" {
  name = "${var.environment_name}-satellite-s3-read"
  role = aws_iam_role.satellite.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "ReadSatelliteArtifacts"
        Effect = "Allow"

        Action = [
          "s3:GetObject"
        ]

        Resource = distinct([
          "arn:aws:s3:::${var.satellite_iso_s3_bucket}/${var.satellite_iso_s3_key}",
          "arn:aws:s3:::${var.satellite_manifest_s3_bucket}/${var.satellite_manifest_s3_key}"
        ])
      },

      {
        Sid    = "ReadSatelliteArtifactBucketMetadata"
        Effect = "Allow"

        Action = [
          "s3:GetBucketLocation"
        ]

        Resource = distinct([
          "arn:aws:s3:::${var.satellite_iso_s3_bucket}",
          "arn:aws:s3:::${var.satellite_manifest_s3_bucket}"
        ])
      },

      {
        Sid    = "ListSatelliteArtifactKeys"
        Effect = "Allow"

        Action = [
          "s3:ListBucket"
        ]

        Resource = distinct([
          "arn:aws:s3:::${var.satellite_iso_s3_bucket}",
          "arn:aws:s3:::${var.satellite_manifest_s3_bucket}"
        ])

        Condition = {
          StringLike = {
            "s3:prefix" = distinct([
              var.satellite_iso_s3_key,
              var.satellite_manifest_s3_key
            ])
          }
        }
      }
    ]
  })
}


############################################################
# Satellite EC2 Instance Profile
############################################################

resource "aws_iam_instance_profile" "satellite" {
  name = "${var.environment_name}-satellite-instance-profile"
  role = aws_iam_role.satellite.name

  tags = {
    Name        = "${var.environment_name}-satellite-instance-profile"
    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "Satellite server runtime instance profile"
  }

  depends_on = [
    aws_iam_role_policy.satellite_secrets_read,
    aws_iam_role_policy.satellite_s3_read,
    aws_iam_role_policy_attachment.satellite_ec2_discovery
  ]
}


############################################################
# Satellite AWS EC2 Provisioning Identity
#
# The access key for this IAM user is configured in the
# Satellite AWS EC2 compute resource.
############################################################

resource "aws_iam_user" "satellite_provisioner" {
  name = "${var.environment_name}-satellite-provisioner"
  path = "/"

  tags = {
    Name        = "${var.environment_name}-satellite-provisioner"
    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "Satellite EC2 compute resource provisioning"
  }

  depends_on = [
    terraform_data.preflight_cleanup
  ]
}


############################################################
# Satellite Compute Resource EC2 Discovery
#
# Allows the AWS credentials stored in Satellite's EC2
# compute resource to populate regions, availability zones,
# VPCs, subnets, security groups, images, instance types,
# and existing instances.
############################################################

resource "aws_iam_user_policy_attachment" "satellite_provisioner_ec2_discovery" {
  user       = aws_iam_user.satellite_provisioner.name
  policy_arn = aws_iam_policy.ec2_discovery.arn
}


############################################################
# Satellite AWS EC2 Provisioning Policy
#
# EC2 discovery permissions are supplied by:
#
#   aws_iam_policy.ec2_discovery
#
# This inline policy contains only permissions that modify or
# create AWS resources.
############################################################

resource "aws_iam_user_policy" "satellite_provisioner" {
  name = "${var.environment_name}-satellite-ec2-provisioning"
  user = aws_iam_user.satellite_provisioner.name

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      #########################################################################
      # Manage Satellite-generated EC2 key pairs
      #
      # Satellite creates an EC2 key pair when the compute resource is created.
      # Satellite-generated key-pair names normally begin with "foreman-".
      #########################################################################

      {
        Sid    = "ManageSatelliteEC2KeyPairs"
        Effect = "Allow"

        Action = [
          "ec2:CreateKeyPair",
          "ec2:DeleteKeyPair",
          "ec2:ImportKeyPair"
        ]

        Resource = (
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:key-pair/foreman-*"
        )
      },

      #########################################################################
      # Manage instances provisioned by Satellite
      #########################################################################

      {
        Sid    = "ManageSatelliteProvisionedInstances"
        Effect = "Allow"

        Action = [
          "ec2:AttachVolume",
          "ec2:CreateTags",
          "ec2:CreateVolume",
          "ec2:DeleteVolume",
          "ec2:DetachVolume",
          "ec2:ModifyInstanceAttribute",
          "ec2:ModifyVolume",
          "ec2:RebootInstances",
          "ec2:RunInstances",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:TerminateInstances"
        ]

        Resource = "*"
      },

      #########################################################################
      # Manage IAM instance-profile associations
      #########################################################################

      {
        Sid    = "ManageIAMInstanceProfileAssociations"
        Effect = "Allow"

        Action = [
          "ec2:AssociateIamInstanceProfile",
          "ec2:DisassociateIamInstanceProfile",
          "ec2:ReplaceIamInstanceProfileAssociation"
        ]

        Resource = "*"
      },

      #########################################################################
      # Discover IAM instance profiles and roles
      #########################################################################

      {
        Sid    = "DiscoverIAMInstanceProfiles"
        Effect = "Allow"

        Action = [
          "iam:GetInstanceProfile",
          "iam:GetRole",
          "iam:ListInstanceProfiles",
          "iam:ListInstanceProfilesForRole",
          "iam:ListRoles"
        ]

        Resource = "*"
      },

      #########################################################################
      # Pass approved runtime roles to EC2
      #########################################################################

      {
        Sid    = "PassApprovedLabRuntimeRoles"
        Effect = "Allow"

        Action = [
          "iam:PassRole"
        ]

        Resource = [
          aws_iam_role.gitlab_runtime.arn,
          aws_iam_role.lab_ec2_default.arn,
          aws_iam_role.image_builder.arn
        ]

        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      }
    ]
  })

  depends_on = [
    terraform_data.preflight_cleanup,
    aws_iam_user.satellite_provisioner,
    aws_iam_user_policy_attachment.satellite_provisioner_ec2_discovery,
    aws_iam_instance_profile.gitlab_runtime,
    aws_iam_instance_profile.lab_ec2_default,
    aws_iam_instance_profile.image_builder
  ]
}


############################################################
# Satellite AWS EC2 Provisioning Access Key
############################################################

resource "aws_iam_access_key" "satellite_provisioner" {
  user = aws_iam_user.satellite_provisioner.name

  depends_on = [
    aws_iam_user_policy.satellite_provisioner,
    aws_iam_user_policy_attachment.satellite_provisioner_ec2_discovery
  ]
}


############################################################
# Satellite Compute Resource Access Key Secret
############################################################

resource "aws_secretsmanager_secret" "satellite_aws_access_key_id" {
  name = (
    "${var.secret_prefix}/satellite/aws_access_key_id"
  )

  description = (
    "AWS access-key ID used by the Satellite EC2 Compute Resource."
  )

  recovery_window_in_days = 0

  tags = {
    Name = (
      "${var.secret_prefix}/satellite/aws_access_key_id"
    )

    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "Satellite EC2 Compute Resource credential"
  }

  depends_on = [
    terraform_data.preflight_cleanup
  ]
}

resource "aws_secretsmanager_secret_version" "satellite_aws_access_key_id" {
  secret_id = (
    aws_secretsmanager_secret.satellite_aws_access_key_id.id
  )

  secret_string = (
    aws_iam_access_key.satellite_provisioner.id
  )

  depends_on = [
    aws_iam_access_key.satellite_provisioner,
    aws_secretsmanager_secret.satellite_aws_access_key_id
  ]
}


############################################################
# Satellite Compute Resource Secret Access Key Secret
############################################################

resource "aws_secretsmanager_secret" "satellite_aws_secret_access_key" {
  name = (
    "${var.secret_prefix}/satellite/aws_secret_access_key"
  )

  description = (
    "AWS secret access key used by the Satellite EC2 Compute Resource."
  )

  recovery_window_in_days = 0

  tags = {
    Name = (
      "${var.secret_prefix}/satellite/aws_secret_access_key"
    )

    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "Satellite EC2 Compute Resource credential"
  }

  depends_on = [
    terraform_data.preflight_cleanup
  ]
}

resource "aws_secretsmanager_secret_version" "satellite_aws_secret_access_key" {
  secret_id = (
    aws_secretsmanager_secret.satellite_aws_secret_access_key.id
  )

  secret_string = (
    aws_iam_access_key.satellite_provisioner.secret
  )

  depends_on = [
    aws_iam_access_key.satellite_provisioner,
    aws_secretsmanager_secret.satellite_aws_secret_access_key
  ]
}



############################################################
# GitLab EC2 Runtime Role
############################################################

resource "aws_iam_role" "gitlab_runtime" {
  name = "${var.environment_name}-gitlab-runtime-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "AllowEC2AssumeRole"
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "${var.environment_name}-gitlab-runtime-role"
    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "GitLab EC2 runtime access"
  }

  depends_on = [
    terraform_data.preflight_cleanup
  ]
}


############################################################
# GitLab EC2 Runtime Policy
############################################################

resource "aws_iam_role_policy" "gitlab_runtime" {
  name = "${var.environment_name}-gitlab-runtime"
  role = aws_iam_role.gitlab_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      #########################################################################
      # GitLab Secrets Manager access
      #########################################################################

      {
        Sid    = "ReadGitLabSecrets"
        Effect = "Allow"

        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue"
        ]

        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.secret_prefix}/gitlab/*"
        ]
      },

      #########################################################################
      # IdM LDAP bind password
      #########################################################################

      {
        Sid    = "ReadIdMLDAPBindPassword"
        Effect = "Allow"

        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue"
        ]

        Resource = [
          aws_secretsmanager_secret.generated["idm/admin_password"].arn
        ]
      },

      #########################################################################
      # Export Terraform-generated GitLab ACM certificates
      #
      # Do not reference aws_acm_certificate.server here. The wildcard ARN,
      # combined with certificate tags, avoids a Terraform dependency cycle.
      #########################################################################

      {
        Sid    = "DescribeAndExportGitLabCertificates"
        Effect = "Allow"

        Action = [
          "acm:DescribeCertificate",
          "acm:ExportCertificate"
        ]

        Resource = [
          "arn:aws:acm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:certificate/*"
        ]

        Condition = {
          StringEquals = {
            "aws:ResourceTag/Role"        = "gitlab"
            "aws:ResourceTag/Environment" = var.environment_name
          }
        }
      },

      #########################################################################
      # AWS Systems Manager
      #########################################################################

      {
        Sid    = "UseSystemsManager"
        Effect = "Allow"

        Action = [
          "ssm:DescribeAssociation",
          "ssm:GetDeployablePatchSnapshotForInstance",
          "ssm:GetDocument",
          "ssm:DescribeDocument",
          "ssm:GetManifest",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:ListAssociations",
          "ssm:ListInstanceAssociations",
          "ssm:PutInventory",
          "ssm:PutComplianceItems",
          "ssm:PutConfigurePackageResult",
          "ssm:UpdateAssociationStatus",
          "ssm:UpdateInstanceAssociationStatus",
          "ssm:UpdateInstanceInformation"
        ]

        Resource = "*"
      },

      {
        Sid    = "UseSSMMessages"
        Effect = "Allow"

        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]

        Resource = "*"
      },

      {
        Sid    = "UseEC2Messages"
        Effect = "Allow"

        Action = [
          "ec2messages:AcknowledgeMessage",
          "ec2messages:DeleteMessage",
          "ec2messages:FailMessage",
          "ec2messages:GetEndpoint",
          "ec2messages:GetMessages",
          "ec2messages:SendReply"
        ]

        Resource = "*"
      },

      #########################################################################
      # CloudWatch
      #########################################################################

      {
        Sid    = "PublishCloudWatchMetrics"
        Effect = "Allow"

        Action = [
          "cloudwatch:PutMetricData"
        ]

        Resource = "*"
      },

      {
        Sid    = "WriteCloudWatchLogs"
        Effect = "Allow"

        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents"
        ]

        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/${var.environment_name}/gitlab*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/${var.environment_name}/gitlab*:*"
        ]
      }
    ]
  })
}


############################################################
# GitLab EC2 Instance Profile
############################################################

resource "aws_iam_instance_profile" "gitlab_runtime" {
  name = "${var.environment_name}-gitlab-instance-profile"
  role = aws_iam_role.gitlab_runtime.name

  tags = {
    Name        = "${var.environment_name}-gitlab-instance-profile"
    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "GitLab EC2 runtime instance profile"
  }

  depends_on = [
    aws_iam_role_policy.gitlab_runtime
  ]
}


############################################################
# Shared Image Mode Artifact Bucket
############################################################

resource "aws_s3_bucket" "image_mode_artifacts" {
  depends_on = [
    terraform_data.preflight_cleanup
  ]

  bucket = "${var.environment_name}-image-mode-artifacts-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  force_destroy = true

  tags = {
    Name = "${var.environment_name}-image-mode-artifacts-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

    Environment = var.environment_name
    Purpose     = "Image Mode AMI build artifacts"
  }
}

resource "aws_s3_bucket_public_access_block" "image_mode_artifacts" {
  bucket = aws_s3_bucket.image_mode_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "image_mode_artifacts" {
  bucket = aws_s3_bucket.image_mode_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "image_mode_artifacts" {
  bucket = aws_s3_bucket.image_mode_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}


############################################################
# Shared Image Mode Artifact Bucket Access Policy
############################################################

resource "aws_iam_policy" "image_mode_artifact_bucket_rw" {

  depends_on = [

    terraform_data.preflight_cleanup

  ]

  name = "${var.environment_name}-image-mode-artifact-bucket-rw"

  description = (
    "Push and pull Image Mode build artifacts from the shared S3 bucket."
  )

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      #########################################################################
      # Account-level S3 discovery
      #########################################################################

      {
        Sid    = "DiscoverAWSBuckets"
        Effect = "Allow"

        Action = [
          "s3:ListAllMyBuckets"
        ]

        Resource = "*"
      },

      #########################################################################
      # Inspect and configure the Image Mode artifact bucket
      #########################################################################

      {
        Sid    = "InspectAndConfigureImageModeArtifactBucket"
        Effect = "Allow"

        Action = [
          "s3:GetBucketAcl",
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning",
          "s3:GetBucketPublicAccessBlock",
          "s3:GetEncryptionConfiguration",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutBucketPublicAccessBlock",
          "s3:PutEncryptionConfiguration"
        ]

        Resource = aws_s3_bucket.image_mode_artifacts.arn
      },

      #########################################################################
      # Read and write Image Mode artifacts
      #########################################################################

      {
        Sid    = "PushAndPullImageModeArtifacts"
        Effect = "Allow"

        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]

        Resource = "${aws_s3_bucket.image_mode_artifacts.arn}/*"
      }
    ]
  })
}



############################################################
# Shared S3 Access For Existing EC2 Roles
############################################################

resource "aws_iam_role_policy_attachment" "aap_image_mode_artifacts" {
  role       = aws_iam_role.aap.name
  policy_arn = aws_iam_policy.image_mode_artifact_bucket_rw.arn
}

resource "aws_iam_role_policy_attachment" "satellite_image_mode_artifacts" {
  role       = aws_iam_role.satellite.name
  policy_arn = aws_iam_policy.image_mode_artifact_bucket_rw.arn
}

resource "aws_iam_role_policy_attachment" "gitlab_image_mode_artifacts" {
  role       = aws_iam_role.gitlab_runtime.name
  policy_arn = aws_iam_policy.image_mode_artifact_bucket_rw.arn
}


############################################################
# Default Image Mode Lab EC2 Role
############################################################

resource "aws_iam_role" "lab_ec2_default" {
  name = "${var.environment_name}-ec2-default-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "AllowEC2AssumeRole"
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "${var.environment_name}-ec2-default-role"
    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "Default Image Mode lab EC2 access"
  }

  depends_on = [
    terraform_data.preflight_cleanup
  ]
}

resource "aws_iam_role_policy_attachment" "lab_ec2_default_image_mode_artifacts" {
  role       = aws_iam_role.lab_ec2_default.name
  policy_arn = aws_iam_policy.image_mode_artifact_bucket_rw.arn
}

resource "aws_iam_instance_profile" "lab_ec2_default" {
  name = "${var.environment_name}-ec2-default-instance-profile"
  role = aws_iam_role.lab_ec2_default.name

  tags = {
    Name        = "${var.environment_name}-ec2-default-instance-profile"
    Environment = var.environment_name
    ManagedBy   = "Terraform"
  }

  depends_on = [
    aws_iam_role_policy_attachment.lab_ec2_default_image_mode_artifacts
  ]
}


############################################################
# AWS VM Import/Export Service Role
############################################################

resource "aws_iam_role" "vmimport" {
  name = "vmimport"

  depends_on = [
    terraform_data.preflight_cleanup
  ]

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "AllowVMImportExportAssumeRole"
        Effect = "Allow"

        Principal = {
          Service = "vmie.amazonaws.com"
        }

        Action = "sts:AssumeRole"

        Condition = {
          StringEquals = {
            "sts:ExternalId" = "vmimport"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "vmimport"
    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "Convert Image Mode raw disks into EC2 AMIs"
  }
}

resource "aws_iam_role_policy" "vmimport" {
  name = "${var.environment_name}-vmimport"
  role = aws_iam_role.vmimport.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "ReadImageModeArtifactBucket"
        Effect = "Allow"

        Action = [
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket"
        ]

        Resource = [
          aws_s3_bucket.image_mode_artifacts.arn,
          "${aws_s3_bucket.image_mode_artifacts.arn}/*"
        ]
      },
      {
        Sid    = "CreateImportedAMI"
        Effect = "Allow"

        Action = [
          "ec2:ModifySnapshotAttribute",
          "ec2:CopySnapshot",
          "ec2:RegisterImage",
          "ec2:Describe*"
        ]

        Resource = "*"
      }
    ]
  })
}


############################################################
# Bootc AMI Import Caller Policy
############################################################

resource "aws_iam_policy" "bootc_ami_import_caller" {
  name = "${var.environment_name}-bootc-ami-import-caller"

  description = (
    "Allow Image Mode automation identities to import AMIs and use the VM Import/Export service role."
  )

  depends_on = [
    terraform_data.preflight_cleanup
  ]

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      #########################################################################
      # Discover AWS regions and EC2 resources
      #
      # bootc-image-builder calls DescribeRegions before starting the import.
      # EC2 Describe actions require Resource = "*".
      #########################################################################

      {
        Sid    = "DiscoverBootcAMIImportResources"
        Effect = "Allow"

        Action = [
          "ec2:DescribeRegions",
          "ec2:DescribeImages",
          "ec2:DescribeSnapshots",
          "ec2:DescribeImportImageTasks",
          "ec2:DescribeImportSnapshotTasks",
          "ec2:DescribeTags"
        ]

        Resource = "*"
      },

      #########################################################################
      # Create and manage bootc AMI imports
      #########################################################################

      {
        Sid    = "ManageBootcAMIImports"
        Effect = "Allow"

        Action = [
          "ec2:ImportImage",
          "ec2:ImportSnapshot",
          "ec2:CancelImportTask",
          "ec2:RegisterImage",
          "ec2:CreateTags",
          "ec2:ModifyImageAttribute",
          "ec2:ModifySnapshotAttribute"
        ]

        Resource = "*"
      },

      #########################################################################
      # Inspect the VM Import/Export service role
      #########################################################################

      {
        Sid    = "ReadVMImportRole"
        Effect = "Allow"

        Action = [
          "iam:GetRole"
        ]

        Resource = aws_iam_role.vmimport.arn
      },

      #########################################################################
      # Allow VM Import/Export to use the service role
      #########################################################################

      {
        Sid    = "PassVMImportRole"
        Effect = "Allow"

        Action = [
          "iam:PassRole"
        ]

        Resource = aws_iam_role.vmimport.arn

        Condition = {
          StringEquals = {
            "iam:PassedToService" = "vmie.amazonaws.com"
          }
        }
      }
    ]
  })
}

############################################################
# Image Builder EC2 Role
############################################################

resource "aws_iam_role" "image_builder" {
  name = "${var.environment_name}-image-builder-role"
  depends_on = [
    terraform_data.preflight_cleanup
  ]

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "AllowEC2AssumeRole"
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "${var.environment_name}-image-builder-role"
    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "Build and import Image Mode AMIs"
  }
}

resource "aws_iam_role_policy_attachment" "image_builder_artifacts" {
  role       = aws_iam_role.image_builder.name
  policy_arn = aws_iam_policy.image_mode_artifact_bucket_rw.arn
}

resource "aws_iam_role_policy_attachment" "image_builder_ami_import" {
  role       = aws_iam_role.image_builder.name
  policy_arn = aws_iam_policy.bootc_ami_import_caller.arn
}

resource "aws_iam_instance_profile" "image_builder" {
  name = "${var.environment_name}-image-builder-instance-profile"
  role = aws_iam_role.image_builder.name
}


############################################################
# Image Mode Automation IAM User
############################################################

resource "aws_iam_user" "rhel_iam" {
  name = "rhel-iam"
  path = "/service-accounts/"

  tags = {
    Name        = "rhel-iam"
    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "Image Mode lab automation service account"
  }

  depends_on = [
    terraform_data.preflight_cleanup
  ]
}

resource "aws_iam_user_policy_attachment" "rhel_iam_artifacts" {
  user       = aws_iam_user.rhel_iam.name
  policy_arn = aws_iam_policy.image_mode_artifact_bucket_rw.arn
}

resource "aws_iam_user_policy_attachment" "rhel_iam_ami_import" {
  user       = aws_iam_user.rhel_iam.name
  policy_arn = aws_iam_policy.bootc_ami_import_caller.arn
}

resource "aws_iam_user_policy_attachment" "rhel_iam_ec2_discovery" {
  user       = aws_iam_user.rhel_iam.name
  policy_arn = aws_iam_policy.ec2_discovery.arn
}


resource "aws_iam_access_key" "rhel_iam" {
  user = aws_iam_user.rhel_iam.name

  depends_on = [
    aws_iam_user_policy_attachment.rhel_iam_artifacts,
    aws_iam_user_policy_attachment.rhel_iam_ami_import,
    aws_iam_user_policy_attachment.rhel_iam_ec2_discovery
  ]
}


############################################################
# rhel-iam Credentials Secret
############################################################

resource "aws_secretsmanager_secret" "rhel_iam_credentials" {
  name = "${var.secret_prefix}/aws/rhel-iam"

  description = (
    "Programmatic AWS credentials for the Image Mode automation user."
  )

  recovery_window_in_days = 0

  tags = {
    Name        = "${var.secret_prefix}/aws/rhel-iam"
    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "Image Mode automation credentials"
  }

  depends_on = [
    terraform_data.preflight_cleanup
  ]
}

resource "aws_secretsmanager_secret_version" "rhel_iam_credentials" {
  secret_id = aws_secretsmanager_secret.rhel_iam_credentials.id

  secret_string = jsonencode({
    username              = aws_iam_user.rhel_iam.name
    aws_access_key_id     = aws_iam_access_key.rhel_iam.id
    aws_secret_access_key = aws_iam_access_key.rhel_iam.secret
    aws_region            = var.aws_region
    s3_bucket             = aws_s3_bucket.image_mode_artifacts.id
    vmimport_role_name    = aws_iam_role.vmimport.name
  })

  depends_on = [
    aws_iam_access_key.rhel_iam,
    aws_secretsmanager_secret.rhel_iam_credentials
  ]
}

############################################################
# Networking
############################################################

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.environment_name}-vpc"
    Environment = var.environment_name
  }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name        = "${var.environment_name}-igw"
    Environment = var.environment_name
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.environment_name}-public-subnet-a"
    Environment = var.environment_name
  }
}

resource "aws_subnet" "resolver" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.resolver_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false

  tags = {
    Name        = "${var.environment_name}-resolver-subnet-b"
    Environment = var.environment_name
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = {
    Name        = "${var.environment_name}-public-rt"
    Environment = var.environment_name
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "resolver" {
  subnet_id      = aws_subnet.resolver.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "lab" {
  name        = "${var.environment_name}-sg"
  description = "Security group for RHEL image mode lab nodes"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "SSH from home network and internal VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"

    cidr_blocks = [
      var.ssh_allowed_cidr,
      var.vpc_cidr
    ]
  }

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Internal lab traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Outbound internet access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment_name}-sg"
    Environment = var.environment_name
  }
}

############################################################
# Image Builder Security Group
############################################################

resource "aws_security_group" "image_builder" {
  name        = "${var.environment_name}-image-builder-sg"
  description = "Additional access for Image Builder hosts"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "Cockpit Web Console"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description      = "Cockpit Web Console IPv6"
    from_port        = 9090
    to_port          = 9090
    protocol         = "tcp"
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name        = "${var.environment_name}-image-builder-sg"
    Environment = var.environment_name
  }
}

############################################################
# GitLab Security Group
############################################################

resource "aws_security_group" "gitlab" {
  name        = "${var.environment_name}-gitlab-sg"
  description = "Additional access for GitLab hosts"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "GitLab container registry"
    from_port   = 5050
    to_port     = 5050
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description      = "GitLab container registry IPv6"
    from_port        = 5050
    to_port          = 5050
    protocol         = "tcp"
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    description = "Outbound access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment_name}-gitlab-sg"
    Environment = var.environment_name
  }
}



############################################################
# EC2 Instances
############################################################

resource "aws_instance" "server" {
  for_each = local.flattened_servers

  ami           = local.selected_ami
  instance_type = each.value.instance_type
  subnet_id     = aws_subnet.public.id

  vpc_security_group_ids = concat(
    [
      aws_security_group.lab.id
    ],
    each.value.role == "image-builder" ? [
      aws_security_group.image_builder.id
    ] : [],
    each.value.role == "gitlab" ? [
      aws_security_group.gitlab.id
    ] : []
  )

  key_name                    = aws_key_pair.lab.key_name
  associate_public_ip_address = true

  iam_instance_profile = (
    each.value.role == "aap"
    ? aws_iam_instance_profile.aap.name
    : each.value.role == "satellite"
    ? aws_iam_instance_profile.satellite.name
    : each.value.role == "gitlab"
    ? aws_iam_instance_profile.gitlab_runtime.name
    : each.value.role == "image-builder"
    ? aws_iam_instance_profile.image_builder.name
    : aws_iam_instance_profile.lab_ec2_default.name
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
# Publicly Trusted TLS Certificates
############################################################

resource "aws_acm_certificate" "server" {
  for_each = (
    var.create_public_dns_records
    ? local.flattened_servers
    : {}
  )

  domain_name       = each.value.hostname
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

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
  acm_validation_records = merge(
    {},
    [
      for server_name, certificate in aws_acm_certificate.server : {
        for validation_option in certificate.domain_validation_options :
        "${server_name}-${validation_option.domain_name}" => {
          server_name = server_name
          name        = validation_option.resource_record_name
          type        = validation_option.resource_record_type
          value       = validation_option.resource_record_value
        }
      }
    ]...
  )
}

resource "aws_route53_record" "server_certificate_validation" {
  for_each = local.acm_validation_records

  zone_id = local.public_route53_zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60

  records = [
    each.value.value
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
    for validation_key, validation_record in local.acm_validation_records :
    aws_route53_record.server_certificate_validation[validation_key].fqdn
    if validation_record.server_name == each.key
  ]
}

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
# Generate Ansible Inventory File
############################################################

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/inventory.ini"

  content = templatefile("${path.module}/inventory.tpl", {
    aws_dns_resolver             = local.aws_dns_resolver
    ansible_ssh_private_key_file = local.ansible_ssh_private_key_file

    aws_region    = var.aws_region
    aws_profile   = var.aws_profile
    secret_prefix = var.secret_prefix

    lab_ssh_private_key_secret_name = (
      local.lab_ssh_private_key_secret_name
    )

    ###########################################################################
    # Image Mode AWS workflow
    ###########################################################################

    image_mode_artifact_bucket = (
      aws_s3_bucket.image_mode_artifacts.bucket
    )

    rhel_iam_credentials_secret_name = (
      aws_secretsmanager_secret.rhel_iam_credentials.name
    )

    vmimport_role_name = (
      aws_iam_role.vmimport.name
    )

    ###########################################################################
    # Satellite installation artifacts
    ###########################################################################

    satellite_iso_s3_bucket = (
      var.satellite_iso_s3_bucket
    )

    satellite_iso_s3_key = (
      var.satellite_iso_s3_key
    )

    satellite_iso_sha256 = (
      var.satellite_iso_sha256
    )

    satellite_manifest_s3_bucket = (
      var.satellite_manifest_s3_bucket
    )

    satellite_manifest_s3_key = (
      var.satellite_manifest_s3_key
    )

    satellite_manifest_sha256 = (
      var.satellite_manifest_sha256
    )

    satellite_initial_admin_username = (
      var.satellite_initial_admin_username
    )

    satellite_organization_name = (
      var.satellite_organization_name
    )

    satellite_location_name = (
      var.satellite_location_name
    )

    ###########################################################################
    # Satellite AWS Compute Resource
    ###########################################################################

    satellite_compute_resource_name = (
      var.satellite_compute_resource_name
    )

    satellite_compute_profile_name = (
      var.satellite_compute_profile_name
    )

    satellite_default_compute_profile_name = (
      var.satellite_default_compute_profile_name
    )

    satellite_gitlab_compute_profile_name = (
      var.satellite_gitlab_compute_profile_name
    )

    satellite_image_builder_compute_profile_name = (
      var.satellite_image_builder_compute_profile_name
    )

    satellite_compute_region = (
      var.aws_region
    )

    satellite_compute_availability_zone = (
      aws_subnet.public.availability_zone
    )

    satellite_compute_subnet_id = (
      aws_subnet.public.id
    )

    satellite_compute_vpc_id = (
      aws_vpc.lab.id
    )

    satellite_compute_key_pair = (
      aws_key_pair.lab.key_name
    )

    ###########################################################################
    # Satellite EC2 instance profiles
    ###########################################################################

    satellite_default_instance_profile = (
      aws_iam_instance_profile.lab_ec2_default.name
    )

    satellite_gitlab_instance_profile = (
      aws_iam_instance_profile.gitlab_runtime.name
    )

    satellite_image_builder_instance_profile = (
      aws_iam_instance_profile.image_builder.name
    )

    ###########################################################################
    # Satellite EC2 security groups
    ###########################################################################

    satellite_compute_security_group_ids = [
      aws_security_group.lab.id,
      aws_security_group.gitlab.id
    ]

    satellite_default_security_group_ids = [
      aws_security_group.lab.id
    ]

    satellite_image_builder_security_group_ids = [
      aws_security_group.lab.id,
      aws_security_group.image_builder.id
    ]

    ###########################################################################
    # Satellite AWS credentials
    ###########################################################################

    satellite_aws_access_key_secret_name = (
      aws_secretsmanager_secret.satellite_aws_access_key_id.name
    )

    satellite_aws_secret_key_secret_name = (
      aws_secretsmanager_secret.satellite_aws_secret_access_key.name
    )

    ###########################################################################
    # Service ports
    ###########################################################################

    gitlab_registry_port = (
      var.gitlab_registry_port
    )

    image_builder_cockpit_port = (
      var.image_builder_cockpit_port
    )

    ###########################################################################
    # Lab identities and IdM
    ###########################################################################

    lab_users          = var.lab_users
    idm_users          = var.idm_users
    parent_domain_name = local.parent_domain_name
    idm_domain_name    = local.idm_domain_name
    idm_realm_name     = local.idm_realm_name
    idm_server_fqdn    = local.primary_idm_hostname
    idm_server_ip      = local.primary_idm_private_ip

    ###########################################################################
    # Terraform-managed servers
    ###########################################################################

    servers = {
      for name, instance in aws_instance.server :
      name => {
        hostname   = instance.tags.Name
        fqdn       = local.flattened_servers[name].hostname
        role       = instance.tags.Role
        private_ip = instance.private_ip

        public_ip = coalesce(
          try(aws_eip.server[name].public_ip, null),
          instance.public_ip,
          ""
        )

        ansible_host = coalesce(
          try(aws_eip.server[name].public_ip, null),
          instance.public_ip,
          instance.private_ip
        )

        iam_instance_profile = (
          local.flattened_servers[name].role == "aap"
          ? aws_iam_instance_profile.aap.name
          : local.flattened_servers[name].role == "satellite"
          ? aws_iam_instance_profile.satellite.name
          : local.flattened_servers[name].role == "gitlab"
          ? aws_iam_instance_profile.gitlab_runtime.name
          : local.flattened_servers[name].role == "image-builder"
          ? aws_iam_instance_profile.image_builder.name
          : aws_iam_instance_profile.lab_ec2_default.name
        )

        acm_certificate_arn = try(
          aws_acm_certificate.server[name].arn,
          ""
        )
      }
    }
  })
}

############################################################
# Clone Repo And Bootstrap Lab
############################################################

resource "terraform_data" "bootstrap_lab" {
  depends_on = [
    local_file.ansible_inventory
  ]

  triggers_replace = [
    local_file.ansible_inventory.content_sha256
  ]

  provisioner "local-exec" {
    working_dir = path.module

    command = <<-EOT
      set -euo pipefail

      REPO_DIR="${abspath(path.module)}/image-mode-hackathon"
      INVENTORY_FILE="${abspath(path.module)}/inventory.ini"

      REPO_URL="https://github.com/claudiol/image-mode-hackathon.git"
      BRANCH="add-new-satellite-inventory"

      echo "Using inventory: $INVENTORY_FILE"

      chmod 600 "${local.ansible_ssh_private_key_file}"

      if [ ! -d "$REPO_DIR/.git" ]; then
        git clone "$REPO_URL" "$REPO_DIR"
      fi

      cd "$REPO_DIR"

      git fetch origin
      git checkout "$BRANCH"
      git pull --ff-only origin "$BRANCH"

      mkdir -p playbooks/inventory
      cp "$INVENTORY_FILE" playbooks/inventory/hosts

      echo "Generated Ansible inventory:"
      cat playbooks/inventory/hosts

      echo "======================================"
      echo " Deploying Image Mode Lab Services"
      echo "======================================"

      ansible-playbook \
        -i playbooks/inventory/hosts \
        playbooks/deploy-services.yml
    EOT
  }
}