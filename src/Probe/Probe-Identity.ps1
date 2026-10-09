# Probe-Identity.ps1 - Microsoft Graph reachability and audit-log availability.
#
# Graph matters because without it every owner in the report is a bare GUID, and there is no
# way to detect the single highest-value finding class: assets owned by people who have left.

function Invoke-PPGraphProbe {
    param([Parameter(Mandatory)][string]$Token)

    $checks = @(
        @{ Name = 'Signed-in identity';        Uri = 'https://graph.microsoft.com/v1.0/me?$select=displayName,userPrincipalName'; Need = 'baseline' },
        @{ Name = 'Directory users';           Uri = 'https://graph.microsoft.com/v1.0/users?$select=id,userPrincipalName,accountEnabled&$top=1'; Need = 'User.Read.All - resolve owners, detect leavers' },
        @{ Name = 'Groups';                    Uri = 'https://graph.microsoft.com/v1.0/groups?$select=id,displayName&$top=1'; Need = 'Group.Read.All - env security groups, group sharing' },
        @{ Name = 'Service principals';        Uri = 'https://graph.microsoft.com/v1.0/servicePrincipals?$select=id,appId&$top=1'; Need = 'Application.Read.All - S2S app users, expiring secrets' },
        @{ Name = 'Subscribed SKUs (licences)'; Uri = 'https://graph.microsoft.com/v1.0/subscribedSkus'; Need = 'Organization.Read.All - licence inventory' },
        @{ Name = 'Directory role assignments'; Uri = 'https://graph.microsoft.com/v1.0/directoryRoles?$top=1'; Need = 'RoleManagement.Read.Directory - admin roster' }
    )

    $results = New-Object System.Collections.ArrayList

    foreach ($c in $checks) {
        $res = Invoke-PPRequest -Uri $c.Uri -Token $Token -Label "graph:$($c.Name)" -MaxRetries 1

        $count = $null
        if ($res.Success -and $res.Content) {
            if ($res.Content.value) { $count = @($res.Content.value).Count }
        }

        $verdict = 'Denied'
        if ($res.Success)                { $verdict = 'Available' }
        elseif ($res.StatusCode -eq 403) { $verdict = 'Insufficient consent' }

        [void]$results.Add([PSCustomObject]@{
            Name       = $c.Name
            Verdict    = $verdict
            StatusCode = $res.StatusCode
            Count      = $count
            NeededFor  = $c.Need
            Error      = $res.Error
        })

        $lvl = 'WARN'
        if ($res.Success) { $lvl = 'OK' }
        Write-PPLog -Level $lvl -Message ("  {0,-30} {1}" -f $c.Name, $verdict)
    }

    return $results
}

<#
.SYNOPSIS
    Reports whether unified-audit-log usage telemetry is even reachable from this workstation.
.DESCRIPTION
    We deliberately do NOT call Connect-ExchangeOnline here - it opens a second interactive
    sign-in and can take a minute. The probe reports prerequisites and lets the operator decide.
    This matters because app-launch counts (MAU, last-used, unused-app detection) come only
    from the unified audit log, and a Power Platform Administrator does NOT hold the role
    required to read it.
#>
function Get-PPAuditCapability {
    $m = Get-Module -ListAvailable -Name 'ExchangeOnlineManagement' |
            Sort-Object Version -Descending | Select-Object -First 1

    $notes = New-Object System.Collections.ArrayList
    if (-not $m) {
        [void]$notes.Add('ExchangeOnlineManagement module is not installed. Install-Module ExchangeOnlineManagement -Scope CurrentUser')
    }
    [void]$notes.Add('Requires the "Audit Logs" or "View-Only Audit Logs" role. Power Platform Administrator alone is NOT sufficient.')
    [void]$notes.Add('Requires unified auditing to be enabled tenant-wide.')
    [void]$notes.Add('Retention is 90 days (E3) / 180+ days (E5) - bounds any usage trend we can produce.')

    return [PSCustomObject]@{
        ModuleInstalled = [bool]$m
        ModuleVersion   = $(if ($m) { $m.Version.ToString() } else { $null })
        Verdict         = $(if ($m) { 'Prerequisites partially met - role still to confirm' } else { 'Module missing' })
        Notes           = $notes
    }
}
