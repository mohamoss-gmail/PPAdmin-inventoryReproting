<#
.SYNOPSIS
    Offline tests for the Phase 0 probe. No tenant, no network, no credentials required.

.DESCRIPTION
    Covers the two things worth guaranteeing before this is ever pointed at a production
    tenant:
      1. The read-only promise actually holds at the code level.
      2. The renderer produces a valid, self-contained report from representative data,
         including the degraded paths (denied environments, missing transcripts).
#>

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

. (Join-Path $root 'src\Core\PPLog.ps1')
. (Join-Path $root 'src\Core\PPHttp.ps1')
. (Join-Path $root 'src\Core\PPAuth.ps1')
. (Join-Path $root 'src\Core\PPDataverse.ps1')
. (Join-Path $root 'src\Render\PPHtml.ps1')
. (Join-Path $root 'src\Render\Render-ProbeReport.ps1')
. (Join-Path $root 'src\Analyze\Invoke-PPFindings.ps1')

$pass = 0; $fail = 0
function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail)
    if ($Condition) {
        $script:pass++
        Write-Host ("  PASS  " + $Name) -ForegroundColor Green
    } else {
        $script:fail++
        Write-Host ("  FAIL  " + $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ("        " + $Detail) -ForegroundColor DarkGray }
    }
}

Write-Host ''
Write-Host '  Read-only guarantee' -ForegroundColor White

# 1. Non-read verbs must be rejected before any socket is opened.
foreach ($verb in @('POST','PUT','PATCH','DELETE')) {
    $threw = $false
    try {
        Invoke-PPRequest -Uri 'https://example.invalid/x' -Method $verb -ErrorAction Stop | Out-Null
    } catch {
        $threw = $true
    }
    Assert-True "$verb is refused" $threw 'Expected a parameter-binding or explicit throw.'
}

# 2. No source file may issue a mutating HTTP call against a tenant. The auth module is the
#    single legitimate exception: it POSTs to login.microsoftonline.com for tokens, which is
#    credential exchange, not tenant data.
$srcFiles = Get-ChildItem -Path (Join-Path $root 'src') -Filter *.ps1 -Recurse
$offenders = @()
foreach ($f in $srcFiles) {
    $text = Get-Content $f.FullName -Raw
    if ($text -match "Method\s+Post|Method\s+Put|Method\s+Patch|Method\s+Delete|-Method\s+'?(POST|PUT|PATCH|DELETE)'?") {
        if ($f.Name -ne 'PPAuth.ps1') { $offenders += $f.Name }
    }
}
Assert-True 'No mutating verbs outside PPAuth' ($offenders.Count -eq 0) ("Offenders: " + ($offenders -join ', '))

$authText = Get-Content (Join-Path $root 'src\Core\PPAuth.ps1') -Raw
$authPosts = [regex]::Matches($authText, 'Invoke-RestMethod[^\r\n]*-Method Post')
$allToLogin = $true
foreach ($m in $authPosts) {
    # Each POST in PPAuth must target a login endpoint variable, never a tenant API.
    if ($m.Value -notmatch '\$deviceUri|\$tokenUri') { $allToLogin = $false }
}
Assert-True 'PPAuth POSTs only to login endpoints' $allToLogin

Write-Host ''
Write-Host '  Helpers' -ForegroundColor White

