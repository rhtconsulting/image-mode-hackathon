# Image Mode Lab Terraform

This Terraform root module builds the AWS infrastructure for the Image Mode Lab and generates the Ansible inventory used to configure its services. The configuration was split from a single large `main.tf` into files organized by responsibility. Terraform evaluates every `.tf` file in this directory together, so this organization does not create child modules or change existing Terraform resource addresses.

## What this deployment creates

The deployment provides:

- A VPC, two subnets, internet routing, and workload security groups.
- RHEL 9 EC2 instances for IdM, Satellite, AAP, Quay, Image Builder, GitLab, and Keycloak.
- Optional additional EBS data volumes based on each server definition.
- Elastic IP addresses for selected servers.
- Route 53 public records, ACM certificates, and an outbound DNS Resolver rule for the IdM domain.
- Workload-specific IAM roles, instance profiles, policies, users, and access keys.
- An encrypted, versioned S3 bucket for Image Mode artifacts.
- Generated credentials stored in AWS Secrets Manager.
- A generated Ansible inventory and an optional local bootstrap execution.

## How the files work together

The main flow is:

1. `versions.tf` configures Terraform and the AWS provider.
2. `variables.tf` defines administrator-controlled settings.
3. `locals.tf` discovers AWS information and converts `var.servers` into individual server records.
4. `network.tf`, `artifacts.tf`, `iam-*.tf`, and `secrets.tf` create shared infrastructure.
5. `compute.tf` creates the EC2, EBS, EIP, DNS, and ACM resources for every expanded server record.
6. `dns-resolver.tf` connects VPC DNS resolution to IdM.
7. `automation.tf` renders `inventory.tpl` and runs the Ansible bootstrap workflow.
8. `outputs.tf` exposes addresses, names, URLs, secret references, and AWS resource identifiers.

## File reference

### `versions.tf`

Defines the minimum Terraform version and the required AWS, Local, Random, and TLS providers. It also configures the AWS provider with `aws_profile`, `aws_region`, and default resource tags.

Edit this file when changing provider constraints, the minimum supported Terraform version, provider aliases, or organization-wide default tags. Backend configuration may be added here or kept in a separate `backend.tf`.

### `variables.tf`

Defines the public interface for the entire root module. Its settings include:

- AWS profile, region, environment name, and Secrets Manager prefix.
- Route 53 discovery and public DNS behavior.
- VPC, public subnet, resolver subnet, and SSH access CIDRs.
- Optional AMI override and automatic RHEL 9 AMI selection behavior.
- IdM users and initial credentials.
- The `servers` map that controls server roles, counts, EC2 sizes, and volumes.
- GitLab registry configuration.
- Red Hat subscription and registry credentials.
- Satellite installation media, manifest, organization, location, and compute-resource settings.
- The set of server names that receive stable Elastic IP addresses.
- Image Builder Cockpit configuration.

Most environment customization should happen through a `.tfvars` file instead of editing defaults directly. Sensitive values should not be committed to source control.

### `locals.tf`

Contains discovery and normalization logic shared across the deployment. It:

- Discovers available AWS Availability Zones and the current AWS account.
- Finds a matching public OpenTLC Route 53 zone when a domain is not supplied explicitly.
- Derives the parent domain, `lab` IdM domain, and IdM realm.
- Validates that DNS discovery produces an unambiguous result.
- Expands each entry in `var.servers` into individual names such as `keycloak-1` and `keycloak-2`.
- Separates stable-public-address servers from the remaining servers.
- Selects and validates the primary IdM server.
- Discovers the latest matching RHEL 9 AMI when `ami_id` is blank.
- Defines the VPC DNS resolver address and generated SSH-key locations.

Edit this file when changing naming conventions, DNS derivation, AMI selection, or how server definitions expand into instances.

### `network.tf`

Creates the shared network foundation:

- Lab VPC.
- Internet gateway.
- Main EC2 subnet and secondary Route 53 Resolver subnet.
- Public route table and subnet associations.
- Common lab security group for SSH, HTTP, HTTPS, and internal VPC traffic.
- Additional Image Builder security group for Cockpit.
- Additional GitLab security group for the container registry.

Edit this file when changing network topology, ingress/egress rules, or workload-specific ports. For a new role that needs extra ports, define its security group here and map it in `additional_security_groups_by_role` in `compute.tf`.

