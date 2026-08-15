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
# This inline policy contains permissions required to create,
# modify, operate, and access the console output of EC2
# resources managed through Satellite.
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
      # Read EC2 instance console output and screenshots
      #
      # Satellite uses these actions when opening the console for an instance.
      #########################################################################

      {
        Sid    = "ReadEC2InstanceConsole"
        Effect = "Allow"

        Action = [
          "ec2:GetConsoleOutput",
          "ec2:GetConsoleScreenshot"
        ]

        Resource = (
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
        )
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
