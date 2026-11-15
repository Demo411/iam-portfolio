# 01 - Bulk User Provisioning

A PowerShell 7 and Microsoft Graph script that runs joiner-mover-leaver (JML) from an HR CSV export for the 40 employees of the fictional Contoso Logistics, with dry-run support and audit logging.

**Status:** In progress. Joiner is implemented. Mover and Leaver are not.

## Contents

| Path | What it is |
|------|------------|
| [`src/Invoke-JML.ps1`](./src/Invoke-JML.ps1) | The provisioning script (certificate auth, `-WhatIf`, CSV audit log) |
| [`samples/hr_export.csv`](./samples/hr_export.csv) | Fake HR export: 40 Contoso Logistics employees across Finance, Sales, IT and Operations |
| [`docs/setup.md`](./docs/setup.md) | Create the app registration and certificate, grant Graph permissions, and run the script |

## Quick start

See [`docs/setup.md`](./docs/setup.md) for the one-time app registration and certificate setup. Then do a dry run:

```powershell
./src/Invoke-JML.ps1 -TenantId <tenant-id> -ClientId <client-id> `
    -CertificateThumbprint <thumbprint> -UpnDomain <verified-domain> -WhatIf
```
