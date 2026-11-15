# Setup: app registration, certificate and permissions

`src/Invoke-JML.ps1` authenticates to Microsoft Graph as an **app registration** using a **certificate**. It needs no client secret and no interactive sign-in. Do this once per lab tenant.

## 1. Prerequisites

- PowerShell 7.2 or later (`pwsh --version`)
- The Microsoft Graph SDK modules the script uses:

  ```powershell
  Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Groups -Scope CurrentUser
  ```
- A **verified domain** in the tenant to use as `-UpnDomain` (for a lab, usually `<name>.onmicrosoft.com`). The CSV uses the placeholder `contoso.example`, which the script replaces at runtime. That domain cannot be used for real accounts.
- An account that can create app registrations and grant admin consent (Application Administrator plus Privileged Role Administrator, or Global Administrator).

## 2. Create the certificate

On Windows, create a self-signed certificate in your user store. The private key is non-exportable, so it stays on this machine:

```powershell
$cert = New-SelfSignedCertificate `
    -Subject 'CN=JML-Automation' `
    -CertStoreLocation Cert:\CurrentUser\My `
    -KeyExportPolicy NonExportable `
    -KeySpec Signature -KeyLength 2048 -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddMonths(12)

$cert.Thumbprint                                   # keep this: it is -CertificateThumbprint
Export-Certificate -Cert $cert -FilePath .\jml-automation.cer   # public key only
```

Only the `.cer` (public key) is uploaded to Entra. Do not commit certificates or keys: `.gitignore` already excludes `*.cer`, `*.pfx`, `*.pem` and `*.key`.

A self-signed certificate is fine for a lab. In production, use a certificate from your PKI, or a managed identity where the workload runs in Azure.

## 3. Register the application

In the Entra admin center (**Identity > Applications > App registrations**):

1. **New registration**. Name it `JML-Automation`, supported account type **Single tenant**, no redirect URI.
2. On the **Overview** page, copy the **Application (client) ID** (`-ClientId`) and the **Directory (tenant) ID** (`-TenantId`).
3. Go to **Certificates & secrets > Certificates > Upload certificate** and upload `jml-automation.cer`. Don't create a client secret.

## 4. Grant Graph application permissions

Go to **API permissions > Add a permission > Microsoft Graph > Application permissions** and add these four, then select **Grant admin consent for \<tenant\>**. Each row should show a green check under *Status*.

| Permission | What the script uses it for |
|---|---|
| `User.ReadWrite.All` | Find users by `employeeId` and by UPN, create users, update department and job title, read and assign managers |
| `Group.Create` | Create the `DEPT-*` security groups |
| `Group.Read.All` | List the `DEPT-*` groups |
| `GroupMember.ReadWrite.All` | Read group membership, add users to their department group and remove movers from their old one |

These are **application** permissions: they apply tenant-wide with no signed-in user, so treat the certificate like a privileged credential.

### Why each permission is needed

Every Graph call the script makes, and the least-privileged application permission Microsoft's documentation lists for it (Joiner calls checked 2026-11-13, Mover calls 2026-11-14):

| Script step | Graph call | Least-privileged application permission per the docs |
|---|---|---|
| Find a user by `employeeId` or UPN | `GET /users?$filter=...` | `User.Read.All` |
| Create a user | `POST /users` | `User.Create` |
| Update department and job title (Mover) | `PATCH /users/{id}` | `User.ReadUpdate.All` |
| Read a user's current manager | `GET /users/{id}/manager` | see "Verified on a live tenant" below |
| Set or change a manager | `PUT /users/{id}/manager/$ref` | **`User.ReadWrite.All`** |
| List the department groups | `GET /groups?$filter=startswith(displayName,'DEPT-')` | `Group.Read.All` (the docs also list broader options) |
| Create a department group | `POST /groups` | `Group.Create` |
| List a group's members | `GET /groups/{id}/members` | `GroupMember.ReadBasic.All` (`GroupMember.ReadWrite.All` is also accepted) |
| Add a user to a group | `POST /groups/{id}/members/$ref` | **`GroupMember.ReadWrite.All`** |
| Remove a mover from their old group | `DELETE /groups/{id}/members/{userId}/$ref` | **`GroupMember.ReadWrite.All`** |

**`User.ReadWrite.All` is the only user permission you need.** Assigning a manager requires it, and it already covers the narrower `User.Read.All` (lookups), `User.Create` (creating users) and `User.ReadUpdate.All` (updating department and job title). Granting those as well would add nothing.

