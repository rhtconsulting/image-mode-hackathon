############################################################
# Preflight Cleanup For Lab Rebuilds
############################################################

resource "terraform_data" "preflight_cleanup" {
  triggers_replace = [
    timestamp()
  ]

  input = {
    cleanup_version      = 9
    environment_name     = var.environment_name
    secret_prefix        = var.secret_prefix
    aws_region           = var.aws_region
    aws_profile          = var.aws_profile
    key_pair_name        = "${var.environment_name}-ssh-key"
    artifact_bucket_name = "${var.environment_name}-image-mode-artifacts-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

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

  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    working_dir = path.module

    command = <<-EOT
      set -euo pipefail

      export AWS_REGION="${var.aws_region}"
      export AWS_DEFAULT_REGION="${var.aws_region}"
      export AWS_PAGER=""

      if [ -n "${var.aws_profile}" ]; then
        export AWS_PROFILE="${var.aws_profile}"
      else
        unset AWS_PROFILE AWS_DEFAULT_PROFILE
      fi

      KEY_PAIR_NAME="${var.environment_name}-ssh-key"
      ENVIRONMENT_NAME="${var.environment_name}"
      ARTIFACT_BUCKET_NAME="${var.environment_name}-image-mode-artifacts-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

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

      state_contains_id() {
        grep -Fq "\"$1\"" "$STATE_FILE"
      }

      fail_cleanup() {
        echo "ERROR: $*" >&2
        exit 1
      }

      STATE_FILE=$(mktemp "$${TMPDIR:-/tmp}/image-mode-lab-state.XXXXXX")
      chmod 600 "$STATE_FILE"
      trap 'rm -f "$STATE_FILE"' EXIT
      terraform state pull >"$STATE_FILE" 2>/dev/null || printf '{}' >"$STATE_FILE"

      cleanup_artifact_bucket() {
        if state_has 'aws_s3_bucket.image_mode_artifacts'; then
          echo "Skipping artifact bucket because it is managed by Terraform state."
          return
        fi

        if ! aws s3api head-bucket --bucket "$ARTIFACT_BUCKET_NAME" 2>/dev/null; then
          return
        fi

        BUCKET_ENVIRONMENT=$(aws s3api get-bucket-tagging \
          --bucket "$ARTIFACT_BUCKET_NAME" \
          --query "TagSet[?Key=='Environment'].Value | [0]" \
          --output text 2>/dev/null || true)
        [ "$BUCKET_ENVIRONMENT" = "$ENVIRONMENT_NAME" ] ||
          fail_cleanup "Refusing to delete unowned bucket $ARTIFACT_BUCKET_NAME"

        echo "Deleting orphaned artifact bucket: $ARTIFACT_BUCKET_NAME"

        UPLOADS=$(aws s3api list-multipart-uploads \
          --bucket "$ARTIFACT_BUCKET_NAME" \
          --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null || true)
        if [ -n "$UPLOADS" ] && [ "$UPLOADS" != "None" ]; then
          while IFS=$'\t' read -r OBJECT_KEY UPLOAD_ID; do
            [ -n "$OBJECT_KEY" ] || continue
            aws s3api abort-multipart-upload --bucket "$ARTIFACT_BUCKET_NAME" \
              --key "$OBJECT_KEY" --upload-id "$UPLOAD_ID"
          done <<< "$UPLOADS"
        fi

        while true; do
          VERSIONS=$(aws s3api list-object-versions \
            --bucket "$ARTIFACT_BUCKET_NAME" --max-items 1000 \
            --query '[Versions[].[Key,VersionId],DeleteMarkers[].[Key,VersionId]][]' \
            --output text)
          [ -n "$VERSIONS" ] && [ "$VERSIONS" != "None" ] || break
          while IFS=$'\t' read -r OBJECT_KEY VERSION_ID; do
            [ -n "$OBJECT_KEY" ] || continue
            aws s3api delete-object --bucket "$ARTIFACT_BUCKET_NAME" \
              --key "$OBJECT_KEY" --version-id "$VERSION_ID" >/dev/null
          done <<< "$VERSIONS"
        done

        aws s3api delete-bucket --bucket "$ARTIFACT_BUCKET_NAME"
      }

      cleanup_orphan_vpcs() {
        VPC_IDS=$(aws ec2 describe-vpcs \
          --filters "Name=tag:Environment,Values=$ENVIRONMENT_NAME" \
          --query 'Vpcs[].VpcId' --output text)
        [ -n "$VPC_IDS" ] && [ "$VPC_IDS" != "None" ] || return 0

        for VPC_ID in $VPC_IDS; do
          if state_contains_id "$VPC_ID"; then
            echo "Skipping state-managed VPC: $VPC_ID"
            continue
          fi

          echo "Cleaning orphaned VPC and dependencies: $VPC_ID"

          SUBNET_IDS=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query 'Subnets[].SubnetId' --output text)

          # Stop Auto Scaling from replacing instances during cleanup.
          ASG_DATA=$(aws autoscaling describe-auto-scaling-groups \
            --query 'AutoScalingGroups[].[AutoScalingGroupName,VPCZoneIdentifier]' \
            --output text 2>/dev/null || true)
          while IFS=$'\t' read -r ASG_NAME ASG_SUBNETS; do
            [ -n "$ASG_NAME" ] && [ "$ASG_NAME" != "None" ] || continue
            for SUBNET_ID in $SUBNET_IDS; do
              case ",$ASG_SUBNETS," in
                *",$SUBNET_ID,"*)
                  aws autoscaling update-auto-scaling-group \
                    --auto-scaling-group-name "$ASG_NAME" \
                    --min-size 0 --max-size 0 --desired-capacity 0
                  aws autoscaling delete-auto-scaling-group \
                    --auto-scaling-group-name "$ASG_NAME" --force-delete
                  break
                  ;;
              esac
            done
          done <<< "$ASG_DATA"

          # Route 53 Resolver endpoints own service-managed ENIs and are a
          # common reason resolver subnets cannot be deleted.
          RESOLVER_ENDPOINT_IDS=$(aws route53resolver list-resolver-endpoints \
            --filters "Name=HostVPCId,Values=$VPC_ID" \
            --query 'ResolverEndpoints[].Id' --output text 2>/dev/null || true)
          for RESOLVER_ENDPOINT_ID in $RESOLVER_ENDPOINT_IDS; do
            [ "$RESOLVER_ENDPOINT_ID" != "None" ] || continue
            echo "Deleting Route 53 Resolver endpoint: $RESOLVER_ENDPOINT_ID"
            aws route53resolver delete-resolver-endpoint \
              --resolver-endpoint-id "$RESOLVER_ENDPOINT_ID" >/dev/null
          done

          INSTANCE_IDS=$(aws ec2 describe-instances \
            --filters "Name=vpc-id,Values=$VPC_ID" \
              'Name=instance-state-name,Values=pending,running,stopping,stopped' \
            --query 'Reservations[].Instances[].InstanceId' --output text)
          if [ -n "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
            for INSTANCE_ID in $INSTANCE_IDS; do
              aws ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" \
                --disable-api-termination Value=false >/dev/null 2>&1 || true
            done
            aws ec2 terminate-instances --instance-ids $INSTANCE_IDS >/dev/null
            aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
          fi

          LOAD_BALANCER_ARNS=$(aws elbv2 describe-load-balancers \
            --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
            --output text 2>/dev/null || true)
          for LOAD_BALANCER_ARN in $LOAD_BALANCER_ARNS; do
            [ "$LOAD_BALANCER_ARN" != "None" ] || continue
            aws elbv2 delete-load-balancer \
              --load-balancer-arn "$LOAD_BALANCER_ARN"
          done

          CLASSIC_LOAD_BALANCERS=$(aws elb describe-load-balancers \
            --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" \
            --output text 2>/dev/null || true)
          for LOAD_BALANCER_NAME in $CLASSIC_LOAD_BALANCERS; do
            [ "$LOAD_BALANCER_NAME" != "None" ] || continue
            aws elb delete-load-balancer \
              --load-balancer-name "$LOAD_BALANCER_NAME"
          done

          VPC_ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || true)
          if [ -n "$VPC_ENDPOINT_IDS" ] && [ "$VPC_ENDPOINT_IDS" != "None" ]; then
            aws ec2 delete-vpc-endpoints \
              --vpc-endpoint-ids $VPC_ENDPOINT_IDS >/dev/null
          fi

          NAT_GATEWAY_IDS=$(aws ec2 describe-nat-gateways \
            --filter "Name=vpc-id,Values=$VPC_ID" \
              'Name=state,Values=pending,available,failed' \
            --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)
          for NAT_GATEWAY_ID in $NAT_GATEWAY_IDS; do
            [ "$NAT_GATEWAY_ID" != "None" ] || continue
            aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GATEWAY_ID" >/dev/null
            aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_GATEWAY_ID"
          done

          # Resolver endpoints, load balancers, and VPC endpoints remove their
          # ENIs asynchronously. Wait up to five minutes and delete only ENIs
          # AWS reports as available.
          for ((ATTEMPT = 1; ATTEMPT <= 60; ATTEMPT++)); do
            AVAILABLE_ENIS=$(aws ec2 describe-network-interfaces \
              --filters "Name=vpc-id,Values=$VPC_ID" \
                'Name=status,Values=available' \
              --query 'NetworkInterfaces[].NetworkInterfaceId' \
              --output text 2>/dev/null || true)
            for ENI_ID in $AVAILABLE_ENIS; do
              [ "$ENI_ID" != "None" ] || continue
              aws ec2 delete-network-interface \
                --network-interface-id "$ENI_ID" >/dev/null 2>&1 || true
            done

            REMAINING_ENIS=$(aws ec2 describe-network-interfaces \
              --filters "Name=vpc-id,Values=$VPC_ID" \
              --query 'length(NetworkInterfaces)' --output text)
            [ "$REMAINING_ENIS" = "0" ] && break
            sleep 5
          done

          REMAINING_ENI_IDS=$(aws ec2 describe-network-interfaces \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)
          if [ -n "$REMAINING_ENI_IDS" ] && [ "$REMAINING_ENI_IDS" != "None" ]; then
            aws ec2 describe-network-interfaces \
              --network-interface-ids $REMAINING_ENI_IDS \
              --query 'NetworkInterfaces[].[NetworkInterfaceId,InterfaceType,Description,Status]' \
              --output table >&2
            fail_cleanup "AWS-managed network interfaces still block deletion of orphaned VPC $VPC_ID"
          fi

          for SUBNET_ID in $SUBNET_IDS; do
            [ "$SUBNET_ID" != "None" ] || continue
            aws ec2 delete-subnet --subnet-id "$SUBNET_ID"
          done

          ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query 'RouteTables[?Associations[?Main==`false`] || length(Associations)==`0`].RouteTableId' \
            --output text 2>/dev/null || true)
          for ROUTE_TABLE_ID in $ROUTE_TABLE_IDS; do
            [ "$ROUTE_TABLE_ID" != "None" ] || continue
            aws ec2 delete-route-table --route-table-id "$ROUTE_TABLE_ID" \
              >/dev/null 2>&1 || true
          done

          SECURITY_GROUP_IDS=$(aws ec2 describe-security-groups \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
            --output text 2>/dev/null || true)
          for SECURITY_GROUP_ID in $SECURITY_GROUP_IDS; do
            [ "$SECURITY_GROUP_ID" != "None" ] || continue
            aws ec2 delete-security-group --group-id "$SECURITY_GROUP_ID" \
              >/dev/null 2>&1 || true
          done

          INTERNET_GATEWAY_IDS=$(aws ec2 describe-internet-gateways \
            --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
            --query 'InternetGateways[].InternetGatewayId' \
            --output text 2>/dev/null || true)
          for INTERNET_GATEWAY_ID in $INTERNET_GATEWAY_IDS; do
            [ "$INTERNET_GATEWAY_ID" != "None" ] || continue
            aws ec2 detach-internet-gateway \
              --internet-gateway-id "$INTERNET_GATEWAY_ID" --vpc-id "$VPC_ID"
            aws ec2 delete-internet-gateway \
              --internet-gateway-id "$INTERNET_GATEWAY_ID"
          done

          aws ec2 delete-vpc --vpc-id "$VPC_ID" ||
            fail_cleanup "Unable to delete orphaned VPC $VPC_ID; dependent AWS resources remain"
        done
      }

      echo "Checking orphaned network and S3 resources"
      cleanup_orphan_vpcs
      cleanup_artifact_bucket

      echo "Preflight cleanup complete"
    EOT
  }
}
############################################################
# Destroy-Time Cleanup Of Unmanaged Lab Resources
#
# This resource depends on the lab network. Terraform therefore destroys it
# before destroying the subnets and VPC. Its destroy provisioner removes EC2
# instances and network dependencies created outside Terraform but located
# inside this lab's dedicated VPC.
############################################################

