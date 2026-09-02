############################################################
# Automation Service Endpoints And CoP Hosts
############################################################

locals {
  aap_server_hostnames = [
    for name, server in local.flattened_servers :
    server.hostname
    if server.role == "aap"
  ]

  # This automation expects exactly one server with role "aap".
  primary_aap_hostname = one(local.aap_server_hostnames)
  primary_aap_url      = "https://${local.primary_aap_hostname}"

  ###########################################################################
  # Image Builder hosts added to the CoP AAP inventory
  ###########################################################################

  cop_image_builder_hosts = [
    for name, instance in aws_instance.server : {
      name       = name
      hostname   = local.flattened_servers[name].hostname
      private_ip = instance.private_ip
    }
    if local.flattened_servers[name].role == "image-builder"
  ]

  ###########################################################################
  # Quay identifiers used to remove hosts created by older automation
  ###########################################################################

  cop_quay_host_identifiers = distinct(flatten([
    for name, instance in aws_instance.server : compact([
      name,
      local.flattened_servers[name].hostname,
      instance.private_ip,
      try(aws_eip.server[name].public_ip, ""),
      instance.public_ip
    ])
    if local.flattened_servers[name].role == "quay"
  ]))
}

############################################################
# Existing Quay LDAP Registry Credential
############################################################

