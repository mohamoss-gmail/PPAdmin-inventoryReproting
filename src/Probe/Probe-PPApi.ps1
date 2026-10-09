# Probe-PPApi.ps1 - the uncertain surface: api.powerplatform.com.
#
# IMPORTANT: the routes below are CANDIDATES, not documented guarantees. Backups, disaster
# recovery, environment groups and agent consumption are the four areas DESIGN.md marks [C]
# ("must be probed"). This file exists precisely so we never bake a guessed endpoint into a
# collector. Whatever comes back here is the truth for this tenant; everything else in the
# report is driven off it.
#
# Interpreting status codes:
#   200 - route exists and we are authorised
#   401 - token audience wrong / not authorised
#   403 - route exists but this admin lacks the role
#   404 - route or resource does not exist at this api-version
#   400 - usually an unsupported api-version for an otherwise real route

# Seed list only. The service tells us the truth: an unsupported version returns
#   {"code":"ApiVersionInvalid","message":"... Supported API versions are: a, b, c"}
# so we harvest that list on the first such response and probe every later route against the
# real set. The first run of this probe wasted three of four attempts on versions that never
# existed, which made genuine 404s indistinguishable from wrong-version 404s.
$script:PPApiVersions = @('2024-10-01', '2022-03-01-preview', '2026-05-01-preview', '2021-10-01-preview')

# Populated at runtime from an ApiVersionInvalid response.
$script:PPApiDiscoveredVersions = $null

function Get-PPApiVersionsToTry {
    if ($script:PPApiDiscoveredVersions -and $script:PPApiDiscoveredVersions.Count -gt 0) {
        return $script:PPApiDiscoveredVersions
    }
    return $script:PPApiVersions
}

function Update-PPApiVersionsFromError {
    param([string]$ErrorBody)
    if (-not $ErrorBody) { return }
    if ($ErrorBody -match 'Supported API versions are:\s*([^"}\r\n]+)') {
        $list = $matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if ($list.Count -gt 0) {
            # Newest first so the richest payload wins, but keep every version we were told about.
            $script:PPApiDiscoveredVersions = @($list | Sort-Object -Descending)
            Write-PPLog -Level OK -Message ("  Discovered supported api-versions: {0}" -f ($script:PPApiDiscoveredVersions -join ', '))
        }
    }
}