### `secrets.tf`

Manages bootstrap keys and secrets. It:

- Generates the lab RSA SSH key.
- registers the public key as an EC2 key pair.
- Writes the private key locally with restricted permissions.
- Defines the generated, static, Red Hat, and SSH-secret collections.
- Generates passwords and stores secret values in AWS Secrets Manager.
- Runs the existing preflight cleanup procedure used for lab rebuilds.

This file contains destructive cleanup commands intended for disposable or rebuildable lab environments. Review `terraform_data.preflight_cleanup` before every production-like use. Do not assume it is safe for infrastructure that must retain existing resources.

### `artifacts.tf`

Creates the shared Image Mode artifact storage:

- Private S3 bucket.
- Public-access block.
- Server-side encryption.
- Bucket versioning.
- Shared read/write IAM policy.
- Policy attachments for the AAP, Satellite, and GitLab roles.

Edit this file when changing artifact retention, encryption, bucket access, or the workloads allowed to use the artifact bucket.

### `iam-default.tf`

Defines shared IAM resources that are not owned by one application:

- `lab_ec2_default` role and instance profile.
- Access from that default role to the Image Mode artifact bucket.
- The AWS `vmimport` service role used for VM Import/Export.
- The caller policy used to import bootc images as AMIs.

The default EC2 profile is assigned to roles without an explicit entry in `instance_profile_by_role`. IdM, Quay, and Keycloak currently use this fallback. If Keycloak later needs its own Secrets Manager, database, KMS, or S3 permissions, create `iam-keycloak.tf` and add its profile to the mapping in `compute.tf`.

### `iam-aap.tf`

Defines the AAP EC2 role and instance profile. Its policies allow AAP to read the lab secrets and required S3 content. This file also defines the shared EC2 discovery policy used by other provisioning identities.

Edit this file when AAP needs additional AWS API, Secrets Manager, or S3 permissions.

### `iam-satellite.tf`

Defines two distinct Satellite identities:

- The Satellite EC2 host role and instance profile, used by software running on the Satellite server.
- The Satellite provisioning IAM user and access key, used by the Satellite AWS compute resource to discover and provision EC2 infrastructure.

It also stores the provisioning access-key ID and secret access key in Secrets Manager. Edit this file when changing Satellite discovery, provisioning, Secrets Manager, or S3 permissions.

### `iam-gitlab.tf`

Defines the GitLab runtime role, its inline runtime policy, and its EC2 instance profile. Edit this file when GitLab runners or GitLab-hosted automation require different AWS permissions.

### `iam-image-builder.tf`

Defines the AWS identities and policies used by Image Builder and image automation. It includes:

- Image Builder EC2 role and instance profile.
- Access to installation ISO content and the shared artifact bucket.
- AMI import permissions.
- EC2 provisioning and certificate-management policies.
- The `rhel_iam` automation user and access key.
- Secrets Manager storage for the automation credentials.

Edit this file when changing automated image creation, AMI import, EC2 reconciliation, ACM, Route 53, or installation-media permissions.

### `compute.tf`

Creates the server fleet from `local.flattened_servers`. It contains:

- `instance_profile_by_role`, which maps exceptional roles to IAM profiles.
- `additional_security_groups_by_role`, which maps exceptional roles to extra security groups.
- The generic `aws_instance.server` resource used for all roles.
- Optional encrypted gp3 data volumes and attachments.
- Elastic IPs and associations for names in `public_server_names`.
- Public Route 53 A records.
- ACM certificates, DNS validation records, and certificate validation.

Roles not present in the two maps automatically use the default EC2 profile and common lab security group. This is the primary extension point when a new workload requires special permissions or ports.

### `dns-resolver.tf`

Creates an outbound Route 53 Resolver endpoint across the two subnets and a forwarding rule for the IdM-managed `lab` domain. DNS queries for that domain are forwarded to the primary IdM server. It also validates that every requested stable-public server name exists in the expanded server map.

Edit this file when changing private DNS forwarding, resolver placement, or IdM DNS integration.

### `inventory.tpl`

Is the Terraform template for the generated Ansible INI inventory. It contains global Ansible variables, AWS and Satellite settings, service ports, lab identities, and IdM information.

