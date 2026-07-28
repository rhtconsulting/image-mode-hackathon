############################################################
# AWS Settings
############################################################

variable "aws_profile" {
  type        = string
  default     = "image-mode-lab"
  description = "AWS CLI profile Terraform should use."
}

variable "aws_region" {
  type        = string
  default     = "us-east-2"
  description = "AWS region to deploy the lab into."

  validation {
    condition     = trimspace(var.aws_region) != ""
    error_message = "aws_region cannot be empty."
  }
}

############################################################
# Environment Settings
############################################################

variable "environment_name" {
  type        = string
  default     = "image-mode-lab"
  description = "Name prefix used for AWS resources and tags."

  validation {
    condition     = trimspace(var.environment_name) != ""
    error_message = "environment_name cannot be empty."
  }
}

############################################################
# AWS Secrets Manager
############################################################

variable "secret_prefix" {
  type        = string
  default     = "image-mode-lab"
  description = "AWS Secrets Manager prefix containing lab bootstrap credentials."

  validation {
    condition     = trimspace(var.secret_prefix) != ""
    error_message = "secret_prefix cannot be empty."
  }
}

############################################################
# DNS Settings
############################################################

variable "domain_name" {
  type        = string
  default     = ""
  description = "Base OpenTLC parent DNS domain. Leave blank to auto-discover the public sandbox*.opentlc.com Route53 hosted zone."
}

variable "opentlc_domain_suffix" {
  type        = string
  default     = "opentlc.com"
  description = "Domain suffix used when auto-discovering OpenTLC sandbox public hosted zones."

  validation {
    condition     = trimspace(var.opentlc_domain_suffix) != ""
    error_message = "opentlc_domain_suffix cannot be empty."
  }
}

variable "create_public_dns_records" {
  type        = bool
  default     = true
  description = "Create public Route53 A records for instances in the parent public Route53 zone."
}

variable "route53_zone_id" {
  type        = string
  default     = ""
  description = "Optional public Route53 zone ID. If blank, Terraform uses the auto-discovered public hosted zone."
}

############################################################
# Networking
############################################################

