<#
.SYNOPSIS
    Phase 0 capability probe for the Power Platform tenant reporting tool.

.DESCRIPTION
    Determines what a given operator can actually collect from a given tenant, BEFORE any
    collector is written. Answers empirically:
      - Which API audiences will issue tokens to this admin?
      - Do the uncertain api.powerplatform.com routes (backups, DR, environment groups,
        agent consumption) exist, and at which api-version?
      - Can this admin reach Dataverse per environment, or only some?
      - Are Copilot Studio agents and their conversation transcripts readable?
      - What is the REAL transcript retention, as opposed to the 30-day default?

    Strictly read-only: the HTTP client refuses any verb other than GET/HEAD.

.PARAMETER TenantId
    Tenant GUID or domain. Defaults to 'organizations' (resolved at sign-in).

.PARAMETER ClientId
    Public client used for device-code auth. Defaults to the Azure CLI first-party client,
    which needs no app registration. Override if Conditional Access blocks it.

.PARAMETER MaxEnvironments
    Cap on environments probed for Dataverse depth. Keeps a first run to a few minutes.

.PARAMETER SkipDataverse
    Skip per-environment Dataverse probing entirely.

.PARAMETER SkipTranscripts
    Probe agents but not conversation transcripts.

.EXAMPLE
    .\Invoke-PPProbe.ps1
.EXAMPLE
    .\Invoke-PPProbe.ps1 -TenantId contoso.onmicrosoft.com -MaxEnvironments 25
#>
[CmdletBinding()]
param(
    [string]$TenantId = 'organizations',
    [string]$ClientId,
    [int]$MaxEnvironments = 10,
    [switch]$SkipDataverse,
    [switch]$SkipTranscripts,
    [string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $root 'src\Core\PPLog.ps1')
. (Join-Path $root 'src\Core\PPHttp.ps1')
. (Join-Path $root 'src\Core\PPAuth.ps1')
. (Join-Path $root 'src\Core\PPDataverse.ps1')
. (Join-Path $root 'src\Render\PPHtml.ps1')
. (Join-Path $root 'src\Probe\Probe-PlatformApi.ps1')
. (Join-Path $root 'src\Probe\Probe-PPApi.ps1')
. (Join-Path $root 'src\Probe\Probe-Dataverse.ps1')
. (Join-Path $root 'src\Probe\Probe-Identity.ps1')
. (Join-Path $root 'src\Render\Render-ProbeReport.ps1')

# ---------------------------------------------------------------------------------------
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
if (-not $OutputRoot) { $OutputRoot = Join-Path $root 'runs' }
$runDir = Join-Path $OutputRoot "$stamp-probe"
New-Item -ItemType Directory -Path (Join-Path $runDir 'raw') -Force | Out-Null

Initialize-PPLog -Path (Join-Path $runDir 'probe.log')
Reset-PPCallLog

$startedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
$swTotal    = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host ''
Write-Host '  Power Platform tenant - Phase 0 capability probe' -ForegroundColor White
Write-Host '  Read-only. No tenant data is modified.' -ForegroundColor DarkGray

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-PPLog -Level WARN -Message ("Running Windows PowerShell {0}. The probe supports it, but Phase 1 collection wants PowerShell 7 for parallelism: winget install Microsoft.PowerShell" -f $PSVersionTable.PSVersion)
}

# --- 1. Sign in ------------------------------------------------------------------------
Write-PPBanner 'Step 1 - Authentication'
if (-not (Connect-PPTenant -TenantId $TenantId -ClientId $ClientId)) {
    Write-PPLog -Level ERROR -Message 'Sign-in failed. Cannot continue.'
    exit 1
}

$auth      = New-Object System.Collections.ArrayList
$resources = Get-PPKnownResources
$tokens    = @{}

foreach ($name in $resources.Keys) {
    $res = $resources[$name]
    $t   = Get-PPToken -Resource $res
    $tokens[$res] = $t.AccessToken
    [void]$auth.Add([PSCustomObject]@{
        Name = $name; Resource = $res; Success = $t.Success; Error = $t.Error
    })
    $lvl = 'WARN'
    if ($t.Success) { $lvl = 'OK' }
    Write-PPLog -Level $lvl -Message ("  {0,-30} {1}" -f $name, $(if ($t.Success) { 'token acquired' } else { $t.Error }))
}

