# 01 - Bulk User Provisioning

A PowerShell 7 and Microsoft Graph script that runs joiner-mover-leaver (JML) from an HR CSV export for the 40 employees of the fictional Contoso Logistics, with dry-run support and audit logging.

**Status:** In progress. Joiner and Mover (department, job title and manager changes, with department group moves) are implemented and verified on a lab tenant. Leaver (disable the account, revoke sessions, remove group access) is implemented and verified on the lab tenant too.

## Contents

| Path | What it is |
|------|------------|
| [`src/Invoke-JML.ps1`](./src/Invoke-JML.ps1) | The provisioning script (certificate auth, `-WhatIf`, CSV audit log) |
| [`samples/hr_export.csv`](./samples/hr_export.csv) | Fake HR export: 40 Contoso Logistics employees across Finance, Sales, IT and Operations |
| [`samples/hr_export_movers.csv`](./samples/hr_export_movers.csv) | The same export with three movers (a department transfer, a promotion and a manager change) for testing the Mover phase |
| [`samples/hr_export_leavers.csv`](./samples/hr_export_leavers.csv) | The same export with three employees set to `Terminated`, for testing the Leaver phase |
| [`samples/jml-audit-leavers-example.csv`](./samples/jml-audit-leavers-example.csv) | The audit log from the live Leaver run on the lab tenant, with the tenant ID, client ID and domain replaced by placeholders |
| [`docs/setup.md`](./docs/setup.md) | Create the app registration and certificate, grant Graph permissions, and run the script |

## Quick start

See [`docs/setup.md`](./docs/setup.md) for the one-time app registration and certificate setup. Then do a dry run:

```powershell
./src/Invoke-JML.ps1 -TenantId <tenant-id> -ClientId <client-id> `
    -CertificateThumbprint <thumbprint> -UpnDomain <verified-domain> -WhatIf
```
