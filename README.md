# Image Mode Hackathon

An end-to-end hack-a-thon lab that stands up a complete stack needed for hack-a-thon lab on AWS and wires it into an **Image Mode (bootc) CI/CD pipeline**. 
1. Terraform builds the infrastructure and bootstraps it;
2. Ansible deploys and configures the services;
3. Ansible Automation Platform (AAP) runs the build → publish → deploy → validate → rollback workflow for `rhel-bootc` images.

---

## What this is

RHEL **Image Mode** delivers the operating system as a bootable container image (`bootc`), so servers are updated by switching to a new image and rebooting rather than by patching packages in place. This repository is a self-contained hackathon environment for practicing that model at scale, backed by the supporting Red Hat platform services:

- **Red Hat Identity Management (IdM )** — DNS, Kerberos, and centralized identity
- **Red Hat Satellite** — content, lifecycle environments, content views, activation keys
- **Red Hat Ansible Automation Platform (AAP)** — the CI/CD control plane (containerized 2.7)
- **Red Hat Quay** — the container registry for published bootc images
- **Image Builder host** — builds and pushes the `rhel-bootc` images

The goal is a "one command builds the world" experience: `terraform apply` creates the AWS foundation, generates all credentials and the Ansible inventory, and launches the configuration playbooks that produce a ready-to-run Image Mode pipeline in AAP.

---

## Architecture

### Servers

Terraform provisions five RHEL 9 EC2 instances, each fronted by an Elastic IP and registered in DNS.

| Role | Instance type | Root vol | Extra vol | Purpose |
|------|---------------|---------:|----------:|---------|
| `idm` | `m6i.large` | 80 GB | — | Identity, Kerberos, DNS for the lab domain |
| `satellite` | `m6i.2xlarge` | 200 GB | 500 GB | Content management and lifecycle |
| `aap` | `m6i.xlarge` | 120 GB | — | Automation controller / CI-CD engine |
| `quay` | `m6i.large` | 100 GB | 300 GB | Container registry |
| `image-builder` | `m6i.2xlarge` | 120 GB | 500 GB | Builds and publishes bootc images |

### DNS design

Route 53 owns the parent sandbox domain and delegates the lab subdomain to IdM, with a Route 53 Resolver forwarding lab queries to IdM DNS:

```text
sandbox1234.opentlc.com            ← Route 53 (parent)
lab.sandbox1234.opentlc.com        ← Red Hat IdM (delegated)

idm-1.lab.sandbox1234.opentlc.com
aap-1.lab.sandbox1234.opentlc.com
satellite-1.lab.sandbox1234.opentlc.com
quay-1.lab.sandbox1234.opentlc.com
image-builder-1.lab.sandbox1234.opentlc.com
```

### Provisioning flow

```text
terraform apply
      │
      ├─ Create AWS network (VPC, subnets, Route 53 Resolver, security groups, EIPs)
      ├─ Generate credentials → AWS Secrets Manager
      ├─ Generate SSH bootstrap key → EC2 Key Pair + Secrets Manager
      ├─ Deploy RHEL 9 EC2 instances
      ├─ Configure public + IdM DNS records
      ├─ Render inventory.ini
      └─ Run Ansible configuration playbooks
```

---

## The Image Mode CI/CD pipeline

The configuration playbooks build an AAP workflow named **"Image Mode CI/CD Pipeline"** whose nodes chain together the `playbooks/image_mode/` plays:

```text
Deploy Quay → Build Image → Publish Image → Deploy Development → Validate Image
                                                                      │
                                                          (on failure) └→ Rollback
```

Under the hood the deploy/rollback steps use native bootc operations:

- **Build** — `podman build` a `rhel-bootc` image on the Image Builder host, then push to the registry
- **Deploy** — `bootc switch <image_ref>` on target hosts, reboot, and wait for reconnection
- **Validate** — inspect `bootc status` / `/etc/os-release` on the updated host
- **Rollback** — `bootc rollback` + reboot back to the previous deployment

> Some image_mode plays (`bootc-update.yml`, `publish-image.yml`) and several AAP job-template definitions are scaffolded/placeholders in this branch, intended to be filled in during the hackathon. `build-image.yml`, `deploy-dev.yml`, `deploy-prod.yml`, `validate-image.yml`, and `rollback.yml` contain working task logic.

---

## Repository layout

```text
.
├── infrastructure_v2/          # Current Terraform stack (use this)
│   ├── main.tf                 # Network, EC2, DNS, secrets, inventory, bootstrap
│   ├── variables.tf            # Region, sizing, DNS, IdM users, RH creds
│   ├── outputs.tf              # URLs, SSH commands, secret names
│   ├── terraform.tfvars.example
│   └── README.md               # Full Terraform deployment guide
│
├── infrastructure/             # Earlier/alternate Terraform + bastion layout
│
├── playbooks/                  # Ansible: deploy & configure the stack
│   ├── deploy-services.yml     # Master play — imports all component deploys
│   ├── deploy-idm.yml / enroll-idm-clients.yml
│   ├── deploy-satellite.yml / deploy-airgap-satellite.yml
│   ├── deploy-aap.yml / deploy-aap-containerized.yml
│   ├── deploy-quay.yml
│   ├── configure-aap-idm-sso.yml
│   ├── configure-aap-image-mode-ci-cd-workflow.yml   # Builds the AAP pipeline
│   ├── configure-image-mode-builder-hosts.yml
│   ├── stage-certs-on-image-builder-hosts.yml
│   ├── activate-satellite-subscription.yml
│   ├── image_mode/             # Pipeline plays: build, publish, deploy, validate, rollback
│   ├── roles/                  # Satellite deploy / content-bootstrap / subscription roles
│   └── README-*.md             # Per-component install runbooks
│
├── vars/                       # AAP-as-code: orgs, credentials, inventories,
│                               #   projects, job & workflow templates, surveys
├── files/                      # Vault/config templates (AAP, Quay)
├── collections/requirements.yaml
├── .pre-commit-config.yaml     # TruffleHog secret scanning
└── README-precommit.md
```

