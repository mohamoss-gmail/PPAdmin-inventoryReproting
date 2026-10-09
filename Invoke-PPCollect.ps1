<#
.SYNOPSIS
    Phase 1 collection: inventories a Power Platform tenant and renders HTML reports.

.DESCRIPTION
    Collects environments, apps, flows, connections, DLP, Copilot Studio agents, solutions and
    Dataverse security, resolves owners through Microsoft Graph, runs the findings engine and
    writes a multi-page HTML report.

    Strictly read-only: the HTTP client refuses any verb other than GET/HEAD.

    Collection and rendering are decoupled. Raw JSON is written to runs/<timestamp>/raw/ before
    anything is rendered, so the report can be rebuilt with -RenderOnly in seconds without
    re-collecting from the tenant.

.PARAMETER Depth
    Quick    - tenant + environments + apps + flows (no Dataverse, no sharing)
    Standard - adds Dataverse agents/solutions/security and Graph identity  (default)
    Deep     - adds per-app sharing resolution and async failure history

.PARAMETER UsageWindowDays
    Look-back window for credit consumption and Azure cost. Default 30 days. The Licensing API
    aggregates daily and lags, so the window end is "as of the last refresh", not "right now".

.PARAMETER AllMeters
    Deep-dive every currency meter rather than only the ones the tenant's currency report names
    (plus Copilot Studio and AI Builder credits, which are always checked). Costs ~5 calls per
    meter.

.PARAMETER UsageReport
    One or more consumption reports downloaded from PPAC (.csv or .xlsx), or a folder of them, to
    import and join to the asset inventory.

    Use this when the probe reports "Credit attribution - which agent or app: Blocked". The
    Licensing route that answers "which agent is spending" (GET /licensing/entitlements/{id}/resources)
    is gated separately from the tenant totals and returns 403 for many Power Platform
    Administrators. The same breakdown - in fact a richer one, carrying channel, LLM model and
    knowledge source - downloads from:
        PPAC > Licensing > Products > Copilot Studio > Summary > Download report > agent
    Imported rows are tagged Source = 'PPAC report' and never replace API data for a meter the
    API already answered, so the same spend is never counted twice.

.PARAMETER IncludeAzureCost
    Also query Azure Consumption for the real currency cost of pay-as-you-go, for each
    subscription behind a billing policy. Needs Azure RBAC on those subscriptions, which
    Power Platform Administrator does NOT grant - without it the module reports 403 and the rest
    of the run is unaffected.

.PARAMETER RenderOnly
    Re-render the report from an existing run directory. No tenant calls at all.

.EXAMPLE
    .\Invoke-PPCollect.ps1
.EXAMPLE
    .\Invoke-PPCollect.ps1 -Depth Deep -MaxEnvironments 50
.EXAMPLE
    .\Invoke-PPCollect.ps1 -RenderOnly -RunDirectory .\runs\20260811-101500
