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

############################################################
# Image Builder Installation ISO Access
############################################################

resource "aws_iam_role_policy" "image_builder_installation_isos_read" {
  name = "${var.environment_name}-image-builder-installation-isos-read"
  role = aws_iam_role.image_builder.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "ReadInstallationISOs"
        Effect = "Allow"

        Action = [
          "s3:GetObject"
        ]

        Resource = "arn:aws:s3:::aap-containerized-installers/*.iso"
      }
    ]
  })
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

  depends_on = [
    aws_iam_role_policy.image_builder_installation_isos_read,
    aws_iam_role_policy_attachment.image_builder_artifacts,
    aws_iam_role_policy_attachment.image_builder_ami_import
  ]
}


############################################################
# Image Builder EC2 Provisioning Policy
#
# Allows the rhel-iam automation user to create and reconcile
# Image Builder EC2 instances and attach existing security groups.
############################################################

resource "aws_iam_policy" "image_builder_ec2_provisioning" {
  name = "${var.environment_name}-image-builder-ec2-provisioning"

  description = (
    "Allow Image Mode automation to provision and reconcile Image Builder EC2 instances."
  )

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "ProvisionImageBuilderInstances"
        Effect = "Allow"

        Action = [
          "ec2:RunInstances"
        ]

        Resource = "*"
      },

      {
        Sid    = "TagProvisionedResources"
        Effect = "Allow"

        Action = [
          "ec2:CreateTags"
        ]

        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:volume/*"
        ]

        Condition = {
          StringEquals = {
            "ec2:CreateAction" = "RunInstances"
          }
        }
      },

      {
        Sid    = "ReconcileImageBuilderInstanceLifecycle"
        Effect = "Allow"

        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:RebootInstances",
          "ec2:TerminateInstances"
        ]

        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
        ]
      },

      {
        Sid    = "ModifyImageBuilderVolumes"
        Effect = "Allow"

        Action = [
          "ec2:ModifyVolume"
        ]

        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:volume/*"
        ]
      },

      #########################################################################
      # Changing an instance's security groups requires authorization for the
      # instance and every security group included in the replacement list.
      # Network-interface coverage is included because security-group changes
      # are applied to the instance's primary network interface.
      #########################################################################

      {
        Sid    = "ManageImageBuilderInstanceSecurityGroups"
        Effect = "Allow"

        Action = [
          "ec2:ModifyInstanceAttribute"
        ]

        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:network-interface/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group/*"
        ]
      },

      {
        Sid    = "PassImageBuilderInstanceRole"
        Effect = "Allow"

        Action = [
          "iam:PassRole"
        ]

        Resource = [
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
    aws_iam_role.image_builder
  ]

  tags = {
    Name        = "${var.environment_name}-image-builder-ec2-provisioning"
    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "Provision Image Builder EC2 instances"
  }
}


############################################################
# Image Builder ACM and Route 53 Certificate Management
#
# Allows the rhel-iam automation user to request exportable
# public ACM certificates, create the Route 53 DNS validation
# records, and export the issued certificate material.
############################################################

resource "aws_iam_policy" "image_builder_certificate_management" {
  name = (
    "${var.environment_name}-image-builder-certificate-management"
  )

  description = (
    "Allow Image Mode automation to create, validate, and export Image Builder ACM certificates."
  )

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      #########################################################################
      # Route 53 zone discovery
      #
      # Route 53 list operations do not support resource-level restrictions.
      #########################################################################

      {
        Sid    = "DiscoverPublicRoute53Zones"
        Effect = "Allow"

        Action = [
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName"
        ]

        Resource = "*"
      },

      #########################################################################
      # Route 53 DNS certificate validation
      #########################################################################

      {
        Sid    = "ManageImageBuilderCertificateValidationRecords"
        Effect = "Allow"

        Action = [
          "route53:GetHostedZone",
          "route53:ListResourceRecordSets",
          "route53:ChangeResourceRecordSets"
        ]

        Resource = (
          "arn:aws:route53:::hostedzone/${local.public_route53_zone_id}"
        )
      },

      {
        Sid    = "ReadRoute53ChangeStatus"
        Effect = "Allow"

        Action = [
          "route53:GetChange"
        ]

        Resource = "arn:aws:route53:::change/*"
      },

      #########################################################################
      # ACM certificate discovery and creation
      #
      # RequestCertificate creates a new resource, so it cannot be restricted
      # to a certificate ARN that does not exist yet.
      #########################################################################

      {
        Sid    = "DiscoverAndRequestACMCertificates"
        Effect = "Allow"

        Action = [
          "acm:ListCertificates",
          "acm:RequestCertificate",
          "acm:AddTagsToCertificate"
        ]

        Resource = "*"
      },

      #########################################################################
      # ACM certificate inspection and export
      #########################################################################

      {
        Sid    = "ManageImageBuilderACMCertificates"
        Effect = "Allow"

        Action = [
          "acm:DescribeCertificate",
          "acm:ExportCertificate",
          "acm:GetCertificate",
          "acm:ListTagsForCertificate"
        ]

        Resource = (
          "arn:aws:acm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:certificate/*"
        )
      }
    ]
  })

  depends_on = [
    terraform_data.preflight_cleanup
  ]

  tags = {
    Name = (
      "${var.environment_name}-image-builder-certificate-management"
    )

    Environment = var.environment_name
    ManagedBy   = "Terraform"
    Purpose     = "Manage Image Builder ACM certificates and DNS validation"
  }
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

resource "aws_iam_user_policy_attachment" "rhel_iam_ec2_provisioning" {
  user       = aws_iam_user.rhel_iam.name
  policy_arn = aws_iam_policy.image_builder_ec2_provisioning.arn
}

resource "aws_iam_user_policy_attachment" "rhel_iam_certificate_management" {
  user       = aws_iam_user.rhel_iam.name
  policy_arn = aws_iam_policy.image_builder_certificate_management.arn
}

resource "aws_iam_access_key" "rhel_iam" {
  user = aws_iam_user.rhel_iam.name

  depends_on = [
    aws_iam_user_policy_attachment.rhel_iam_artifacts,
    aws_iam_user_policy_attachment.rhel_iam_ami_import,
    aws_iam_user_policy_attachment.rhel_iam_ec2_discovery,
    aws_iam_user_policy_attachment.rhel_iam_ec2_provisioning,
    aws_iam_user_policy_attachment.rhel_iam_certificate_management,
    aws_iam_user_policy.rhel_iam_installation_isos_read
  ]
}


###############################################################################
# rhel-iam access to Image Builder installation ISO media
###############################################################################

resource "aws_iam_user_policy" "rhel_iam_installation_isos_read" {
  name = "${var.environment_name}-rhel-iam-installation-isos-read"
  user = aws_iam_user.rhel_iam.name

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "ReadInstallationISOBucketMetadata"
        Effect = "Allow"

        Action = [
          "s3:GetBucketLocation"
        ]

        Resource = "arn:aws:s3:::aap-containerized-installers"
      },
      {
        Sid    = "ListInstallationISOs"
        Effect = "Allow"

        Action = [
          "s3:ListBucket"
        ]

        Resource = "arn:aws:s3:::aap-containerized-installers"

        Condition = {
          StringLike = {
            "s3:prefix" = [
              "rhel-9.8-x86_64-dvd.iso",
              "rhel-10.2-x86_64-dvd.iso"
            ]
          }
        }
      },
      {
        Sid    = "ReadInstallationISOs"
        Effect = "Allow"

        Action = [
          "s3:GetObject"
        ]

        Resource = [
          "arn:aws:s3:::aap-containerized-installers/rhel-9.8-x86_64-dvd.iso",
          "arn:aws:s3:::aap-containerized-installers/rhel-10.2-x86_64-dvd.iso"
        ]
      }
    ]
  })
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