**`Group.Create` plus `Group.Read.All` instead of `Group.ReadWrite.All`.** The script needs to create groups and look them up, but never edits or deletes one. `Group.ReadWrite.All` would also let the app modify or delete any group in the tenant.

**`GroupMember.ReadWrite.All`** is the only application permission listed for adding and removing group members, and it is also accepted for listing them. It can't change a group's properties. The Mover phase needed no new permissions.

**Not granted on purpose:** `Directory.ReadWrite.All` (a catch-all that covers everything above and much more), `Group.ReadWrite.All`, `User.Create`, `User.Read.All` and `User.ReadUpdate.All` (redundant with `User.ReadWrite.All`), and anything role-related. The script doesn't touch roles, licenses, passwords or role-assignable groups.

### Verified on a live tenant

The Joiner permission list was checked against Microsoft Learn, then exercised end to end in a Microsoft Entra lab tenant on 2026-11-14: a dry run, a 3-user test run, a full 40-user run and a re-run. The Mover phase was verified the same way, also on 2026-11-14, using `samples/hr_export_movers.csv`: a dry run showed the 7 expected changes, the live run applied all 7 (2 `UpdateUser`, 3 `SetManager`, 1 `AddToGroup`, 1 `RemoveFromGroup`) with the same four permissions, and a re-run skipped everything. The four permissions above were enough and nothing failed. The re-run skipped every action, so the script is idempotent in practice.

Three behaviours the documentation left unclear turned out like this:

- **Manager reads work with application permissions.** The *List manager* page says application permissions aren't supported, but the same page documents `GET /users/{id}/manager` for apps and only rules out the `/me` endpoint. In the lab tenant the call worked both ways: it returned the manager for users who had one and a `404` for users who didn't. The script treats only a `404` as "no manager". Any other error is logged as `Failed` and the manager is left alone, so an existing manager is never overwritten because of a permissions problem.
- **Groups created with `Group.Create` accept new members.** Microsoft notes that a group created with `Group.Create` and no owners is created anonymously and "isn't modifiable". The script never edits group properties, and adding members to the groups it created worked with `GroupMember.ReadWrite.All`. If another tenant returns a `403` here, replace `Group.Create` and `Group.Read.All` with `Group.ReadWrite.All` and note the change.
- **The `employeeId` filter works as a normal `$filter`.** Existing users were matched on it without the `ConsistencyLevel: eventual` header. If another tenant rejects it with `Request_UnsupportedQuery`, add the header.

