#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Groups

<#
.SYNOPSIS
    Joiner-mover-leaver automation driven by an HR CSV export (Joiner phase only).

.DESCRIPTION
    For every row with status 'Active' in the HR export this script:
      1. Ensures a department security group exists ("<GroupPrefix><Department>").
      2. Finds the user by employeeId. If there is no match, it creates the user with a UPN
         derived from the display name. employeeId is the identity key: a UPN is only derived
         when creating.
      3. Sets the manager if the user has none.
      4. Adds the user to the department group if not already a member.

    If the derived UPN is already taken by a user with a different employeeId, the row is
    logged as Failed (it is never silently skipped or adopted).

    Rows with any other status are logged as skipped (Leaver handling is not implemented yet).
    Existing users' attributes are never overwritten; reconciling changes is the Mover phase.

    The script is idempotent: re-running it only does the work that is still missing.
    It authenticates as an app registration with a certificate (no secrets, no interactive login).

    Every action is written to a CSV audit file in the project's logs/ folder (git-ignored)
    with a Result of Success, WhatIf, Skipped, Declined or Failed. Use -WhatIf for a dry run:
    reads still happen, nothing is written to the tenant, and the audit log is still written.

.PARAMETER TenantId
    Directory (tenant) ID of the Entra tenant.

.PARAMETER ClientId
    Application (client) ID of the app registration.

.PARAMETER CertificateThumbprint
    Thumbprint of the certificate in the current user's certificate store whose public key
    is uploaded to the app registration.

.PARAMETER UpnDomain
    A verified domain in the tenant. Replaces the 'contoso.example' placeholder used in the CSV.

.PARAMETER CsvPath
    HR export to process. Defaults to ../samples/hr_export.csv.

.PARAMETER AuditLogPath
    Where to write the audit CSV. Defaults to ../logs/jml-audit-<timestamp>.csv.

.PARAMETER GroupPrefix
    Prefix for department group names. Defaults to 'DEPT-' (for example DEPT-Finance).

.PARAMETER UsageLocation
    Two-letter country code set as usageLocation on new users. Defaults to 'US'.
    Group-based licensing fails for users without a usage location.

.EXAMPLE
    ./Invoke-JML.ps1 -TenantId $tid -ClientId $cid -CertificateThumbprint $thumb -UpnDomain contoso.onmicrosoft.com -WhatIf

.EXAMPLE
    ./Invoke-JML.ps1 -TenantId $tid -ClientId $cid -CertificateThumbprint $thumb -UpnDomain contoso.onmicrosoft.com
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $ClientId,
    [Parameter(Mandatory)] [string] $CertificateThumbprint,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$')] [string] $UpnDomain,
    [string] $CsvPath = (Join-Path $PSScriptRoot '../samples/hr_export.csv'),
    [string] $AuditLogPath = (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'logs') ('jml-audit-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))),
    [string] $GroupPrefix = 'DEPT-',
    [ValidatePattern('^[A-Z]{2}$')] [string] $UsageLocation = 'US'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$mode = if ($WhatIfPreference) { 'WhatIf' } else { 'Live' }
$declined = if ($WhatIfPreference) { 'WhatIf' } else { 'Declined' }
$failures = 0

# -WhatIf is inherited by every cmdlet this script calls, including New-Item and Export-Csv.
# The audit log is the dry-run output, so those two must ignore it (-WhatIf:$false).
$logDir = Split-Path -Path $AuditLogPath -Parent
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false | Out-Null
}

# ---------------------------------------------------------------- helpers

function Write-Audit {
    param(
        [string] $Action,
        [string] $Result,
        [string] $EmployeeId = '',
        [string] $Target = '',
        [string] $Detail = ''
    )
    [pscustomobject]@{
        Timestamp  = (Get-Date).ToUniversalTime().ToString('o')
        Mode       = $mode
        Actor      = $ClientId
        Action     = $Action
        EmployeeId = $EmployeeId
        Target     = $Target
        Result     = $Result
        Detail     = $Detail
    } | Export-Csv -Path $AuditLogPath -Append -Encoding utf8 -WhatIf:$false
}

function Get-UpnFromName {
    param([string] $DisplayName)
    $local = ($DisplayName.ToLowerInvariant() -replace '[^a-z0-9 ]', '' -replace '\s+', '.').Trim('.')
    "$local@$UpnDomain"
}

function Convert-ManagerUpn {
    # CSV manager values use the placeholder domain; swap in the real one.
    param([string] $Manager)
    '{0}@{1}' -f ($Manager -split '@')[0].ToLowerInvariant(), $UpnDomain
}

