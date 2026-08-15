############################################################
# Preflight Cleanup For Lab Rebuilds
############################################################

resource "terraform_data" "preflight_cleanup" {
  triggers_replace = [
    8
  ]

  input = {
    cleanup_version  = 8
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

    image_builder_installation_isos_policy_name = (
      "${var.environment_name}-image-builder-installation-isos-read"
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

    image_builder_ec2_provisioning_policy_name = (
      "${var.environment_name}-image-builder-ec2-provisioning"
    )

    image_builder_certificate_policy_name = (
      "${var.environment_name}-image-builder-certificate-management"
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
      IMAGE_BUILDER_INSTALLATION_ISOS_POLICY_NAME="${var.environment_name}-image-builder-installation-isos-read"

      VMIMPORT_ROLE_NAME="vmimport"
      VMIMPORT_POLICY_NAME="${var.environment_name}-vmimport"

      SATELLITE_PROVISIONER_USER_NAME="${var.environment_name}-satellite-provisioner"
      SATELLITE_PROVISIONER_POLICY_NAME="${var.environment_name}-satellite-ec2-provisioning"

      RHEL_IAM_USER_NAME="rhel-iam"

      IMAGE_MODE_ARTIFACT_POLICY_NAME="${var.environment_name}-image-mode-artifact-bucket-rw"
      BOOTC_AMI_IMPORT_POLICY_NAME="${var.environment_name}-bootc-ami-import-caller"
      EC2_DISCOVERY_POLICY_NAME="${var.environment_name}-ec2-discovery"
      IMAGE_BUILDER_EC2_PROVISIONING_POLICY_NAME="${var.environment_name}-image-builder-ec2-provisioning"
      IMAGE_BUILDER_CERTIFICATE_POLICY_NAME="${var.environment_name}-image-builder-certificate-management"

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
%{for secret_name in local.all_lab_secret_names~}
${secret_name}
%{endfor~}
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

      cleanup_inline_role_policy \
        'aws_iam_role_policy.image_builder_installation_isos_read' \
        "$IMAGE_BUILDER_ROLE_NAME" \
        "$IMAGE_BUILDER_INSTALLATION_ISOS_POLICY_NAME"

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

      cleanup_managed_policy \
        'aws_iam_policy.image_builder_ec2_provisioning' \
        "$IMAGE_BUILDER_EC2_PROVISIONING_POLICY_NAME"

      cleanup_managed_policy \
        'aws_iam_policy.image_builder_certificate_management' \
        "$IMAGE_BUILDER_CERTIFICATE_POLICY_NAME"

      echo "Preflight cleanup complete"
    EOT
  }
}