Sources (Microsoft Learn, Graph v1.0): [Create user](https://learn.microsoft.com/en-us/graph/api/user-post-users), [List users](https://learn.microsoft.com/en-us/graph/api/user-list), [Update user](https://learn.microsoft.com/en-us/graph/api/user-update), [Assign manager](https://learn.microsoft.com/en-us/graph/api/user-post-manager), [List manager](https://learn.microsoft.com/en-us/graph/api/user-list-manager), [Create group](https://learn.microsoft.com/en-us/graph/api/group-post-groups), [List groups](https://learn.microsoft.com/en-us/graph/api/group-list), [Add members](https://learn.microsoft.com/en-us/graph/api/group-post-members), [Remove member](https://learn.microsoft.com/en-us/graph/api/group-delete-members), [List group members](https://learn.microsoft.com/en-us/graph/api/group-list-members).

When Leaver is added (for example disabling accounts or revoking sessions), any extra permissions will be listed here.

## 5. Run it

Always dry-run first. `-WhatIf` does read-only lookups and writes nothing to the tenant. It still writes the audit log, which shows what it would do:

```powershell
cd 01-bulk-user-provisioning
./src/Invoke-JML.ps1 `
    -TenantId              '<directory-tenant-id>' `
    -ClientId              '<application-client-id>' `
    -CertificateThumbprint '<thumbprint>' `
    -UpnDomain             '<verified-domain>' `
    -WhatIf
```

Review the audit file before writing anything.

### Test on a small batch first

A dry run proves sign-in and the read permissions, but not the write permissions. Before the first full run, run the script for real on 3 employees. The first 3 rows (the COO and two of his direct reports) exercise every write: creating users and a group, setting managers and adding group members.

```powershell
Get-Content .\samples\hr_export.csv | Select-Object -First 4 | Set-Content "$env:TEMP\hr_test3.csv"
./src/Invoke-JML.ps1 <same parameters as above> -CsvPath "$env:TEMP\hr_test3.csv"
```

`-First 4` is the header row plus 3 employees. If anything fails, only 3 accounts need cleaning up instead of 40.

### Full run

When the small batch shows no `Failed` rows, run the full file without `-WhatIf`. The 3 test users are matched on `employeeId` and skipped. Re-running is safe: users, managers and memberships that already exist are skipped.

### Try the Mover phase

[`samples/hr_export_movers.csv`](../samples/hr_export_movers.csv) is the same HR export with three changes, run against a tenant the full file has already been loaded into:

| Employee | Change | Expected actions |
|---|---|---|
| E1015 Laura Jensen | Finance Financial Analyst → Sales, Sales Operations Analyst, new manager Daniel Okafor | `UpdateUser`, `SetManager`, `AddToGroup` DEPT-Sales, `RemoveFromGroup` DEPT-Finance |
| E1036 Omar Farouk | Promoted to Service Desk Lead, now reports to Hannah Brooks | `UpdateUser`, `SetManager` |
| E1009 James Whelan | Now reports to Elena Vasquez | `SetManager` |

```powershell
./src/Invoke-JML.ps1 <same parameters as above> -CsvPath ./samples/hr_export_movers.csv -WhatIf
```

The dry run should show exactly those 7 actions as `WhatIf` and everything else as `Skipped`. Run it again without `-WhatIf` to apply them, then once more to confirm only `Skipped` remains. Running the original `hr_export.csv` afterwards moves the three back.

### Audit logs

Each run writes `logs/jml-audit-<timestamp>.csv` inside the project folder (override with `-AuditLogPath`). The `logs/` folder is git-ignored because the logs contain names, UPNs and employee IDs. Commit a redacted copy to `samples/` if you want to show example output.

Columns: `Timestamp, Mode, Actor, Action, EmployeeId, Target, Result, Detail`. `Result` is one of `Success`, `WhatIf`, `Skipped`, `Declined` or `Failed`. The script exits with code 1 if any action failed.

## 6. What the script does and doesn't do

- **Matches users on `employeeId`**, not on the UPN. A UPN is only derived (`first.last@<UpnDomain>`) when a user has to be created. An existing user whose UPN differs from the derived one is still matched and is never renamed.
- **UPN collisions fail loudly.** If the derived UPN is already used by an account with a different `employeeId` (or none), the row is logged as `Failed` and nothing is created or changed.
- **Creates** each missing Active user with department, job title, employee ID, hire date and `usageLocation` (`US` by default, set with `-UsageLocation`). A usage location is required for group-based licensing. New users are added to `DEPT-<Department>`.
- **The HR export is the source of truth for existing users (Mover).** If a user's department or job title differs from the export, it is updated (`UpdateUser`). If their manager differs, it is changed (`SetManager`, with the old and new manager in the log). An empty job title or manager in the export leaves the tenant value alone, so the script never clears data.
- **Department moves change access.** The user is added to the new `DEPT-<Department>` group and removed from every other department group the script manages (`RemoveFromGroup`). A group counts as managed if its description ends with `(managed by Invoke-JML)` (the script sets this on groups it creates) or it is the group of a department in the export. Other groups, even ones whose name starts with `DEPT-`, are never touched.
- **Never renames** a user. A changed display name in the export doesn't change the UPN or display name in the tenant.
- **Skips** rows whose status isn't `Active` and logs them. Leaver handling isn't built yet.
- **Passwords:** new accounts get a random password that is never displayed or logged. To sign in as a lab user, issue a Temporary Access Pass or reset the password in the admin center.
- **No licenses** are assigned by the script.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Connect-MgGraph` fails with a certificate error | The thumbprint isn't in `Cert:\CurrentUser\My` for the account running the script, or the `.cer` wasn't uploaded to the app registration |
| `Insufficient privileges to complete the operation` | Admin consent wasn't granted, or a permission was added as delegated instead of application |
| `CreateUser` is `Failed` with "UPN already in use by a different employeeId" | An account with that UPN exists but belongs to someone else (or has no `employeeId`). Fix the data in the tenant or the HR export, then re-run |
| `domain ... is not verified` or `unknown domain` on create | `-UpnDomain` isn't a verified domain in this tenant |
| `Request_UnsupportedQuery` on the `employeeId` lookup | The filter needs the `ConsistencyLevel: eventual` header; see "Verified on a live tenant" in step 4 |
| `SetManager` is `Failed` with "Could not read current manager" | The manager read was denied or errored; see "Verified on a live tenant" in step 4. The current manager is left unchanged |
| `UpdateUser` or `RemoveFromGroup` is `Failed` with `Insufficient privileges` | `User.ReadWrite.All` or `GroupMember.ReadWrite.All` is missing admin consent |
| The run stops with "Active rows with no department" | Every Active row in the HR export needs a department, because it decides group membership |