variable "vpc_cidr" {
  type        = string
  default     = "10.20.0.0/16"
  description = "CIDR block for the lab VPC."

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "public_subnet_cidr" {
  type        = string
  default     = "10.20.1.0/24"
  description = "CIDR block for the main subnet where lab instances are deployed."

  validation {
    condition     = can(cidrhost(var.public_subnet_cidr, 0))
    error_message = "public_subnet_cidr must be a valid IPv4 CIDR block."
  }
}

variable "resolver_subnet_cidr" {
  type        = string
  default     = "10.20.2.0/24"
  description = "Second subnet CIDR used by the Route53 Resolver endpoint."

  validation {
    condition     = can(cidrhost(var.resolver_subnet_cidr, 0))
    error_message = "resolver_subnet_cidr must be a valid IPv4 CIDR block."
  }
}

############################################################
# Access
############################################################

variable "ssh_allowed_cidr" {
  type        = string
  description = "Allowed IPv4 CIDR for SSH bootstrap access."

  validation {
    condition     = can(cidrhost(var.ssh_allowed_cidr, 0))
    error_message = "ssh_allowed_cidr must be a valid IPv4 CIDR block."
  }
}

############################################################
# AMI Settings
############################################################

variable "ami_id" {
  type        = string
  default     = ""
  description = "Optional RHEL AMI ID. Leave blank to auto-discover the latest matching RHEL 9 AMI."

  validation {
    condition = (
      trimspace(var.ami_id) == "" ||
      can(regex("^ami-[a-fA-F0-9]+$", trimspace(var.ami_id)))
    )

    error_message = "ami_id must be blank or a valid AMI ID beginning with ami-."
  }
}

############################################################
# IdM Users
############################################################

variable "lab_users" {
  description = "Users created inside Red Hat IdM."

  type = map(object({
    first_name = string
    last_name  = string
    groups     = list(string)
  }))

  default = {
    student01 = {
      first_name = "Student"
      last_name  = "One"

      groups = [
        "developers",
        "quay-users",
        "gitlab-users"
      ]
    }

    instructor01 = {
      first_name = "Instructor"
      last_name  = "One"

      groups = [
        "linux-admins",
        "aap-admins",
        "satellite-admins",
        "quay-admins",
        "gitlab-admins"
      ]
    }
  }
}

variable "idm_users" {
  description = "Simple IdM users created as lab IdM administrators."
  type        = list(string)

  default = [
    "claudiol",
    "pduncan",
    "cpranava",
    "stripura",
    "ablock",
    "itewksbu"
  ]
}

variable "idm_default_user_password" {
  type        = string
  sensitive   = true
  description = "Temporary default password for initial IdM lab users."

  validation {
    condition     = length(var.idm_default_user_password) >= 8
    error_message = "idm_default_user_password must contain at least 8 characters."
  }
}

############################################################
# EC2 Server Definitions
############################################################

variable "servers" {
  description = "Server definitions for the RHEL Image Mode lab."

  type = map(object({
    count         = number
    instance_type = string
    root_volume   = number
    extra_volume  = number
  }))

  default = {
    idm = {
      count         = 1
      instance_type = "m6i.large"
      root_volume   = 80
      extra_volume  = 0
    }

    satellite = {
      count         = 1
      instance_type = "m6i.2xlarge"
      root_volume   = 200
      extra_volume  = 500
    }

    aap = {
      count         = 1
      instance_type = "m6i.xlarge"
      root_volume   = 120
      extra_volume  = 0
    }

    quay = {
      count         = 1
      instance_type = "m6i.large"
      root_volume   = 100
      extra_volume  = 300
    }

    image-builder = {
      count         = 1
      instance_type = "m6i.2xlarge"
      root_volume   = 120
      extra_volume  = 500
    }

    gitlab = {
      count         = 1
      instance_type = "m6i.xlarge"
      root_volume   = 120
      extra_volume  = 500
    }
  }

  validation {
    condition = alltrue([
      for role, config in var.servers :
      config.count >= 0 &&
      floor(config.count) == config.count &&
      trimspace(config.instance_type) != "" &&
      config.root_volume > 0 &&
      config.extra_volume >= 0
    ])

    error_message = "Each server definition must have a non-negative integer count, a non-empty instance_type, a positive root_volume, and a non-negative extra_volume."
  }

  validation {
    condition = (
      contains(keys(var.servers), "idm") &&
      var.servers["idm"].count >= 1
    )

    error_message = "servers must include at least one IdM server."
  }
}

############################################################
# GitLab Settings
############################################################

variable "gitlab_registry_port" {
  type        = number
  default     = 5050
  description = "TCP port exposed for the GitLab container registry."

  validation {
    condition = (
      var.gitlab_registry_port >= 1 &&
      var.gitlab_registry_port <= 65535
    )

    error_message = "gitlab_registry_port must be between 1 and 65535."
  }
}

variable "gitlab_registry_allowed_cidrs" {
  type = list(string)

  default = [
    "0.0.0.0/0"
  ]

  description = "IPv4 CIDR blocks allowed to access the GitLab container registry."

  validation {
    condition = alltrue([
      for cidr in var.gitlab_registry_allowed_cidrs :
      can(cidrhost(cidr, 0))
    ])

    error_message = "Every entry in gitlab_registry_allowed_cidrs must be a valid IPv4 CIDR block."
  }
}

variable "gitlab_external_url_scheme" {
  type        = string
  default     = "https"
  description = "URL scheme used for GitLab public endpoints."

  validation {
    condition = contains(
      [
        "http",
        "https"
      ],
      lower(trimspace(var.gitlab_external_url_scheme))
    )

    error_message = "gitlab_external_url_scheme must be http or https."
  }
}

############################################################
# Red Hat Credentials
#
# Pass these with TF_VAR_* environment variables.
# Do not commit values to terraform.tfvars.
############################################################

variable "redhat_org_id" {
  type        = string
  description = "Red Hat organization ID."
  sensitive   = true

  validation {
    condition     = trimspace(var.redhat_org_id) != ""
    error_message = "redhat_org_id cannot be empty."
  }
}

variable "redhat_aap_activation_key" {
  type        = string
  description = "Red Hat activation key for AAP and RHEL registration."
  sensitive   = true

  validation {
    condition     = trimspace(var.redhat_aap_activation_key) != ""
    error_message = "redhat_aap_activation_key cannot be empty."
  }
}

variable "redhat_registry_username" {
  type        = string
  description = "registry.redhat.io username."
  sensitive   = true

  validation {
    condition     = trimspace(var.redhat_registry_username) != ""
    error_message = "redhat_registry_username cannot be empty."
  }
}

variable "redhat_registry_password" {
  type        = string
  description = "registry.redhat.io password."
  sensitive   = true

  validation {
    condition     = trimspace(var.redhat_registry_password) != ""
    error_message = "redhat_registry_password cannot be empty."
  }
}

############################################################
# Satellite Installation Settings
############################################################

variable "satellite_iso_s3_bucket" {
  type        = string
  default     = "aap-containerized-installers"
  description = "S3 bucket containing the Red Hat Satellite installation ISO."

  validation {
    condition     = trimspace(var.satellite_iso_s3_bucket) != ""
    error_message = "satellite_iso_s3_bucket cannot be empty."
  }
}

variable "satellite_iso_s3_key" {
  type        = string
  default     = "Satellite-6.19.2-rhel-9-x86_64.dvd.iso"
  description = "S3 object key for the Red Hat Satellite installation ISO."

  validation {
    condition     = trimspace(var.satellite_iso_s3_key) != ""
    error_message = "satellite_iso_s3_key cannot be empty."
  }
}

variable "satellite_iso_sha256" {
  type        = string
  default     = ""
  description = "Optional SHA-256 checksum for the Satellite ISO. Leave blank to skip checksum validation."

  validation {
    condition = (
      trimspace(var.satellite_iso_sha256) == "" ||
      can(regex("^[a-fA-F0-9]{64}$", trimspace(var.satellite_iso_sha256)))
    )

    error_message = "satellite_iso_sha256 must be blank or a 64-character SHA-256 hexadecimal value."
  }
}

variable "satellite_initial_admin_username" {
  type        = string
  default     = "admin"
  description = "Initial local Satellite administrator username."

  validation {
    condition     = trimspace(var.satellite_initial_admin_username) != ""
    error_message = "satellite_initial_admin_username cannot be empty."
  }
}

variable "satellite_organization_name" {
  type        = string
  default     = "Image Mode Lab"
  description = "Initial Satellite organization name."

  validation {
    condition     = trimspace(var.satellite_organization_name) != ""
    error_message = "satellite_organization_name cannot be empty."
  }
}

variable "satellite_location_name" {
  type        = string
  default     = "AWS"
  description = "Initial Satellite location name."

  validation {
    condition     = trimspace(var.satellite_location_name) != ""
    error_message = "satellite_location_name cannot be empty."
  }
}

############################################################
# Satellite AWS Compute Resource Settings
############################################################

variable "satellite_compute_resource_name" {
  type        = string
  default     = "AWS Image Mode"
  description = "Name of the AWS EC2 Compute Resource created in Satellite."

  validation {
    condition     = trimspace(var.satellite_compute_resource_name) != ""
    error_message = "satellite_compute_resource_name cannot be empty."
  }
}

variable "satellite_compute_profile_name" {
  type        = string
  default     = "AWS POC"
  description = "Name of the Satellite compute profile used for GitLab and future EC2 provisioning."

  validation {
    condition     = trimspace(var.satellite_compute_profile_name) != ""
    error_message = "satellite_compute_profile_name cannot be empty."
  }
}

variable "satellite_gitlab_compute_profile_name" {
  type        = string
  default     = "GitLab Image Mode"
  description = "Name of the Satellite compute-profile configuration used for GitLab EC2 instances."

  validation {
    condition     = trimspace(var.satellite_gitlab_compute_profile_name) != ""
    error_message = "satellite_gitlab_compute_profile_name cannot be empty."
  }
}

############################################################
# Satellite Subscription Manifest
############################################################

variable "satellite_manifest_s3_bucket" {
  type        = string
  default     = "aap-containerized-installers"
  description = "S3 bucket containing the Red Hat Satellite subscription manifest."

  validation {
    condition     = trimspace(var.satellite_manifest_s3_bucket) != ""
    error_message = "satellite_manifest_s3_bucket cannot be empty."
  }
}

variable "satellite_manifest_s3_key" {
  type        = string
  default     = "manifest_Satellite.zip"
  description = "S3 object key for the Red Hat Satellite subscription manifest."

  validation {
    condition     = trimspace(var.satellite_manifest_s3_key) != ""
    error_message = "satellite_manifest_s3_key cannot be empty."
  }
}

variable "satellite_manifest_sha256" {
  type        = string
  default     = ""
  description = "Optional SHA-256 checksum for the Satellite subscription manifest."

  validation {
    condition = (
      trimspace(var.satellite_manifest_sha256) == "" ||
      can(
        regex(
          "^[a-fA-F0-9]{64}$",
          trimspace(var.satellite_manifest_sha256)
        )
      )
    )

    error_message = "satellite_manifest_sha256 must be blank or a 64-character SHA-256 value."
  }
}

#############################################################
# Servers Requiring Stable Public Addresses
############################################################

variable "public_server_names" {
  description = <<-EOT
    Exact flattened server names that require an Elastic IP,
    public Route53 record, and public ACM certificate.

    Servers not listed remain private-only.
  EOT

  type = set(string)

  default = [
    "idm-1",
    "satellite-1",
    "aap-1",
    "quay-1",
    "gitlab-1"
  ]

  validation {
    condition = (
      length(var.public_server_names) <= 5
    )

    error_message = "public_server_names cannot contain more than five servers because the current regional Elastic IP quota is five."
  }
}

###############################################################################
# Image Builder
###############################################################################

variable "image_builder_cockpit_port" {
  description = "TCP port used by the Image Builder Cockpit web interface."
  type        = number
  default     = 9090

  validation {
    condition = (
      var.image_builder_cockpit_port >= 1 &&
      var.image_builder_cockpit_port <= 65535
    )

    error_message = "image_builder_cockpit_port must be between 1 and 65535."
  }
}

###############################################################################
# Satellite AWS Compute Profiles
###############################################################################

variable "satellite_default_compute_profile_name" {
  description = "Satellite compute profile used for generic Image Mode EC2 hosts."
  type        = string
  default     = "Image Mode Default"

  validation {
    condition     = length(trimspace(var.satellite_default_compute_profile_name)) > 0
    error_message = "satellite_default_compute_profile_name must not be empty."
  }
}

variable "satellite_image_builder_compute_profile_name" {
  description = "Satellite compute profile used for Image Builder EC2 hosts."
  type        = string
  default     = "Image Builder"

  validation {
    condition     = length(trimspace(var.satellite_image_builder_compute_profile_name)) > 0
    error_message = "satellite_image_builder_compute_profile_name must not be empty."
  }
}