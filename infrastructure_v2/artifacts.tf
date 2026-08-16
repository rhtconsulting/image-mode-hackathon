############################################################
# Shared Image Mode Artifact Bucket
############################################################

resource "aws_s3_bucket" "image_mode_artifacts" {
  depends_on = [
    terraform_data.preflight_cleanup
  ]

  bucket = "${var.environment_name}-image-mode-artifacts-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  force_destroy = true

  tags = {
    Name = "${var.environment_name}-image-mode-artifacts-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

    Environment = var.environment_name
    Purpose     = "Image Mode AMI build artifacts"
  }
}

resource "aws_s3_bucket_public_access_block" "image_mode_artifacts" {
  bucket = aws_s3_bucket.image_mode_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "image_mode_artifacts" {
  bucket = aws_s3_bucket.image_mode_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "image_mode_artifacts" {
  bucket = aws_s3_bucket.image_mode_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}


############################################################
# Shared Image Mode Artifact Bucket Access Policy
############################################################

resource "aws_iam_policy" "image_mode_artifact_bucket_rw" {

  depends_on = [

    terraform_data.preflight_cleanup

  ]

  name = "${var.environment_name}-image-mode-artifact-bucket-rw"

  description = (
    "Push and pull Image Mode build artifacts from the shared S3 bucket."
  )

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      #########################################################################
      # Account-level S3 discovery
      #########################################################################

      {
        Sid    = "DiscoverAWSBuckets"
        Effect = "Allow"

        Action = [
          "s3:ListAllMyBuckets"
        ]

        Resource = "*"
      },

      #########################################################################
      # Inspect and configure the Image Mode artifact bucket
      #########################################################################

      {
        Sid    = "InspectAndConfigureImageModeArtifactBucket"
        Effect = "Allow"

        Action = [
          "s3:GetBucketAcl",
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning",
          "s3:GetBucketPublicAccessBlock",
          "s3:GetEncryptionConfiguration",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutBucketPublicAccessBlock",
          "s3:PutEncryptionConfiguration"
        ]

        Resource = aws_s3_bucket.image_mode_artifacts.arn
      },

      #########################################################################
      # Read and write Image Mode artifacts
      #########################################################################

      {
        Sid    = "PushAndPullImageModeArtifacts"
        Effect = "Allow"

        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]

        Resource = "${aws_s3_bucket.image_mode_artifacts.arn}/*"
      },

      #########################################################################
      # Read the Keycloak installer from the existing installer bucket
      #########################################################################

      {
        Sid    = "ListKeycloakInstaller"
        Effect = "Allow"

        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket"
        ]

        Resource = "arn:aws:s3:::${var.keycloak_installer_s3_bucket}"

        Condition = {
          StringLike = {
            "s3:prefix" = [var.keycloak_installer_s3_key]
          }
        }
      },
      {
        Sid    = "DownloadKeycloakInstaller"
        Effect = "Allow"

        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion"
        ]

        Resource = "arn:aws:s3:::${var.keycloak_installer_s3_bucket}/${var.keycloak_installer_s3_key}"
      }
    ]
  })
}



############################################################
# Shared S3 Access For Existing EC2 Roles
############################################################

resource "aws_iam_role_policy_attachment" "aap_image_mode_artifacts" {
  role       = aws_iam_role.aap.name
  policy_arn = aws_iam_policy.image_mode_artifact_bucket_rw.arn
}

resource "aws_iam_role_policy_attachment" "satellite_image_mode_artifacts" {
  role       = aws_iam_role.satellite.name
  policy_arn = aws_iam_policy.image_mode_artifact_bucket_rw.arn
}

resource "aws_iam_role_policy_attachment" "gitlab_image_mode_artifacts" {
  role       = aws_iam_role.gitlab_runtime.name
  policy_arn = aws_iam_policy.image_mode_artifact_bucket_rw.arn
}


############################################################