---

## Prerequisites

- An AWS account with permission to create VPCs, EC2, EIPs, Route 53 records, IAM roles, and Secrets Manager entries
- A Route 53 hosted zone for sandbox domain
- Terraform and the AWS CLI installed locally
- Ansible with the required collections:

  ```bash
  ansible-galaxy collection install -r collections/requirements.yaml
  ```
  (`amazon.aws`, `redhat.satellite`, `ansible.posix`, `ansible.controller`, `infra.aap_configuration`)
- Red Hat credentials (org ID, activation key, registry username/password)
- Access to the private AAP containerized installer S3 bucket (see below)

---

## Quick start

All commands run from `infrastructure_v2/`.

**1. Configure AWS**

```bash
aws configure --profile image-mode-lab
aws sts get-caller-identity --profile image-mode-lab
```

**2. Provide secrets via environment (recommended — keeps them off disk)**

```bash
export TF_VAR_idm_default_user_password='YourPassword!'
export TF_VAR_redhat_org_id="123456"
export TF_VAR_redhat_aap_activation_key="activation-key"
export TF_VAR_redhat_registry_username="username"
export TF_VAR_redhat_registry_password="password"
export TF_VAR_ssh_allowed_cidr="your-ip-addr"
```

**3. Configure the deployment**

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit: aws_region, domain_name, route53_zone_id, ssh_allowed_cidr, idm_users, ...
```

**4. Deploy**

```bash
terraform init
terraform plan  -out lab.tfplan
terraform apply lab.tfplan
```

**5. Explore outputs**

```bash
terraform output               # aap_url, quay_url, satellite_url, idm_fqdn, ...
terraform output ssh_commands  # ready-to-paste SSH commands
```

Terraform generates `image-mode-lab-key.pem` and an `inventory.ini`, and stores every generated credential in AWS Secrets Manager under the `image-mode-lab/...` prefix (IdM admin/directory-manager/user passwords, AAP controller/gateway/vault passwords, Quay DB/superuser passwords, and the SSH private key).

**Tear down**

```bash
terraform destroy
```

### ⚠️ AAP installer S3 bucket access

The AAP deployment pulls the containerized installer bundle and manifest from a **private** S3 bucket:

```text
s3://aap-containerized-installers/2.7/
  ansible-automation-platform-containerized-setup-bundle-2.7-1.2-x86_64.tar.gz
  manifest_AAP.zip
```

Terraform creates the EC2 IAM role, but the **bucket policy must trust your AWS account**, or AAP deployment fails with `AccessDenied`. Add your account to the bucket policy:

```json
{
  "Sid": "AllowLabAccountDownloadAAPInstaller",
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::123456789012:root" },
  "Action": ["s3:GetObject"],
  "Resource": ["arn:aws:s3:::aap-containerized-installers/2.7/*"]
}
```

---

## Configuring services with Ansible

Terraform launches the configuration automatically, but the plays can also be run by hand against the generated inventory. The master play `playbooks/deploy-services.yml` imports the full sequence:

```text
deploy-idm → enroll-idm-clients → deploy-satellite → deploy-aap
  → configure-aap-idm-sso → deploy-quay → stage-certs-on-image-builder-hosts
  → configure-aap-image-mode-ci-cd-workflow → activate-satellite-subscription
```

The AAP objects (organization, credentials, inventories, execution environment, projects, job templates, and the workflow) are defined declaratively in `vars/` and applied through the `infra.aap_configuration` / `ansible.controller` collections.

---

## Component runbooks

Detailed per-service guides live alongside the code:

| Guide | Location |
|-------|----------|
| Terraform deployment (v2) | `infrastructure_v2/README.md`, `infrastructure_v2/README-deploy-image-mode-lab.md` |
| Legacy infrastructure & connectivity | `infrastructure/README.md`, `infrastructure/README-HOWTO-CONNECT.md` |
| IdM (FreeIPA) install | `playbooks/README-idm-install.md` |
| Satellite offline install | `playbooks/README-satellite-install.md` |
| AAP containerized install | `playbooks/README-aap-containerized-install.md` |
| Quay install | `playbooks/README-quay-install.md` |
| Pre-commit / secret scanning | `README-precommit.md` |


---

## Security

- **Never commit secrets.** Prefer `TF_VAR_*` environment variables over `terraform.tfvars`; add `terraform.tfvars` and `*.tfvars` to `.gitignore`.
- **Pre-commit secret scanning** is configured with TruffleHog to block hardcoded secrets locally:

  ```bash
  pip install pre-commit   # or: brew install pre-commit
  pre-commit install
  ```

- **Generated credentials** live in AWS Secrets Manager, not in the repo.
- **Hardening for anything beyond a disposable lab:** use encrypted remote Terraform state with restricted access, tighten `ssh_allowed_cidr`, rotate the generated credentials, and store production secrets in an external secrets manager.

---

## License
