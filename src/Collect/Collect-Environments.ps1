# Collect-Environments.ps1 - environment inventory plus backup / DR evidence.
#
# Backups confirmed working in Phase 0 on api.powerplatform.com @ 2022-03-01-preview.
# Disaster-recovery configuration was NOT confirmed: the candidate route returned 404 at the
# only valid api-version tried. We therefore report DR as "unknown", never as "not configured" -
# absence of evidence is not evidence of absence, and telling an admin their production
# environment has no DR when we simply could not read it would be worse than saying nothing.

function Invoke-PPCollectEnvironments {
    param(
        [Parameter(Mandatory)][string]$BapToken,
        [string]$PPApiToken,
        [switch]$IncludeBackups
    )

    $uri = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01'
    $res = Invoke-PPRequest -Uri $uri -Token $BapToken -Label 'env:list'

    if (-not $res.Success) {
        Write-PPLog -Level ERROR -Message "Environment enumeration failed (HTTP $($res.StatusCode)). Nothing downstream can proceed."
        return @()
    }

    $envs = New-Object System.Collections.ArrayList

    foreach ($e in $res.Content.value) {
        $p = $e.properties
        $lem = $p.linkedEnvironmentMetadata

        $orgUrl = $null; $orgVer = $null; $sgId = $null
        if ($lem) {
            $orgUrl = $lem.instanceApiUrl
            if (-not $orgUrl) { $orgUrl = $lem.instanceUrl }
            if ($orgUrl) { $orgUrl = $orgUrl.TrimEnd('/') }
            $orgVer = $lem.version
            $sgId   = $lem.securityGroupId
        }

        $env = [PSCustomObject]@{
            Name            = $e.name
            DisplayName     = $p.displayName
            Sku             = $p.environmentSku
            Type            = $p.environmentType
            State           = $p.provisioningState
            Region          = $p.azureRegion
            Location        = $e.location
            CreatedTime     = $p.createdTime
            CreatedBy       = $(if ($p.createdBy) { $p.createdBy.displayName } else { $null })
            CreatedByEmail  = $(if ($p.createdBy) { $p.createdBy.email } else { $null })
            IsDefault       = [bool]$p.isDefault
            HasDataverse    = [bool]$orgUrl
            OrgUrl          = $orgUrl
            OrgVersion      = $orgVer
            SecurityGroupId = $sgId
            ProtectionLevel = $p.governanceConfiguration.protectionLevel
            # Managed Environments could not be confirmed in Phase 0; treat as unknown.
            IsManagedEnv    = $null
            Backups         = @()
            BackupCount     = $null
            LatestBackup    = $null
            BackupStatus    = 'Not collected'
            DrStatus        = 'Unknown - no confirmed API'
        }

        [void]$envs.Add($env)
    }

    Write-PPLog -Level OK -Message ("  {0} environment(s); {1} with Dataverse" -f `
        $envs.Count, @($envs | Where-Object { $_.HasDataverse }).Count)

    if ($IncludeBackups -and $PPApiToken) {
        foreach ($env in $envs) {
            $bu = Invoke-PPRequest -Label "env:backups:$($env.Name)" -Token $PPApiToken -MaxRetries 1 `
                -Uri "https://api.powerplatform.com/environmentmanagement/environments/$($env.Name)/backups?api-version=2022-03-01-preview"

            if ($bu.Success) {
                $rows = @()
                if ($bu.Content.value) { $rows = @($bu.Content.value) }
                $env.Backups     = $rows
                $env.BackupCount = $rows.Count
                $env.BackupStatus = 'Collected'

                if ($rows.Count -gt 0) {
                    # Backup payload shape varies; try the usual timestamp fields in order.
                    $stamps = $rows | ForEach-Object {
                        $t = $_.pointInTime
                        if (-not $t) { $t = $_.createdDateTime }
                        if (-not $t) { $t = $_.expiryTime }
                        $t
                    } | Where-Object { $_ }
                    if ($stamps) { $env.LatestBackup = ($stamps | Sort-Object -Descending | Select-Object -First 1) }
                }
            } else {
                $env.BackupStatus = "Unavailable (HTTP $($bu.StatusCode))"
            }
        }
        $ok = @($envs | Where-Object { $_.BackupStatus -eq 'Collected' }).Count
        Write-PPLog -Level OK -Message ("  Backup data collected for {0}/{1} environment(s)" -f $ok, $envs.Count)
    }

    return $envs
}