function Get-PPApiRouteCandidates {
    param([string]$EnvironmentId)

    $routes = New-Object System.Collections.ArrayList

    function Add-Route {
        param($Area, $Name, $Path, $Confidence, $Why)
        [void]$routes.Add([PSCustomObject]@{
            Area = $Area; Name = $Name; Path = $Path; Confidence = $Confidence; Why = $Why
        })
    }

    # The consumption routes are date-ranged. 30 days back is enough to prove the shape without
    # asking the service for a year of fan-out across every environment.
    $toDate   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    $fromDate = (Get-Date).ToUniversalTime().AddDays(-30).ToString('yyyy-MM-dd')

    # Entitlement IDs are not enumerable from a documented "list entitlements" route. The
    # ExternalCurrencyType enum published with the allocation and currency-report models is the
    # only public list of valid values, so we probe the two that matter and let the tenant
    # confirm the vocabulary. MCSMessages is the Copilot Studio credit meter (renamed from
    # messages to Copilot Credits in Sept 2025, but the API vocabulary did not follow); AI is
    # the AI Builder credit meter.
    $copilotCredits  = 'MCSMessages'
    $aiBuilderCredit = 'AI'

    # --- Tenant scope ---
    Add-Route 'Environments' 'List environments' `
        '/environmentmanagement/environments' 'B' 'Modern replacement for the BAP environment list'
    Add-Route 'Governance' 'Tenant settings (v2)' `
        '/governance/v2/tenantSettings' 'B' 'Successor to listtenantsettings'
    Add-Route 'Governance' 'Data policies (v2)' `
        '/governance/v2/policies' 'B' 'Successor to the v1 DLP policy API'
    Add-Route 'Environments' 'Environment groups' `
        '/environmentmanagement/environmentGroups' 'C' 'Newer feature; API shape unconfirmed'
    Add-Route 'Licensing' 'Billing policies' `
        '/licensing/billingPolicies' 'B' 'Pay-as-you-go billing policy inventory'
    Add-Route 'Licensing' 'Tenant capacity / allocations' `
        '/licensing/allocations' 'C' 'Capacity add-on allocation at tenant scope'
    # --- Usage, credits and consumption ---
    # These replace the earlier '/licensing/consumption' guess, which 404'd because it never
    # existed. Every route below is a documented GET on the Licensing namespace, so a failure
    # here means "this tenant/operator cannot read it", not "we picked the wrong URL".
    Add-Route 'Usage' 'Tenant capacity + consumption' `
        '/licensing/tenantCapacity' 'B' 'Storage/API capacity: entitled vs actual vs rated, per capacity type'
    Add-Route 'Usage' 'Currency reports (purchased/allocated/consumed)' `
        '/licensing/tenantCapacity/currencyReports?includeAllocations=true&includeConsumptions=true' 'B' `
        'The headline number: Copilot credits, AI Builder credits, RPA, per-app passes - purchased vs allocated vs consumed'
    Add-Route 'Usage' 'Allocations by environment (tenant-wide)' `
        '/licensing/allocationsByEnvironment' 'B' 'Which environment holds which slice of each credit pool'
    Add-Route 'Usage' 'Entitlement detail - Copilot credits' `
        "/licensing/entitlements/$copilotCredits" 'C' 'Confirms the entitlement ID vocabulary; carries capacity + pay-as-you-go split'
    Add-Route 'Usage' 'Copilot credits consumed by resource (all envs)' `
        "/licensing/entitlements/$copilotCredits/resources?fromDate=$fromDate&toDate=$toDate" 'C' `
        'Per-agent credit burn across every environment - billed and non-billed. The "which agent" answer'
    Add-Route 'Usage' 'Copilot credits consumed by user' `
        "/licensing/entitlements/$copilotCredits/users?fromDate=$fromDate&toDate=$toDate" 'C' `
        'Per-user credit burn. The "which user" answer'
    Add-Route 'Usage' 'Copilot credit thresholds / alerts' `
        "/licensing/entitlements/$copilotCredits/resourceThresholds" 'C' 'Whether anyone configured a spend alarm - absence is itself a finding'
    Add-Route 'Usage' 'Licence trend - Copilot credits' `
        "/licensing/entitlements/$copilotCredits/licenses?fromDate=$fromDate&toDate=$toDate" 'C' 'Entitlement over time rather than a single snapshot'
    Add-Route 'Usage' 'AI Builder credits consumed by resource' `
        "/licensing/entitlements/$aiBuilderCredit/resources?fromDate=$fromDate&toDate=$toDate" 'C' `
        'Same shape as Copilot credits, for the AI Builder meter'
    Add-Route 'Usage' 'AI Builder credits consumed by user' `
        "/licensing/entitlements/$aiBuilderCredit/users?fromDate=$fromDate&toDate=$toDate" 'C' `
        'Per-user AI Builder credit burn'
    Add-Route 'Usage' 'AI Builder credit thresholds / alerts' `
        "/licensing/entitlements/$aiBuilderCredit/resourceThresholds" 'C' 'Spend alarm on the AI Builder meter'
    # Alternative spellings for the capacity dataset. `pac licensing get-tenant-capacity-details`
    # is the documented operation, but the REST spelling is not published, so both are probed and
    # the collector uses whichever answers. Without this the capacity denominator is simply lost.
    Add-Route 'Usage' 'Tenant capacity details (alt spelling)' `
        '/licensing/tenantCapacityDetails' 'C' 'Candidate REST spelling behind pac licensing get-tenant-capacity-details'
    Add-Route 'Usage' 'Tenant capacity details (nested spelling)' `
        '/licensing/tenantCapacity/details' 'C' 'Second candidate spelling for the same dataset'

    # --- Environment scope ---
    if ($EnvironmentId) {
        Add-Route 'Backups' 'List backups / restore points' `
            "/environmentmanagement/environments/$EnvironmentId/backups" 'B' 'Core DR evidence'
        Add-Route 'Backups' 'Restore operation history' `
            "/environmentmanagement/environments/$EnvironmentId/restoreOperations" 'C' 'Who restored what, when'
        Add-Route 'Backups' 'Copy operation history' `
            "/environmentmanagement/environments/$EnvironmentId/copyOperations" 'C' 'Prod-to-sandbox copies'
        Add-Route 'DR' 'Disaster recovery config' `
            "/environmentmanagement/environments/$EnvironmentId/disasterRecoveryConfiguration" 'C' 'BCDR posture - least certain route in the design'
        Add-Route 'Governance' 'Managed environment settings' `
            "/governance/environments/$EnvironmentId/settings" 'B' 'Managed env: sharing limits, solution checker'
        Add-Route 'Licensing' 'Environment allocations' `
            "/licensing/environments/$EnvironmentId/allocations" 'B' 'Per-env capacity add-on allocation'
        Add-Route 'Usage' 'Environment entitlements' `
            "/licensing/environments/$EnvironmentId/entitlements" 'C' 'Which meters this environment is entitled to - and how entitlement IDs are actually spelled'
        Add-Route 'Usage' 'Environment billing policy (pay-as-you-go link)' `
            "/licensing/environments/$EnvironmentId/billingPolicy" 'B' 'Links the environment to an Azure subscription; 404 = not on pay-as-you-go'
        Add-Route 'Usage' 'Copilot credits by resource, this environment' `
            "/licensing/entitlements/$copilotCredits/environments/$EnvironmentId/resources?fromDate=$fromDate&toDate=$toDate" 'C' `
            'Per-agent credit burn scoped to one environment - cheaper than the tenant-wide fan-out'
    }

    return $routes
}

