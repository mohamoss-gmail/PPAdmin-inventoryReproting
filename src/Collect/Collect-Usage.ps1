# Collect-Usage.ps1 - credit, capacity and consumption collection from the Licensing namespace.
#
# This is the money half of the report. Everything else inventories what exists; this answers
# "what is it costing, and who is spending it".
#
# Three hard-won facts shape this file:
#
#  1. ROUTE VOCABULARY IS NOT STABLE. The Licensing namespace is still preview and its public
#     surface is documented mainly through `pac licensing` commands rather than REST reference
#     pages. Several datasets answer under more than one spelling depending on tenant and
#     api-version. So every dataset declares a CANDIDATE LIST and the first spelling that
#     answers wins. Whatever worked is recorded in RouteMap and printed in the report, because a
#     consumption figure whose provenance is unknown is not auditable.
#
#  2. API VERSION VARIES PER ROUTE, in the same tenant. Observed here: currencyReports answers
#     at 2024-10-01, while the per-user and licence-trend routes answer only at
#     2026-05-01-preview. So the version is probed per route, newest first, and the service's own
#     "Supported API versions are: ..." response is harvested rather than guessed at.
#
#  3. THE ATTRIBUTION ROUTES ARE SEPARATELY GATED. /entitlements/{id}/resources - the route that
#     says WHICH AGENT burned the credits - returns 403 for an operator who can read the tenant
#     currency report perfectly well. That must never render as "no consumption": an empty table
#     and a forbidden table mean opposite things to an admin. Every failure lands in Gaps with
#     its HTTP code and what it means, and the renderer refuses to imply zero.
#
# Read-only: PPHttp rejects any verb but GET/HEAD.

# Newest first: a newer version carries more fields, and the per-user routes exist only on the
# preview versions. Replaced at runtime by whatever the service says it supports.
$script:PPLicVersions          = @('2026-05-01-preview', '2024-10-01', '2022-03-01-preview', '2021-10-01-preview')
$script:PPLicDiscoveredVersion = $null

# The ExternalCurrencyType enum, confirmed against the `pac licensing
# retrieve-temporary-currency-entitlement-count --currency-type` value list. There is no
# documented "list entitlements" route, so this enum IS the vocabulary. Order matters only for
# presentation: the two meters an admin asks about first come first.
$script:PPCurrencyCatalog = [ordered]@{
    'MCSMessages'              = @{ Label = 'Copilot Studio credits';      Meters = 'Agent messages and generative answers. Renamed "Copilot Credits" in Sept 2025; the API kept the "messages" name.' }
    'AI'                       = @{ Label = 'AI Builder credits';          Meters = 'AI Builder model training, prediction and document processing.' }
    'MCSSessions'              = @{ Label = 'Copilot Studio sessions';     Meters = 'Billed agent sessions, where the tenant is on the session meter rather than credits.' }
    'SCMessages'               = @{ Label = 'Service Copilot messages';    Meters = 'Customer Service embedded copilot messages.' }
    'VAConversations'          = @{ Label = 'Virtual agent conversations'; Meters = 'Legacy Power Virtual Agents conversation meter.' }
    'AppPass'                  = @{ Label = 'Power Apps per-app passes';   Meters = 'Per-app access: one pass per user per app per month.' }
    'AppPassForTeams'          = @{ Label = 'Power Apps per-app (Teams)';  Meters = 'Per-app passes consumed in Teams environments.' }
    'PAHostedRPA'              = @{ Label = 'Hosted RPA';                  Meters = 'Hosted-machine desktop-flow runtime.' }
    'PAUnattendedRPA'          = @{ Label = 'Unattended RPA';              Meters = 'Unattended desktop-flow runs.' }
    'PowerAutomatePerProcess'  = @{ Label = 'Automate per-process';        Meters = 'Process-licensed flows.' }
    'PerFlowPlan'              = @{ Label = 'Per-flow plan';               Meters = 'Flows licensed individually rather than per user.' }
    'PortalLogins'             = @{ Label = 'Portal logins';               Meters = 'Authenticated Power Pages logins (legacy meter).' }
    'PortalViews'              = @{ Label = 'Portal page views';           Meters = 'Anonymous Power Pages page views (legacy meter).' }
    'PowerPagesAuthenticated'  = @{ Label = 'Power Pages authenticated';   Meters = 'Authenticated site users.' }
    'PowerPagesAnonymous'      = @{ Label = 'Power Pages anonymous';       Meters = 'Anonymous site visits.' }
    'ProcessMiningDataStorage' = @{ Label = 'Process mining storage';      Meters = 'Process and task mining data storage.' }
    'PortalAddOns'             = @{ Label = 'Portal add-ons';              Meters = 'Power Pages capacity add-ons.' }
    'Invoice'                  = @{ Label = 'Invoice';                     Meters = 'Invoiced currency, used by some ISV contracts.' }
}

function Get-PPCurrencyLabel {
    param([string]$Currency)
    if (-not $Currency) { return 'Unknown meter' }
    if ($script:PPCurrencyCatalog.Contains($Currency)) { return $script:PPCurrencyCatalog[$Currency].Label }
    # An unrecognised currency is information, not an error: the enum grows. Show it raw.
    return $Currency
}

