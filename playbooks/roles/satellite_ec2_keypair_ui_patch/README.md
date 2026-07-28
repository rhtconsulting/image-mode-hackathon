# Satellite EC2 key-pair UI patch

## Purpose

This role applies a local workaround for an HTTP 500 error in the Red Hat
Satellite 6.19 EC2 Compute Resource SSH Keys page.

Affected navigation:

```text
Infrastructure
-> Compute Resources
-> <EC2 compute resource>
-> SSH Keys