#>
[CmdletBinding()]
param(
    [string]$TenantId = 'organizations',
    [string]$ClientId,
    [ValidateSet('Quick','Standard','Deep')][string]$Depth = 'Standard',
    [int]$MaxEnvironments = 50,
    [switch]$SkipDataverse,
    [switch]$SkipGraph,
    [switch]$SkipUsage,
    [int]$UsageWindowDays = 30,
    [switch]$AllMeters,
    [switch]$IncludeAzureCost,
    [string[]]$UsageReport,
    [switch]$RenderOnly,
    [string]$RunDirectory,
    [string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $root 'src\Core\PPLog.ps1')
. (Join-Path $root 'src\Core\PPHttp.ps1')
. (Join-Path $root 'src\Core\PPAuth.ps1')
. (Join-Path $root 'src\Core\PPDataverse.ps1')
. (Join-Path $root 'src\Collect\Collect-Tenant.ps1')
. (Join-Path $root 'src\Collect\Collect-Environments.ps1')
. (Join-Path $root 'src\Collect\Collect-Assets.ps1')
. (Join-Path $root 'src\Collect\Collect-Dataverse.ps1')
. (Join-Path $root 'src\Collect\Collect-Identity.ps1')
. (Join-Path $root 'src\Collect\Collect-Usage.ps1')
. (Join-Path $root 'src\Collect\Collect-AzureCost.ps1')
. (Join-Path $root 'src\Collect\Import-PPUsageReport.ps1')
. (Join-Path $root 'src\Analyze\Invoke-PPFindings.ps1')
. (Join-Path $root 'src\Render\PPHtml.ps1')
. (Join-Path $root 'src\Render\Render-Report.ps1')

# =======================================================================================
# Render-only path: rebuild the report from raw JSON without touching the tenant.
# =======================================================================================
if ($RenderOnly) {
    if (-not $RunDirectory) {
        $latest = Get-ChildItem -Path (Join-Path $root 'runs') -Directory -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path (Join-Path $_.FullName 'raw\data.json') } |
                    Sort-Object Name -Descending | Select-Object -First 1
        if (-not $latest) { throw 'No previous run with raw/data.json found. Run a collection first.' }
        $RunDirectory = $latest.FullName
    }
    $dataPath = Join-Path $RunDirectory 'raw\data.json'
    if (-not (Test-Path $dataPath)) { throw "No raw data at $dataPath" }

    Initialize-PPLog -Path (Join-Path $RunDirectory 'render.log')
    Write-PPLog -Level STEP -Message "Re-rendering from $RunDirectory"

    $data     = Get-Content $dataPath -Raw | ConvertFrom-Json
    $findings = Invoke-PPFindings -Data $data
    $index    = New-PPReport -Data $data -Findings $findings -OutputDir (Join-Path $RunDirectory 'report')

    Write-PPLog -Level OK -Message ("Rendered {0} finding(s)" -f @($findings).Count)
    Write-Host ''
    Write-Host ('  Report: ' + $index) -ForegroundColor White
    try { Start-Process $index -ErrorAction SilentlyContinue | Out-Null } catch { }
    return
}

# =======================================================================================
# Collection
# =======================================================================================
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
if (-not $OutputRoot) { $OutputRoot = Join-Path $root 'runs' }
$runDir = Join-Path $OutputRoot $stamp
New-Item -ItemType Directory -Path (Join-Path $runDir 'raw') -Force | Out-Null

Initialize-PPLog -Path (Join-Path $runDir 'collect.log')
Reset-PPCallLog

$startedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
$swTotal    = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host ''
Write-Host '  Power Platform tenant report - collection' -ForegroundColor White
Write-Host ("  Depth: $Depth   Read-only: no tenant data is modified.") -ForegroundColor DarkGray

# --- Auth ------------------------------------------------------------------------------
Write-PPBanner 'Authentication'
if (-not (Connect-PPTenant -TenantId $TenantId -ClientId $ClientId)) {
    Write-PPLog -Level ERROR -Message 'Sign-in failed.'
    exit 1
}

$bapTok   = (Get-PPToken -Resource 'https://api.bap.microsoft.com/')
$papsTok  = (Get-PPToken -Resource 'https://service.powerapps.com/')
$flowTok  = (Get-PPToken -Resource 'https://service.flow.microsoft.com/')
$ppapiTok = (Get-PPToken -Resource 'https://api.powerplatform.com/')
$graphTok = (Get-PPToken -Resource 'https://graph.microsoft.com/')

if (-not $bapTok.Success) {
    Write-PPLog -Level ERROR -Message "No BAP token: $($bapTok.Error). Cannot enumerate environments."
    exit 1
}
$tenantId = (Get-PPAuthState).TenantId

# --- Tenant ----------------------------------------------------------------------------
Write-PPBanner 'Tenant governance'
$tenant = Invoke-PPCollectTenant -BapToken $bapTok.AccessToken `
            -PPApiToken $(if ($ppapiTok.Success) { $ppapiTok.AccessToken } else { $null }) `
            -TenantId $tenantId

# --- Environments ----------------------------------------------------------------------
Write-PPBanner 'Environments'
$environments = Invoke-PPCollectEnvironments -BapToken $bapTok.AccessToken `
                  -PPApiToken $(if ($ppapiTok.Success) { $ppapiTok.AccessToken } else { $null }) `
                  -IncludeBackups:($ppapiTok.Success)

if (@($environments).Count -eq 0) {
    Write-PPLog -Level ERROR -Message 'No environments collected. Aborting.'
    exit 1
}
$scoped = @($environments | Select-Object -First $MaxEnvironments)

# --- Apps / flows / connections ---------------------------------------------------------
Write-PPBanner 'Apps, flows and connections'
$apps = @(); $flows = @(); $connections = @(); $customConnectors = @()