$bapToken   = $tokens['https://api.bap.microsoft.com/']
$papsToken  = $tokens['https://service.powerapps.com/']
$ppapiToken = $tokens['https://api.powerplatform.com/']
$graphToken = $tokens['https://graph.microsoft.com/']

# Flow has its own audience and is not in the shared list.
$flowTok   = Get-PPToken -Resource 'https://service.flow.microsoft.com/'
$flowToken = $flowTok.AccessToken
[void]$auth.Add([PSCustomObject]@{
    Name = 'Power Automate'; Resource = 'https://service.flow.microsoft.com/'
    Success = $flowTok.Success; Error = $flowTok.Error
})

# --- 2. Environments -------------------------------------------------------------------
Write-PPBanner 'Step 2 - Environment inventory'
$environments = @()
if ($bapToken) {
    $environments = Get-PPEnvironmentList -BapToken $bapToken
} else {
    Write-PPLog -Level ERROR -Message 'No BAP token: cannot enumerate environments.'
}

# --- 3. Core admin APIs ----------------------------------------------------------------
Write-PPBanner 'Step 3 - Core admin APIs'
$platformApi = @()
if ($environments.Count -gt 0 -or $bapToken) {
    $platformApi = Invoke-PPPlatformApiProbe -Environments $environments -BapToken $bapToken `
                        -PowerAppsToken $papsToken -FlowToken $flowToken `
                        -TenantId (Get-PPAuthState).TenantId
    foreach ($r in $platformApi) {
        $lvl = 'WARN'; if ($r.Success) { $lvl = 'OK' }
        Write-PPLog -Level $lvl -Message ("  {0,-42} HTTP {1}" -f $r.Check, $r.StatusCode)
    }
}

# --- 4. Power Platform API candidate routes --------------------------------------------
Write-PPBanner 'Step 4 - Power Platform API (candidate routes)'
$ppApi = @()
if ($ppapiToken) {
    $sampleEnv = $environments | Select-Object -First 1
    $ppApi = Invoke-PPApiProbe -Token $ppapiToken `
                -EnvironmentId $(if ($sampleEnv) { $sampleEnv.Name } else { $null }) `
                -EnvironmentLabel $(if ($sampleEnv) { $sampleEnv.DisplayName } else { $null })
} else {
    Write-PPLog -Level WARN -Message '  No api.powerplatform.com token - backups/DR/env-groups cannot be assessed.'
}

# --- 5. Dataverse per environment ------------------------------------------------------
Write-PPBanner 'Step 5 - Dataverse, agents and transcripts'
$dataverse = @()
if (-not $SkipDataverse) {
    $dvEnvs = @($environments | Where-Object { $_.HasDataverse } | Select-Object -First $MaxEnvironments)
    if ($dvEnvs.Count -eq 0) {
        Write-PPLog -Level WARN -Message '  No Dataverse-backed environments found.'
    }
    $i = 0
    foreach ($env in $dvEnvs) {
        $i++
        Write-PPLog -Message ("[{0}/{1}] {2}" -f $i, $dvEnvs.Count, $env.DisplayName)
        $dataverse += Invoke-PPDataverseProbe -Environment $env -IncludeTranscripts:(-not $SkipTranscripts)
    }
} else {
    Write-PPLog -Message '  Skipped (-SkipDataverse).'
}

# --- 6. Graph + audit ------------------------------------------------------------------
Write-PPBanner 'Step 6 - Identity and usage telemetry'
$graph = @()
if ($graphToken) { $graph = Invoke-PPGraphProbe -Token $graphToken }
else { Write-PPLog -Level WARN -Message '  No Graph token - owner names cannot be resolved.' }

$audit = Get-PPAuditCapability
Write-PPLog -Message ("  Unified audit log: {0}" -f $audit.Verdict)

# --- 7. Verdicts -----------------------------------------------------------------------
$verdicts  = New-Object System.Collections.ArrayList
$nextSteps = New-Object System.Collections.ArrayList

function Add-Verdict {
    param($Capability, $Verdict, $Consequence)
    [void]$verdicts.Add([PSCustomObject]@{
        Capability = $Capability; Verdict = $Verdict; Consequence = $Consequence
    })
}

