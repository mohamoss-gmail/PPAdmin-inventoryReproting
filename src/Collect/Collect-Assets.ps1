# Collect-Assets.ps1 - apps, flows, connections and custom connectors per environment.
#
# The flows route is V2. V1 was retired in June 2023 and now answers 403 with a deprecation
# message, which is easy to misread as a permissions problem - Phase 0 caught exactly that.

function Invoke-PPCollectApps {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)]$Environments,
        [switch]$IncludeSharing
    )

    $apps = New-Object System.Collections.ArrayList

    foreach ($env in $Environments) {
        $res = Invoke-PPRequest -Label "apps:$($env.Name)" -Token $Token `
            -Uri "https://api.powerapps.com/providers/Microsoft.PowerApps/scopes/admin/environments/$($env.Name)/apps?api-version=2016-11-01"

        if (-not $res.Success) {
            Write-PPLog -Level WARN -Message ("  apps in '{0}': HTTP {1}" -f $env.DisplayName, $res.StatusCode)
            continue
        }

        foreach ($a in @($res.Content.value)) {
            $p = $a.properties
            $owner = $p.owner

            $app = [PSCustomObject]@{
                Id              = $a.name
                DisplayName     = $p.displayName
                EnvironmentId   = $env.Name
                EnvironmentName = $env.DisplayName
                Description     = $p.description
                OwnerId         = $(if ($owner) { $owner.id } else { $null })
                OwnerName       = $(if ($owner) { $owner.displayName } else { $null })
                OwnerEmail      = $(if ($owner) { $owner.email } else { $null })
                CreatedTime     = $p.createdTime
                LastModified    = $p.lastModifiedTime
                AppVersion      = $p.appVersion
                SharedUsers     = $p.sharedUsersCount
                SharedGroups    = $p.sharedGroupsCount
                Connections     = @()
                SharedWithTenant = $false
                Permissions     = @()
            }

            # Connector references live under the embedded connection metadata.
            try {
                if ($p.connectionReferences) {
                    $app.Connections = @($p.connectionReferences.PSObject.Properties |
                        ForEach-Object { $_.Value.displayName } | Where-Object { $_ } | Select-Object -Unique)
                }
            } catch { }

            [void]$apps.Add($app)
        }
    }

    Write-PPLog -Level OK -Message ("  {0} app(s) collected" -f $apps.Count)

    if ($IncludeSharing) {
        $n = 0
        foreach ($app in $apps) {
            $perm = Invoke-PPRequest -Label "apps:perms:$($app.Id)" -Token $Token -MaxRetries 1 -Quiet `
                -Uri "https://api.powerapps.com/providers/Microsoft.PowerApps/scopes/admin/environments/$($app.EnvironmentId)/apps/$($app.Id)/permissions?api-version=2016-11-01"
            if ($perm.Success -and $perm.Content.value) {
                $app.Permissions = @($perm.Content.value | ForEach-Object {
                    [PSCustomObject]@{
                        PrincipalId   = $_.properties.principal.id
                        PrincipalType = $_.properties.principal.type
                        PrincipalName = $_.properties.principal.displayName
                        RoleName      = $_.properties.roleName
                    }
                })
                # 'Tenant' principal type means shared with everyone in the organisation.
                $app.SharedWithTenant = [bool](@($app.Permissions | Where-Object { $_.PrincipalType -eq 'Tenant' }).Count)
                $n++
            }
        }
        Write-PPLog -Level OK -Message ("  sharing resolved for {0}/{1} app(s)" -f $n, $apps.Count)
    }

    return $apps
}