function Get-PPLicVersionsToTry {
    if ($script:PPLicDiscoveredVersion -and $script:PPLicDiscoveredVersion.Count -gt 0) {
        return $script:PPLicDiscoveredVersion
    }
    return $script:PPLicVersions
}

function Update-PPLicVersionsFromError {
    param([string]$ErrorBody)
    if (-not $ErrorBody) { return }
    if ($ErrorBody -match 'Supported API versions are:\s*([^"}\r\n]+)') {
        $list = @($matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($list.Count -gt 0) {
            $script:PPLicDiscoveredVersion = @($list | Sort-Object -Descending)
            Write-PPLog -Level DEBUG -Message ("  licensing api-versions: {0}" -f ($script:PPLicDiscoveredVersion -join ', '))
        }
    }
}

<#
.SYNOPSIS
    GETs one Licensing route, trying each candidate path and api-version until one answers.
.DESCRIPTION
    Returns the first success. On total failure it returns the most informative attempt, ranked
    403 > 401 > 400 > 404, because "the route exists but you lack the role" and "the route does
    not exist" lead to completely different remediation and must not be collapsed together.
.OUTPUTS
    PSCustomObject: Success, StatusCode, Content, Path, Version, Error, Attempts
#>
function Invoke-PPLicensing {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$Label,
        [int]$MaxRetries = 1
    )

    $base     = 'https://api.powerplatform.com'
    $best     = $null
    $attempts = 0
    $rank     = { param($c) switch ($c) { 403 {4} 401 {3} 400 {2} 404 {1} default {0} } }

    foreach ($path in $Paths) {
        foreach ($ver in (Get-PPLicVersionsToTry)) {
            # The separator must be computed with Contains, NOT with -like '*?*': in PowerShell
            # -like treats ? as a single-character wildcard, so '*?*' matches every non-empty
            # string and every path silently gets '&api-version='. That bug produced a whole set
            # of bogus 404s in Phase 0 probing before it was caught.
            $sep = '?'
            if ($path.Contains('?')) { $sep = '&' }
            $uri = "$base$path$sep" + "api-version=$ver"

            $attempts++
            $res = Invoke-PPRequest -Uri $uri -Token $Token -Label $Label -MaxRetries $MaxRetries -Quiet

            # An unsupported api-version is evidence about the version, not about the route.
            if ($res.StatusCode -eq 400 -and $res.Error -match 'ApiVersion(Invalid|Unsupported)') {
                Update-PPLicVersionsFromError -ErrorBody $res.Error
                continue
            }

            if ($res.Success) {
                return [PSCustomObject]@{
                    Success = $true; StatusCode = $res.StatusCode; Content = $res.Content
                    Path = $path; Version = $ver; Error = $null; Attempts = $attempts
                }
            }

            if (-not $best -or ((& $rank $res.StatusCode) -gt (& $rank $best.StatusCode))) {
                $best = [PSCustomObject]@{
                    Success = $false; StatusCode = $res.StatusCode; Content = $null
                    Path = $path; Version = $ver; Error = $res.Error; Attempts = $attempts
                }
            }

            # 403/401 is final: the route is real and the operator is not allowed. Other
            # spellings and versions cannot change that, and each further attempt is a wasted
            # call against a tenant we are trying to be light on.
            if ($res.StatusCode -eq 403 -or $res.StatusCode -eq 401) { return $best }

            # A 404 is about this spelling, so stop versioning it and try the next candidate.
            if ($res.StatusCode -eq 404) { break }
        }
    }

    if (-not $best) {
        $best = [PSCustomObject]@{
            Success = $false; StatusCode = 0; Content = $null
            Path = @($Paths)[0]; Version = $null; Error = 'no request issued'; Attempts = $attempts
        }
    }
    return $best
}

<#
.SYNOPSIS
    As Invoke-PPLicensing, but follows the Licensing namespace's pagination to the end.
.DESCRIPTION
    The consumption routes page with an opaque continuationToken (`pac licensing` exposes it as
    --continuation-token); some versions return a plain nextLink instead. Both are handled.
    MaxPages is a guard, not a preference: a tenant-wide fan-out over users can be large, and a
    truncated page set is reported as a gap rather than silently under-counting spend.
.OUTPUTS
    PSCustomObject: Success, StatusCode, Rows, Path, Version, Error, Truncated, Pages
