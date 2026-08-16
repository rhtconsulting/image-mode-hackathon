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


