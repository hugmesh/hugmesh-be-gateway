# Security Policy

If you find a vulnerability in this repository, or in any other HugMesh
repository, report it privately. Do not open a public issue.

Use GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
on this repository (Security tab, then "Report a vulnerability"), or open a draft
security advisory. We will acknowledge your report as quickly as we can and agree
a fix and disclosure timeline with you.

## Scope

This repository is a thin overlay on the shared
[hugmesh-gateway](https://github.com/hugmesh/hugmesh-gateway) image. It holds a
`Dockerfile`, one config file (`application-be.yml`), deployment manifests and a
Liquibase changelog. It holds no gateway code of its own.

- Report problems in this overlay here: the route set, the downstream URI, the
  image build and the deployment manifests.
- Report problems in token validation, route-access enforcement, revocation or
  downstream mTLS against `hugmesh-gateway`, which supplies all of that code.

## Supported versions

The supported version is the latest commit on `main`. Fixes land on `main`; there
are no maintenance branches.

Keep exploit details out of public issues and discussions until a fix has shipped.
