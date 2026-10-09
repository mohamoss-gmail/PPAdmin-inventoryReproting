# Probe-PlatformApi.ps1 - the "known good" admin surface: BAP, PowerApps, Flow.
#
# We call these REST endpoints directly rather than going through
# Microsoft.PowerApps.Administration.PowerShell. Reasons:
#   - The module runs its own interactive sign-in (Add-PowerAppsAccount) which would mean a
#     second auth prompt on top of our device code flow.
#   - Direct REST is what Phase 1 needs anyway for parallelism and retry control.
# The module is still detected and reported as an available fallback.

function Get-PPEnvironmentList {
    param([Parameter(Mandatory)][string]$BapToken)

    $uri = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01'
    $res = Invoke-PPRequest -Uri $uri -Token $BapToken -Label 'bap:environments'

    if (-not $res.Success) {
        Write-PPLog -Level ERROR -Message ("Could not list environments (HTTP {0}). Everything downstream depends on this." -f $res.StatusCode)
        return @()
    }

    $envs = New-Object System.Collections.ArrayList
    foreach ($e in $res.Content.value) {
        $props = $e.properties

        # Dataverse org URL lives under linkedEnvironmentMetadata and is absent for
        # environments without a Dataverse database.
        $orgUrl = $null
        $orgVer = $null
        if ($props.linkedEnvironmentMetadata) {
            $orgUrl = $props.linkedEnvironmentMetadata.instanceApiUrl
            if (-not $orgUrl) { $orgUrl = $props.linkedEnvironmentMetadata.instanceUrl }
            $orgVer = $props.linkedEnvironmentMetadata.version
        }
        if ($orgUrl) { $orgUrl = $orgUrl.TrimEnd('/') }

        [void]$envs.Add([PSCustomObject]@{
            Name            = $e.name
            DisplayName     = $props.displayName
            Sku             = $props.environmentSku
            Type            = $props.environmentType
            State           = $props.provisioningState
            Region          = $props.azureRegion
            Location        = $e.location
            CreatedTime     = $props.createdTime
            CreatedBy       = $(if ($props.createdBy) { $props.createdBy.displayName } else { $null })
            SecurityGroupId = $(if ($props.linkedEnvironmentMetadata) { $props.linkedEnvironmentMetadata.securityGroupId } else { $null })
            IsDefault       = $props.isDefault
            HasDataverse    = [bool]$orgUrl
            OrgUrl          = $orgUrl
            OrgVersion      = $orgVer
            GovernanceState = $props.governanceConfiguration.protectionLevel
        })
    }

    Write-PPLog -Level OK -Message ("Found {0} environment(s); {1} with Dataverse." -f `
        $envs.Count, (@($envs | Where-Object { $_.HasDataverse })).Count)

    return $envs
}

function Invoke-PPPlatformApiProbe {
    param(
        [Parameter(Mandatory)]$Environments,
        [string]$BapToken,
        [string]$PowerAppsToken,
        [string]$FlowToken,
        [string]$TenantId
    )

    $results = New-Object System.Collections.ArrayList

    function Add-Result {
        param($Area, $Check, $Result, $Detail)
        [void]$results.Add([PSCustomObject]@{
            Area       = $Area
            Check      = $Check
            Success    = $Result.Success
            StatusCode = $Result.StatusCode
            Count      = $Detail
            Error      = $Result.Error
            Uri        = $Result.Uri
        })
    }

    # --- Tenant-wide, no environment needed ---------------------------------------------
    #
    # NOTE: tenant settings are deliberately absent here. The documented operation
    # (/providers/Microsoft.BusinessAppPlatform/listtenantsettings) is POST-only despite being
    # semantically a read. Our client refuses POST, so we cannot call it without widening the
    # read-only guarantee. See README "Known gap: POST-only read operations".

    if ($BapToken -and $TenantId) {
        # Confirmed by probe: the tenant GUID is a required path segment; omitting it 404s.
        $ti = Invoke-PPRequest -Label 'bap:tenantIsolation' -Token $BapToken `
            -Uri "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/tenants/$TenantId/tenantIsolationPolicy?api-version=2020-10-01"
        Add-Result 'Tenant' 'Tenant isolation policy' $ti $null
    }

    if ($BapToken) {
        # DLP v1 lives on api.bap.microsoft.com, not api.powerapps.com (probe returned 404 there).
        $dlp = Invoke-PPRequest -Label 'bap:dlpPolicies' -Token $BapToken `
            -Uri 'https://api.bap.microsoft.com/providers/PowerPlatform.Governance/v1/policies?api-version=2016-11-01'
        $dlpCount = $null
        if ($dlp.Success -and $dlp.Content.value) { $dlpCount = @($dlp.Content.value).Count }
        Add-Result 'Governance' 'DLP policies (v1)' $dlp $dlpCount
    }

    # --- Per-environment, sampled ------------------------------------------------------
    # A probe only needs to prove reachability, so we sample rather than enumerate the tenant.

    $sample = @($Environments | Select-Object -First 3)

    foreach ($env in $sample) {
        $label = $env.DisplayName
        if (-not $label) { $label = $env.Name }

        if ($PowerAppsToken) {
            $apps = Invoke-PPRequest -Label "papps:apps:$($env.Name)" -Token $PowerAppsToken `
                -Uri "https://api.powerapps.com/providers/Microsoft.PowerApps/scopes/admin/environments/$($env.Name)/apps?api-version=2016-11-01"
            $c = $null
            if ($apps.Success -and $apps.Content.value) { $c = @($apps.Content.value).Count }
            Add-Result 'Apps' "Canvas apps in '$label'" $apps $c
        }

        if ($PowerAppsToken) {
            # Connector catalogue is per-environment; '~all' is rejected with
            # ServiceToServiceEnvironmentNotFound, so it must be a real environment name.
            $conn = Invoke-PPRequest -Label "papps:connectors:$($env.Name)" -Token $PowerAppsToken `
                -Uri "https://api.powerapps.com/providers/Microsoft.PowerApps/apis?api-version=2016-11-01&`$filter=environment%20eq%20%27$($env.Name)%27"
            $c = $null
            if ($conn.Success -and $conn.Content.value) { $c = @($conn.Content.value).Count }
            Add-Result 'Connectors' "Connectors in '$label'" $conn $c
        }

        if ($FlowToken) {
            # V1 was retired in 2023: "The List Flows as Admin API is no longer supported.
            # Please use the List Flows as Admin (V2) API." The 403 we first saw was a
            # deprecation notice, not a permissions problem.
            $flows = Invoke-PPRequest -Label "flow:flowsV2:$($env.Name)" -Token $FlowToken `
                -Uri "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments/$($env.Name)/v2/flows?api-version=2016-11-01"
            $c = $null
            if ($flows.Success -and $flows.Content.value) { $c = @($flows.Content.value).Count }
            Add-Result 'Flows' "Cloud flows in '$label' (V2)" $flows $c
        }

        if ($BapToken) {
            # Candidate: the addOns route 404s. Capacity may only be exposed via
            # api.powerplatform.com /licensing. Left here to confirm or eliminate.
            $cap = Invoke-PPRequest -Label "bap:capacity:$($env.Name)" -Token $BapToken `
                -Uri "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$($env.Name)/capacity?api-version=2020-10-01"
            Add-Result 'Capacity' "Capacity for '$label'" $cap $null
        }
    }

    return $results
}

function Get-PPAdminModuleStatus {
    $m = Get-Module -ListAvailable -Name 'Microsoft.PowerApps.Administration.PowerShell' |
            Sort-Object Version -Descending | Select-Object -First 1
    if ($m) {
        return [PSCustomObject]@{ Installed = $true;  Version = $m.Version.ToString() }
    }
    return [PSCustomObject]@{ Installed = $false; Version = $null }
}