function Get-UserByEmployeeId {
    param([string] $EmployeeId)
    $escaped = $EmployeeId -replace "'", "''"
    $found = @(Get-MgUser -Filter "employeeId eq '$escaped'" -Property Id, UserPrincipalName, EmployeeId)
    if ($found.Count -gt 1) {
        throw "employeeId $EmployeeId matches $($found.Count) users: $($found.UserPrincipalName -join ', ')"
    }
    $found | Select-Object -First 1
}

function Get-UserByUpn {
    param([string] $Upn)
    $escaped = $Upn -replace "'", "''"
    Get-MgUser -Filter "userPrincipalName eq '$escaped'" -Property Id, UserPrincipalName, EmployeeId |
        Select-Object -First 1
}

function Test-HasManager {
    # Only a 404 means "no manager". Any other error is rethrown so it is never mistaken for
    # "no manager" (which would lead to overwriting an existing manager).
    param([string] $UserId)
    try {
        $null = Get-MgUserManager -UserId $UserId -ErrorAction Stop
        return $true
    }
    catch {
        if ($_.Exception.Message -match 'NotFound|ResourceNotFound|does not exist') { return $false }
        throw
    }
}

function New-RandomPassword {
    # Nobody is told this password. Users get a Temporary Access Pass or a reset instead.
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*-_=+'
    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })) + 'Aa1!'
}

$memberCache = @{}
function Get-GroupMemberIds {
    param([string] $GroupId)
    if (-not $memberCache.ContainsKey($GroupId)) {
        $ids = [string[]]@(Get-MgGroupMember -GroupId $GroupId -All | ForEach-Object { $_.Id })
        $memberCache[$GroupId] = [System.Collections.Generic.HashSet[string]]::new($ids)
    }
    # The leading comma stops PowerShell unrolling the set (an empty set would otherwise return $null).
    , $memberCache[$GroupId]
}

# State shared by the passes below, all keyed by employeeId.
$userIds = @{}        # object id of the user in the tenant
$userUpns = @{}       # UPN the user has (or will have) in the tenant
$plannedIds = [System.Collections.Generic.HashSet[string]]::new()   # would be created (dry run only)
$rowByUpnLocal = @{}  # CSV manager values are placeholder UPNs; map their local part back to a row

function Resolve-Manager {
    # Returns the manager's object id, whether they are only planned (dry run), and a display label.
    param([string] $CsvManager)
    $local = ($CsvManager -split '@')[0].ToLowerInvariant()
    $managerRow = $rowByUpnLocal[$local]
    if ($managerRow) {
        $managerEmpId = $managerRow.employeeId
        $id = $userIds[$managerEmpId]
        $planned = $plannedIds.Contains($managerEmpId)
        if (-not $id -and -not $planned) {
            try {
                $u = Get-UserByEmployeeId $managerEmpId
                if ($u) { $id = $u.Id; $userIds[$managerEmpId] = $u.Id; $userUpns[$managerEmpId] = $u.UserPrincipalName }
            }
            catch { $id = $null }
        }
        $label = if ($userUpns[$managerEmpId]) { $userUpns[$managerEmpId] } else { Get-UpnFromName $managerRow.displayName }
    }
    else {
        $label = Convert-ManagerUpn $CsvManager
        $id = $null
        $planned = $false
        try { $u = Get-UserByUpn $label; if ($u) { $id = $u.Id } } catch { $id = $null }
    }
    [pscustomobject]@{ Id = $id; Planned = $planned; Label = $label }
}

# ---------------------------------------------------------------- load and validate the HR export

$required = 'employeeId', 'displayName', 'department', 'jobTitle', 'manager', 'status', 'startDate'
$rows = @(Import-Csv -Path $CsvPath)
if ($rows.Count -eq 0) { throw "No rows found in $CsvPath" }

$missingColumns = @($required | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name })
if ($missingColumns.Count -gt 0) { throw "CSV is missing columns: $($missingColumns -join ', ')" }

$duplicateIds = @($rows | Group-Object employeeId | Where-Object Count -gt 1)
if ($duplicateIds.Count -gt 0) { throw "Duplicate employeeId values: $($duplicateIds.Name -join ', ')" }

$active = @($rows | Where-Object status -eq 'Active')

# Two different people can derive the same UPN (same name). Catch it before touching the tenant.
$duplicateUpns = @($active | Group-Object { Get-UpnFromName $_.displayName } | Where-Object Count -gt 1)
if ($duplicateUpns.Count -gt 0) { throw "Rows derive the same UPN: $($duplicateUpns.Name -join ', ')" }

foreach ($r in $rows) { $rowByUpnLocal[((Get-UpnFromName $r.displayName) -split '@')[0]] = $r }