data "aws_secretsmanager_secret" "quay_image_mode_builder" {
  name = "${var.secret_prefix}/quay/ldap_users/image-mode-builder"
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
    #
    # This original inventory behavior remains unchanged.
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
      BRANCH="dev"

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
#
# Each Terraform-created image-builder is added to the CoP
# AAP inventory using its private IP address.
#
# Quay remains the image registry and is not added as a
# build host.
############################################################

resource "terraform_data" "deploy_cop_aap_pipeline" {
  depends_on = [
    terraform_data.bootstrap_lab
  ]

  triggers_replace = [
    terraform_data.bootstrap_lab.id,
    local_file.ansible_inventory.content_sha256,
    local.primary_aap_url,
    jsonencode(local.cop_image_builder_hosts),
    jsonencode(local.cop_quay_host_identifiers),

    aws_secretsmanager_secret.redhat[
      "redhat/registry_username"
    ].arn,

    aws_secretsmanager_secret.redhat[
      "redhat/registry_password"
    ].arn,

    aws_secretsmanager_secret.generated[
      "aap/gateway_admin_password"
    ].arn,

    data.aws_secretsmanager_secret.quay_image_mode_builder.arn,

    aws_secretsmanager_secret.satellite_aws_access_key_id.arn,
    aws_secretsmanager_secret.satellite_aws_secret_access_key.arn
  ]

  provisioner "local-exec" {
    working_dir = path.module

    environment = {
      AWS_PROFILE = var.aws_profile
      AWS_REGION  = var.aws_region

      AAP2_CONTROLLER_URL = local.primary_aap_url

      # Image builders added to the AAP inventory.
      IMAGE_BUILDER_HOSTS_JSON = jsonencode(
        local.cop_image_builder_hosts
      )

      # Possible names and addresses of an incorrectly created Quay host.
      QUAY_HOST_IDENTIFIERS_JSON = jsonencode(
        local.cop_quay_host_identifiers
      )

      COP_AAP_INVENTORY_NAME = (
        "Image Mode CI/CD - AAP - SCM Inventory"
      )

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
          "aap/gateway_admin_password"
        ].name
      )

      QUAY_CREDENTIALS_SECRET = (
        data.aws_secretsmanager_secret.quay_image_mode_builder.name
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

      COP_REPO_URL="https://gitlab.com/philip860/rhel-image-mode-aap.git"
      COP_REPO_BRANCH="dev"

      COP_VARS_TEMPLATE="$HACKATHON_REPO_DIR/infrastructure_v2/cop-aap-pipeline-vars.tpl"
      COP_VARS_FILE="$COP_REPO_DIR/demo-setup-vars.yml"

      BUILDERS_FILE=""
      QUAY_IDENTIFIERS_FILE=""

      get_secret() {
        aws secretsmanager get-secret-value \
          --secret-id "$1" \
          --query SecretString \
          --output text
      }

      cleanup() {
        if [ -n "$BUILDERS_FILE" ]; then
          rm -f "$BUILDERS_FILE"
        fi

        if [ -n "$QUAY_IDENTIFIERS_FILE" ]; then
          rm -f "$QUAY_IDENTIFIERS_FILE"
        fi

        unset \
          REDHAT_REGISTRY_USERNAME \
          REDHAT_REGISTRY_PASSWORD \
          AAP2_CONTROLLER_URL \
          AAP2_CONTROLLER_USERNAME \
          AAP2_CONTROLLER_PASSWORD \
          QUAY_CREDENTIALS_JSON \
          QUAY_USERNAME \
          QUAY_PASSWORD \
          PIPELINE_AWS_ACCESS_KEY \
          PIPELINE_AWS_SECRET_KEY \
          PIPELINE_AWS_STS_TOKEN \
          AUTOMATION_HUB_TOKEN \
          IMAGE_BUILDER_HOSTS_JSON \
          QUAY_HOST_IDENTIFIERS_JSON
      }

      trap cleanup EXIT

      if ! command -v jq >/dev/null 2>&1; then
        echo "jq is required by the CoP deployment process." >&2
        exit 1
      fi

      if [ ! -f "$INVENTORY_FILE" ]; then
        echo "Generated inventory not found: $INVENTORY_FILE" >&2
        exit 1
      fi

      if [ ! -f "$COP_VARS_TEMPLATE" ]; then
        echo "CoP variables template not found: $COP_VARS_TEMPLATE" >&2
        exit 1
      fi

      if [ -z "$AAP2_CONTROLLER_URL" ]; then
        echo "Terraform did not generate an AAP URL." >&2
        exit 1
      fi

      case "$AAP2_CONTROLLER_URL" in
        http://*|https://*)
          ;;
        *)
          echo "Invalid AAP URL: $AAP2_CONTROLLER_URL" >&2
          echo "The URL must begin with http:// or https://." >&2
          exit 1
          ;;
      esac

      IMAGE_BUILDER_COUNT="$(
        printf '%s' "$IMAGE_BUILDER_HOSTS_JSON" |
          jq 'length'
      )"

      if [ "$IMAGE_BUILDER_COUNT" -eq 0 ]; then
        echo "No Terraform servers with role image-builder were found." >&2
        exit 1
      fi

      echo "Image builders selected for the CoP AAP inventory:"

      printf '%s' "$IMAGE_BUILDER_HOSTS_JSON" |
        jq -r \
          '.[] | "  \(.hostname) -> \(.private_ip)"'

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

      # Restore only the variables file generated during the prior run.
      git restore \
        --source=HEAD \
        -- demo-setup-vars.yml \
        2>/dev/null || true

      git fetch origin "$COP_REPO_BRANCH"
      git checkout "$COP_REPO_BRANCH"
      git pull --ff-only origin "$COP_REPO_BRANCH"

      # Copy the locally maintained variable template over the
      # default variables file in the cloned CoP repository.
      install -m 0600 \
        "$COP_VARS_TEMPLATE" \
        "$COP_VARS_FILE"

      # Reuse the original Terraform-generated inventory without
      # modifying its public ansible_host values.
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

      QUAY_CREDENTIALS_JSON="$(
        get_secret "$QUAY_CREDENTIALS_SECRET"
      )"

      export QUAY_USERNAME="$(
        printf '%s' "$QUAY_CREDENTIALS_JSON" |
          jq -er '.username | strings | select(length > 0)'
      )"

      export QUAY_PASSWORD="$(
        printf '%s' "$QUAY_CREDENTIALS_JSON" |
          jq -er '.password | strings | select(length > 0)'
      )"

      if [ "$QUAY_USERNAME" != "image-mode-builder" ]; then
        echo \
          "Secret $QUAY_CREDENTIALS_SECRET contains an unexpected username." \
          >&2
        exit 1
      fi

      unset QUAY_CREDENTIALS_JSON

      export PIPELINE_AWS_ACCESS_KEY="$(
        get_secret "$PIPELINE_AWS_ACCESS_KEY_SECRET"
      )"

      export PIPELINE_AWS_SECRET_KEY="$(
        get_secret "$PIPELINE_AWS_SECRET_KEY_SECRET"
      )"

      export PIPELINE_AWS_STS_TOKEN=""
      export AUTOMATION_HUB_TOKEN=""

      echo "======================================"
      echo " Validating AAP Endpoint"
      echo "======================================"

      echo "AAP endpoint: $AAP2_CONTROLLER_URL"

      if ! curl \
        --silent \
        --show-error \
        --insecure \
        --connect-timeout 15 \
        --max-time 30 \
        --output /dev/null \
        "$AAP2_CONTROLLER_URL/"; then
        echo "Unable to connect to AAP at $AAP2_CONTROLLER_URL" >&2
        exit 1
      fi

      echo "AAP endpoint is reachable."

      if [ -f "$COP_REPO_DIR/configure-aap-controller.yml" ]; then
        COP_PLAYBOOK="$COP_REPO_DIR/configure-aap-controller.yml"
      elif [ -f "$COP_REPO_DIR/demo-setup/configure-aap-controller.yml" ]; then
        COP_PLAYBOOK="$COP_REPO_DIR/demo-setup/configure-aap-controller.yml"
      else
        echo "Unable to find configure-aap-controller.yml." >&2
        exit 1
      fi

      echo "======================================"
      echo " Configuring CoP AAP Pipeline"
      echo "======================================"

      echo "Using playbook: $COP_PLAYBOOK"
      echo "Using variables: $COP_VARS_FILE"
      echo "Using inventory: $COP_REPO_DIR/inventory/hosts"

      BUILDERS_FILE="$(mktemp)"
      chmod 600 "$BUILDERS_FILE"

      printf '%s' "$IMAGE_BUILDER_HOSTS_JSON" |
        jq -c '.[]' > "$BUILDERS_FILE"

      while IFS= read -r BUILDER_JSON; do
        BUILDER_NAME="$(
          printf '%s' "$BUILDER_JSON" |
            jq -r '.name'
        )"

        BUILDER_HOSTNAME="$(
          printf '%s' "$BUILDER_JSON" |
            jq -r '.hostname'
        )"

        BUILDER_PRIVATE_IP="$(
          printf '%s' "$BUILDER_JSON" |
            jq -r '.private_ip'
        )"

        if [ -z "$BUILDER_PRIVATE_IP" ] ||
           [ "$BUILDER_PRIVATE_IP" = "null" ]; then
          echo "Image builder $BUILDER_NAME has no private IP." >&2
          exit 1
        fi

        echo "--------------------------------------"
        echo " Configuring image builder"
        echo " Name:       $BUILDER_NAME"
        echo " Hostname:   $BUILDER_HOSTNAME"
        echo " Private IP: $BUILDER_PRIVATE_IP"
        echo "--------------------------------------"

        # Command-line extra variables override server_hostname from
        # demo-setup-vars.yml. The CoP repository currently models
        # one build server, so run it once for each image builder.
        ansible-playbook \
          -i "$COP_REPO_DIR/inventory/hosts" \
          --extra-vars "@$COP_VARS_FILE" \
          --extra-vars "server_hostname=$BUILDER_PRIVATE_IP" \
          --extra-vars "server_name=$BUILDER_HOSTNAME" \
          "$COP_PLAYBOOK"
      done < "$BUILDERS_FILE"

      rm -f "$BUILDERS_FILE"
      BUILDERS_FILE=""

      echo "======================================"
      echo " Removing Stale Quay Inventory Hosts"
      echo "======================================"

      AAP_INVENTORY_ID="$(
        curl \
          --silent \
          --show-error \
          --insecure \
          --user "$AAP2_CONTROLLER_USERNAME:$AAP2_CONTROLLER_PASSWORD" \
          --get \
          --data-urlencode "name=$COP_AAP_INVENTORY_NAME" \
          "$AAP2_CONTROLLER_URL/api/controller/v2/inventories/" |
          jq -r '.results[0].id // empty'
      )"

      if [ -z "$AAP_INVENTORY_ID" ]; then
        echo "AAP inventory not found: $COP_AAP_INVENTORY_NAME" >&2
        exit 1
      fi

      QUAY_IDENTIFIERS_FILE="$(mktemp)"
      chmod 600 "$QUAY_IDENTIFIERS_FILE"

      printf '%s' "$QUAY_HOST_IDENTIFIERS_JSON" |
        jq -r '.[]' > "$QUAY_IDENTIFIERS_FILE"

      while IFS= read -r QUAY_IDENTIFIER; do
        [ -n "$QUAY_IDENTIFIER" ] || continue

        STALE_HOST_ID="$(
          curl \
            --silent \
            --show-error \
            --insecure \
            --user "$AAP2_CONTROLLER_USERNAME:$AAP2_CONTROLLER_PASSWORD" \
            --get \
            --data-urlencode "name=$QUAY_IDENTIFIER" \
            "$AAP2_CONTROLLER_URL/api/controller/v2/inventories/$AAP_INVENTORY_ID/hosts/" |
            jq -r '.results[0].id // empty'
        )"

        if [ -n "$STALE_HOST_ID" ]; then
          echo "Removing stale Quay host: $QUAY_IDENTIFIER"

          curl \
            --silent \
            --show-error \
            --fail \
            --insecure \
            --user "$AAP2_CONTROLLER_USERNAME:$AAP2_CONTROLLER_PASSWORD" \
            --request DELETE \
            "$AAP2_CONTROLLER_URL/api/controller/v2/hosts/$STALE_HOST_ID/"
        fi
      done < "$QUAY_IDENTIFIERS_FILE"

      rm -f "$QUAY_IDENTIFIERS_FILE"
      QUAY_IDENTIFIERS_FILE=""

      echo "======================================"
      echo " CoP AAP Pipeline Configuration Done"
      echo "======================================"
    EOT
  }
}