# Environments / core inventory
if ($environments.Count -gt 0) {
    Add-Verdict 'Environment, app, flow and DLP inventory' 'Available' `
        "$($environments.Count) environments enumerated. Pages 01-08 of the report are viable."
} else {
    Add-Verdict 'Environment, app, flow and DLP inventory' 'Blocked' `
        'Environment enumeration failed - nothing downstream can proceed. Confirm the account holds Power Platform Administrator.'
    [void]$nextSteps.Add('Resolve environment enumeration first: confirm the Power Platform Administrator role and that the client app is permitted by Conditional Access.')
}

# Backups / DR
$backupOk = @($ppApi | Where-Object { $_.Area -eq 'Backups' -and $_.Verdict -eq 'Available' }).Count
$drOk     = @($ppApi | Where-Object { $_.Area -eq 'DR'      -and $_.Verdict -eq 'Available' }).Count
if ($backupOk -gt 0) {
    Add-Verdict 'Backups and restore points' 'Available' 'Backup evidence can be reported per environment.'
} else {
    Add-Verdict 'Backups and restore points' 'Unavailable' `
        'No working backup route found at the api-versions tried. Backup/DR reporting must fall back to what PPAC exposes, or be dropped.'
    [void]$nextSteps.Add('Backup routes did not respond: capture the exact routes PPAC calls via browser devtools while viewing an environment backup page, then re-probe with those.')
}
if ($drOk -eq 0) {
    Add-Verdict 'Disaster recovery posture' 'Unavailable' `
        'The BCDR route was a design guess and did not resolve. Do not build a DR page until a real endpoint is confirmed.'
}

# Credit / capacity consumption. Split deliberately: the tenant totals and the per-agent
# per-user attribution are different report sections with different failure modes, and
# "we know the tenant burned 40k credits but not who burned them" is a real outcome.
$usage      = @($ppApi | Where-Object { $_.Area -eq 'Usage' })
$usageTotal = @($usage | Where-Object { ($_.Name -like '*Currency reports*' -or $_.Name -like '*Tenant capacity*') -and $_.Verdict -eq 'Available' }).Count