foreach ($r in ($rows | Where-Object status -ne 'Active')) {
    Write-Audit -Action 'Skip' -Result 'Skipped' -EmployeeId $r.employeeId -Target $r.displayName `
        -Detail "Status '$($r.status)': Leaver handling not implemented"
}

Write-Host "Mode: $mode | Active rows: $($active.Count) of $($rows.Count) | Audit log: $AuditLogPath"

# ---------------------------------------------------------------- run

Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -NoWelcome
Write-Audit -Action 'Connect' -Result 'Success' -Target $TenantId -Detail "Certificate auth as app $ClientId"

try {
    # 1. Department groups
    $groupIds = @{}
    foreach ($dept in ($active.department | Sort-Object -Unique)) {
        $groupName = "$GroupPrefix$dept"
        $group = Get-MgGroup -Filter "displayName eq '$groupName'" | Select-Object -First 1
        if ($group) {
            $groupIds[$dept] = $group.Id
            Write-Audit -Action 'CreateGroup' -Result 'Skipped' -Target $groupName -Detail 'Group already exists'
            continue
        }
        if ($PSCmdlet.ShouldProcess($groupName, 'Create security group')) {
            try {
                $group = New-MgGroup -DisplayName $groupName `
                    -Description "Contoso Logistics $dept department (managed by Invoke-JML)" `
                    -MailEnabled:$false -MailNickname ($groupName -replace '[^A-Za-z0-9]', '') `
                    -SecurityEnabled:$true
                $groupIds[$dept] = $group.Id
                Write-Audit -Action 'CreateGroup' -Result 'Success' -Target $groupName -Detail "Id $($group.Id)"
            }
            catch {
                $failures++
                Write-Audit -Action 'CreateGroup' -Result 'Failed' -Target $groupName -Detail $_.Exception.Message
            }
        }
        else {
            Write-Audit -Action 'CreateGroup' -Result $declined -Target $groupName
        }
    }

    # 2. Users. Match on employeeId; derive a UPN only when creating. All users are handled
    #    before any manager is set, so manager order in the CSV does not matter.
    foreach ($r in $active) {
        $empId = $r.employeeId
        $derivedUpn = Get-UpnFromName $r.displayName
        try {
            $existing = Get-UserByEmployeeId $empId
            $upnOwner = if ($existing) { $null } else { Get-UserByUpn $derivedUpn }
        }
        catch {
            $failures++
            Write-Audit -Action 'LookupUser' -Result 'Failed' -EmployeeId $empId -Target $derivedUpn -Detail $_.Exception.Message
            continue
        }

        if ($existing) {
            $userIds[$empId] = $existing.Id
            $userUpns[$empId] = $existing.UserPrincipalName
            Write-Audit -Action 'CreateUser' -Result 'Skipped' -EmployeeId $empId -Target $existing.UserPrincipalName `
                -Detail 'Matched existing user on employeeId'
            continue
        }

        if ($upnOwner) {
            $failures++
            $otherId = if ($upnOwner.EmployeeId) { $upnOwner.EmployeeId } else { '(none)' }
            Write-Audit -Action 'CreateUser' -Result 'Failed' -EmployeeId $empId -Target $derivedUpn `
                -Detail "UPN already in use by a different employeeId: found $otherId, expected $empId (object id $($upnOwner.Id))"
            continue
        }

        if ($PSCmdlet.ShouldProcess($derivedUpn, "Create user $($r.displayName) ($empId)")) {
            try {
                $hireDate = [datetime]::ParseExact($r.startDate, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
                $body = @{
                    accountEnabled    = $true
                    displayName       = $r.displayName
                    userPrincipalName = $derivedUpn
                    mailNickname      = ($derivedUpn -split '@')[0]
                    employeeId        = $empId
                    department        = $r.department
                    jobTitle          = $r.jobTitle
                    employeeHireDate  = $hireDate.ToString('yyyy-MM-dd') + 'T00:00:00Z'
                    usageLocation     = $UsageLocation
                    passwordProfile   = @{
                        password                      = New-RandomPassword
                        forceChangePasswordNextSignIn = $true
                    }
                }
                $user = New-MgUser -BodyParameter $body
                $userIds[$empId] = $user.Id
                $userUpns[$empId] = $derivedUpn
                Write-Audit -Action 'CreateUser' -Result 'Success' -EmployeeId $empId -Target $derivedUpn `
                    -Detail "Id $($user.Id); $($r.department); $($r.jobTitle); usageLocation $UsageLocation"
            }
            catch {
                $failures++
                Write-Audit -Action 'CreateUser' -Result 'Failed' -EmployeeId $empId -Target $derivedUpn -Detail $_.Exception.Message
            }
        }
        else {
            [void]$plannedIds.Add($empId)
            $userUpns[$empId] = $derivedUpn
            Write-Audit -Action 'CreateUser' -Result $declined -EmployeeId $empId -Target $derivedUpn `
                -Detail "$($r.department); $($r.jobTitle); usageLocation $UsageLocation"
        }
    }

    # 3. Manager and department group membership
    foreach ($r in $active) {
        $empId = $r.employeeId
        $userId = $userIds[$empId]
        $upn = if ($userUpns[$empId]) { $userUpns[$empId] } else { Get-UpnFromName $r.displayName }
        $isPlanned = $plannedIds.Contains($empId)

        if (-not $userId -and -not $isPlanned) {
            Write-Audit -Action 'SetManager' -Result 'Skipped' -EmployeeId $empId -Target $upn -Detail 'No user resolved (lookup or create failed)'
            Write-Audit -Action 'AddToGroup' -Result 'Skipped' -EmployeeId $empId -Target $upn -Detail 'No user resolved (lookup or create failed)'
            continue
        }

        # Manager
        if (-not $r.manager) {
            Write-Audit -Action 'SetManager' -Result 'Skipped' -EmployeeId $empId -Target $upn -Detail 'No manager in HR export'
        }
        else {
            $manager = Resolve-Manager $r.manager
            $hasManager = $false
            $checkFailed = $false
            if ($userId) {
                try { $hasManager = Test-HasManager $userId }
                catch {
                    $checkFailed = $true
                    $failures++
                    Write-Audit -Action 'SetManager' -Result 'Failed' -EmployeeId $empId -Target $upn `
                        -Detail "Could not read current manager: $($_.Exception.Message)"
                }
            }

            if ($checkFailed) {
                # already logged; leave the manager untouched
            }
            elseif ($hasManager) {
                Write-Audit -Action 'SetManager' -Result 'Skipped' -EmployeeId $empId -Target $upn -Detail 'Manager already set'
            }
            elseif (-not $manager.Id -and -not $manager.Planned) {
                $failures++
                Write-Audit -Action 'SetManager' -Result 'Failed' -EmployeeId $empId -Target $upn -Detail "Manager $($manager.Label) not found"
            }
            elseif ($PSCmdlet.ShouldProcess($upn, "Set manager to $($manager.Label)")) {
                try {
                    Set-MgUserManagerByRef -UserId $userId `
                        -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($manager.Id)" }
                    Write-Audit -Action 'SetManager' -Result 'Success' -EmployeeId $empId -Target $upn -Detail "Manager $($manager.Label)"
                }
                catch {
                    $failures++
                    Write-Audit -Action 'SetManager' -Result 'Failed' -EmployeeId $empId -Target $upn -Detail $_.Exception.Message
                }
            }
            else {
                Write-Audit -Action 'SetManager' -Result $declined -EmployeeId $empId -Target $upn -Detail "Manager $($manager.Label)"
            }
        }

        # Department group
        $groupName = "$GroupPrefix$($r.department)"
        $groupId = $groupIds[$r.department]
        if (-not $groupId -and -not $WhatIfPreference) {
            $failures++
            Write-Audit -Action 'AddToGroup' -Result 'Failed' -EmployeeId $empId -Target $upn -Detail "Group $groupName not available"
        }
        elseif ($groupId -and $userId -and (Get-GroupMemberIds $groupId).Contains($userId)) {
            Write-Audit -Action 'AddToGroup' -Result 'Skipped' -EmployeeId $empId -Target $upn -Detail "Already a member of $groupName"
        }
        elseif ($PSCmdlet.ShouldProcess($upn, "Add to group $groupName")) {
            try {
                New-MgGroupMember -GroupId $groupId -DirectoryObjectId $userId
                [void](Get-GroupMemberIds $groupId).Add($userId)
                Write-Audit -Action 'AddToGroup' -Result 'Success' -EmployeeId $empId -Target $upn -Detail $groupName
            }
            catch {
                $failures++
                Write-Audit -Action 'AddToGroup' -Result 'Failed' -EmployeeId $empId -Target $upn -Detail $_.Exception.Message
            }
        }
        else {
            Write-Audit -Action 'AddToGroup' -Result $declined -EmployeeId $empId -Target $upn -Detail $groupName
        }
    }
}
finally {
    Disconnect-MgGraph | Out-Null
}

# ---------------------------------------------------------------- summary

Write-Host "`nAudit summary ($AuditLogPath):"
Import-Csv $AuditLogPath | Group-Object Action, Result | Sort-Object Name |
    ForEach-Object { '{0,-28} {1}' -f $_.Name, $_.Count } | Write-Host

if ($failures -gt 0) {
    # Write-Warning, not Write-Error: with $ErrorActionPreference = 'Stop' the latter throws before exit runs.
    Write-Warning "$failures action(s) failed. See the audit log for details."
    exit 1
}