if ($papsTok.Success) {
    $apps = Invoke-PPCollectApps -Token $papsTok.AccessToken -Environments $scoped `
                                 -IncludeSharing:($Depth -eq 'Deep')
} else {
    Write-PPLog -Level WARN -Message "No PowerApps token: $($papsTok.Error)"
}

if ($flowTok.Success) {
    $flows = Invoke-PPCollectFlows -Token $flowTok.AccessToken -Environments $scoped
} else {
    Write-PPLog -Level WARN -Message "No Flow token: $($flowTok.Error)"
}

if ($papsTok.Success) {
    $conn = Invoke-PPCollectConnections -Token $papsTok.AccessToken -Environments $scoped
    $connections      = $conn.Connections
    $customConnectors = $conn.CustomConnectors
}

# --- Dataverse -------------------------------------------------------------------------
Write-PPBanner 'Dataverse depth'
$dataverse = @()
if (-not $SkipDataverse -and $Depth -ne 'Quick') {
    $dvEnvs = @($scoped | Where-Object { $_.HasDataverse })
    $i = 0
    foreach ($env in $dvEnvs) {
        $i++
        Write-PPLog -Message ("[{0}/{1}] {2}" -f $i, $dvEnvs.Count, $env.DisplayName)
        $dataverse += Invoke-PPCollectDataverse -Environment $env `
                        -IncludeAgents -IncludeSolutions -IncludeSecurity `
                        -IncludeErrors:($Depth -eq 'Deep')
    }
} else {
    Write-PPLog -Message '  Skipped.'
}

$agents = @()
foreach ($dv in $dataverse) { $agents += @($dv.Agents) }

# --- Identity --------------------------------------------------------------------------
Write-PPBanner 'Identity'
$identity = [PSCustomObject]@{ Users=@(); Groups=@(); ServicePrincipals=@(); Skus=@(); UserIndex=@{}; Gaps=@() }
if (-not $SkipGraph -and $Depth -ne 'Quick') {
    if ($graphTok.Success) {
        $identity = Invoke-PPCollectIdentity -Token $graphTok.AccessToken
    } else {
        Write-PPLog -Level WARN -Message "No Graph token: $($graphTok.Error). Owners cannot be resolved."
    }
} else {
    Write-PPLog -Message '  Skipped.'
}

# --- Usage, credits and cost -------------------------------------------------------------
# Deliberately last of the collectors: it joins resource IDs to the agent/app/flow inventory and
# user IDs to the Graph directory, so it needs both to already be in hand. Running it earlier
# would leave the top-spend tables full of bare GUIDs.
Write-PPBanner 'Credits, capacity and consumption'
$usage = $null
if (-not $SkipUsage) {
    if ($ppapiTok.Success) {
        $usage = Invoke-PPCollectUsage -PPApiToken $ppapiTok.AccessToken `
                    -Environments $environments -Agents $agents -Apps $apps -Flows $flows `
                    -UserIndex $identity.UserIndex -WindowDays $UsageWindowDays -AllMeters:$AllMeters
    } else {
        Write-PPLog -Level WARN -Message "No Power Platform API token: $($ppapiTok.Error). Credit and capacity consumption cannot be read."
    }
} else {
    Write-PPLog -Message '  Skipped.'
}

# Hand-exported PPAC reports fill the gap the 403 leaves. Imported after collection so the
# importer can see which meters the API already answered and refuse to double-count them.
if ($UsageReport) {
    Write-PPBanner 'Importing downloaded consumption reports'
    if ($usage) {
        $usage = Import-PPUsageReport -Path $UsageReport -Usage $usage `
                    -Agents $agents -Apps $apps -Flows $flows `
                    -Environments $environments -UserIndex $identity.UserIndex
    } else {
        # Without a Usage object there is nothing to join against or merge into. Importing into a
        # vacuum would produce a cost table with no tenant totals to sanity-check it against.
        Write-PPLog -Level WARN -Message '  No usage data collected, so there is nothing to import into. Re-run without -SkipUsage.'
    }
}

$azureCost = $null
if ($IncludeAzureCost) {
    Write-PPBanner 'Azure pay-as-you-go cost'
    $armTok = (Get-PPToken -Resource 'https://management.azure.com/')
    if ($armTok.Success) {
        $azureCost = Invoke-PPCollectAzureCost -Token $armTok.AccessToken `
                        -BillingPolicies $tenant.BillingPolicies -WindowDays $UsageWindowDays
    } else {
        # Not a failure of the run: this audience is simply not consented for this operator.
        Write-PPLog -Level WARN -Message "No Azure Resource Manager token: $($armTok.Error). Azure cost skipped."
        $azureCost = [PSCustomObject]@{
            WindowFrom = $null; WindowTo = $null; Subscriptions = @(); Meters = @(); Resources = @()
            Totals = $null; Attempted = $false
            Gaps = @([PSCustomObject]@{ Item = 'Azure cost'; Reason = "No management.azure.com token: $($armTok.Error)" })
        }
    }
}