function Invoke-PPApiProbe {
    param(
        [Parameter(Mandatory)][string]$Token,
        [string]$EnvironmentId,
        [string]$EnvironmentLabel
    )

    $base    = 'https://api.powerplatform.com'
    $routes  = Get-PPApiRouteCandidates -EnvironmentId $EnvironmentId
    $results = New-Object System.Collections.ArrayList

    foreach ($route in $routes) {
        $best        = $null
        $versionsTried = New-Object System.Collections.ArrayList

        foreach ($ver in (Get-PPApiVersionsToTry)) {
            # Consumption routes carry their own query string (date range, include flags), so
            # api-version has to be appended rather than assumed to be the first parameter.
            #
            # Use Contains, NOT -like '*?*'. In PowerShell -like treats ? as a
            # single-character wildcard, so '*?*' is true for every non-empty string: every
            # path without a query string got '&api-version=' and came back 404 RouteNotFound.
            # That silently invalidated the verdict for a dozen routes - billingPolicies among
            # them, which the collector proves answers 200 at the same api-version - and the
            # false negatives were indistinguishable from genuinely absent routes.
            $sep = '?'
            if ($route.Path.Contains('?')) { $sep = '&' }
            $uri = "$base$($route.Path)$sep" + "api-version=$ver"
            $res = Invoke-PPRequest -Uri $uri -Token $Token -Label "ppapi:$($route.Name)" `
                                    -MaxRetries 1 -Quiet
            [void]$versionsTried.Add($ver)

            # An unsupported api-version tells us nothing about the route, so learn the real
            # version list and don't let that response count as evidence.
            if ($res.StatusCode -eq 400 -and $res.Error -match 'ApiVersion(Invalid|Unsupported)') {
                Update-PPApiVersionsFromError -ErrorBody $res.Error
                continue
            }

            # First success wins. Otherwise keep the most informative failure: a 403 tells us
            # the route is real but gated, which is far more useful than a 404.
            if ($res.Success) { $best = @{ Res = $res; Version = $ver }; break }

            if (-not $best) {
                $best = @{ Res = $res; Version = $ver }
            } else {
                $rank = { param($c) switch ($c) { 403 {4} 401 {3} 400 {2} 404 {1} default {0} } }
                if ((& $rank $res.StatusCode) -gt (& $rank $best.Res.StatusCode)) {
                    $best = @{ Res = $res; Version = $ver }
                }
            }
        }

        if (-not $best) {
            # Every attempt was an unsupported-version response; we never actually tested it.
            $best = @{ Res = [PSCustomObject]@{ Success=$false; StatusCode=400; Error='No valid api-version tried'; Uri=$route.Path }; Version = $null }
        }

        $count = $null
        if ($best.Res.Success -and $best.Res.Content) {
            if ($best.Res.Content.value) { $count = @($best.Res.Content.value).Count }
            elseif ($best.Res.Content -is [System.Array]) { $count = @($best.Res.Content).Count }
            elseif ($best.Res.Content.PSObject.Properties.Name -contains 'id') { $count = 1 }
        }

        $verdict = 'Unavailable'
        if ($best.Res.Success)                { $verdict = 'Available' }
        elseif ($best.Res.StatusCode -eq 403) { $verdict = 'Blocked (role)' }
        elseif ($best.Res.StatusCode -eq 401) { $verdict = 'Blocked (auth)' }
        elseif ($best.Res.StatusCode -eq 404) { $verdict = 'Not found' }
        elseif ($best.Res.StatusCode -eq 400) {
            # A 400 that is NOT about the api-version means the route resolved and rejected
            # our arguments - i.e. it exists and needs query parameters we have not supplied.
            $verdict = 'Exists (needs params)'
        }

        [void]$results.Add([PSCustomObject]@{
            Area          = $route.Area
            Name          = $route.Name
            Path          = $route.Path
            Confidence    = $route.Confidence
            Why           = $route.Why
            Verdict       = $verdict
            StatusCode    = $best.Res.StatusCode
            WorkingVersion = $(if ($best.Res.Success) { $best.Version } else { $null })
            Count         = $count
            Environment   = $EnvironmentLabel
            VersionsTried = ($versionsTried -join ', ')
            Error         = $best.Res.Error
        })

        $lvl = 'WARN'
        if ($best.Res.Success) { $lvl = 'OK' }
        Write-PPLog -Level $lvl -Message ("  {0,-38} {1} (HTTP {2})" -f `
            $route.Name, $verdict, $best.Res.StatusCode)
    }

    return $results
}