#>
function Get-PPLicensingRows {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$Label,
        [int]$MaxPages = 10
    )

    $first = Invoke-PPLicensing -Token $Token -Paths $Paths -Label $Label
    if (-not $first.Success) {
        return [PSCustomObject]@{
            Success = $false; StatusCode = $first.StatusCode; Rows = @()
            Path = $first.Path; Version = $first.Version; Error = $first.Error
            Truncated = $false; Pages = 0
        }
    }

    # Routes have returned the collection as .value, as .items, or as a bare array.
    $take = {
        param($Content)
        if ($null -eq $Content) { return @() }
        if ($Content.PSObject.Properties.Name -contains 'value' -and $null -ne $Content.value) { return @($Content.value) }
        if ($Content.PSObject.Properties.Name -contains 'items' -and $null -ne $Content.items) { return @($Content.items) }
        if ($Content -is [System.Array]) { return @($Content) }
        return @($Content)
    }

    $rows = New-Object System.Collections.ArrayList
    foreach ($r in (& $take $first.Content)) { [void]$rows.Add($r) }

    $pages     = 1
    $truncated = $false
    $content   = $first.Content
    $basePath  = $first.Path

    while ($pages -lt $MaxPages) {
        $token = $null
        $next  = $null
        if ($content.PSObject.Properties.Name -contains 'continuationToken') { $token = $content.continuationToken }
        if (-not $token -and $content.PSObject.Properties.Name -contains 'nextLink') { $next = $content.nextLink }
        if (-not $token -and -not $next) { break }

        if ($next) {
            $res = Invoke-PPRequest -Uri $next -Token $Token -Label "$Label(page)" -MaxRetries 1 -Quiet
            if (-not $res.Success) { $truncated = $true; break }
            $content = $res.Content
        } else {
            $sep = '?'
            if ($basePath.Contains('?')) { $sep = '&' }
            $page = "$basePath$sep" + 'continuationToken=' + [uri]::EscapeDataString([string]$token)
            $res  = Invoke-PPLicensing -Token $Token -Paths @($page) -Label "$Label(page)"
            if (-not $res.Success) { $truncated = $true; break }
            $content = $res.Content
        }

        $batch = @(& $take $content)
        if ($batch.Count -eq 0) { break }
        foreach ($r in $batch) { [void]$rows.Add($r) }
        $pages++
    }

    # Stopped on the guard with a token still outstanding: say so rather than under-report.
    if ($pages -ge $MaxPages -and $content -and
        (($content.PSObject.Properties.Name -contains 'continuationToken' -and $content.continuationToken) -or
         ($content.PSObject.Properties.Name -contains 'nextLink' -and $content.nextLink))) {
        $truncated = $true
    }

    return [PSCustomObject]@{
        Success = $true; StatusCode = 200; Rows = @($rows)
        Path = $first.Path; Version = $first.Version; Error = $null
        Truncated = $truncated; Pages = $pages
    }
}

# --- Field plucking -----------------------------------------------------------------------
# The Licensing models are preview and field names drift between versions (consumed vs
# consumedQuantity vs quantity; resourceId vs id). Rather than pin one spelling and silently
# render blanks when it changes, each value is read from a candidate list.
function Get-PPFirstProp {
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($n in $Names) {
        if ($Object.PSObject.Properties.Name -contains $n) {
            $v = $Object.$n
            if ($null -ne $v -and "$v" -ne '') { return $v }
        }
    }
    return $null
}

# A value that is genuinely absent must stay $null and render as "unknown", never as 0: a zero
# in a cost report is a statement about spend, and we are not entitled to make it on no data.
function Get-PPNumberOrNull {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    $d = 0.0
    if ([double]::TryParse([string]$Value, [ref]$d)) { return $d }
    return $null
}

<#
.SYNOPSIS
    Builds the resourceId -> real asset index that turns consumption rows into a report.
.DESCRIPTION
    The consumption API returns a resourceId GUID. An admin cannot act on a GUID. This index
    joins it back to the agent, app or flow inventory already collected, so the top-spend table
    names the thing that is spending. Unmatched IDs are kept and labelled - a resource that
    consumes credits but appears in no inventory is itself worth seeing (a deleted asset, an
    asset in an environment we could not read, or a resource kind not yet inventoried).
#>
function New-PPResourceIndex {
    param($Agents, $Apps, $Flows)

    $idx = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    $add = {
        param($Id, $Name, $Kind, $EnvId, $EnvName)
        if (-not $Id) { return }
        $key = [string]$Id
        if (-not $idx.ContainsKey($key)) {
            $idx[$key] = [PSCustomObject]@{
                Name = $Name; Kind = $Kind; EnvironmentId = $EnvId; EnvironmentName = $EnvName
            }
        }
    }

    foreach ($a in @($Agents)) {
        & $add $a.Id $a.Name 'Agent' $a.EnvironmentId $a.EnvironmentName
        # Copilot Studio also identifies agents by schema name in some payloads.
        & $add $a.SchemaName $a.Name 'Agent' $a.EnvironmentId $a.EnvironmentName
    }
    foreach ($a in @($Apps))  { & $add $a.Id $a.DisplayName 'App'  $a.EnvironmentId $a.EnvironmentName }
    foreach ($f in @($Flows)) { & $add $f.Id $f.DisplayName 'Flow' $f.EnvironmentId $f.EnvironmentName }

    return $idx
}

<#
.SYNOPSIS
    Collects credit/capacity entitlement, allocation and consumption for the tenant.
.PARAMETER Meters
    Entitlement IDs to deep-dive. Defaults to the meters the tenant's own currency report names,
    plus Copilot Studio and AI Builder credits, which are asked about whether or not the currency
    report lists them.
.PARAMETER AllMeters
    Sweep every ExternalCurrencyType. Costs roughly five calls per meter.
.OUTPUTS
    PSCustomObject consumed by Render-Report and Invoke-PPFindings.