# --- Assemble --------------------------------------------------------------------------
$swTotal.Stop()
$calls = Get-PPCallLog

$data = [PSCustomObject]@{
    Meta = [PSCustomObject]@{
        TenantId       = $tenantId
        Account        = (Get-PPAuthState).Account
        StartedUtc     = $startedUtc
        ElapsedSeconds = [int]$swTotal.Elapsed.TotalSeconds
        Depth          = $Depth
        PSVersion      = $PSVersionTable.PSVersion.ToString()
        CallCount      = @($calls).Count
        Calls          = $calls
    }
    Tenant           = $tenant
    Environments     = $environments
    Apps             = $apps
    Flows            = $flows
    Connections      = $connections
    CustomConnectors = $customConnectors
    Dataverse        = $dataverse
    Agents           = $agents
    Identity         = $identity
    Usage            = $usage
    AzureCost        = $azureCost
}

# Raw first: collection is the expensive, fragile half. Once this file exists the report can
# be rebuilt any number of times with -RenderOnly and no further tenant calls.
$dataPath = Join-Path $runDir 'raw\data.json'
$data | ConvertTo-Json -Depth 14 | Set-Content -Path $dataPath -Encoding utf8
Write-PPLog -Level OK -Message ("Raw data written: {0}" -f $dataPath)

# --- Analyse and render ------------------------------------------------------------------
Write-PPBanner 'Findings'
$findings = Invoke-PPFindings -Data $data
$summary  = Get-PPFindingSummary -Findings $findings
$findings | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $runDir 'raw\findings.json') -Encoding utf8

foreach ($sev in @('Critical','High','Medium','Low','Info')) {
    if ($summary[$sev] -gt 0) {
        $lvl = 'WARN'
        if ($sev -eq 'Critical' -or $sev -eq 'High') { $lvl = 'ERROR' }
        if ($sev -eq 'Info') { $lvl = 'INFO' }
        Write-PPLog -Level $lvl -Message ("  {0,-9} {1}" -f $sev, $summary[$sev])
    }
}

$index = New-PPReport -Data $data -Findings $findings -OutputDir (Join-Path $runDir 'report')

Write-Host ''
Write-PPLog -Level OK -Message ("Collection complete in {0}s - {1} API calls, {2} finding(s)." -f `
    $data.Meta.ElapsedSeconds, $data.Meta.CallCount, @($findings).Count)
Write-Host ''
Write-Host ('  Report : ' + $index) -ForegroundColor White
Write-Host ('  Raw    : ' + $dataPath) -ForegroundColor DarkGray
Write-Host ''
Write-Host ('  {0} environments, {1} apps, {2} flows, {3} agents, {4} connections' -f `
    @($environments).Count, @($apps).Count, @($flows).Count, @($agents).Count, @($connections).Count) -ForegroundColor Gray

if ($usage) {
    Write-Host ('  {0} meter(s) reported, {1} consuming resource(s), {2} consuming user(s) over {3} days' -f `
        @($usage.CurrencyReports).Count, @($usage.Resources).Count, @($usage.Users).Count, $usage.WindowDays) -ForegroundColor Gray
    # A gap count here is the honest headline: it tells the reader up front how much of the
    # cost picture is missing before they read any number on the usage page.
    if (@($usage.Gaps).Count -gt 0) {
        Write-Host ('  {0} usage dataset(s) unavailable - see the Usage page and Integrity page' -f `
            @($usage.Gaps).Count) -ForegroundColor DarkYellow
    }
}
if ($azureCost -and $azureCost.Totals) {
    Write-Host ('  Azure pay-as-you-go: {0} {1} across {2} meter(s)' -f `
        $azureCost.Totals.Cost, $azureCost.Totals.Currency, $azureCost.Totals.MeterCount) -ForegroundColor Gray
}
Write-Host ''

try { Start-Process $index -ErrorAction SilentlyContinue | Out-Null } catch { }
