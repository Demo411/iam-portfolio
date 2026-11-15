# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## State of the repo

An identity and access management (IAM) portfolio of five numbered, self-contained projects. The remote is the public GitHub repo `Demo411/iam-portfolio` (branch `main`), so everything committed is publicly visible.

Only Project 01 has code so far, and only its Joiner phase (Mover and Leaver are not built). Projects 02-05 are folders with empty READMEs. The root `README.md` has a project table with a Status column; keep it in sync with reality (01 is "In progress", the rest "Planned").

All projects use one fictional company, Contoso Logistics (Finance, Sales, IT, Operations).

## Layout

- `01-bulk-user-provisioning` (`src/`, `docs/`, `samples/`; `logs/` is git-ignored)
- `02-conditional-access-baseline`
- `03-sso-saml-oidc`
- `04-access-review-program`
- `05-iam-as-code-pipeline`

Keep new work inside the matching folder, and keep the numeric-prefix, kebab-case naming for any new project.

## Project 01: running and changing the script

There is no build step, linter or test suite. The script is `01-bulk-user-provisioning/src/Invoke-JML.ps1`; run it from that project folder:

```powershell
./src/Invoke-JML.ps1 -TenantId <id> -ClientId <id> -CertificateThumbprint <thumb> -UpnDomain <verified-domain> -WhatIf
```

- It needs **PowerShell 7** (`pwsh`), not Windows PowerShell 5.1, plus the `Microsoft.Graph.Authentication`, `.Users` and `.Groups` modules.
- It authenticates as an app registration with a certificate. `docs/setup.md` has the full setup and the four Graph application permissions it needs (checked against Microsoft Learn); keep that list in sync with any new Graph call.
- Always dry-run (`-WhatIf`) before a live run. A dry run reads the tenant but writes nothing.

Behaviour that is easy to break:

- **`employeeId` is the identity key.** Users are matched on it; a UPN is derived from the display name only when creating a user. A derived UPN already used by a different `employeeId` is logged as `Failed`, never skipped or adopted.
- **The script is idempotent.** A re-run against an up-to-date tenant must produce only `Skipped` results.
- **`-WhatIf` is inherited by every cmdlet the script calls**, including `Export-Csv` and `New-Item`. The audit log writes use `-WhatIf:$false` so a dry run still produces its log. New code that must run during a dry run needs the same.
- **Audit logs** go to `01-bulk-user-provisioning/logs/` (git-ignored). They contain real names, UPNs and IDs, so a redacted copy must be made by hand before anything goes in `samples/`.
- A failed read (for example a manager lookup) must never be treated as "nothing there", because that leads to overwriting existing data.

## Secrets and tenant details

The repo is public. `.gitignore` excludes `*.pfx`, `*.pem`, `*.key`, `*.cer`, `.env`, `*.tfstate*`, `.terraform/`, `*.tfvars`, `logs/`, `CLAUDE.local.md` and `.claude/settings.local.json`.

Real tenant ID, client ID, domain and certificate thumbprint belong only in `CLAUDE.local.md` (git-ignored) or on the command line. Committed files, docs and examples use placeholders (the sample CSV uses `contoso.example`).