function Invoke-PPCollectFlows {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)]$Environments
    )

    $flows = New-Object System.Collections.ArrayList

    foreach ($env in $Environments) {
        $res = Invoke-PPRequest -Label "flows:$($env.Name)" -Token $Token `
            -Uri "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments/$($env.Name)/v2/flows?api-version=2016-11-01"

        if (-not $res.Success) {
            Write-PPLog -Level WARN -Message ("  flows in '{0}': HTTP {1}" -f $env.DisplayName, $res.StatusCode)
            continue
        }

        foreach ($f in @($res.Content.value)) {
            $p = $f.properties
            [void]$flows.Add([PSCustomObject]@{
                Id              = $f.name
                DisplayName     = $p.displayName
                EnvironmentId   = $env.Name
                EnvironmentName = $env.DisplayName
                State           = $p.state          # Started / Stopped / Suspended
                CreatedTime     = $p.createdTime
                LastModified    = $p.lastModifiedTime
                OwnerId         = $(if ($p.creator) { $p.creator.objectId } else { $null })
                OwnerTenant     = $(if ($p.creator) { $p.creator.tenantId } else { $null })
                TriggerType     = $(if ($p.definitionSummary -and $p.definitionSummary.triggers) { @($p.definitionSummary.triggers)[0].type } else { $null })
                ActionCount     = $(if ($p.definitionSummary -and $p.definitionSummary.actions) { @($p.definitionSummary.actions).Count } else { $null })
                Connections     = @($p.referencedResources | ForEach-Object { $_.resource.name } | Where-Object { $_ } | Select-Object -Unique)
            })
        }
    }

    Write-PPLog -Level OK -Message ("  {0} flow(s) collected" -f $flows.Count)
    return $flows
}

function Invoke-PPCollectConnections {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)]$Environments
    )

    $connections = New-Object System.Collections.ArrayList
    $connectors  = New-Object System.Collections.ArrayList

    foreach ($env in $Environments) {
        $res = Invoke-PPRequest -Label "conns:$($env.Name)" -Token $Token -MaxRetries 1 `
            -Uri "https://api.powerapps.com/providers/Microsoft.PowerApps/scopes/admin/environments/$($env.Name)/connections?api-version=2016-11-01"

        if ($res.Success) {
            foreach ($c in @($res.Content.value)) {
                $p = $c.properties
                [void]$connections.Add([PSCustomObject]@{
                    Id              = $c.name
                    DisplayName     = $p.displayName
                    EnvironmentId   = $env.Name
                    EnvironmentName = $env.DisplayName
                    ConnectorName   = $(if ($p.apiId) { ($p.apiId -split '/')[-1] } else { $null })
                    CreatedTime     = $p.createdTime
                    OwnerId         = $(if ($p.createdBy) { $p.createdBy.id } else { $null })
                    OwnerName       = $(if ($p.createdBy) { $p.createdBy.displayName } else { $null })
                    Status          = $(if ($p.statuses) { @($p.statuses)[0].status } else { $null })
                    AuthenticatedAs = $(if ($p.connectionParameters) { $p.connectionParameters.displayName } else { $null })
                })
            }
        }

        # Custom connectors are per-environment; '~all' is rejected by the service.
        $api = Invoke-PPRequest -Label "connectors:$($env.Name)" -Token $Token -MaxRetries 1 `
            -Uri "https://api.powerapps.com/providers/Microsoft.PowerApps/apis?api-version=2016-11-01&`$filter=environment%20eq%20%27$($env.Name)%27"

        if ($api.Success) {
            foreach ($a in @($api.Content.value)) {
                $p = $a.properties
                # Only custom connectors are interesting; the first-party catalogue is noise.
                if ($p.isCustomApi -ne $true) { continue }
                [void]$connectors.Add([PSCustomObject]@{
                    Id              = $a.name
                    DisplayName     = $p.displayName
                    EnvironmentId   = $env.Name
                    EnvironmentName = $env.DisplayName
                    CreatedTime     = $p.createdTime
                    OwnerName       = $(if ($p.createdBy) { $p.createdBy.displayName } else { $null })
                    BackendHost     = $p.backendService.serviceUrl
                    Tier            = $p.tier
                })
            }
        }
    }

    Write-PPLog -Level OK -Message ("  {0} connection(s), {1} custom connector(s)" -f $connections.Count, $connectors.Count)
    return [PSCustomObject]@{ Connections = $connections; CustomConnectors = $connectors }
}
