# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## State of the repo

This is an identity and access management (IAM) portfolio, currently scaffolding only. The root `README.md` and every project `README.md` are empty, and there is no source code, build system, linter or test suite yet. Don't assume any commands exist. Add them here once real code lands.

The remote is the public GitHub repo `Demo411/iam-portfolio` (branch `main`). Everything committed is publicly visible.

## Layout

Five independent, numbered project folders. Each is meant to be self-contained, with its own README:

- `01-bulk-user-provisioning`
- `02-conditional-access-baseline`
- `03-sso-saml-oidc`
- `04-access-review-program`
- `05-iam-as-code-pipeline`

Keep new work inside the matching folder, and keep the numeric-prefix, kebab-case naming for any new project.

## Secrets

The repo is public, and `.gitignore` already excludes `*.pfx`, `*.pem`, `*.key`, `*.cer`, `.env`, `*.tfstate*`, `.terraform/` and `*.tfvars`. Examples for Terraform, certificates or tenant config should use placeholders or a committed `*.example` file. Use placeholder tenant IDs, domains and user names, not real ones.
