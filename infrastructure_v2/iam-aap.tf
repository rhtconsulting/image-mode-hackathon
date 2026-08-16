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
