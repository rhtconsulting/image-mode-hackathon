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