Server groups are generated dynamically from the roles in the `servers` map. Hyphens are converted to underscores, so `image-builder` becomes `[image_builder]`. Adding `keycloak` automatically creates a `[keycloak]` group. Role-specific host variables for Quay, GitLab, and Image Builder are added conditionally.

Edit this template when Ansible needs a new global variable or role-specific host variable. A basic new server group does not require a template change.

### `automation.tf`

Connects Terraform to Ansible. It:

- Calls `templatefile()` with infrastructure values and renders `inventory.tpl`.
- Writes the result to `inventory.ini`.
- Clones or updates the configured automation repository.
- Copies the generated inventory into that repository.
- Runs `playbooks/deploy-services.yml`.

Because the bootstrap uses local commands, the machine running Terraform must have Git, Ansible, network access, and the required AWS credentials. Edit this file when changing the automation repository, branch, inventory destination, or entry-point playbook.

### `outputs.tf`

Exposes deployment information for administrators, scripts, and downstream Terraform consumers. Outputs cover:

- Per-server names, roles, IP addresses, profiles, FQDNs, and SSH commands.
- Generated inventory content and SSH-key references.
- VPC, subnet, security-group, DNS Resolver, Route 53, and domain information.
- Role-specific server lists and service URLs.
- LDAP integration settings for Quay and GitLab.
- Secret names rather than secret values.
- Satellite installation and compute-resource settings.
- IAM role, profile, user, policy, access-key, S3 bucket, and VM import identifiers.

Keycloak is available immediately through the generic `servers`, `server_fqdns`, and `ssh_commands` outputs. Add dedicated Keycloak outputs only if downstream automation requires a Keycloak-specific contract.

## Add or scale a server role

Edit the `servers` map in `variables.tf`, or preferably override the complete map in an environment `.tfvars` file. Each role expands to `<role>-1`, `<role>-2`, and so on. Keycloak is enabled by default:

```hcl
keycloak = {
  count         = 1
  instance_type = "m6i.large"
  root_volume   = 80
  extra_volume  = 0
}
```

Increasing `count` creates `keycloak-2`, `keycloak-3`, and subsequent instances. Setting `extra_volume` above zero creates one encrypted gp3 data volume for each instance.

Unknown roles receive the shared default EC2 profile and common lab security group. For special requirements:

1. Define a workload IAM role and instance profile in an `iam-<role>.tf` file.
2. Add the profile to `instance_profile_by_role` in `compute.tf`.
3. Define any additional security group in `network.tf`.
4. Add that group to `additional_security_groups_by_role` in `compute.tf`.
5. Add role-specific Ansible host variables to `inventory.tpl` only when needed.

## Stable public addresses

`public_server_names` controls Elastic IP allocation. Keycloak is not included by default because the supplied configuration already lists five servers, matching the validation limit based on the default regional Elastic IP quota.

To give Keycloak a stable public address:

1. Raise the applicable AWS Elastic IP quota or remove another server from the set.
2. Add `"keycloak-1"` to `public_server_names`.
3. Adjust the set-size validation if the AWS quota was raised.
4. Review the resulting Terraform plan before applying.

## Deployment and migration

1. Back up the current Terraform directory and state.
2. Preserve existing backend configuration, `.tfvars` files, and the provider lock file when appropriate.
3. Replace the monolithic files with the refactored files in this directory. Do not leave the old `main.tf` in place because its resources would be declared twice.
4. Run `terraform init`.
5. Run `terraform fmt -recursive` and `terraform validate`.
6. Run `terraform plan -out=plan.tfplan`.
7. Confirm that existing resources retain their addresses and are not unexpectedly replaced or destroyed.
8. Confirm that the planned additions include `aws_instance.server["keycloak-1"]` and the expected related resources.
9. Apply only the reviewed saved plan.

Splitting resources among `.tf` files does not change their Terraform addresses. Moving them into child modules would change addresses and would require explicit `moved` blocks or state migration; this refactor intentionally does not do that.

## Operational cautions

- Review the destructive preflight cleanup in `secrets.tf` before running Terraform.
- Keep Terraform state and generated private keys protected.
- Never commit secret-bearing `.tfvars`, `inventory.ini`, private keys, or provider credentials.
- Review IAM policy changes for least privilege.
- Treat changes to `for_each` keys and server role names as resource identity changes.
- Always inspect plans for replacement or deletion before applying.