# The two attribution halves are reported separately because they FAIL separately, and in this
# tenant they actually do: the per-user routes answer 200 while every per-resource route answers
# 403 with the same token. An earlier version OR-ed them into one $usageWho count, which made a
# blocked "which agent" route render as "attribution is Available" - the exact false reassurance
# the comment above warns about. Never collapse two independently-gated capabilities into one
# verdict.
$whoResource = @($usage | Where-Object { $_.Name -like '*by resource*' -and $_.Verdict -eq 'Available' }).Count
$whoUser     = @($usage | Where-Object { $_.Name -like '*by user*'     -and $_.Verdict -eq 'Available' }).Count
$resBlocked  = @($usage | Where-Object { $_.Name -like '*by resource*' -and $_.StatusCode -eq 403 }).Count
if ($usageTotal -gt 0) {
    Add-Verdict 'Credit and capacity consumption (tenant)' 'Available' `
        'Purchased vs allocated vs consumed is readable for every meter - Copilot credits, AI Builder, RPA, per-app passes. A cost page is viable.'
} else {
    Add-Verdict 'Credit and capacity consumption (tenant)' 'Unavailable' `
        'The Licensing consumption routes did not respond. Cost reporting would be limited to per-environment storage capacity.'
}
if ($whoResource -gt 0) {
    Add-Verdict 'Credit attribution - which agent or app' 'Available' `
        'Consumption is attributable per resource, so credit burn can be charged back to a named agent, app or flow.'
} elseif ($resBlocked -gt 0) {
    Add-Verdict 'Credit attribution - which agent or app' 'Blocked' `
        'Every per-resource consumption route returned 403 while the tenant totals and the per-user routes returned 200 with the same token. The routes exist and this operator is not permitted to call them, so "which agent is spending" is UNKNOWN - never zero. The same breakdown is available by hand from PPAC: Licensing > Products > Copilot Studio > Summary > Download report > agent.'
    [void]$nextSteps.Add('Per-resource credit attribution is 403 at every api-version while per-user is 200 - this is a permission boundary specific to resource-level consumption, not a wrong route. The service returns no error body naming the required permission. Either obtain the agent-level report from PPAC (Licensing > Products > Copilot Studio > Summary > Download report) and ingest it, or raise a support case asking which role grants GET /licensing/entitlements/{id}/resources.')
} else {
    Add-Verdict 'Credit attribution - which agent or app' 'Unavailable' `
        'The per-resource routes did not resolve. Per-agent attribution would have to come from the pay-as-you-go report in PPAC, downloaded by hand.'
    [void]$nextSteps.Add('Per-resource credit attribution did not resolve: check the entitlement ID spelling by reading /licensing/environments/{env}/entitlements in the raw probe output, then re-probe with the IDs this tenant actually returns.')
}
if ($whoUser -gt 0) {
    Add-Verdict 'Credit attribution - which user' 'Available' `
        'Per-user consumption is readable, so credit burn can be attributed to a person and rolled up by department.'
} else {
    Add-Verdict 'Credit attribution - which user' 'Unavailable' `
        'Per-user consumption did not respond, so a single heavy consumer cannot be identified from the API.'
}

# Dataverse depth
$dvTotal = @($dataverse).Count
$dvOk    = @($dataverse | Where-Object { $_.Reachable }).Count
if ($dvTotal -gt 0) {
    if ($dvOk -eq $dvTotal) {
        Add-Verdict 'Dataverse depth (solutions, security, agents)' 'Available' `
            "All $dvTotal sampled environments reachable. Pages 06, 09, 10 and 12 are viable."
    } elseif ($dvOk -eq 0) {
        Add-Verdict 'Dataverse depth (solutions, security, agents)' 'Blocked' `
            'No sampled environment allowed Dataverse access. Agent, solution and security reporting is impossible without granting the admin a security role per environment.'
        [void]$nextSteps.Add('Dataverse is denied everywhere: either add the operator as a System Administrator in each environment, or switch to an app registration with an application user per environment.')
    } else {
        Add-Verdict 'Dataverse depth (solutions, security, agents)' 'Partial' `
            "$dvOk of $dvTotal environments reachable. The report must show the gap explicitly rather than silently omitting environments."
        [void]$nextSteps.Add("Dataverse access is partial ($dvOk/$dvTotal). Decide whether to grant access to the remainder or accept documented blind spots.")
    }
}

# Agents
$agentEnvs = @($dataverse | Where-Object { $_.AgentCount -gt 0 })
if ($agentEnvs.Count -gt 0) {
    $tot = 0; foreach ($d in $agentEnvs) { $tot += $d.AgentCount }
    Add-Verdict 'Copilot Studio agent inventory' 'Available' `
        "$tot agents readable from the bot table, including access-control and auth posture."
} elseif ($dvOk -gt 0) {
    Add-Verdict 'Copilot Studio agent inventory' 'No data' 'No agents found in the sampled environments.'
}

# Transcripts
$trOk     = @($dataverse | Where-Object { $_.TranscriptAccess -eq 'Readable' })
$trDenied = @($dataverse | Where-Object { $_.TranscriptAccess -like 'Denied*' })
if ($trOk.Count -gt 0) {
    $ret = @($trOk | Where-Object { $null -ne $_.ObservedRetentionDays } |
                ForEach-Object { $_.ObservedRetentionDays } | Measure-Object -Maximum).Maximum
    Add-Verdict 'Agent usage telemetry (transcripts)' 'Available' `
        "Readable in $($trOk.Count) environment(s). Longest observed history: $ret days - this hard-bounds any usage trend."
    if ($ret -and $ret -le 31) {
        [void]$nextSteps.Add("Transcript history is only ~$ret days (default 30-day purge active). To trend agent usage over time, either extend the bulk-delete job or stand up Azure Synapse Link in append-only mode.")
    }
} elseif ($trDenied.Count -gt 0) {
    Add-Verdict 'Agent usage telemetry (transcripts)' 'Blocked' `
        'Transcripts denied - the Bot Transcript Viewer security role is missing. Agent engagement, resolution and escalation metrics are unavailable until granted.'
    [void]$nextSteps.Add('Grant the operator the Bot Transcript Viewer security role in each environment with agents, or accept that agent usage metrics cannot be reported.')
} elseif ($dvOk -gt 0) {
    Add-Verdict 'Agent usage telemetry (transcripts)' 'No data' `
        'No transcripts present. Expected for developer/Teams environments, where they are never written.'
}

