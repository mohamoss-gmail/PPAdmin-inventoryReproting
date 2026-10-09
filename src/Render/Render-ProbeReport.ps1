# Render-ProbeReport.ps1 - self-contained HTML output for the Phase 0 probe.
#
# No CDN references, no external fonts, no remote images: enterprise/air-gapped safe and
# emailable as a single file.

# ConvertTo-PPHtmlText, Get-PPVerdictClass and Get-PPRiskCell live in src/Render/PPHtml.ps1,
# shared with the Phase 1 report.

function New-PPProbeReport {
    param(
        [Parameter(Mandatory)]$Probe,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $sb = New-Object System.Text.StringBuilder
    function Add-Html { param($s) [void]$sb.AppendLine($s) }

    $css = @'
<style>
:root{--bg:#fbfbfa;--fg:#1a1a18;--muted:#6b6b66;--line:#e3e3df;--card:#fff;
--ok:#1a7f4b;--okbg:#e8f5ee;--bad:#b3261e;--badbg:#fdeceb;--warn:#8a6100;--warnbg:#fdf3e0;--accent:#2f5fd0;}
@media (prefers-color-scheme:dark){:root{--bg:#16161a;--fg:#e8e8e4;--muted:#9a9a94;--line:#2e2e34;--card:#1e1e23;
--ok:#5ec98d;--okbg:#12291d;--bad:#f08079;--badbg:#2e1614;--warn:#e0b25e;--warnbg:#2c2314;--accent:#7ba0ff;}}
:root[data-theme=dark]{--bg:#16161a;--fg:#e8e8e4;--muted:#9a9a94;--line:#2e2e34;--card:#1e1e23;
--ok:#5ec98d;--okbg:#12291d;--bad:#f08079;--badbg:#2e1614;--warn:#e0b25e;--warnbg:#2c2314;--accent:#7ba0ff;}
:root[data-theme=light]{--bg:#fbfbfa;--fg:#1a1a18;--muted:#6b6b66;--line:#e3e3df;--card:#fff;
--ok:#1a7f4b;--okbg:#e8f5ee;--bad:#b3261e;--badbg:#fdeceb;--warn:#8a6100;--warnbg:#fdf3e0;--accent:#2f5fd0;}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;}
.wrap{max-width:1180px;margin:0 auto;padding:32px 24px 80px}
h1{font-size:26px;margin:0 0 4px;letter-spacing:-.02em}
h2{font-size:18px;margin:38px 0 12px;padding-bottom:7px;border-bottom:1px solid var(--line);letter-spacing:-.01em}
h3{font-size:14px;margin:22px 0 8px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}
p{margin:0 0 12px}
.sub{color:var(--muted);font-size:13.5px}
.meta{display:flex;flex-wrap:wrap;gap:22px;margin:18px 0 6px;padding:14px 18px;background:var(--card);border:1px solid var(--line);border-radius:8px}
.meta div{font-size:13px}.meta b{display:block;color:var(--muted);font-weight:500;font-size:11px;text-transform:uppercase;letter-spacing:.05em;margin-bottom:2px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin:16px 0 8px}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:14px 16px}
.card .n{font-size:26px;font-weight:600;letter-spacing:-.02em}
.card .l{font-size:12px;color:var(--muted);margin-top:2px}
.tw{overflow-x:auto;border:1px solid var(--line);border-radius:8px;background:var(--card);margin:12px 0}
table{border-collapse:collapse;width:100%;font-size:13.5px}
th{text-align:left;font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);padding:10px 12px;border-bottom:1px solid var(--line);white-space:nowrap}
td{padding:9px 12px;border-bottom:1px solid var(--line);vertical-align:top}
tr:last-child td{border-bottom:none}
code{font:12.5px ui-monospace,SFMono-Regular,Consolas,monospace;background:var(--bg);padding:1px 5px;border-radius:4px;border:1px solid var(--line)}
.pill{display:inline-block;padding:2px 9px;border-radius:99px;font-size:11.5px;font-weight:600;white-space:nowrap}
.ok{background:var(--okbg);color:var(--ok)}.bad{background:var(--badbg);color:var(--bad)}
.warn{background:var(--warnbg);color:var(--warn)}.muted{background:var(--line);color:var(--muted)}
.note{background:var(--card);border:1px solid var(--line);border-left:3px solid var(--accent);border-radius:6px;padding:12px 16px;margin:12px 0;font-size:13.5px}
.note.bad{border-left-color:var(--bad)}.note.warn{border-left-color:var(--warn)}.note.ok{border-left-color:var(--ok)}
.banner{background:var(--warnbg);color:var(--warn);border:1px solid var(--warn);border-radius:8px;padding:12px 18px;margin:18px 0;font-size:13.5px;font-weight:500}
details{margin:10px 0}summary{cursor:pointer;font-size:13.5px;color:var(--accent);padding:6px 0}
ul{margin:6px 0 12px;padding-left:20px}li{margin:3px 0;font-size:13.5px}
.dim{color:var(--muted)}
footer{margin-top:60px;padding-top:18px;border-top:1px solid var(--line);color:var(--muted);font-size:12px}
</style>
'@

    Add-Html '<meta name="viewport" content="width=device-width,initial-scale=1">'
    Add-Html ('<title>Power Platform tenant probe - ' + (ConvertTo-PPHtmlText $Probe.TenantId) + '</title>')
    Add-Html $css
    Add-Html '<div class="wrap">'

    # ---------- Header ----------
    Add-Html '<h1>Power Platform tenant &mdash; capability probe</h1>'
    Add-Html '<p class="sub">Phase 0. Establishes what this tenant and this operator actually permit us to collect, before any collector is written. All requests were read-only (GET).</p>'

    Add-Html '<div class="meta">'
    Add-Html ('<div><b>Tenant</b>' + (ConvertTo-PPHtmlText $Probe.TenantId) + '</div>')
    Add-Html ('<div><b>Signed in as</b>' + (ConvertTo-PPHtmlText $Probe.Account) + '</div>')
    Add-Html ('<div><b>Run</b>' + (ConvertTo-PPHtmlText $Probe.StartedUtc) + ' UTC</div>')
    Add-Html ('<div><b>Elapsed</b>' + $Probe.ElapsedSeconds + 's</div>')
    Add-Html ('<div><b>API calls</b>' + $Probe.CallCount + '</div>')
    Add-Html '</div>'

    Add-Html '<div class="banner">CONFIDENTIAL &mdash; this report maps the governance and security posture of the tenant. Treat as sensitive.</div>'

    # ---------- Headline counts ----------
    $envAll   = @($Probe.Environments)
    $envDv    = @($envAll | Where-Object { $_.HasDataverse })
    $dvOk     = @($Probe.Dataverse | Where-Object { $_.Reachable })
    $agentSum = 0
    foreach ($d in $Probe.Dataverse) { if ($d.AgentCount) { $agentSum += $d.AgentCount } }

    Add-Html '<h2>At a glance</h2>'
    Add-Html '<div class="cards">'
    Add-Html ('<div class="card"><div class="n">' + $envAll.Count + '</div><div class="l">Environments</div></div>')
    Add-Html ('<div class="card"><div class="n">' + $envDv.Count + '</div><div class="l">With Dataverse</div></div>')
    Add-Html ('<div class="card"><div class="n">' + $dvOk.Count + ' / ' + @($Probe.Dataverse).Count + '</div><div class="l">Dataverse reachable</div></div>')
    Add-Html ('<div class="card"><div class="n">' + $agentSum + '</div><div class="l">Agents found (sampled)</div></div>')
    Add-Html '</div>'

    # ---------- Verdict ----------
    if ($Probe.Verdicts -and @($Probe.Verdicts).Count -gt 0) {
        Add-Html '<h2>What this tenant will let us collect</h2>'
        Add-Html '<div class="tw"><table><thead><tr><th>Capability</th><th>Verdict</th><th>Consequence for the report</th></tr></thead><tbody>'
        foreach ($v in $Probe.Verdicts) {
            $cls = Get-PPVerdictClass $v.Verdict
            Add-Html ('<tr><td><b>' + (ConvertTo-PPHtmlText $v.Capability) + '</b></td>' +
                      '<td><span class="pill ' + $cls + '">' + (ConvertTo-PPHtmlText $v.Verdict) + '</span></td>' +
                      '<td>' + (ConvertTo-PPHtmlText $v.Consequence) + '</td></tr>')
        }
        Add-Html '</tbody></table></div>'
    }

    # ---------- Auth ----------
    Add-Html '<h2>Authentication</h2>'
    Add-Html '<p class="sub">One interactive sign-in; tokens for every other audience were obtained silently by refresh. A failure here means that entire data source is unavailable.</p>'
    Add-Html '<div class="tw"><table><thead><tr><th>Audience</th><th>Resource</th><th>Token</th><th>Detail</th></tr></thead><tbody>'
    foreach ($a in $Probe.Auth) {
        $cls = 'bad'; $txt = 'Failed'
        if ($a.Success) { $cls = 'ok'; $txt = 'Acquired' }
        Add-Html ('<tr><td>' + (ConvertTo-PPHtmlText $a.Name) + '</td><td><code>' + (ConvertTo-PPHtmlText $a.Resource) +
                  '</code></td><td><span class="pill ' + $cls + '">' + $txt + '</span></td><td class="dim">' +
                  (ConvertTo-PPHtmlText $a.Error) + '</td></tr>')
    }
    Add-Html '</tbody></table></div>'

    # ---------- Platform APIs ----------
    if ($Probe.PlatformApi -and @($Probe.PlatformApi).Count -gt 0) {
        Add-Html '<h2>Core admin APIs (BAP / PowerApps / Flow)</h2>'
        Add-Html '<p class="sub">The backbone surface: environments, apps, flows, DLP, tenant settings. Sampled across the first few environments.</p>'
        Add-Html '<div class="tw"><table><thead><tr><th>Area</th><th>Check</th><th>Result</th><th>HTTP</th><th>Rows</th></tr></thead><tbody>'
        foreach ($r in $Probe.PlatformApi) {
            $cls = 'bad'; $txt = 'Failed'
            if ($r.Success) { $cls = 'ok'; $txt = 'OK' }
            Add-Html ('<tr><td>' + (ConvertTo-PPHtmlText $r.Area) + '</td><td>' + (ConvertTo-PPHtmlText $r.Check) +
                      '</td><td><span class="pill ' + $cls + '">' + $txt + '</span></td><td>' + $r.StatusCode +
                      '</td><td>' + (ConvertTo-PPHtmlText $r.Count) + '</td></tr>')
        }
        Add-Html '</tbody></table></div>'
    }

    # ---------- PPAC candidate routes ----------
    if ($Probe.PPApi -and @($Probe.PPApi).Count -gt 0) {
        Add-Html '<h2>Power Platform API &mdash; candidate routes</h2>'
        Add-Html '<div class="note">These routes were <b>probed, not assumed</b>. Backups, disaster recovery, environment groups and agent consumption are the areas the design flags as uncertain; this table is the authoritative answer for this tenant. Confidence <code>B</code> = documented but version-sensitive, <code>C</code> = unverified guess.</div>'
        Add-Html '<div class="tw"><table><thead><tr><th>Area</th><th>Route</th><th>Conf.</th><th>Verdict</th><th>HTTP</th><th>Working api-version</th></tr></thead><tbody>'
        foreach ($r in $Probe.PPApi) {
            $cls = Get-PPVerdictClass $r.Verdict
            Add-Html ('<tr><td>' + (ConvertTo-PPHtmlText $r.Area) + '</td><td>' + (ConvertTo-PPHtmlText $r.Name) +
                      '<div class="dim" style="font-size:11.5px">' + (ConvertTo-PPHtmlText $r.Why) + '</div></td>' +
                      '<td><span class="pill muted">' + $r.Confidence + '</span></td>' +
                      '<td><span class="pill ' + $cls + '">' + (ConvertTo-PPHtmlText $r.Verdict) + '</span></td>' +
                      '<td>' + $r.StatusCode + '</td><td><code>' + (ConvertTo-PPHtmlText $r.WorkingVersion) + '</code></td></tr>')
        }
        Add-Html '</tbody></table></div>'
    }

    # ---------- Dataverse matrix ----------
    if ($Probe.Dataverse -and @($Probe.Dataverse).Count -gt 0) {
        Add-Html '<h2>Dataverse access per environment</h2>'
        Add-Html '<p class="sub">A Power Platform Administrator is not automatically a Dataverse user in every environment. Any environment denied here is a hole in the final report and must be surfaced there, never silently skipped.</p>'

        Add-Html '<div class="tw"><table><thead><tr><th>Environment</th><th>SKU</th><th>Access</th><th>Agents</th><th>Transcripts</th><th>Observed retention</th></tr></thead><tbody>'
        foreach ($d in $Probe.Dataverse) {
            $accCls = 'bad'; $accTxt = 'Denied'
            if ($d.Reachable) { $accCls = 'ok'; $accTxt = 'Reachable' }
            elseif (-not $d.TokenAcquired) { $accTxt = 'No token' }

            $trCls = Get-PPVerdictClass $d.TranscriptAccess
            $ret = '&mdash;'
            if ($null -ne $d.ObservedRetentionDays) { $ret = "$($d.ObservedRetentionDays) days" }

            Add-Html ('<tr><td><b>' + (ConvertTo-PPHtmlText $d.Environment) + '</b><div class="dim" style="font-size:11.5px">' +
                      (ConvertTo-PPHtmlText $d.OrgUrl) + '</div></td>' +
                      '<td>' + (ConvertTo-PPHtmlText $d.Sku) + '</td>' +
                      '<td><span class="pill ' + $accCls + '">' + $accTxt + '</span></td>' +
                      '<td>' + (ConvertTo-PPHtmlText $d.AgentCount) + '</td>' +
                      '<td><span class="pill ' + $trCls + '">' + (ConvertTo-PPHtmlText $d.TranscriptAccess) + '</span></td>' +
                      '<td>' + $ret + '</td></tr>')
        }
        Add-Html '</tbody></table></div>'

        # Table-level matrix
        $reach = @($Probe.Dataverse | Where-Object { $_.Reachable })
        if ($reach.Count -gt 0) {
            Add-Html '<h3>Table-level readability</h3>'
            $tableNames = @($reach[0].Tables | ForEach-Object { $_.Table })
            Add-Html '<div class="tw"><table><thead><tr><th>Environment</th>'
            foreach ($tn in $tableNames) { Add-Html ('<th>' + (ConvertTo-PPHtmlText $tn) + '</th>') }
            Add-Html '</tr></thead><tbody>'
            foreach ($d in $reach) {
                Add-Html ('<tr><td>' + (ConvertTo-PPHtmlText $d.Environment) + '</td>')
                foreach ($tn in $tableNames) {
                    $t = $d.Tables | Where-Object { $_.Table -eq $tn } | Select-Object -First 1
                    $mark = '&mdash;'; $cls = 'muted'
                    if ($t -and $t.Success) { $mark = 'yes'; $cls = 'ok' }
                    elseif ($t) { $mark = [string]$t.StatusCode; $cls = 'bad' }
                    Add-Html ('<td><span class="pill ' + $cls + '">' + $mark + '</span></td>')
                }
                Add-Html '</tr>'
            }
            Add-Html '</tbody></table></div>'
        }

        # Agent findings preview
        $withAgents = @($Probe.Dataverse | Where-Object { $_.AgentStats -and $_.AgentStats.Total -gt 0 })
        if ($withAgents.Count -gt 0) {
            Add-Html '<h2>Copilot Studio agents &mdash; findings preview</h2>'
            Add-Html '<p class="sub">Derived from the <code>bot</code> table. <code>accesscontrolpolicy</code> 0 = Any (anonymous), 3 = Any (multi-tenant); <code>authenticationmode</code> 1 = None; <code>statuscode</code> 4 = ProvisionFailed, 5 = MissingLicense.</p>'
            Add-Html '<div class="tw"><table><thead><tr><th>Environment</th><th>Total</th><th>Published</th><th>Never published</th><th>Anonymous access</th><th>Cross-tenant</th><th>No auth</th><th>Missing licence</th><th>Unmanaged</th></tr></thead><tbody>'
            foreach ($d in $withAgents) {
                $s = $d.AgentStats
                Add-Html ('<tr><td>' + (ConvertTo-PPHtmlText $d.Environment) + '</td><td>' + $s.Total + '</td><td>' + $s.Published +
                          '</td><td>' + (Get-PPRiskCell $s.NeverPublished) + '</td><td>' + (Get-PPRiskCell $s.AnonymousAccess) +
                          '</td><td>' + (Get-PPRiskCell $s.CrossTenant) + '</td><td>' + (Get-PPRiskCell $s.NoAuth) +
                          '</td><td>' + (Get-PPRiskCell $s.MissingLicense) + '</td><td>' + (Get-PPRiskCell $s.Unmanaged) + '</td></tr>')
            }
            Add-Html '</tbody></table></div>'
        }

        # Per-environment notes
        $notes = @($Probe.Dataverse | Where-Object { $_.Notes -and @($_.Notes).Count -gt 0 })
        if ($notes.Count -gt 0) {
            Add-Html '<h3>Environment notes</h3>'
            foreach ($d in $notes) {
                Add-Html ('<div class="note warn"><b>' + (ConvertTo-PPHtmlText $d.Environment) + '</b><ul>')
                foreach ($n in $d.Notes) { Add-Html ('<li>' + (ConvertTo-PPHtmlText $n) + '</li>') }
                Add-Html '</ul></div>'
            }
        }
    }

    # ---------- Graph ----------
    if ($Probe.Graph -and @($Probe.Graph).Count -gt 0) {
        Add-Html '<h2>Microsoft Graph</h2>'
        Add-Html '<p class="sub">Without Graph, every owner in the report stays a bare GUID and orphaned-asset detection is impossible.</p>'
        Add-Html '<div class="tw"><table><thead><tr><th>Check</th><th>Verdict</th><th>HTTP</th><th>Needed for</th></tr></thead><tbody>'
        foreach ($g in $Probe.Graph) {
            $cls = Get-PPVerdictClass $g.Verdict
            Add-Html ('<tr><td>' + (ConvertTo-PPHtmlText $g.Name) + '</td><td><span class="pill ' + $cls + '">' +
                      (ConvertTo-PPHtmlText $g.Verdict) + '</span></td><td>' + $g.StatusCode + '</td><td class="dim">' +
                      (ConvertTo-PPHtmlText $g.NeededFor) + '</td></tr>')
        }
        Add-Html '</tbody></table></div>'
    }

    # ---------- Audit ----------
    if ($Probe.Audit) {
        Add-Html '<h2>Usage telemetry (unified audit log)</h2>'
        $cls = 'warn'
        if ($Probe.Audit.ModuleInstalled) { $cls = 'ok' }
        Add-Html ('<div class="note ' + $cls + '"><b>' + (ConvertTo-PPHtmlText $Probe.Audit.Verdict) + '</b><ul>')
        foreach ($n in $Probe.Audit.Notes) { Add-Html ('<li>' + (ConvertTo-PPHtmlText $n) + '</li>') }
        Add-Html '</ul></div>'
        Add-Html '<p class="sub">App launch counts, MAU and last-used dates come only from here. If this stays unavailable, "we have no usage data" is itself a governance finding worth reporting.</p>'
    }

    # ---------- Next steps ----------
    if ($Probe.NextSteps -and @($Probe.NextSteps).Count -gt 0) {
        Add-Html '<h2>Recommended next steps</h2><ul>'
        foreach ($s in $Probe.NextSteps) { Add-Html ('<li>' + (ConvertTo-PPHtmlText $s) + '</li>') }
        Add-Html '</ul>'
    }

    # ---------- Call log ----------
    Add-Html '<h2>Collection integrity</h2>'
    Add-Html ('<p class="sub">Every HTTP request issued during this run. All were GET; the client refuses any other verb. Provided so a security team can verify exactly what was touched.</p>')
    Add-Html ('<details><summary>Show all ' + $Probe.CallCount + ' calls</summary><div class="tw"><table><thead><tr><th>Label</th><th>Method</th><th>HTTP</th><th>ms</th><th>URI</th></tr></thead><tbody>')
    foreach ($c in $Probe.Calls) {
        $cls = 'ok'
        if (-not $c.Success) { $cls = 'bad' }
        Add-Html ('<tr><td>' + (ConvertTo-PPHtmlText $c.Label) + '</td><td>' + $c.Method +
                  '</td><td><span class="pill ' + $cls + '">' + $c.StatusCode + '</span></td><td>' + $c.DurationMs +
                  '</td><td class="dim" style="font-size:11.5px;word-break:break-all">' + (ConvertTo-PPHtmlText $c.Uri) + '</td></tr>')
    }
    Add-Html '</tbody></table></div></details>'

    Add-Html ('<footer>Generated ' + (ConvertTo-PPHtmlText $Probe.StartedUtc) + ' UTC &middot; read-only probe &middot; Power Platform tenant reporting tool, Phase 0</footer>')
    Add-Html '</div>'

    $dir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -Path $OutputPath -Value $sb.ToString() -Encoding utf8

    return $OutputPath
}