Assert-True 'HTML escaping neutralises tags' `
    ((ConvertTo-PPHtmlText '<script>x&y"') -eq '&lt;script&gt;x&amp;y&quot;')
Assert-True 'HTML escaping tolerates null' ((ConvertTo-PPHtmlText $null) -eq '')
Assert-True 'Verdict class: Available -> ok'    ((Get-PPVerdictClass 'Available') -eq 'ok')
Assert-True 'Verdict class: Blocked -> bad'     ((Get-PPVerdictClass 'Blocked (role)') -eq 'bad')
Assert-True 'Verdict class: Not found -> muted' ((Get-PPVerdictClass 'Not found') -eq 'muted')
Assert-True 'Risk cell highlights non-zero'     ((Get-PPRiskCell 3) -match 'pill bad')
Assert-True 'Risk cell dims zero'               ((Get-PPRiskCell 0) -match 'dim')

# JWT parsing against a hand-built unsigned token.
$claims = '{"upn":"admin@contoso.com","tid":"11111111-2222-3333-4444-555555555555"}'
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_')
$parsed = Read-PPJwtClaims -Token "header.$b64.signature"
Assert-True 'JWT claims parse (upn)' ($parsed -and $parsed.upn -eq 'admin@contoso.com')
Assert-True 'JWT claims parse (tid)' ($parsed -and $parsed.tid -eq '11111111-2222-3333-4444-555555555555')
Assert-True 'JWT parser survives garbage' ($null -eq (Read-PPJwtClaims -Token 'not-a-token'))

Write-Host ''
Write-Host '  Report rendering' -ForegroundColor White

# Representative fixture, deliberately including degraded paths: one environment denied,
# one developer environment with no transcripts, one healthy environment with risky agents.
$fixture = [PSCustomObject]@{
    TenantId = '11111111-2222-3333-4444-555555555555'
    Account  = 'admin@contoso.com'
    StartedUtc = '2026-08-06 09:00:00'
    ElapsedSeconds = 214
    PSVersion = '5.1'
    AdminModule = [PSCustomObject]@{ Installed = $true; Version = '2.0.217' }
    Auth = @(
        [PSCustomObject]@{ Name='BAP'; Resource='https://api.bap.microsoft.com/'; Success=$true; Error=$null },
        [PSCustomObject]@{ Name='Power Platform API'; Resource='https://api.powerplatform.com/'; Success=$false; Error='AADSTS500011: resource principal not found' }
    )
    Environments = @(
        [PSCustomObject]@{ Name='env-1'; DisplayName='Contoso (default)'; HasDataverse=$true; Sku='Default' },
        [PSCustomObject]@{ Name='env-2'; DisplayName='HR Production';     HasDataverse=$true; Sku='Production' },
        [PSCustomObject]@{ Name='env-3'; DisplayName='Dev sandbox';       HasDataverse=$true; Sku='Developer' }
    )
    PlatformApi = @(
        [PSCustomObject]@{ Area='Tenant'; Check='Tenant settings'; Success=$true;  StatusCode=200; Count=$null; Error=$null; Uri='x' },
        [PSCustomObject]@{ Area='Governance'; Check='DLP policies (v1)'; Success=$true; StatusCode=200; Count=4; Error=$null; Uri='x' }
    )
    PPApi = @(
        [PSCustomObject]@{ Area='Backups'; Name='List backups'; Path='/x'; Confidence='B'; Why='Core DR evidence'; Verdict='Available'; StatusCode=200; WorkingVersion='2023-06-01'; Count=12; Environment='HR Production'; Error=$null },
        [PSCustomObject]@{ Area='DR'; Name='Disaster recovery config'; Path='/y'; Confidence='C'; Why='Least certain route'; Verdict='Not found'; StatusCode=404; WorkingVersion=$null; Count=$null; Environment='HR Production'; Error='NotFound' }
    )
    Dataverse = @(
        [PSCustomObject]@{
            Environment='HR Production'; EnvironmentId='env-2'; OrgUrl='https://hr.crm4.dynamics.com'
            Sku='Production'; TokenAcquired=$true; Reachable=$true; WhoAmIUserId='u1'; AccessError=$null
            Tables=@(
                [PSCustomObject]@{ Table='bots'; Verdict='Readable'; StatusCode=200; Success=$true; Error=$null },
                [PSCustomObject]@{ Table='solutions'; Verdict='Readable'; StatusCode=200; Success=$true; Error=$null }
            )
            AgentCount=7
            AgentStats=[PSCustomObject]@{ Total=7; Published=5; NeverPublished=2; AnonymousAccess=3; CrossTenant=1; NoAuth=2; MissingLicense=1; ProvisionFailed=0; Unmanaged=4; Inactive=0 }
            TranscriptAccess='Readable'; TranscriptCount=1840; OldestTranscript='2026-07-08T00:00:00Z'
            ObservedRetentionDays=29; RetentionJob=$null
            Notes=@('Transcript history is ~29 days - default 30-day purge appears active.')
        },
        [PSCustomObject]@{
            Environment='Dev sandbox'; EnvironmentId='env-3'; OrgUrl='https://dev.crm4.dynamics.com'
            Sku='Developer'; TokenAcquired=$true; Reachable=$true; WhoAmIUserId='u1'; AccessError=$null
            Tables=@(
                [PSCustomObject]@{ Table='bots'; Verdict='Readable'; StatusCode=200; Success=$true; Error=$null },
                [PSCustomObject]@{ Table='solutions'; Verdict='Readable'; StatusCode=200; Success=$true; Error=$null }
            )
            AgentCount=2; AgentStats=$null
            TranscriptAccess='Table not present'; TranscriptCount=$null; OldestTranscript=$null
            ObservedRetentionDays=$null; RetentionJob=$null
            Notes=@('Developer environment - transcripts are never written here by design. Usage is UNKNOWN, not zero.')
        },
        [PSCustomObject]@{
            Environment='Contoso (default)'; EnvironmentId='env-1'; OrgUrl='https://contoso.crm4.dynamics.com'
            Sku='Default'; TokenAcquired=$true; Reachable=$false; WhoAmIUserId=$null; AccessError='HTTP 403'
            Tables=@(); AgentCount=$null; AgentStats=$null
            TranscriptAccess='Not probed'; TranscriptCount=$null; OldestTranscript=$null
            ObservedRetentionDays=$null; RetentionJob=$null
            Notes=@('Admin has no Dataverse security role in this environment.')
        }
    )
    Graph = @(
        [PSCustomObject]@{ Name='Directory users'; Verdict='Available'; StatusCode=200; Count=1; NeededFor='resolve owners'; Error=$null },
        [PSCustomObject]@{ Name='Service principals'; Verdict='Insufficient consent'; StatusCode=403; Count=$null; NeededFor='S2S app users'; Error='Authorization_RequestDenied' }
    )
    Audit = [PSCustomObject]@{ ModuleInstalled=$false; ModuleVersion=$null; Verdict='Module missing'; Notes=@('Install ExchangeOnlineManagement','Requires View-Only Audit Logs role') }
    Verdicts = @(
        [PSCustomObject]@{ Capability='Environment inventory'; Verdict='Available'; Consequence='Pages 01-08 viable.' },
        [PSCustomObject]@{ Capability='Dataverse depth'; Verdict='Partial'; Consequence='2 of 3 environments reachable.' },
        [PSCustomObject]@{ Capability='Agent usage telemetry'; Verdict='Available'; Consequence='29 days of history only.' }
    )
    NextSteps = @('Grant Bot Transcript Viewer in agent environments.', 'Install ExchangeOnlineManagement.')
    Calls = @(
        [PSCustomObject]@{ Label='bap:environments'; Uri='https://api.bap.microsoft.com/x'; Method='GET'; StatusCode=200; Success=$true; DurationMs=412; Attempts=1; Error=$null; Timestamp='t' },
        [PSCustomObject]@{ Label='dv:whoami:env-1'; Uri='https://contoso.crm4.dynamics.com/api/data/v9.2/WhoAmI'; Method='GET'; StatusCode=403; Success=$false; DurationMs=201; Attempts=1; Error='Forbidden'; Timestamp='t' }
    )
    CallCount = 2
}

$out = Join-Path $env:TEMP 'pp-probe-test-report.html'
$null = New-PPProbeReport -Probe $fixture -OutputPath $out

Assert-True 'Report file written' (Test-Path $out)
$html = Get-Content $out -Raw
Assert-True 'Report is non-trivial'          ($html.Length -gt 6000) ("Length: " + $html.Length)
Assert-True 'No external resource references' ($html -notmatch 'src\s*=\s*"https?://|href\s*=\s*"https?://|@import')
Assert-True 'Dark mode styling present'       ($html -match 'prefers-color-scheme:dark')
Assert-True 'Denied environment surfaced'     ($html -match 'no Dataverse security role')
Assert-True 'Developer env caveat surfaced'   ($html -match 'UNKNOWN, not zero')
Assert-True 'Retention reported'              ($html -match '29 days')
Assert-True 'Risky agents highlighted'        ($html -match 'Anonymous access')
Assert-True 'Uncertain route marked'          ($html -match 'Not found')
Assert-True 'Confidentiality banner present'  ($html -match 'CONFIDENTIAL')
Assert-True 'Call log included'               ($html -match 'Collection integrity')

Write-Host ''
if ($fail -eq 0) {
    Write-Host ("  $pass passed, 0 failed") -ForegroundColor Green
} else {
    Write-Host ("  $pass passed, $fail FAILED") -ForegroundColor Red
}
Write-Host ("  Sample report: " + $out) -ForegroundColor DarkGray
Write-Host ''
exit $(if ($fail -gt 0) { 1 } else { 0 })
