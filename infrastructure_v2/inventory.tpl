[all:vars]
ansible_user=ec2-user
ansible_ssh_private_key_file=${ansible_ssh_private_key_file}
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
ansible_python_interpreter=/usr/bin/python3.9

###############################################################################
# AWS environment
###############################################################################

aws_region=${aws_region}
aws_profile=${aws_profile}
secret_prefix=${secret_prefix}

aws_dns_resolver=${aws_dns_resolver}
lab_ssh_private_key_secret_name=${lab_ssh_private_key_secret_name}

###############################################################################
# Image Mode AWS workflow
###############################################################################

image_mode_artifact_bucket=${image_mode_artifact_bucket}
rhel_iam_credentials_secret_name=${rhel_iam_credentials_secret_name}
vmimport_role_name=${vmimport_role_name}

###############################################################################
# IdM and DNS
###############################################################################

parent_domain_name=${parent_domain_name}
idm_domain_name=${idm_domain_name}
idm_realm_name=${idm_realm_name}
idm_server_fqdn=${idm_server_fqdn}
idm_server_ip=${idm_server_ip}

###############################################################################
# Satellite installation artifacts
###############################################################################

satellite_iso_s3_bucket=${satellite_iso_s3_bucket}
satellite_iso_s3_key=${satellite_iso_s3_key}
satellite_iso_sha256=${satellite_iso_sha256}

satellite_manifest_s3_bucket=${satellite_manifest_s3_bucket}
satellite_manifest_s3_key=${satellite_manifest_s3_key}
satellite_manifest_sha256=${satellite_manifest_sha256}

satellite_initial_admin_username=${satellite_initial_admin_username}
satellite_organization_name=${satellite_organization_name}
satellite_location_name=${satellite_location_name}

###############################################################################
# Satellite AWS Compute Resource
###############################################################################

satellite_compute_resource_name=${satellite_compute_resource_name}

satellite_compute_profile_name=${satellite_compute_profile_name}
satellite_default_compute_profile_name=${satellite_default_compute_profile_name}
satellite_gitlab_compute_profile_name=${satellite_gitlab_compute_profile_name}
satellite_image_builder_compute_profile_name=${satellite_image_builder_compute_profile_name}

satellite_compute_region=${satellite_compute_region}
satellite_compute_availability_zone=${satellite_compute_availability_zone}
satellite_compute_subnet_id=${satellite_compute_subnet_id}
satellite_compute_vpc_id=${satellite_compute_vpc_id}
satellite_compute_key_pair=${satellite_compute_key_pair}

###############################################################################
# Satellite EC2 instance profiles
###############################################################################

satellite_default_instance_profile=${satellite_default_instance_profile}
satellite_gitlab_instance_profile=${satellite_gitlab_instance_profile}
satellite_image_builder_instance_profile=${satellite_image_builder_instance_profile}

###############################################################################
# Satellite EC2 security groups
###############################################################################

satellite_compute_security_group_ids=${jsonencode(satellite_compute_security_group_ids)}
satellite_default_security_group_ids=${jsonencode(satellite_default_security_group_ids)}
satellite_image_builder_security_group_ids=${jsonencode(satellite_image_builder_security_group_ids)}

###############################################################################
# Satellite AWS credentials
###############################################################################

satellite_aws_access_key_secret_name=${satellite_aws_access_key_secret_name}
satellite_aws_secret_key_secret_name=${satellite_aws_secret_key_secret_name}

###############################################################################
# Service ports
###############################################################################

gitlab_registry_port=${gitlab_registry_port}
image_builder_cockpit_port=${image_builder_cockpit_port}

###############################################################################
# Lab identities
###############################################################################

lab_users=${jsonencode(lab_users)}
idm_users=${jsonencode(idm_users)}

###############################################################################
# IdM
###############################################################################

[idm]
%{ for name, s in servers ~}
%{ if s.role == "idm" ~}
${s.fqdn} ansible_host=${s.ansible_host} private_ip=${s.private_ip} public_ip=${s.public_ip} role=${s.role} iam_instance_profile=${s.iam_instance_profile} public_tls_fqdn=${s.fqdn} acm_certificate_arn=${s.acm_certificate_arn}
%{ endif ~}
%{ endfor ~}

###############################################################################
# Satellite
###############################################################################

[satellite]
%{ for name, s in servers ~}
%{ if s.role == "satellite" ~}
${s.fqdn} ansible_host=${s.ansible_host} private_ip=${s.private_ip} public_ip=${s.public_ip} role=${s.role} iam_instance_profile=${s.iam_instance_profile} public_tls_fqdn=${s.fqdn} acm_certificate_arn=${s.acm_certificate_arn}
%{ endif ~}
%{ endfor ~}

###############################################################################
# Ansible Automation Platform
###############################################################################

[aap]
%{ for name, s in servers ~}
%{ if s.role == "aap" ~}
${s.fqdn} ansible_host=${s.ansible_host} private_ip=${s.private_ip} public_ip=${s.public_ip} role=${s.role} iam_instance_profile=${s.iam_instance_profile} public_tls_fqdn=${s.fqdn} acm_certificate_arn=${s.acm_certificate_arn}
%{ endif ~}
%{ endfor ~}

###############################################################################
# Quay
###############################################################################

[quay]
%{ for name, s in servers ~}
%{ if s.role == "quay" ~}
${s.fqdn} ansible_host=${s.ansible_host} private_ip=${s.private_ip} public_ip=${s.public_ip} role=${s.role} iam_instance_profile=${s.iam_instance_profile} quay_hostname=${s.fqdn} public_tls_fqdn=${s.fqdn} acm_certificate_arn=${s.acm_certificate_arn}
%{ endif ~}
%{ endfor ~}

###############################################################################
# Image Builder
###############################################################################

[image_builder]
%{ for name, s in servers ~}
%{ if s.role == "image-builder" ~}
${s.fqdn} ansible_host=${s.ansible_host} private_ip=${s.private_ip} public_ip=${s.public_ip} role=${s.role} iam_instance_profile=${s.iam_instance_profile} image_builder_cockpit_port=${image_builder_cockpit_port} public_tls_fqdn=${s.fqdn} acm_certificate_arn=${s.acm_certificate_arn}
%{ endif ~}
%{ endfor ~}

###############################################################################
# GitLab
###############################################################################

[gitlab]
%{ for name, s in servers ~}
%{ if s.role == "gitlab" ~}
${s.fqdn} ansible_host=${s.ansible_host} private_ip=${s.private_ip} public_ip=${s.public_ip} role=${s.role} iam_instance_profile=${s.iam_instance_profile} gitlab_hostname=${s.fqdn} gitlab_registry_port=${gitlab_registry_port} public_tls_fqdn=${s.fqdn} acm_certificate_arn=${s.acm_certificate_arn}
%{ endif ~}
%{ endfor ~}