resource "terraform_data" "destroy_cleanup" {
  depends_on = [
    aws_vpc.lab,
    aws_subnet.public
  ]

  input = {
    environment_name = var.environment_name
    aws_region       = var.aws_region
    aws_profile      = var.aws_profile
    aws_account_id   = data.aws_caller_identity.current.account_id
    vpc_id           = aws_vpc.lab.id
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = fail

    interpreter = ["/bin/bash", "-c"]
    working_dir = path.module

    environment = {
      CLEANUP_ENVIRONMENT_NAME = self.input.environment_name
      CLEANUP_AWS_REGION       = self.input.aws_region
      CLEANUP_AWS_PROFILE      = self.input.aws_profile
      CLEANUP_AWS_ACCOUNT_ID   = self.input.aws_account_id
      CLEANUP_VPC_ID           = self.input.vpc_id
      AWS_PAGER                = ""
    }

    command = <<-EOT
      set -euo pipefail

      fail() {
        echo "ERROR: $*" >&2
        exit 1
      }

      require_command() {
        command -v "$1" >/dev/null 2>&1 ||
          fail "Required command is unavailable: $1"
      }

      require_command aws

      export AWS_REGION="$CLEANUP_AWS_REGION"
      export AWS_DEFAULT_REGION="$CLEANUP_AWS_REGION"
      export AWS_PAGER=""

      if [ -n "$CLEANUP_AWS_PROFILE" ]; then
        export AWS_PROFILE="$CLEANUP_AWS_PROFILE"
      else
        unset AWS_PROFILE AWS_DEFAULT_PROFILE
      fi

      echo "Destroy cleanup environment: $CLEANUP_ENVIRONMENT_NAME"
      echo "Destroy cleanup VPC: $CLEANUP_VPC_ID"
      echo "Destroy cleanup region: $CLEANUP_AWS_REGION"

      ########################################################
      # Safety checks
      ########################################################

      ACTUAL_ACCOUNT_ID="$(
        aws sts get-caller-identity \
          --query Account \
          --output text
      )"

      if [ "$ACTUAL_ACCOUNT_ID" != "$CLEANUP_AWS_ACCOUNT_ID" ]; then
        fail \
          "AWS account mismatch: expected $CLEANUP_AWS_ACCOUNT_ID, got $ACTUAL_ACCOUNT_ID"
      fi

      VPC_ENVIRONMENT="$(
        aws ec2 describe-vpcs \
          --vpc-ids "$CLEANUP_VPC_ID" \
          --query \
            'Vpcs[0].Tags[?Key==`Environment`].Value | [0]' \
          --output text 2>/dev/null || true
      )"

      if [ -z "$VPC_ENVIRONMENT" ] ||
         [ "$VPC_ENVIRONMENT" = "None" ]; then
        fail \
          "VPC $CLEANUP_VPC_ID has no Environment tag; refusing broad cleanup"
      fi

      if [ "$VPC_ENVIRONMENT" != "$CLEANUP_ENVIRONMENT_NAME" ]; then
        fail \
          "VPC ownership mismatch: expected $CLEANUP_ENVIRONMENT_NAME, got $VPC_ENVIRONMENT"
      fi

      ########################################################
      # Delete Auto Scaling groups using lab subnets
      #
      # This prevents an ASG from replacing instances while
      # cleanup is running.
      ########################################################

      LAB_SUBNET_IDS="$(
        aws ec2 describe-subnets \
          --filters "Name=vpc-id,Values=$CLEANUP_VPC_ID" \
          --query 'Subnets[].SubnetId' \
          --output text
      )"

      ASG_DATA="$(
        aws autoscaling describe-auto-scaling-groups \
          --query \
            'AutoScalingGroups[].[AutoScalingGroupName,VPCZoneIdentifier]' \
          --output text 2>/dev/null || true
      )"

      while IFS=$'\t' read -r ASG_NAME ASG_SUBNETS; do
        [ -n "$ASG_NAME" ] || continue
        [ "$ASG_NAME" != "None" ] || continue

        ASG_IN_LAB=false

        for LAB_SUBNET_ID in $LAB_SUBNET_IDS; do
          case ",$ASG_SUBNETS," in
            *",$LAB_SUBNET_ID,"*)
              ASG_IN_LAB=true
              break
              ;;
          esac
        done

        if [ "$ASG_IN_LAB" = true ]; then
          echo "Deleting Auto Scaling group in lab VPC: $ASG_NAME"

          aws autoscaling update-auto-scaling-group \
            --auto-scaling-group-name "$ASG_NAME" \
            --min-size 0 \
            --max-size 0 \
            --desired-capacity 0

          aws autoscaling delete-auto-scaling-group \
            --auto-scaling-group-name "$ASG_NAME" \
            --force-delete
        fi
      done <<< "$ASG_DATA"

      ########################################################
      # Terminate every remaining EC2 instance in the lab VPC
      #
      # At destroy time all instances in this dedicated VPC are
      # in scope, including instances created through Satellite
      # or manually and therefore absent from Terraform state.
      ########################################################

      INSTANCE_IDS="$(
        aws ec2 describe-instances \
          --filters \
            "Name=vpc-id,Values=$CLEANUP_VPC_ID" \
            'Name=instance-state-name,Values=pending,running,stopping,stopped' \
          --query 'Reservations[].Instances[].InstanceId' \
          --output text
      )"

      if [ -n "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
        echo "Disabling termination protection for lab instances"

        for INSTANCE_ID in $INSTANCE_IDS; do
          aws ec2 modify-instance-attribute \
            --instance-id "$INSTANCE_ID" \
            --disable-api-termination Value=false \
            >/dev/null 2>&1 || true
        done

        echo "Terminating lab instances: $INSTANCE_IDS"

        aws ec2 terminate-instances \
          --instance-ids $INSTANCE_IDS \
          >/dev/null

        aws ec2 wait instance-terminated \
          --instance-ids $INSTANCE_IDS
      fi

      ########################################################
      # Delete load balancers in the lab VPC
      ########################################################

      LOAD_BALANCER_ARNS="$(
        aws elbv2 describe-load-balancers \
          --query \
            "LoadBalancers[?VpcId=='$CLEANUP_VPC_ID'].LoadBalancerArn" \
          --output text 2>/dev/null || true
      )"

      for LOAD_BALANCER_ARN in $LOAD_BALANCER_ARNS; do
        [ "$LOAD_BALANCER_ARN" != "None" ] || continue

        echo "Deleting load balancer: $LOAD_BALANCER_ARN"

        aws elbv2 delete-load-balancer \
          --load-balancer-arn "$LOAD_BALANCER_ARN"
      done

      CLASSIC_LOAD_BALANCERS="$(
        aws elb describe-load-balancers \
          --query \
            "LoadBalancerDescriptions[?VPCId=='$CLEANUP_VPC_ID'].LoadBalancerName" \
          --output text 2>/dev/null || true
      )"

      for LOAD_BALANCER_NAME in $CLASSIC_LOAD_BALANCERS; do
        [ "$LOAD_BALANCER_NAME" != "None" ] || continue

        echo "Deleting classic load balancer: $LOAD_BALANCER_NAME"

        aws elb delete-load-balancer \
          --load-balancer-name "$LOAD_BALANCER_NAME"
      done

      ########################################################
      # Delete VPC endpoints
      ########################################################

      VPC_ENDPOINT_IDS="$(
        aws ec2 describe-vpc-endpoints \
          --filters "Name=vpc-id,Values=$CLEANUP_VPC_ID" \
          --query 'VpcEndpoints[].VpcEndpointId' \
          --output text 2>/dev/null || true
      )"

      if [ -n "$VPC_ENDPOINT_IDS" ] &&
         [ "$VPC_ENDPOINT_IDS" != "None" ]; then
        echo "Deleting VPC endpoints: $VPC_ENDPOINT_IDS"

        aws ec2 delete-vpc-endpoints \
          --vpc-endpoint-ids $VPC_ENDPOINT_IDS \
          >/dev/null
      fi

      ########################################################
      # Delete NAT gateways and wait for removal
      ########################################################

      NAT_GATEWAY_IDS="$(
        aws ec2 describe-nat-gateways \
          --filter \
            "Name=vpc-id,Values=$CLEANUP_VPC_ID" \
            'Name=state,Values=pending,available,failed' \
          --query 'NatGateways[].NatGatewayId' \
          --output text 2>/dev/null || true
      )"

      for NAT_GATEWAY_ID in $NAT_GATEWAY_IDS; do
        [ "$NAT_GATEWAY_ID" != "None" ] || continue

        echo "Deleting NAT gateway: $NAT_GATEWAY_ID"

        aws ec2 delete-nat-gateway \
          --nat-gateway-id "$NAT_GATEWAY_ID" \
          >/dev/null

        aws ec2 wait nat-gateway-deleted \
          --nat-gateway-ids "$NAT_GATEWAY_ID"
      done

      ########################################################
      # Wait for service-managed network interfaces to clear
      ########################################################

      for ((ATTEMPT = 1; ATTEMPT <= 60; ATTEMPT++)); do
        REMAINING_ENIS="$(
          aws ec2 describe-network-interfaces \
            --filters "Name=vpc-id,Values=$CLEANUP_VPC_ID" \
            --query 'length(NetworkInterfaces)' \
            --output text
        )"

        [ "$REMAINING_ENIS" = "0" ] && break

        echo \
          "Waiting for $REMAINING_ENIS network interfaces to clear ($ATTEMPT/60)"

        AVAILABLE_ENIS="$(
          aws ec2 describe-network-interfaces \
            --filters \
              "Name=vpc-id,Values=$CLEANUP_VPC_ID" \
              'Name=status,Values=available' \
            --query 'NetworkInterfaces[].NetworkInterfaceId' \
            --output text 2>/dev/null || true
        )"

        for ENI_ID in $AVAILABLE_ENIS; do
          [ "$ENI_ID" != "None" ] || continue

          aws ec2 delete-network-interface \
            --network-interface-id "$ENI_ID" \
            >/dev/null 2>&1 || true
        done

        sleep 5
      done

      REMAINING_ENIS="$(
        aws ec2 describe-network-interfaces \
          --filters "Name=vpc-id,Values=$CLEANUP_VPC_ID" \
          --query 'NetworkInterfaces[].NetworkInterfaceId' \
          --output text
      )"

      if [ -n "$REMAINING_ENIS" ] &&
         [ "$REMAINING_ENIS" != "None" ]; then
        echo "Network interfaces still blocking VPC deletion:" >&2

        aws ec2 describe-network-interfaces \
          --network-interface-ids $REMAINING_ENIS \
          --query \
            'NetworkInterfaces[].[NetworkInterfaceId,InterfaceType,Description,Status]' \
          --output table >&2

        fail "AWS-managed dependencies remain in the lab VPC"
      fi

      echo "Destroy-time cleanup complete"
    EOT
  }
}
