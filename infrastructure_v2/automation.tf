
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

    keycloak_installer_s3_bucket = (
      var.keycloak_installer_s3_bucket
    )

    keycloak_installer_s3_key = (
      var.keycloak_installer_s3_key
    )

    ###########################################################################
    # Keycloak OIDC and RHTAS
    ###########################################################################

    rhtas_oidc_client_id = (
      var.rhtas_oidc_client_id
    )

    rhtas_https_port = (
      var.rhtas_https_port
    )

    rhtas_oidc_issuer_url = (
      local.output_rhtas_oidc_issuer_url
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

        iam_instance_profile = lookup(
          local.instance_profile_by_role,
          local.flattened_servers[name].role,
          aws_iam_instance_profile.lab_ec2_default.name
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
# Clone Hackathon Repository And Bootstrap Lab
############################################################

resource "terraform_data" "bootstrap_lab" {
  depends_on = [
    local_file.ansible_inventory,
    aws_route53_record.public_dns,
    aws_route53_record.rhtas_service
  ]

  triggers_replace = [
    local_file.ansible_inventory.content_sha256,
    tostring(var.run_deploy_services)
  ]

  provisioner "local-exec" {
    working_dir = path.module

    environment = {
      RUN_DEPLOY_SERVICES = tostring(var.run_deploy_services)
    }

    command = <<-EOT
      set -euo pipefail

      REPO_DIR="${abspath(path.module)}/image-mode-hackathon"
      INVENTORY_FILE="${abspath(path.module)}/inventory.ini"

      REPO_URL="https://github.com/rhtconsulting/image-mode-hackathon.git"
      BRANCH="add-cop-aap-pipeline"

      echo "Using inventory: $INVENTORY_FILE"

      chmod 600 "${local.ansible_ssh_private_key_file}"

      if [ ! -d "$REPO_DIR/.git" ]; then
        git clone "$REPO_URL" "$REPO_DIR"
      fi

      cd "$REPO_DIR"

      git fetch origin "$BRANCH"
      git checkout "$BRANCH"
      git pull --ff-only origin "$BRANCH"

      mkdir -p playbooks/inventory

      install -m 0600 \
        "$INVENTORY_FILE" \
        playbooks/inventory/hosts

      if [ "$RUN_DEPLOY_SERVICES" = "true" ]; then
        echo "======================================"
        echo " Deploying Image Mode Lab Services"
        echo "======================================"

        ansible-playbook \
          -i playbooks/inventory/hosts \
          playbooks/deploy-services.yml
      else
        echo "======================================"
        echo " Skipping deploy-services.yml"
        echo " Using previously deployed environment"
        echo "======================================"
      fi
    EOT
  }
}

############################################################
# Clone And Deploy CoP AAP Pipeline
#
# This starts after bootstrap_lab. When run_deploy_services
# is false, bootstrap_lab refreshes the repository and
# inventory but skips deploy-services.yml.
############################################################

resource "terraform_data" "deploy_cop_aap_pipeline" {
  depends_on = [
    terraform_data.bootstrap_lab
  ]

  triggers_replace = [
    terraform_data.bootstrap_lab.id,
    local_file.ansible_inventory.content_sha256,

    aws_secretsmanager_secret.redhat[
      "redhat/registry_username"
    ].arn,

    aws_secretsmanager_secret.redhat[
      "redhat/registry_password"
    ].arn,

    aws_secretsmanager_secret.generated[
      "aap/controller_admin_password"
    ].arn,

    aws_secretsmanager_secret.static[
      "quay/superuser"
    ].arn,

    aws_secretsmanager_secret.generated[
      "quay/superuser_password"
    ].arn,

    aws_secretsmanager_secret.satellite_aws_access_key_id.arn,
    aws_secretsmanager_secret.satellite_aws_secret_access_key.arn
  ]

  provisioner "local-exec" {
    working_dir = path.module

    environment = {
      AWS_PROFILE = var.aws_profile
      AWS_REGION  = var.aws_region

      REDHAT_REGISTRY_USERNAME_SECRET = (
        aws_secretsmanager_secret.redhat[
          "redhat/registry_username"
        ].name
      )

      REDHAT_REGISTRY_PASSWORD_SECRET = (
        aws_secretsmanager_secret.redhat[
          "redhat/registry_password"
        ].name
      )

      AAP_CONTROLLER_PASSWORD_SECRET = (
        aws_secretsmanager_secret.generated[
          "aap/controller_admin_password"
        ].name
      )

      QUAY_USERNAME_SECRET = (
        aws_secretsmanager_secret.static[
          "quay/superuser"
        ].name
      )

      QUAY_PASSWORD_SECRET = (
        aws_secretsmanager_secret.generated[
          "quay/superuser_password"
        ].name
      )

      PIPELINE_AWS_ACCESS_KEY_SECRET = (
        aws_secretsmanager_secret.satellite_aws_access_key_id.name
      )

      PIPELINE_AWS_SECRET_KEY_SECRET = (
        aws_secretsmanager_secret.satellite_aws_secret_access_key.name
      )
    }

    command = <<-EOT
      set -euo pipefail

      HACKATHON_REPO_DIR="${abspath(path.module)}/image-mode-hackathon"
      COP_REPO_DIR="${abspath(path.module)}/rhel-image-mode-aap"
      INVENTORY_FILE="${abspath(path.module)}/inventory.ini"

      COP_REPO_URL="https://gitlab.com/redhat/cop/rhel/rhel-image-mode-aap.git"
      COP_REPO_BRANCH="main"

      COP_VARS_TEMPLATE="$HACKATHON_REPO_DIR/infrastructure_v2/cop-aap-pipeline-vars.tpl"
      COP_VARS_FILE="$COP_REPO_DIR/demo-setup-vars.yml"

      get_secret() {
        aws secretsmanager get-secret-value \
          --secret-id "$1" \
          --query SecretString \
          --output text
      }

      cleanup() {
        unset \
          REDHAT_REGISTRY_USERNAME \
          REDHAT_REGISTRY_PASSWORD \
          AAP2_CONTROLLER_USERNAME \
          AAP2_CONTROLLER_PASSWORD \
          QUAY_USERNAME \
          QUAY_PASSWORD \
          PIPELINE_AWS_ACCESS_KEY \
          PIPELINE_AWS_SECRET_KEY \
          PIPELINE_AWS_STS_TOKEN \
          AUTOMATION_HUB_TOKEN
      }

      trap cleanup EXIT

      if [ ! -f "$INVENTORY_FILE" ]; then
        echo "Generated inventory not found: $INVENTORY_FILE" >&2
        exit 1
      fi

      if [ ! -f "$COP_VARS_TEMPLATE" ]; then
        echo "CoP variables template not found: $COP_VARS_TEMPLATE" >&2
        exit 1
      fi

      echo "======================================"
      echo " Cloning CoP AAP Pipeline Repository"
      echo "======================================"

      if [ ! -d "$COP_REPO_DIR/.git" ]; then
        git clone \
          --branch "$COP_REPO_BRANCH" \
          "$COP_REPO_URL" \
          "$COP_REPO_DIR"
      fi

      cd "$COP_REPO_DIR"

      # Restore the upstream variables file before pulling in case
      # this resource generated it during a previous Terraform run.
      git restore \
        --source=HEAD \
        -- demo-setup-vars.yml \
        2>/dev/null || true

      git fetch origin "$COP_REPO_BRANCH"
      git checkout "$COP_REPO_BRANCH"
      git pull --ff-only origin "$COP_REPO_BRANCH"

      # Replace the default variables only in the local clone.
      install -m 0600 \
        "$COP_VARS_TEMPLATE" \
        "$COP_VARS_FILE"

      # Reuse the inventory generated by Terraform. It contains
      # the dynamically provisioned Quay server and other hosts.
      mkdir -p inventory

      install -m 0600 \
        "$INVENTORY_FILE" \
        inventory/hosts

      export REDHAT_REGISTRY_USERNAME="$(
        get_secret "$REDHAT_REGISTRY_USERNAME_SECRET"
      )"

      export REDHAT_REGISTRY_PASSWORD="$(
        get_secret "$REDHAT_REGISTRY_PASSWORD_SECRET"
      )"

      export AAP2_CONTROLLER_USERNAME="admin"

      export AAP2_CONTROLLER_PASSWORD="$(
        get_secret "$AAP_CONTROLLER_PASSWORD_SECRET"
      )"

      export QUAY_USERNAME="$(
        get_secret "$QUAY_USERNAME_SECRET"
      )"

      export QUAY_PASSWORD="$(
        get_secret "$QUAY_PASSWORD_SECRET"
      )"

      export PIPELINE_AWS_ACCESS_KEY="$(
        get_secret "$PIPELINE_AWS_ACCESS_KEY_SECRET"
      )"

      export PIPELINE_AWS_SECRET_KEY="$(
        get_secret "$PIPELINE_AWS_SECRET_KEY_SECRET"
      )"

      export PIPELINE_AWS_STS_TOKEN=""
      export AUTOMATION_HUB_TOKEN=""

      echo "======================================"
      echo " Deploying CoP AAP Pipeline"
      echo "======================================"

      if [ -f "$COP_REPO_DIR/demo-setup.yml" ]; then
        COP_PLAYBOOK="$COP_REPO_DIR/demo-setup.yml"
      elif [ -f "$COP_REPO_DIR/playbooks/demo-setup.yml" ]; then
        COP_PLAYBOOK="$COP_REPO_DIR/playbooks/demo-setup.yml"
      else
        echo "Unable to find the CoP demo-setup.yml playbook." >&2
        exit 1
      fi

      ansible-playbook \
        -i inventory/hosts \
        "$COP_PLAYBOOK"
    EOT
  }
}