#>
function Invoke-PPCollectUsage {
    param(
        [Parameter(Mandatory)][string]$PPApiToken,
        $Environments,
        $Agents,
        $Apps,
        $Flows,
        $UserIndex,
        [int]$WindowDays = 30,
        [string[]]$Meters,
        [switch]$AllMeters,
        [int]$MaxUserRows = 2000,
        [int]$MaxResourceRows = 2000
    )

    $toDate   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    $fromDate = (Get-Date).ToUniversalTime().AddDays(-$WindowDays).ToString('yyyy-MM-dd')

    $out = [ordered]@{
        WindowFrom             = $fromDate
        WindowTo               = $toDate
        WindowDays             = $WindowDays
        CurrencyReports        = @()
        TenantCapacity         = @()
        EnvironmentAllocations = @()
        Meters                 = @()
        Resources              = @()
        Users                  = @()
        Departments            = @()
        Thresholds             = @()
        Trends                 = @()
        RouteMap               = New-Object System.Collections.ArrayList
        Gaps                   = New-Object System.Collections.ArrayList
    }

    $envIndex = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in @($Environments)) { if ($e.Name) { $envIndex[[string]$e.Name] = $e } }
    $resIndex = New-PPResourceIndex -Agents $Agents -Apps $Apps -Flows $Flows

    $envLabel = {
        param($Id)
        if ($Id -and $envIndex.ContainsKey([string]$Id)) { return $envIndex[[string]$Id].DisplayName }
        return $null
    }

    # Records both halves of provenance in one place: which spelling answered, and - when
    # nothing did - what the failure means in English. The report prints both.
    $note = {
        param($Dataset, $Res, $Meaning)
        [void]$out.RouteMap.Add([PSCustomObject]@{
            Dataset = $Dataset
            Path    = $Res.Path
            Version = $Res.Version
            Status  = $Res.StatusCode
            Verdict = $(if ($Res.Success) { 'Available' }
                        elseif ($Res.StatusCode -eq 403) { 'Blocked (role)' }
                        elseif ($Res.StatusCode -eq 401) { 'Blocked (auth)' }
                        elseif ($Res.StatusCode -eq 404) { 'Not found' }
                        elseif ($Res.StatusCode -eq 400) { 'Rejected arguments' }
                        else { 'Unavailable' })
        })
        if (-not $Res.Success) {
            $reason = "HTTP $($Res.StatusCode)"
            if ($Res.StatusCode -eq 403)     { $reason += ' - the route exists but this operator lacks the role for it' }
            elseif ($Res.StatusCode -eq 404) { $reason += ' - no candidate spelling resolved at any supported api-version' }
            if ($Meaning) { $reason += ". $Meaning" }
            [void]$out.Gaps.Add([PSCustomObject]@{ Item = $Dataset; Reason = $reason })
        }
    }

    # ---------------- Currency report: the headline ----------------
    # Purchased vs allocated vs consumed, per currency, tenant-wide. The only dataset that gives
    # a denominator, so without it no consumption figure can be expressed as a percentage.
    Write-PPLog -Message '  Currency report (purchased / allocated / consumed)'
    $cur = Get-PPLicensingRows -Token $PPApiToken -Label 'usage:currencyReports' -Paths @(
        '/licensing/tenantCapacity/currencyReports?includeAllocations=true&includeConsumptions=true',
        '/licensing/currencyReports?includeAllocations=true&includeConsumptions=true'
    )
    & $note 'Currency report' $cur 'Without it there is no tenant denominator, so consumption cannot be expressed as a share of entitlement.'

    $discovered = New-Object System.Collections.ArrayList
    if ($cur.Success) {
        $out.CurrencyReports = @($cur.Rows | ForEach-Object {
            $code      = [string](Get-PPFirstProp $_ @('currencyType','currency','externalCurrencyType','type','name'))
            $purchased = Get-PPNumberOrNull (Get-PPFirstProp $_ @('purchased','purchasedQuantity','entitled','totalPurchased'))
            $allocated = Get-PPNumberOrNull (Get-PPFirstProp $_ @('allocated','allocatedQuantity','totalAllocated'))
            $consumed  = Get-PPNumberOrNull (Get-PPFirstProp $_ @('consumed','consumedQuantity','totalConsumed','actual'))

            if ($code) { [void]$discovered.Add($code) }

            # Derived only where both sides are real numbers: a consumed figure with no
            # purchased figure gets no percentage rather than a divide-by-zero 100%.
            $pct = $null
            if ($null -ne $consumed -and $null -ne $purchased -and $purchased -gt 0) {
                $pct = [math]::Round(($consumed / $purchased) * 100, 1)
            }
            $remaining = $null
            if ($null -ne $consumed -and $null -ne $purchased) { $remaining = $purchased - $consumed }

            [PSCustomObject]@{
                Currency    = $code
                Label       = (Get-PPCurrencyLabel $code)
                Purchased   = $purchased
                Allocated   = $allocated
                Consumed    = $consumed
                Remaining   = $remaining
                PctConsumed = $pct
                Overage     = $(if ($null -ne $remaining) { $remaining -lt 0 } else { $null })
                LastUpdated = (Get-PPFirstProp $_ @('lastUpdatedDate','lastRefreshedDate','asOfDate','lastUpdated','updatedOn'))
                Unit        = (Get-PPFirstProp $_ @('unit','units'))
            }
        })
        Write-PPLog -Level OK -Message ("    {0} currency/currencies reported" -f @($out.CurrencyReports).Count)
    } else {
        Write-PPLog -Level WARN -Message ("    Currency report unavailable (HTTP {0})" -f $cur.StatusCode)
    }

    # ---------------- Tenant capacity: storage and API ----------------
    Write-PPLog -Message '  Tenant capacity (entitled vs actual)'
    # Order is evidence-based, not alphabetical: probing confirmed plain /licensing/tenantCapacity
    # answers 200 at 2024-10-01, while both "details" spellings suggested by the `pac licensing
    # get-tenant-capacity-details` command name return 404. Cheapest correct call goes first; the
    # others stay as fallbacks because this namespace is preview and spellings move.
    $cap = Get-PPLicensingRows -Token $PPApiToken -Label 'usage:tenantCapacity' -Paths @(
        '/licensing/tenantCapacity',
        '/licensing/tenantCapacityDetails',
        '/licensing/tenantCapacity/details'
    )
    & $note 'Tenant capacity' $cap 'Storage and API capacity headroom is unknown; only credit currencies can be reported.'
    if ($cap.Success) {
        $out.TenantCapacity = @($cap.Rows | ForEach-Object {
            $entitled = Get-PPNumberOrNull (Get-PPFirstProp $_ @('entitled','entitlement','totalEntitled','capacity'))
            $actual   = Get-PPNumberOrNull (Get-PPFirstProp $_ @('actual','consumed','used','actualConsumption'))
            $pct = $null
            if ($null -ne $actual -and $null -ne $entitled -and $entitled -gt 0) {
                $pct = [math]::Round(($actual / $entitled) * 100, 1)
            }
            [PSCustomObject]@{
                CapacityType = [string](Get-PPFirstProp $_ @('capacityType','type','name','storageType'))
                Entitled     = $entitled
                Actual       = $actual
                Rated        = Get-PPNumberOrNull (Get-PPFirstProp $_ @('rated','ratedConsumption'))
                Overflow     = Get-PPNumberOrNull (Get-PPFirstProp $_ @('overflow','overage'))
                Unit         = [string](Get-PPFirstProp $_ @('unit','units'))
                PctConsumed  = $pct
                LastUpdated  = (Get-PPFirstProp $_ @('lastUpdatedDate','lastRefreshedDate','asOfDate'))
            }
        })
        Write-PPLog -Level OK -Message ("    {0} capacity type(s)" -f @($out.TenantCapacity).Count)
    }

    # ---------------- Allocation by environment ----------------
    # What turns "the tenant is at 90%" into "this environment is the reason".
    Write-PPLog -Message '  Credit allocation per environment'
    $alloc = Get-PPLicensingRows -Token $PPApiToken -Label 'usage:allocationsByEnvironment' -Paths @(
        '/licensing/allocationsByEnvironment',
        '/licensing/allocations/environments',
        '/licensing/currencyAllocations'
    )
    & $note 'Allocation by environment' $alloc 'Tenant totals cannot be attributed to an environment, so an environment heading for enforcement cannot be spotted in advance.'
    if ($alloc.Success) {
        $rows = New-Object System.Collections.ArrayList
        foreach ($r in $alloc.Rows) {
            $envId = [string](Get-PPFirstProp $r @('environmentId','environment','envId','id'))
            # Allocations arrive either as one row per environment+currency, or as one row per
            # environment carrying a nested currency array. Flatten both into one shape.
            $nested = $null
            foreach ($n in @('currencyAllocations','allocations','currencies')) {
                if ($r.PSObject.Properties.Name -contains $n -and $r.$n) { $nested = @($r.$n); break }
            }
            if ($nested) {
                foreach ($c in $nested) {
                    $code = [string](Get-PPFirstProp $c @('currencyType','currency','type','name'))
                    [void]$rows.Add([PSCustomObject]@{
                        EnvironmentId   = $envId
                        EnvironmentName = (& $envLabel $envId)
                        Currency        = $code
                        # Carried on the row so the findings engine and renderer never have to
                        # reach back into this collector's catalog to label a number.
                        CurrencyLabel   = (Get-PPCurrencyLabel $code)
                        Allocated       = Get-PPNumberOrNull (Get-PPFirstProp $c @('allocated','allocatedQuantity','quantity'))
                        Consumed        = Get-PPNumberOrNull (Get-PPFirstProp $c @('consumed','consumedQuantity'))
                        TenantPool      = (Get-PPFirstProp $c @('tenantPool','useTenantPool','tenantPoolEnabled'))
                        Enforcement     = (Get-PPFirstProp $c @('enforcementRule','enforcement','enforcementType'))
                    })
                }
            } else {
                $code = [string](Get-PPFirstProp $r @('currencyType','currency','type'))
                [void]$rows.Add([PSCustomObject]@{
                    EnvironmentId   = $envId
                    EnvironmentName = (& $envLabel $envId)
                    Currency        = $code
                    CurrencyLabel   = (Get-PPCurrencyLabel $code)
                    Allocated       = Get-PPNumberOrNull (Get-PPFirstProp $r @('allocated','allocatedQuantity','quantity'))
                    Consumed        = Get-PPNumberOrNull (Get-PPFirstProp $r @('consumed','consumedQuantity'))
                    TenantPool      = (Get-PPFirstProp $r @('tenantPool','useTenantPool','tenantPoolEnabled'))
                    Enforcement     = (Get-PPFirstProp $r @('enforcementRule','enforcement','enforcementType'))
                })
            }
        }
        $out.EnvironmentAllocations = @($rows)
        Write-PPLog -Level OK -Message ("    {0} allocation row(s)" -f @($rows).Count)
    }

    # ---------------- Which meters to deep-dive ----------------
    # Prefer what the tenant itself reported; always include the two meters an admin asks about
    # first, even when the currency report omits them, so their absence is proven not assumed.
    if ($AllMeters) {
        $targets = @($script:PPCurrencyCatalog.Keys)
    } elseif ($Meters -and @($Meters).Count -gt 0) {
        $targets = @($Meters)
    } else {
        $targets = @(@($discovered) + @('MCSMessages','AI') | Where-Object { $_ } | Select-Object -Unique)
    }
    Write-PPLog -Message ("  Deep-diving {0} meter(s): {1}" -f @($targets).Count, (@($targets) -join ', '))

    $meterOut    = New-Object System.Collections.ArrayList
    $allResource = New-Object System.Collections.ArrayList
    $allUsers    = New-Object System.Collections.ArrayList
    $allThresh   = New-Object System.Collections.ArrayList
    $allTrends   = New-Object System.Collections.ArrayList

    foreach ($m in $targets) {
        $label = Get-PPCurrencyLabel $m
        Write-PPLog -Message ("    {0} ({1})" -f $label, $m)

        $entry = [ordered]@{
            Id             = $m
            Label          = $label
            Meters         = $(if ($script:PPCurrencyCatalog.Contains($m)) { $script:PPCurrencyCatalog[$m].Meters } else { $null })
            Detail         = $null
            ResourceCount  = $null
            UserCount      = $null
            ResourceState  = 'Not collected'
            UserState      = 'Not collected'
            ThresholdState = 'Not collected'
        }

        # --- entitlement detail: capacity, pay-as-you-go split, overage state ---
        $det = Invoke-PPLicensing -Token $PPApiToken -Label "usage:entitlement:$m" -Paths @(
            "/licensing/entitlements/$m"
        )
        & $note "Entitlement detail ($label)" $det 'The prepaid-versus-pay-as-you-go split and overage state for this meter are unknown.'
        if ($det.Success) {
            $c = $det.Content
            $entry.Detail = [PSCustomObject]@{
                Capacity     = Get-PPNumberOrNull (Get-PPFirstProp $c @('capacity','purchased','entitled','totalCapacity'))
                Consumed     = Get-PPNumberOrNull (Get-PPFirstProp $c @('consumed','consumedQuantity','totalConsumed'))
                Allocated    = Get-PPNumberOrNull (Get-PPFirstProp $c @('allocated','allocatedQuantity'))
                PayAsYouGo   = Get-PPFirstProp $c @('payAsYouGo','payAsYouGoEnabled','isPayAsYouGo','payAsYouGoCapacity')
                OverageState = Get-PPFirstProp $c @('overageState','overage','enforcementState','state')
                LastUpdated  = Get-PPFirstProp $c @('lastUpdatedDate','lastRefreshedDate','asOfDate')
                Licenses     = Get-PPFirstProp $c @('contributingLicenses','licenses','skus')
            }
        }

        # --- spend thresholds / alarms: absence is itself a finding ---
        $th = Get-PPLicensingRows -Token $PPApiToken -Label "usage:thresholds:$m" -Paths @(
            "/licensing/entitlements/$m/resourceThresholds",
            "/licensing/entitlements/$m/thresholds"
        )
        & $note "Spend thresholds ($label)" $th 'Whether a spend alarm exists for this meter cannot be determined, so its absence must not be reported as a finding.'
        if ($th.Success) {
            $entry.ThresholdState = 'Collected'
            foreach ($t in $th.Rows) {
                $rid = [string](Get-PPFirstProp $t @('resourceId','resource','id'))
                $hit = $null
                if ($rid -and $resIndex.ContainsKey($rid)) { $hit = $resIndex[$rid] }
                [void]$allThresh.Add([PSCustomObject]@{
                    Currency           = $m
                    CurrencyLabel      = $label
                    ResourceId         = $rid
                    ResourceName       = $(if ($hit) { $hit.Name } else { $null })
                    ResourceKind       = $(if ($hit) { $hit.Kind } else { 'Unmatched' })
                    EnvironmentId      = [string](Get-PPFirstProp $t @('environmentId','environment'))
                    Limit              = Get-PPNumberOrNull (Get-PPFirstProp $t @('limit','consumptionLimit'))
                    NotifyAt           = Get-PPNumberOrNull (Get-PPFirstProp $t @('notificationThreshold','notifyThreshold'))
                    StopOverCapacity   = Get-PPFirstProp $t @('stopIfOverCapacity','stopResource','stopOverCapacity')
                    NotifyOverCapacity = Get-PPFirstProp $t @('notifyIfOverCapacity','notifyOverCapacity')
                    Consumption        = Get-PPNumberOrNull (Get-PPFirstProp $t @('resourceConsumption','consumption','consumed'))
                })
            }
        } else {
            $entry.ThresholdState = "HTTP $($th.StatusCode)"
        }

        # --- consumption by resource: WHICH AGENT is spending ---
        # The highest-value table in the report, and the one most often gated: an operator who
        # can read the tenant currency report may still get 403 here.
        $rsrc = Get-PPLicensingRows -Token $PPApiToken -Label "usage:resources:$m" -Paths @(
            "/licensing/entitlements/$m/resources?fromDate=$fromDate&toDate=$toDate&pageSize=200",
            "/licensing/entitlements/$m/resources?fromDate=$fromDate&toDate=$toDate"
        )
        # The 403 case is observed, reproducible and specific to these routes: in a tenant where
        # the currency report, entitlement detail, thresholds and the per-USER route all answer
        # 200 at 2024-10-01, every per-RESOURCE route answers 403 at every api-version, with an
        # empty body naming no required permission. So the remediation text points at the one
        # route to the same data that a Power Platform Administrator demonstrably does have.
        & $note "Consumption by resource ($label)" $rsrc 'Per-agent and per-app credit attribution is unavailable for this meter. Tenant totals remain trustworthy; the breakdown is absent, which is NOT the same as no consumption. Where this is a 403, the same agent-level breakdown can be downloaded by hand from PPAC: Licensing > Products > Copilot Studio > Summary > Download report > agent.'
        if ($rsrc.Success) {
            $entry.ResourceState = 'Collected'
            if ($rsrc.Truncated) {
                $entry.ResourceState = 'Collected (truncated)'
                [void]$out.Gaps.Add([PSCustomObject]@{
                    Item   = "Consumption by resource ($label)"
                    Reason = 'Paging stopped at the page guard with more data outstanding. The per-resource breakdown is incomplete and under-counts; the tenant totals are unaffected.'
                })
            }
            $n = 0
            foreach ($r in $rsrc.Rows) {
                if ($n -ge $MaxResourceRows) { break }
                $n++
                $rid   = [string](Get-PPFirstProp $r @('resourceId','resource','id'))
                $envId = [string](Get-PPFirstProp $r @('environmentId','environment','envId'))
                $meta  = Get-PPFirstProp $r @('metadata','meta','properties')
                $hit   = $null
                if ($rid -and $resIndex.ContainsKey($rid)) { $hit = $resIndex[$rid] }

                $consumed    = Get-PPNumberOrNull (Get-PPFirstProp $r @('consumed','consumedQuantity','quantity','billableConsumed'))
                $nonBillable = Get-PPNumberOrNull (Get-PPFirstProp $r @('nonBillableConsumed','nonBillable'))
                if ($null -eq $nonBillable -and $meta) {
                    $nonBillable = Get-PPNumberOrNull (Get-PPFirstProp $meta @('nonBillableConsumed','nonBillable'))
                }
                # Billed is what the money conversation is about. Derive it only when the
                # inputs are real; an agent burning mostly non-billable credits is a very
                # different cost conversation from one burning billed credits at the same volume.
                $billed = $null
                if ($null -ne $consumed) {
                    $billed = $(if ($null -ne $nonBillable) { [math]::Max(0, $consumed - $nonBillable) } else { $consumed })
                }

                # Name resolution order: our own inventory (authoritative, carries the kind),
                # then whatever name the API supplied, then nothing - never a fabricated label.
                $apiName = Get-PPFirstProp $r @('resourceName','name','displayName')
                if (-not $apiName -and $meta) { $apiName = Get-PPFirstProp $meta @('resourceName','name','displayName','ProductName') }

                [void]$allResource.Add([PSCustomObject]@{
                    Currency        = $m
                    CurrencyLabel   = $label
                    ResourceId      = $rid
                    ResourceName    = $(if ($hit) { $hit.Name } elseif ($apiName) { [string]$apiName } else { $null })
                    ResourceKind    = $(if ($hit) { $hit.Kind } else { 'Unmatched' })
                    Matched         = [bool]$hit
                    EnvironmentId   = $envId
                    EnvironmentName = $(if ($hit -and $hit.EnvironmentName) { $hit.EnvironmentName } else { (& $envLabel $envId) })
                    Consumed        = $consumed
                    NonBillable     = $nonBillable
                    Billed          = $billed
                    Unit            = [string](Get-PPFirstProp $r @('unit','units','currencyType'))
                    Feature         = [string]$(if ($meta) { Get-PPFirstProp $meta @('Feature','feature') } else { $null })
                    ProductName     = [string]$(if ($meta) { Get-PPFirstProp $meta @('ProductName','productName') } else { $null })
                    LastConsumed    = Get-PPFirstProp $r @('consumedDateTime','lastConsumed','lastUpdatedDate','date')
                })
            }
            $entry.ResourceCount = $n
            Write-PPLog -Level OK -Message ("      {0} consuming resource(s)" -f $n)
        } else {
            $entry.ResourceState = "HTTP $($rsrc.StatusCode)"
            if ($rsrc.StatusCode -eq 403) {
                Write-PPLog -Level WARN -Message '      Per-resource attribution blocked (403) - totals only for this meter'
            }
        }

        # --- consumption by user: WHO is spending ---
        $usr = Get-PPLicensingRows -Token $PPApiToken -Label "usage:users:$m" -Paths @(
            "/licensing/entitlements/$m/users?fromDate=$fromDate&toDate=$toDate&pageSize=200",
            "/licensing/entitlements/$m/users?fromDate=$fromDate&toDate=$toDate"
        )
        & $note "Consumption by user ($label)" $usr 'Per-user credit attribution is unavailable for this meter, so a single heavy consumer cannot be identified.'
        if ($usr.Success) {
            $entry.UserState = 'Collected'
            if ($usr.Truncated) { $entry.UserState = 'Collected (truncated)' }
            $n = 0
            foreach ($u in $usr.Rows) {
                if ($n -ge $MaxUserRows) { break }
                $n++
                $uid   = [string](Get-PPFirstProp $u @('userId','user','id','principalId'))
                $envId = [string](Get-PPFirstProp $u @('environmentId','environment'))
                $resolved = Resolve-PPOwner -UserIndex $UserIndex -OwnerId $uid `
                                -FallbackName (Get-PPFirstProp $u @('userPrincipalName','displayName','userName'))
                $dir = $null
                if ($UserIndex -and $uid -and $UserIndex.ContainsKey($uid)) { $dir = $UserIndex[$uid] }

                [void]$allUsers.Add([PSCustomObject]@{
                    Currency         = $m
                    CurrencyLabel    = $label
                    UserId           = $uid
                    UserName         = $resolved.Name
                    UPN              = $(if ($resolved.UPN) { $resolved.UPN } else { [string](Get-PPFirstProp $u @('userPrincipalName','upn')) })
                    Department       = $(if ($dir) { $dir.Department } else { $null })
                    JobTitle         = $(if ($dir) { $dir.JobTitle } else { $null })
                    AccountEnabled   = $resolved.Enabled
                    # A leaver still burning credits is a governance finding, not just a cost one.
                    Orphaned         = $resolved.Orphaned
                    KnownInDirectory = $resolved.Known
                    EnvironmentId    = $envId
                    EnvironmentName  = (& $envLabel $envId)
                    Consumed         = Get-PPNumberOrNull (Get-PPFirstProp $u @('consumed','consumedQuantity','quantity'))
                    NonBillable      = Get-PPNumberOrNull (Get-PPFirstProp $u @('nonBillableConsumed','nonBillable'))
                    Unit             = [string](Get-PPFirstProp $u @('unit','units','currencyType'))
                    LastConsumed     = Get-PPFirstProp $u @('consumedDateTime','lastConsumed','lastUpdatedDate','date')
                })
            }
            $entry.UserCount = $n
            Write-PPLog -Level OK -Message ("      {0} consuming user(s)" -f $n)
        } else {
            $entry.UserState = "HTTP $($usr.StatusCode)"
        }

        # --- licence trend: a point-in-time snapshot cannot show a direction of travel ---
        $tr = Get-PPLicensingRows -Token $PPApiToken -Label "usage:trend:$m" -MaxPages 4 -Paths @(
            "/licensing/entitlements/$m/licenses?fromDate=$fromDate&toDate=$toDate"
        )
        if ($tr.Success) {
            foreach ($t in $tr.Rows) {
                [void]$allTrends.Add([PSCustomObject]@{
                    Currency      = $m
                    CurrencyLabel = $label
                    Date          = Get-PPFirstProp $t @('date','asOfDate','day','lastUpdatedDate')
                    Consumed      = Get-PPNumberOrNull (Get-PPFirstProp $t @('consumed','consumedQuantity'))
                    Entitled      = Get-PPNumberOrNull (Get-PPFirstProp $t @('entitled','capacity','purchased'))
                    Allocated     = Get-PPNumberOrNull (Get-PPFirstProp $t @('allocated','allocatedQuantity'))
                })
            }
        }
        [void]$out.RouteMap.Add([PSCustomObject]@{
            Dataset = "Licence trend ($label)"; Path = $tr.Path; Version = $tr.Version
            Status = $tr.StatusCode; Verdict = $(if ($tr.Success) { 'Available' } else { 'Unavailable' })
        })

        [void]$meterOut.Add([PSCustomObject]$entry)
    }

    $out.Meters     = @($meterOut)
    $out.Resources  = @($allResource)
    $out.Users      = @($allUsers)
    $out.Thresholds = @($allThresh)
    $out.Trends     = @($allTrends)

    # ---------------- Department rollup ----------------
    # The closest honest answer to "which group is spending this". It is a Graph department
    # rollup of per-user consumption, NOT security-group membership: the consumption API
    # attributes to a user and never to a group, and deriving group attribution from app-sharing
    # would be a guess dressed up as a number. The renderer states this on the page.
    if (@($allUsers).Count -gt 0) {
        $out.Departments = @($allUsers |
            Group-Object -Property Currency, { if ($_.Department) { $_.Department } else { '(no department set)' } } |
            ForEach-Object {
                $rows = @($_.Group)
                $sum  = @($rows | Where-Object { $null -ne $_.Consumed } | Measure-Object -Property Consumed -Sum).Sum
                [PSCustomObject]@{
                    Currency      = $rows[0].Currency
                    CurrencyLabel = $rows[0].CurrencyLabel
                    Department    = $(if ($rows[0].Department) { $rows[0].Department } else { '(no department set)' })
                    Users         = $rows.Count
                    Consumed      = $sum
                }
            } | Sort-Object -Property @{ Expression = 'Consumed'; Descending = $true })
    }

    $ranked = @($out.CurrencyReports | Where-Object { $null -ne $_.PctConsumed } | Sort-Object PctConsumed -Descending)
    if ($ranked.Count -gt 0) {
        Write-PPLog -Level OK -Message ("  Highest meter utilisation: {0}% ({1})" -f $ranked[0].PctConsumed, $ranked[0].Label)
    }

    return [PSCustomObject]$out
}
