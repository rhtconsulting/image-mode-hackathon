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
      BRANCH="dev"

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
