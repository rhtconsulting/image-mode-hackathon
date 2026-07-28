# image_mode_build_ami

Builds a bootc container, pushes it to Quay, and uses
`bootc-image-builder` to upload and register an AWS AMI directly.

## Important workflow change

The role does not:

- export `disk.raw`;
- create a checksum;
- upload the raw disk with the AWS CLI;
- call `aws ec2 import-image`;
- poll an import-image task manually.

Instead it supplies all three direct-upload flags to bootc-image-builder:

```text
--aws-ami-name
--aws-bucket
--aws-region
```

The S3 bucket must already exist. The role creates and secures it when
`image_mode_create_artifacts_bucket` is true.

## Required variable

```yaml
image_mode_ssh_public_key: "ssh-rsa AAAA..."
```

## AAP credential

Attach an AWS custom credential that injects:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN       # optional
AWS_REGION
```

The role writes these values to a temporary root-only environment file,
passes it to the builder container, and removes it in an `always` section.

## Registry authentication

The Image Builder host must already be logged in as root to:

```text
registry.redhat.io
<image_mode_quay_host>
```

The role validates both logins by default.

## 40 GiB disk

The current default is:

```yaml
image_mode_root_disk_size: "40 GiB"
```

It is configurable, but should remain at 40 GiB until larger direct uploads
are tested successfully.

## Run

```bash
ansible-playbook \
  -i playbooks/inventory/hosts \
  playbooks/build-image-mode-ami.yml \
  -e @image-vars.yml \
  -vvv
```

Example variables:

```yaml
image_mode_image_name: "sample-rhel9"
image_mode_image_tag: "v1"
image_mode_quay_host: "quay-1.lab.example.com"
image_mode_quay_organization: "image-mode"
image_mode_ssh_public_key: "ssh-rsa AAAA... image-mode-lab"
image_mode_root_disk_size: "40 GiB"
```