# Graph
$graphOk = @($graph | Where-Object { $_.Verdict -eq 'Available' }).Count
if ($graphOk -ge 3) {
    Add-Verdict 'Identity resolution (owners, leavers, licences)' 'Available' `
        'Owner GUIDs can be resolved to people and orphaned-asset detection is viable.'
} elseif ($graphOk -gt 0) {
    Add-Verdict 'Identity resolution (owners, leavers, licences)' 'Partial' `
        'Some Graph reads are consented. Owner resolution may be incomplete.'
    [void]$nextSteps.Add('Graph consent is partial: grant User.Read.All, Group.Read.All, Application.Read.All and Organization.Read.All to resolve owners and detect departed staff.')
} else {
    Add-Verdict 'Identity resolution (owners, leavers, licences)' 'Blocked' `
        'Every owner stays a bare GUID and orphaned-asset findings are impossible.'
    [void]$nextSteps.Add('Graph is unavailable: consent the delegated scopes above, or the report cannot name a single owner.')
}

# Audit
if ($audit.ModuleInstalled) {
    Add-Verdict 'App/flow usage telemetry (audit log)' 'Needs confirmation' `
        'Module present. Role and unified-auditing status still need confirming before MAU / last-used reporting can be promised.'
} else {
    Add-Verdict 'App/flow usage telemetry (audit log)' 'Unavailable' `
        'No ExchangeOnlineManagement module. App launch counts, MAU and unused-app detection cannot be produced.'
    [void]$nextSteps.Add('Install ExchangeOnlineManagement and confirm the operator holds View-Only Audit Logs, otherwise drop the usage/adoption page from scope.')
}

[void]$nextSteps.Add('Review the collection-integrity call log at the foot of the report, then lock the confirmed routes into Phase 1 collectors.')

# --- 8. Emit ---------------------------------------------------------------------------
$swTotal.Stop()
$calls = Get-PPCallLog

$probe = [PSCustomObject]@{
    TenantId        = (Get-PPAuthState).TenantId
    Account         = (Get-PPAuthState).Account
    StartedUtc      = $startedUtc
    ElapsedSeconds  = [int]$swTotal.Elapsed.TotalSeconds
    PSVersion       = $PSVersionTable.PSVersion.ToString()
    AdminModule     = Get-PPAdminModuleStatus
    Auth            = $auth
    Environments    = $environments
    PlatformApi     = $platformApi
    PPApi           = $ppApi
    Dataverse       = $dataverse
    Graph           = $graph
    Audit           = $audit
    Verdicts        = $verdicts
    NextSteps       = $nextSteps
    Calls           = $calls
    CallCount       = @($calls).Count
}

$jsonPath = Join-Path $runDir 'raw\probe.json'
$probe | ConvertTo-Json -Depth 12 | Set-Content -Path $jsonPath -Encoding utf8

$htmlPath = Join-Path $runDir 'probe-report.html'
New-PPProbeReport -Probe $probe -OutputPath $htmlPath | Out-Null

Write-Host ''
Write-PPLog -Level OK -Message ("Probe complete in {0}s - {1} API calls." -f $probe.ElapsedSeconds, $probe.CallCount)
Write-Host ''
Write-Host ('  Report : ' + $htmlPath) -ForegroundColor White
Write-Host ('  Raw    : ' + $jsonPath) -ForegroundColor DarkGray
Write-Host ''

foreach ($v in $verdicts) {
    $color = 'Yellow'
    if ($v.Verdict -eq 'Available') { $color = 'Green' }
    elseif ($v.Verdict -eq 'Blocked' -or $v.Verdict -eq 'Unavailable') { $color = 'Red' }
    Write-Host ('  {0,-14} {1}' -f $v.Verdict, $v.Capability) -ForegroundColor $color
}
Write-Host ''

try { Start-Process $htmlPath -ErrorAction SilentlyContinue | Out-Null } catch { }
