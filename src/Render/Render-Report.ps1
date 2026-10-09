# Render-Report.ps1 - the Phase 1 multi-page report.
#
# Pages are written as separate files with a shared nav so a large tenant does not produce one
# unusable megabyte-scale document. index.html carries the executive summary and the full risk
# register, because that is what an admin actually opens first.

function Get-PPNav {
    return @(
        [PSCustomObject]@{ Key='index';    Label='Summary';      File='index.html' },
        [PSCustomObject]@{ Key='findings'; Label='Findings';     File='findings.html' },
        [PSCustomObject]@{ Key='envs';     Label='Environments'; File='environments.html' },
        [PSCustomObject]@{ Key='agents';   Label='Agents';       File='agents.html' },
        [PSCustomObject]@{ Key='apps';     Label='Apps';         File='apps.html' },
        [PSCustomObject]@{ Key='flows';    Label='Flows';        File='flows.html' },
        [PSCustomObject]@{ Key='conns';    Label='Connections';  File='connections.html' },
        [PSCustomObject]@{ Key='security'; Label='Security';     File='security.html' },
        [PSCustomObject]@{ Key='dlp';      Label='DLP';          File='dlp.html' },
        [PSCustomObject]@{ Key='usage';    Label='Usage & credits'; File='usage.html' },
        [PSCustomObject]@{ Key='billing';  Label='Billing';      File='billing.html' },
        [PSCustomObject]@{ Key='integrity';Label='Integrity';    File='integrity.html' }
    )
}

function New-PPFindingCard {
    param($Finding)
    $cls = Get-PPSeverityClass $Finding.Severity
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<div class="finding ' + $cls + '">')
    [void]$sb.AppendLine('<h4><span class="pill ' + $cls + '">' + $Finding.Severity + '</span> ' +
                         (ConvertTo-PPHtmlText $Finding.Title) + '</h4>')
    $loc = @()
    if ($Finding.Environment) { $loc += 'Environment: ' + $Finding.Environment }
    if ($Finding.Asset -and $Finding.Asset -ne $Finding.Environment) { $loc += 'Asset: ' + $Finding.Asset }
    $loc += 'Rule: ' + $Finding.Rule
    [void]$sb.AppendLine('<div class="loc">' + (ConvertTo-PPHtmlText ($loc -join '  &middot;  ')) + '</div>')
    if ($Finding.Evidence)    { [void]$sb.AppendLine('<div class="ev">' + (ConvertTo-PPHtmlText $Finding.Evidence) + '</div>') }
    if ($Finding.Why)         { [void]$sb.AppendLine('<div class="why">' + (ConvertTo-PPHtmlText $Finding.Why) + '</div>') }
    if ($Finding.Remediation) { [void]$sb.AppendLine('<div class="fix"><b>Fix:</b> ' + (ConvertTo-PPHtmlText $Finding.Remediation) + '</div>') }
    [void]$sb.AppendLine('</div>')
    return $sb.ToString()
}

function New-PPReport {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)]$Findings,
        [Parameter(Mandatory)][string]$OutputDir
    )

    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
    $nav  = Get-PPNav
    $gen  = $Data.Meta.StartedUtc
    $summary = Get-PPFindingSummary -Findings $Findings

    function Write-Page {
        param($Key, $Title, $Subtitle, $Body)
        $file = (@($nav | Where-Object { $_.Key -eq $Key })[0]).File
        $html = New-PPPageShell -Title $Title -Subtitle $Subtitle -Body $Body -Nav $nav `
                                -Current $Key -GeneratedUtc $gen
        Set-Content -Path (Join-Path $OutputDir $file) -Value $html -Encoding utf8
    }

    # ---------------- index ----------------
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<div class="meta">')
    [void]$sb.AppendLine('<div><b>Tenant</b>' + (ConvertTo-PPHtmlText $Data.Meta.TenantId) + '</div>')
    [void]$sb.AppendLine('<div><b>Collected by</b>' + (ConvertTo-PPHtmlText $Data.Meta.Account) + '</div>')
    [void]$sb.AppendLine('<div><b>Run</b>' + (ConvertTo-PPHtmlText $gen) + ' UTC</div>')
    [void]$sb.AppendLine('<div><b>Duration</b>' + $Data.Meta.ElapsedSeconds + 's</div>')
    [void]$sb.AppendLine('<div><b>API calls</b>' + $Data.Meta.CallCount + '</div>')
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('<div class="banner">CONFIDENTIAL &mdash; this report maps the governance and security posture of the tenant.</div>')

    [void]$sb.AppendLine('<h2>Risk register</h2>')
    [void]$sb.AppendLine('<div class="cards">')
    foreach ($sev in @('Critical','High','Medium','Low','Info')) {
        $cls = Get-PPSeverityClass $sev
        [void]$sb.AppendLine('<div class="card sev ' + $cls + '"><div class="n">' + $summary[$sev] +
                             '</div><div class="l">' + $sev + '</div></div>')
    }
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine('<h2>Inventory</h2><div class="cards">')
    $counts = @(
        @{ N = @($Data.Environments).Count; L = 'Environments' },
        @{ N = @($Data.Apps).Count;         L = 'Apps' },
        @{ N = @($Data.Flows).Count;        L = 'Flows' },
        @{ N = @($Data.Agents).Count;       L = 'Agents' },
        @{ N = @($Data.Connections).Count;  L = 'Connections' },
        @{ N = @($Data.Tenant.DlpPolicies).Count; L = 'DLP policies' }
    )
    foreach ($c in $counts) {
        [void]$sb.AppendLine('<div class="card"><div class="n">' + $c.N + '</div><div class="l">' + $c.L + '</div></div>')
    }
    [void]$sb.AppendLine('</div>')

    # Credit headroom on the summary page, because the tightest meter is the thing most likely
    # to interrupt users, and an admin should not have to open a second page to learn it.
    if ($Data.Usage) {
        $tight = @($Data.Usage.CurrencyReports | Where-Object { $null -ne $_.PctConsumed } | Sort-Object PctConsumed -Descending)
        if ($tight.Count -gt 0) {
            [void]$sb.AppendLine('<h2>Credit headroom</h2>')
            [void]$sb.AppendLine('<p class="sub">Tightest meters first, over the ' + $Data.Usage.WindowDays +
                                 '-day window. Figures are daily aggregates and lag, so each is a floor. ' +
                                 'Full breakdown on the Usage &amp; credits page.</p>')
            [void]$sb.AppendLine('<div class="cards">')
            foreach ($m in @($tight | Select-Object -First 4)) {
                $cls = 'sev'
                if ($m.PctConsumed -ge 100)    { $cls = 'sev crit' }
                elseif ($m.PctConsumed -ge 90) { $cls = 'sev bad' }
                elseif ($m.PctConsumed -ge 75) { $cls = 'sev warn' }
                [void]$sb.AppendLine('<div class="card ' + $cls + '"><div class="n">' + $m.PctConsumed +
                                     '%</div><div class="l">' + (ConvertTo-PPHtmlText $m.Label) + '</div></div>')
            }
            [void]$sb.AppendLine('</div>')
        }
        if (@($Data.Usage.Gaps).Count -gt 0) {
            [void]$sb.AppendLine('<div class="note warn">' + @($Data.Usage.Gaps).Count +
                                 ' usage dataset(s) could not be read, so the cost picture in this report is ' +
                                 'incomplete. What is missing is listed on the Usage &amp; credits page and on Integrity.</div>')
        }
    }

    $top = @($Findings | Where-Object { $_.Severity -eq 'Critical' -or $_.Severity -eq 'High' } | Select-Object -First 10)
    if ($top.Count -gt 0) {
        [void]$sb.AppendLine('<h2>Most severe findings</h2>')
        [void]$sb.AppendLine('<p class="sub">Top ' + $top.Count + ' of ' + @($Findings).Count + '. Full register on the Findings page.</p>')
        foreach ($x in $top) { [void]$sb.AppendLine((New-PPFindingCard $x)) }
    } elseif (@($Findings).Count -eq 0) {
        [void]$sb.AppendLine('<div class="note">No findings were raised. Check the Integrity page before treating that as a clean bill of health &mdash; a collector that could not read a source produces no findings from it.</div>')
    }

    Write-Page 'index' 'Power Platform tenant report' 'Executive summary and risk register.' $sb.ToString()

    # ---------------- findings ----------------
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<input class="filter" data-target="findings-list" placeholder="Filter findings...">')
    [void]$sb.AppendLine('<div id="findings-list">')
    if (@($Findings).Count -eq 0) {
        [void]$sb.AppendLine('<div class="note dim">No findings.</div>')
    }
    foreach ($x in $Findings) { [void]$sb.AppendLine((New-PPFindingCard $x)) }
    [void]$sb.AppendLine('</div>')
    Write-Page 'findings' 'Findings' ("$(@($Findings).Count) finding(s), most severe first. Every finding cites the record that produced it.") $sb.ToString()

    # ---------------- environments ----------------
    $cols = @(
        @{ H='Environment'; F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.DisplayName) + '</b>' + $(if($r.IsDefault){' <span class="pill info">default</span>'}else{''}) } },
        @{ H='SKU';     P='Sku' },
        @{ H='Region';  P='Region' },
        @{ H='State';   P='State' },
        @{ H='Dataverse'; F={ param($r) if($r.HasDataverse){'<span class="pill ok">yes</span>'}else{'<span class="pill muted">no</span>'} } },
        @{ H='Version'; P='OrgVersion' },
        @{ H='Security group'; F={ param($r) if($r.SecurityGroupId){'<span class="pill ok">set</span>'}else{'<span class="pill warn">none</span>'} } },
        @{ H='Backups'; F={ param($r)
            if ($r.BackupStatus -ne 'Collected') { return '<span class="pill muted">' + (ConvertTo-PPHtmlText $r.BackupStatus) + '</span>' }
            if ($r.BackupCount -gt 0) { return '<span class="pill ok">' + $r.BackupCount + '</span>' }
            return '<span class="pill bad">0</span>' } },
        @{ H='Latest backup'; P='LatestBackup' },
        @{ H='DR'; F={ param($r) '<span class="pill muted">unknown</span>' } },
        @{ H='Created'; P='CreatedTime' }
    )
    $body = '<div class="note">Disaster recovery shows as <b>unknown</b> throughout: the candidate API did not resolve during capability probing. That is an absence of evidence, not evidence that DR is unconfigured.</div>'
    $body += (New-PPTable -Rows $Data.Environments -Columns $cols -EmptyMessage 'No environments collected.')
    Write-Page 'envs' 'Environments' ("$(@($Data.Environments).Count) environment(s).") $body

    # ---------------- agents ----------------
    $cols = @(
        @{ H='Agent';       F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.Name) + '</b>' } },
        @{ H='Environment'; P='EnvironmentName' },
        @{ H='State';       P='State' },
        @{ H='Status';      F={ param($r) $c = if($r.StatusCode -eq 1){'ok'}else{'bad'}; '<span class="pill ' + $c + '">' + (ConvertTo-PPHtmlText $r.Status) + '</span>' } },
        @{ H='Access policy'; F={ param($r) $c = if($r.AccessPolicyCode -eq 0 -or $r.AccessPolicyCode -eq 3){'bad'}else{'ok'}; '<span class="pill ' + $c + '">' + (ConvertTo-PPHtmlText $r.AccessPolicy) + '</span>' } },
        @{ H='Auth';        F={ param($r) $c = if($r.AuthModeCode -eq 1){'bad'}else{'ok'}; '<span class="pill ' + $c + '">' + (ConvertTo-PPHtmlText $r.AuthMode) + '</span>' } },
        @{ H='Published';   F={ param($r) if($r.IsPublished){'<span class="pill ok">yes</span>'}else{'<span class="pill warn">never</span>'} } },
        @{ H='Autonomous';  F={ param($r) if($r.IsAutonomous){'<span class="pill warn">yes</span>'}else{'<span class="dim">no</span>'} } },
        @{ H='Generative';  F={ param($r) if($r.GenerativeOrch){'yes'}else{'<span class="dim">no</span>'} } },
        @{ H='Model knowledge'; F={ param($r) if($r.UsesModelKnowledge){'<span class="pill warn">yes</span>'}else{'<span class="dim">no</span>'} } },
        @{ H='Managed';     F={ param($r) if($r.IsManaged){'yes'}else{'<span class="pill warn">unmanaged</span>'} } },
        @{ H='Modified';    P='ModifiedOn' }
    )
    $body = '<input class="filter" data-target="agents-tbl" placeholder="Filter agents...">'
    $body += (New-PPTable -Rows $Data.Agents -Columns $cols -Id 'agents-tbl' -EmptyMessage 'No agents found, or Dataverse was unreadable. Check the Integrity page.')
    Write-Page 'agents' 'Copilot Studio agents' ("$(@($Data.Agents).Count) agent(s). Column semantics follow the Copilot Studio Kit's published Agent Details rules.") $body

    # ---------------- apps ----------------
    $cols = @(
        @{ H='App';         F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.DisplayName) + '</b>' } },
        @{ H='Environment'; P='EnvironmentName' },
        @{ H='Owner';       P='OwnerName' },
        @{ H='Shared with tenant'; F={ param($r) if($r.SharedWithTenant){'<span class="pill bad">yes</span>'}else{'<span class="dim">no</span>'} } },
        @{ H='Shared users'; P='SharedUsers' },
        @{ H='Created';     P='CreatedTime' },
        @{ H='Modified';    P='LastModified' }
    )
    $body = '<input class="filter" data-target="apps-tbl" placeholder="Filter apps...">'
    $body += (New-PPTable -Rows $Data.Apps -Columns $cols -Id 'apps-tbl' -EmptyMessage 'No apps collected.')
    Write-Page 'apps' 'Apps' ("$(@($Data.Apps).Count) app(s).") $body

    # ---------------- flows ----------------
    $cols = @(
        @{ H='Flow';        F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.DisplayName) + '</b>' } },
        @{ H='Environment'; P='EnvironmentName' },
        @{ H='State';       F={ param($r) $c = switch($r.State){ 'Started'{'ok'} 'Suspended'{'bad'} default{'muted'} }; '<span class="pill ' + $c + '">' + (ConvertTo-PPHtmlText $r.State) + '</span>' } },
        @{ H='Trigger';     P='TriggerType' },
        @{ H='Actions';     P='ActionCount' },
        @{ H='Created';     P='CreatedTime' },
        @{ H='Modified';    P='LastModified' }
    )
    $body = '<input class="filter" data-target="flows-tbl" placeholder="Filter flows...">'
    $body += (New-PPTable -Rows $Data.Flows -Columns $cols -Id 'flows-tbl' -EmptyMessage 'No flows collected.')
    Write-Page 'flows' 'Flows' ("$(@($Data.Flows).Count) flow(s). Collected via the List Flows as Admin V2 API; V1 was retired in 2023.") $body

    # ---------------- connections ----------------
    $cols = @(
        @{ H='Connection';  F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.DisplayName) + '</b>' } },
        @{ H='Connector';   P='ConnectorName' },
        @{ H='Environment'; P='EnvironmentName' },
        @{ H='Owner';       P='OwnerName' },
        @{ H='Status';      F={ param($r) $c = if($r.Status -eq 'Connected'){'ok'}else{'bad'}; '<span class="pill ' + $c + '">' + (ConvertTo-PPHtmlText $r.Status) + '</span>' } },
        @{ H='Created';     P='CreatedTime' }
    )
    $body = '<input class="filter" data-target="conns-tbl" placeholder="Filter connections...">'
    $body += (New-PPTable -Rows $Data.Connections -Columns $cols -Id 'conns-tbl' -EmptyMessage 'No connections collected.')

    if (@($Data.CustomConnectors).Count -gt 0) {
        $ccols = @(
            @{ H='Custom connector'; P='DisplayName' },
            @{ H='Environment';      P='EnvironmentName' },
            @{ H='Backend host';     P='BackendHost' },
            @{ H='Owner';            P='OwnerName' },
            @{ H='Created';          P='CreatedTime' }
        )
        $body += '<h2>Custom connectors</h2>'
        $body += (New-PPTable -Rows $Data.CustomConnectors -Columns $ccols)
    }
    Write-Page 'conns' 'Connections and connectors' ("$(@($Data.Connections).Count) connection(s), $(@($Data.CustomConnectors).Count) custom connector(s).") $body

    # ---------------- security ----------------
    $body = ''
    $admins = @()
    foreach ($dv in @($Data.Dataverse)) { $admins += @($dv.AdminUsers) }
    $cols = @(
        @{ H='Principal';   F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.FullName) + '</b>' } },
        @{ H='UPN';         P='UPN' },
        @{ H='Environment'; P='EnvironmentName' },
        @{ H='Type';        F={ param($r) if($r.IsAppUser){'<span class="pill bad">service principal</span>'}else{'user'} } },
        @{ H='Disabled';    F={ param($r) if($r.IsDisabled){'<span class="pill warn">yes</span>'}else{'<span class="dim">no</span>'} } }
    )
    $body += '<h2>System Administrators</h2>'
    $body += (New-PPTable -Rows $admins -Columns $cols -EmptyMessage 'No System Administrator assignments collected.')

    $spCols = @(
        @{ H='Service principal'; P='DisplayName' },
        @{ H='App ID';            F={ param($r) '<code>' + (ConvertTo-PPHtmlText $r.AppId) + '</code>' } },
        @{ H='Credentials';       P='CredentialCount' },
        @{ H='Soonest expiry';    P='SoonestExpiry' },
        @{ H='Days left';         F={ param($r)
            if ($null -eq $r.DaysToExpiry) { return '<span class="dim">n/a</span>' }
            if ($r.DaysToExpiry -lt 0)  { return '<span class="pill bad">expired</span>' }
            if ($r.DaysToExpiry -le 60) { return '<span class="pill warn">' + $r.DaysToExpiry + '</span>' }
            return [string]$r.DaysToExpiry } }
    )
    $expiring = @($Data.Identity.ServicePrincipals | Where-Object { $null -ne $_.DaysToExpiry -and $_.DaysToExpiry -le 90 } |
                  Sort-Object DaysToExpiry)
    $body += '<h2>Service principal credentials expiring within 90 days</h2>'
    $body += (New-PPTable -Rows $expiring -Columns $spCols -EmptyMessage 'None expiring within 90 days.')
    Write-Page 'security' 'Security' 'Privileged access and credential hygiene.' $body

    # ---------------- dlp ----------------
    $body = ''
    $cols = @(
        @{ H='Policy';   F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.DisplayName) + '</b>' } },
        @{ H='Scope';    P='Type' },
        @{ H='Environments'; F={ param($r) if(@($r.Environments).Count -gt 0){ [string]@($r.Environments).Count }else{'<span class="dim">all</span>'} } },
        @{ H='Connector groups'; F={ param($r)
            $parts = @($r.ConnectorGroups | ForEach-Object { (ConvertTo-PPHtmlText $_.Classification) + ': ' + $_.ConnectorCount })
            ($parts -join '<br>') } },
        @{ H='Created by'; P='CreatedBy' },
        @{ H='Modified';   P='LastModified' }
    )
    $body += (New-PPTable -Rows $Data.Tenant.DlpPolicies -Columns $cols -EmptyMessage 'No DLP policies collected. If the tenant genuinely has none, every environment is unprotected.')

    if ($Data.Tenant.IsolationPolicy) {
        $body += '<h2>Tenant isolation</h2>'
        $body += '<div class="note">Tenant isolation policy was collected. See <code>raw/tenant.json</code> for the full allow-list.</div>'
    }
    Write-Page 'dlp' 'Data loss prevention' ("$(@($Data.Tenant.DlpPolicies).Count) policy/policies.") $body

    # ---------------- usage and credits ----------------
    # The page is ordered the way the cost conversation actually goes: how much headroom is
    # left, then what is eating it, then who is driving that, then what it costs in money.
    #
    # The discipline throughout: a number that was not collected renders as "unknown", never as
    # zero, and a dataset we were refused gets a visible explanation rather than an empty table.
    # An empty consumption table and a forbidden consumption table mean opposite things, and
    # conflating them would make the page actively misleading.
    $u    = $Data.Usage
    $body = ''

    if (-not $u) {
        $body = '<div class="note warn">Usage collection did not run for this report. Re-run without <code>-SkipUsage</code>, ' +
                'and with an account that can obtain a token for <code>api.powerplatform.com</code>.</div>'
        Write-Page 'usage' 'Usage and credits' 'Not collected.' $body
    } else {
        $num = {
            param($V, $Dp)
            # The whole point of the null discipline: unknown must look different from zero.
            if ($null -eq $V) { return '<span class="dim">unknown</span>' }
            $d = 0; if ($Dp) { $d = $Dp }
            return [string][math]::Round([double]$V, $d)
        }
        # Per-meter states are HTTP-code strings ('HTTP 403', 'Collected (truncated)'), which the
        # shared verdict classifier does not recognise - it would paint a refusal amber and a
        # truncated collection clean green. Both matter too much here to be mis-coloured.
        $stateCls = {
            param([string]$State)
            if ($State -like 'Collected (truncated)*') { return 'warn' }
            if ($State -eq 'Collected')                { return 'ok' }
            if ($State -like 'HTTP 40*')               { return 'bad' }
            if ($State -like 'HTTP*')                  { return 'warn' }
            return 'muted'
        }
        $pctCell = {
            param($Pct)
            if ($null -eq $Pct) { return '<span class="dim">unknown</span>' }
            $cls = 'ok'
            if ($Pct -ge 100)    { $cls = 'crit' }
            elseif ($Pct -ge 90) { $cls = 'bad' }
            elseif ($Pct -ge 75) { $cls = 'warn' }
            return '<span class="pill ' + $cls + '">' + $Pct + '%</span>'
        }

        $body += '<div class="meta">'
        $body += '<div><b>Window</b>' + (ConvertTo-PPHtmlText $u.WindowFrom) + ' to ' + (ConvertTo-PPHtmlText $u.WindowTo) + '</div>'
        $body += '<div><b>Meters reported</b>' + @($u.CurrencyReports).Count + '</div>'
        $body += '<div><b>Consuming resources</b>' + @($u.Resources).Count + '</div>'
        $body += '<div><b>Consuming users</b>' + @($u.Users).Count + '</div>'
        $body += '<div><b>Datasets unavailable</b>' + @($u.Gaps).Count + '</div>'
        $body += '</div>'

        # Stated once, at the top, because every figure below inherits it.
        $body += '<div class="note">Consumption is aggregated <b>daily by the service and lags</b>. Each figure is ' +
                 'as of its own last-refresh date, shown per row where the API supplies one &mdash; so treat every ' +
                 'number here as a floor, not a live reading. Credits are also not sessions: this page counts money, ' +
                 'while agent transcripts count conversations. The two will not tie out, and both are legitimate.</div>'

        if (@($u.Gaps).Count -gt 0) {
            $body += '<div class="note bad"><b>This cost picture is incomplete.</b> ' +
                     @($u.Gaps).Count + ' usage dataset(s) could not be read. What is missing and why is listed at the ' +
                     'bottom of this page. Nothing below should be read as "zero" where it is actually "unknown".</div>'
        }

        # --- Headline: entitlement vs consumption per meter ---
        $body += '<h2>Credit and currency meters</h2>'
        $body += '<p class="sub">Purchased against consumed, per meter, tenant-wide. This is the only table with a ' +
                 'denominator, so it is the only place a percentage can honestly be shown.</p>'
        $body += (New-PPTable -Rows $u.CurrencyReports -Id 'cur-tbl' -Columns @(
            @{ H='Meter';     F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.Label) + '</b><br><span class="dim" style="font-size:11.5px">' + (ConvertTo-PPHtmlText $r.Currency) + '</span>' } },
            @{ H='Purchased'; F={ param($r) & $num $r.Purchased } },
            @{ H='Allocated'; F={ param($r) & $num $r.Allocated } },
            @{ H='Consumed';  F={ param($r) & $num $r.Consumed } },
            @{ H='Remaining'; F={ param($r)
                if ($null -eq $r.Remaining) { return '<span class="dim">unknown</span>' }
                if ($r.Remaining -lt 0) { return '<span class="pill crit">' + [math]::Round($r.Remaining,0) + '</span>' }
                return [string][math]::Round($r.Remaining,0) } },
            @{ H='Consumed %'; F={ param($r) & $pctCell $r.PctConsumed } },
            @{ H='As of';     F={ param($r) if ($r.LastUpdated) { ConvertTo-PPHtmlText $r.LastUpdated } else { '<span class="dim">not supplied</span>' } } }
        ) -EmptyMessage 'The tenant currency report returned no meters. If the route was readable this genuinely means no metered currency is provisioned; check the dataset table below before concluding that.')

        # --- Storage / API capacity ---
        if (@($u.TenantCapacity).Count -gt 0) {
            $body += '<h2>Storage and API capacity</h2>'
            $body += (New-PPTable -Rows $u.TenantCapacity -Columns @(
                @{ H='Capacity type'; F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.CapacityType) + '</b>' } },
                @{ H='Entitled';   F={ param($r) & $num $r.Entitled 1 } },
                @{ H='Actual';     F={ param($r) & $num $r.Actual 1 } },
                @{ H='Rated';      F={ param($r) & $num $r.Rated 1 } },
                @{ H='Overflow';   F={ param($r) & $num $r.Overflow 1 } },
                @{ H='Unit';       P='Unit' },
                @{ H='Consumed %'; F={ param($r) & $pctCell $r.PctConsumed } }
            ))
        }

        # --- Which agent / app is spending: the question the page exists for ---
        $body += '<h2>Consumption by resource &mdash; which agent or app is spending</h2>'
        $blocked = @($u.Meters | Where-Object { [string]$_.ResourceState -like 'HTTP 40*' })
        if ($blocked.Count -gt 0) {
            $body += '<div class="note bad">Per-resource attribution was <b>refused</b> for ' +
                     (@($blocked | ForEach-Object { (ConvertTo-PPHtmlText $_.Label) + ' (' + (ConvertTo-PPHtmlText $_.ResourceState) + ')' }) -join ', ') +
                     '. The route exists; this operator lacks the role for it. Consumption on those meters is ' +
                     '<b>unknown, not zero</b> &mdash; the totals above still stand.</div>'
        }
        $imported = @($u.Resources | Where-Object { $_.Source -eq 'PPAC report' })
        if ($imported.Count -gt 0) {
            # Provenance has to be stated where the numbers are, not only in a footnote: an
            # imported export is frozen at its download date and nothing refreshes it.
            $srcFiles = @($imported | ForEach-Object { $_.SourceFile } | Where-Object { $_ } | Select-Object -Unique)
            $body += '<div class="note warn"><b>' + $imported.Count + ' row(s) below were imported from a ' +
                     'downloaded PPAC report</b> (' + (ConvertTo-PPHtmlText (@($srcFiles) -join ', ')) + '), not read ' +
                     'from the API &mdash; the per-resource route is refused for this operator. They are correct as of ' +
                     'the moment that file was exported and <b>will not refresh on a later run</b>. The ' +
                     '<b>Source</b> column marks every row.</div>'
        }
        $body += '<p class="sub">Resource IDs are joined back to the collected agent, app and flow inventory. ' +
                 'A row marked <b>unmatched</b> is consuming credits under an ID that appears in no inventory &mdash; ' +
                 'usually an asset in an unreadable environment, or one deleted mid-period.</p>'
        $topRes = @($u.Resources | Sort-Object -Property @{ Expression = { if ($null -eq $_.Consumed) { -1 } else { $_.Consumed } }; Descending = $true })
        $body += '<input class="filter" data-target="res-tbl" placeholder="Filter resources...">'
        $body += (New-PPTable -Rows $topRes -Id 'res-tbl' -Columns @(
            @{ H='Resource'; F={ param($r)
                $n = $(if ($r.ResourceName) { ConvertTo-PPHtmlText $r.ResourceName } else { '<span class="dim">unnamed</span>' })
                $s = '<b>' + $n + '</b>'
                if (-not $r.Matched) { $s += ' <span class="pill warn">unmatched</span>' }
                if ($r.ResourceId) { $s += '<br><span class="dim" style="font-size:11px;word-break:break-all">' + (ConvertTo-PPHtmlText $r.ResourceId) + '</span>' }
                return $s } },
            @{ H='Kind';        F={ param($r) if ($r.ResourceKind -eq 'Unmatched') { '<span class="dim">unknown</span>' } else { ConvertTo-PPHtmlText $r.ResourceKind } } },
            @{ H='Environment'; F={ param($r) if ($r.EnvironmentName) { ConvertTo-PPHtmlText $r.EnvironmentName } else { '<span class="dim">' + (ConvertTo-PPHtmlText $r.EnvironmentId) + '</span>' } } },
            @{ H='Meter';       P='CurrencyLabel' },
            @{ H='Consumed';    F={ param($r) & $num $r.Consumed 1 } },
            # nonBillableConsumed is the field that changes the conversation: same volume,
            # different bill. It gets its own column rather than being folded into the total.
            @{ H='Non-billable'; F={ param($r) & $num $r.NonBillable 1 } },
            @{ H='Billed';      F={ param($r) & $num $r.Billed 1 } },
            @{ H='Feature';     F={ param($r) if ($r.Feature) { ConvertTo-PPHtmlText $r.Feature } else { '<span class="dim">&mdash;</span>' } } },
            # Channel, model and knowledge source exist only in the downloaded report - the API
            # route does not return them. Columns are rendered only when something populates
            # them, so an API-only run does not carry three permanently empty columns.
            @{ H='Channel';     F={ param($r) if ($r.Channel) { ConvertTo-PPHtmlText $r.Channel } else { '<span class="dim">&mdash;</span>' } } },
            @{ H='Model';       F={ param($r) if ($r.Model) { ConvertTo-PPHtmlText $r.Model } else { '<span class="dim">&mdash;</span>' } } },
            @{ H='Knowledge / tool'; F={ param($r) if ($r.Knowledge) { ConvertTo-PPHtmlText $r.Knowledge } else { '<span class="dim">&mdash;</span>' } } },
            @{ H='Last used';   F={ param($r) if ($r.LastConsumed) { ConvertTo-PPHtmlText $r.LastConsumed } else { '<span class="dim">&mdash;</span>' } } },
            @{ H='Source';      F={ param($r)
                if ($r.Source -eq 'PPAC report') { return '<span class="pill warn">imported</span>' }
                if ($r.Source) { return '<span class="pill ok">API</span>' }
                return '<span class="dim">&mdash;</span>' } }
        ) -EmptyMessage 'No per-resource consumption rows were returned. Check the dataset table at the foot of this page: if the route was blocked this is an access gap, not an absence of spend. You can supply the breakdown by hand with -UsageReport.')

        # --- Who is spending ---
        $body += '<h2>Consumption by user</h2>'
        $body += '<p class="sub">Joined to the directory for name, UPN and department. A user the directory does not ' +
                 'know, or one whose account is disabled, is flagged &mdash; spend under a departed identity is a ' +
                 'governance problem before it is a cost one.</p>'
        $topUsers = @($u.Users | Sort-Object -Property @{ Expression = { if ($null -eq $_.Consumed) { -1 } else { $_.Consumed } }; Descending = $true })
        $body += '<input class="filter" data-target="usr-tbl" placeholder="Filter users...">'
        $body += (New-PPTable -Rows $topUsers -Id 'usr-tbl' -Columns @(
            @{ H='User'; F={ param($r)
                $n = $(if ($r.UserName) { ConvertTo-PPHtmlText $r.UserName } else { '<span class="dim">' + (ConvertTo-PPHtmlText $r.UserId) + '</span>' })
                $s = '<b>' + $n + '</b>'
                if ($r.Orphaned) {
                    $s += $(if ($r.KnownInDirectory) { ' <span class="pill bad">disabled</span>' } else { ' <span class="pill bad">not in directory</span>' })
                }
                if ($r.UPN) { $s += '<br><span class="dim" style="font-size:11.5px">' + (ConvertTo-PPHtmlText $r.UPN) + '</span>' }
                return $s } },
            @{ H='Department';  F={ param($r) if ($r.Department) { ConvertTo-PPHtmlText $r.Department } else { '<span class="dim">not set</span>' } } },
            @{ H='Job title';   F={ param($r) if ($r.JobTitle) { ConvertTo-PPHtmlText $r.JobTitle } else { '<span class="dim">&mdash;</span>' } } },
            @{ H='Environment'; F={ param($r) if ($r.EnvironmentName) { ConvertTo-PPHtmlText $r.EnvironmentName } else { '<span class="dim">&mdash;</span>' } } },
            @{ H='Meter';       P='CurrencyLabel' },
            @{ H='Consumed';    F={ param($r) & $num $r.Consumed 1 } },
            @{ H='Non-billable'; F={ param($r) & $num $r.NonBillable 1 } },
            @{ H='Last used';   F={ param($r) if ($r.LastConsumed) { ConvertTo-PPHtmlText $r.LastConsumed } else { '<span class="dim">&mdash;</span>' } } },
            @{ H='Source';      F={ param($r)
                if ($r.Source -eq 'PPAC report') { return '<span class="pill warn">imported</span>' }
                if ($r.Source) { return '<span class="pill ok">API</span>' }
                return '<span class="dim">&mdash;</span>' } }
        ) -EmptyMessage 'No per-user consumption rows were returned.')

        # --- Department rollup: the honest answer to "which group" ---
        if (@($u.Departments).Count -gt 0) {
            $body += '<h2>Consumption by department</h2>'
            # This caveat is load-bearing. Without it the table reads as group-based chargeback,
            # which the API cannot support and we must not imply.
            $body += '<div class="note">This is a rollup of per-user consumption by the <b>department attribute in ' +
                     'Entra ID</b>. It is <b>not</b> security-group attribution: the consumption API attributes spend ' +
                     'to a user and never to a group, so group-level chargeback would have to be inferred, and an ' +
                     'inferred cost split does not belong in a cost report. Users with no department set are grouped ' +
                     'separately rather than dropped.</div>'
            $body += (New-PPTable -Rows $u.Departments -Columns @(
                @{ H='Department'; F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.Department) + '</b>' } },
                @{ H='Meter';      P='CurrencyLabel' },
                @{ H='Users';      P='Users' },
                @{ H='Consumed';   F={ param($r) & $num $r.Consumed 1 } }
            ))
        }

        # --- Allocation per environment ---
        if (@($u.EnvironmentAllocations).Count -gt 0) {
            $body += '<h2>Credit allocation per environment</h2>'
            $body += '<p class="sub">Which environment holds which slice of each pool. This is what turns a tenant-level ' +
                     'percentage into a named environment to act on.</p>'
            $body += (New-PPTable -Rows $u.EnvironmentAllocations -Columns @(
                @{ H='Environment'; F={ param($r) if ($r.EnvironmentName) { '<b>' + (ConvertTo-PPHtmlText $r.EnvironmentName) + '</b>' } else { '<span class="dim">' + (ConvertTo-PPHtmlText $r.EnvironmentId) + '</span>' } } },
                @{ H='Meter';     F={ param($r) if ($r.CurrencyLabel) { ConvertTo-PPHtmlText $r.CurrencyLabel } else { ConvertTo-PPHtmlText $r.Currency } } },
                @{ H='Allocated'; F={ param($r) & $num $r.Allocated 1 } },
                @{ H='Consumed';  F={ param($r) & $num $r.Consumed 1 } },
                @{ H='Over allocation'; F={ param($r)
                    if ($null -eq $r.Allocated -or $null -eq $r.Consumed) { return '<span class="dim">unknown</span>' }
                    if ($r.Consumed -gt $r.Allocated) { return '<span class="pill bad">yes</span>' }
                    return '<span class="dim">no</span>' } },
                @{ H='Tenant pool'; F={ param($r)
                    if ($null -eq $r.TenantPool) { return '<span class="dim">unknown</span>' }
                    if ($r.TenantPool) { return '<span class="pill info">drawing on tenant pool</span>' }
                    return '<span class="dim">no</span>' } },
                @{ H='Enforcement'; F={ param($r) if ($r.Enforcement) { ConvertTo-PPHtmlText $r.Enforcement } else { '<span class="dim">&mdash;</span>' } } }
            ))
        }

        # --- Spend alarms ---
        $body += '<h2>Spend thresholds and alerts</h2>'
        $thReadable = @($u.Meters | Where-Object { $_.ThresholdState -eq 'Collected' })
        if (@($u.Thresholds).Count -gt 0) {
            $body += (New-PPTable -Rows $u.Thresholds -Columns @(
                @{ H='Resource'; F={ param($r) if ($r.ResourceName) { '<b>' + (ConvertTo-PPHtmlText $r.ResourceName) + '</b>' } else { '<span class="dim">' + (ConvertTo-PPHtmlText $r.ResourceId) + '</span>' } } },
                @{ H='Kind';     P='ResourceKind' },
                @{ H='Meter';    P='CurrencyLabel' },
                @{ H='Limit';    F={ param($r) & $num $r.Limit 1 } },
                @{ H='Notify at'; F={ param($r) & $num $r.NotifyAt 1 } },
                @{ H='Consumption'; F={ param($r) & $num $r.Consumption 1 } },
                @{ H='Stop at capacity'; F={ param($r)
                    if ($null -eq $r.StopOverCapacity) { return '<span class="dim">unknown</span>' }
                    if ($r.StopOverCapacity) { return '<span class="pill warn">stops the resource</span>' }
                    return '<span class="dim">no</span>' } }
            ))
        } elseif ($thReadable.Count -gt 0) {
            # Readable and empty is a real finding; readable-and-empty is the only state in which
            # we are entitled to say "nobody configured one".
            $body += '<div class="note bad">The threshold route was readable and returned <b>no configured thresholds</b>. ' +
                     'Nothing will warn anyone before a meter reaches its limit &mdash; the first signal will be users ' +
                     'reporting that an agent stopped responding.</div>'
        } else {
            $body += '<div class="note dim">Threshold configuration could not be read, so whether a spend alarm exists ' +
                     'is unknown. Its absence is deliberately <b>not</b> reported as a finding on that basis.</div>'
        }

        # --- Per-meter collection state: provenance, not decoration ---
        $body += '<h2>Per-meter collection state</h2>'
        $body += (New-PPTable -Rows $u.Meters -Columns @(
            @{ H='Meter'; F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.Label) + '</b><br><span class="dim" style="font-size:11.5px">' + (ConvertTo-PPHtmlText $r.Id) + '</span>' } },
            @{ H='What it meters'; F={ param($r) '<span class="dim" style="font-size:12.5px">' + (ConvertTo-PPHtmlText $r.Meters) + '</span>' } },
            @{ H='Per-resource'; F={ param($r) '<span class="pill ' + (& $stateCls $r.ResourceState) + '">' + (ConvertTo-PPHtmlText $r.ResourceState) + '</span>' } },
            @{ H='Per-user';     F={ param($r) '<span class="pill ' + (& $stateCls $r.UserState) + '">' + (ConvertTo-PPHtmlText $r.UserState) + '</span>' } },
            @{ H='Thresholds';   F={ param($r) '<span class="pill ' + (& $stateCls $r.ThresholdState) + '">' + (ConvertTo-PPHtmlText $r.ThresholdState) + '</span>' } },
            @{ H='Resources';    F={ param($r) if ($null -eq $r.ResourceCount) { '<span class="dim">&mdash;</span>' } else { [string]$r.ResourceCount } } },
            @{ H='Users';        F={ param($r) if ($null -eq $r.UserCount) { '<span class="dim">&mdash;</span>' } else { [string]$r.UserCount } } }
        ) -EmptyMessage 'No meters were deep-dived.')

        # Imports and ImportedEnvironments are added only when a report was actually imported, so
        # on an API-only run they are absent. Null must be filtered out rather than counted:
        # @($null).Count is 1 in PowerShell, which would render a table containing one blank row.
        $impRows = @($u.Imports | Where-Object { $_ })
        $impEnvs = @($u.ImportedEnvironments | Where-Object { $_ })

        # --- Imported environment-level rows ---
        if ($impEnvs.Count -gt 0) {
            $body += '<h2>Environment consumption (imported)</h2>'
            $body += '<p class="sub">From a downloaded PPAC environment report. Shown separately from the ' +
                     'allocation table above because these are consumption figures from a file, not live ' +
                     'allocations read from the API.</p>'
            $body += (New-PPTable -Rows $impEnvs -Columns @(
                @{ H='Environment'; F={ param($r) if ($r.EnvironmentName) { '<b>' + (ConvertTo-PPHtmlText $r.EnvironmentName) + '</b>' } else { '<span class="dim">' + (ConvertTo-PPHtmlText $r.EnvironmentId) + '</span>' } } },
                @{ H='Meter';       P='CurrencyLabel' },
                @{ H='Consumed';    F={ param($r) & $num $r.Consumed 1 } },
                @{ H='Non-billable'; F={ param($r) & $num $r.NonBillable 1 } },
                @{ H='Billed';      F={ param($r) & $num $r.Billed 1 } },
                @{ H='Overage';     F={ param($r) & $num $r.Overage 1 } },
                @{ H='From file';   F={ param($r) '<span class="dim" style="font-size:11.5px">' + (ConvertTo-PPHtmlText $r.SourceFile) + '</span>' } }
            ))
        }

        # --- Imported files: what was read, and what was not understood ---
        if ($impRows.Count -gt 0) {
            $body += '<h2>Imported reports</h2>'
            $body += '<p class="sub">Files supplied with <code>-UsageReport</code>. Column names in these exports ' +
                     'are not stable, so any header the importer did not recognise is listed rather than dropped ' +
                     'silently &mdash; an unmapped column is how a renamed field shows up before it becomes a ' +
                     'missing number.</p>'
            $body += (New-PPTable -Rows $impRows -Columns @(
                @{ H='File'; F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.File) + '</b>' } },
                @{ H='Kind'; F={ param($r)
                    $cls = 'ok'
                    if ($r.Kind -eq 'Unknown' -or $r.Kind -eq 'Unreadable') { $cls = 'bad' }
                    '<span class="pill ' + $cls + '">' + (ConvertTo-PPHtmlText $r.Kind) + '</span>' } },
                @{ H='Meter';    F={ param($r) if ($r.Currency) { ConvertTo-PPHtmlText $r.Currency } else { '<span class="dim">&mdash;</span>' } } },
                @{ H='Rows';     P='Rows' },
                @{ H='Imported'; F={ param($r)
                    if ($r.Imported -gt 0) { return '<span class="pill ok">' + $r.Imported + '</span>' }
                    return '<span class="pill muted">0</span>' } },
                @{ H='Unmapped columns'; F={ param($r)
                    if (@($r.Unmapped).Count -eq 0) { return '<span class="dim">none</span>' }
                    return '<span class="dim" style="font-size:12px">' + (ConvertTo-PPHtmlText (@($r.Unmapped) -join ', ')) + '</span>' } },
                @{ H='Note';     F={ param($r) if ($r.Reason) { ConvertTo-PPHtmlText $r.Reason } else { '<span class="dim">&mdash;</span>' } } }
            ))
        }

        # --- Route provenance ---
        # The Licensing namespace is preview and several datasets answer under more than one
        # spelling, so which URL produced a number is part of the evidence for that number.
        $body += '<h2>Where these numbers came from</h2>'
        $body += '<p class="sub">The Licensing API is in preview and some datasets answer under more than one path or ' +
                 'api-version. The exact route that produced each figure is recorded so the number can be re-derived ' +
                 'and audited rather than taken on trust.</p>'
        $body += '<details><summary>Show route map (' + @($u.RouteMap).Count + ' datasets)</summary>'
        $body += (New-PPTable -Rows $u.RouteMap -Columns @(
            @{ H='Dataset'; P='Dataset' },
            @{ H='Verdict'; F={ param($r) '<span class="pill ' + (Get-PPVerdictClass $r.Verdict) + '">' + (ConvertTo-PPHtmlText $r.Verdict) + '</span>' } },
            @{ H='HTTP';    F={ param($r) if ($r.Status) { [string]$r.Status } else { '<span class="dim">&mdash;</span>' } } },
            @{ H='api-version'; F={ param($r) if ($r.Version) { '<code>' + (ConvertTo-PPHtmlText $r.Version) + '</code>' } else { '<span class="dim">&mdash;</span>' } } },
            @{ H='Path';    F={ param($r) '<span class="dim" style="font-size:11.5px;word-break:break-all">' + (ConvertTo-PPHtmlText $r.Path) + '</span>' } }
        ))
        $body += '</details>'

        $body += '<h2>Usage data we could not read</h2>'
        $body += (New-PPTable -Rows $u.Gaps -Columns @(
            @{ H='Dataset'; F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.Item) + '</b>' } },
            @{ H='Reason';  P='Reason' }
        ) -EmptyMessage 'Every usage dataset was readable.')

        Write-Page 'usage' 'Usage and credits' `
            ("Consumption over $($u.WindowDays) days: which meters, which agents, which users.") $body
    }

    # ---------------- billing ----------------
    # Two questions, in this order: is there a pay-as-you-go plan at all, and does it reach the
    # environments where agents actually run? The second is the one that bites, so the coverage
    # table is not optional even when policies exist.
    $bp     = @($Data.Tenant.BillingPolicies)
    $bpGap  = @($Data.Tenant.Gaps | Where-Object { $_.Item -eq 'Billing policies' })
    $body   = ''

    if ($bpGap.Count -gt 0) {
        $body += '<div class="note">Billing policies could not be read (' +
                 (ConvertTo-PPHtmlText $bpGap[0].Reason) +
                 '). Nothing below should be read as "the tenant has no pay-as-you-go plan" &mdash; it is unknown.</div>'
    } elseif ($bp.Count -eq 0) {
        $body += '<div class="note">No billing policies exist. Every environment runs on prepaid capacity only: ' +
                 'when Copilot credit consumption exceeds the tenant pool, overage enforcement makes agents ' +
                 'unavailable to users rather than billing the overage.</div>'
    }

    $cols = @(
        @{ H='Policy'; F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.Name) + '</b>' } },
        @{ H='Status'; F={ param($r)
            $cls = 'ok'; if ([string]$r.Status -ne 'Enabled') { $cls = 'high' }
            '<span class="pill ' + $cls + '">' + (ConvertTo-PPHtmlText $r.Status) + '</span>' } },
        @{ H='Azure subscription'; F={ param($r) '<code>' + (ConvertTo-PPHtmlText $r.SubscriptionId) + '</code>' } },
        @{ H='Resource group';     P='ResourceGroup' },
        @{ H='Region';             P='Location' },
        @{ H='Environments'; F={ param($r)
            if ($r.EnvironmentStatus -ne 'Collected') { '<span class="dim">' + (ConvertTo-PPHtmlText $r.EnvironmentStatus) + '</span>' }
            else { [string]$r.EnvironmentCount } } },
        @{ H='Created';            P='CreatedOn' }
    )
    $body += (New-PPTable -Rows $bp -Columns $cols -EmptyMessage 'No pay-as-you-go billing policies in this tenant.')

    # Coverage, agent-first: an uncovered environment with no agents is noise, an uncovered
    # environment with published agents is the finding.
    $agentEnvIds = @($Data.Agents | ForEach-Object { $_.EnvironmentId } | Where-Object { $_ } | Select-Object -Unique)
    if ($bpGap.Count -eq 0 -and $agentEnvIds.Count -gt 0) {
        $coverage = @($Data.Environments | Where-Object { $agentEnvIds -contains $_.Name } | ForEach-Object {
            $envId  = $_.Name
            $agents = @($Data.Agents | Where-Object { $_.EnvironmentId -eq $envId })
            $pol    = @($bp | Where-Object { @($_.Environments) -contains $envId })[0]
            [PSCustomObject]@{
                Environment = $_.DisplayName
                Sku         = $_.Sku
                Agents      = $agents.Count
                Published   = @($agents | Where-Object { $_.PublishedOn }).Count
                Policy      = $(if ($pol) { $pol.Name } else { $null })
                PolicyStatus= $(if ($pol) { $pol.Status } else { 'None' })
            }
        })
        $body += '<h2>Copilot billing coverage</h2>'
        $body += '<p class="sub">Environments that host agents, and whether a billing policy reaches them. ' +
                 'Pay-as-you-go supports production and sandbox environments only.</p>'
        $body += (New-PPTable -Rows $coverage -Columns @(
            @{ H='Environment'; F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.Environment) + '</b>' } },
            @{ H='SKU';       P='Sku' },
            @{ H='Agents';    P='Agents' },
            @{ H='Published'; P='Published' },
            @{ H='Billing policy'; F={ param($r)
                if ($r.Policy) { ConvertTo-PPHtmlText $r.Policy } else { '<span class="pill bad">none</span>' } } },
            @{ H='Status'; F={ param($r)
                $cls = 'ok'; if ([string]$r.PolicyStatus -ne 'Enabled') { $cls = 'high' }
                '<span class="pill ' + $cls + '">' + (ConvertTo-PPHtmlText $r.PolicyStatus) + '</span>' } }
        ) -EmptyMessage 'No agent-bearing environments.')
    }

    # ---- Azure cost: the money figure, and the one thing it cannot tell you ----
    $az = $Data.AzureCost
    $body += '<h2>Azure pay-as-you-go cost</h2>'
    if (-not $az) {
        $body += '<div class="note dim">Azure cost was not collected. Re-run with <code>-IncludeAzureCost</code> to query ' +
                 'Azure Consumption for the currency cost behind these policies. It needs Azure RBAC on the ' +
                 'subscriptions above, which Power Platform Administrator does not grant.</div>'
    } elseif (-not $az.Attempted) {
        $body += '<div class="note dim">No billing policy names an Azure subscription, so there is no pay-as-you-go ' +
                 'spend to query. On a prepaid-only tenant this is the expected result.</div>'
    } else {
        if ($az.Totals) {
            $body += '<div class="cards">'
            $body += '<div class="card"><div class="n">' + (ConvertTo-PPHtmlText $az.Totals.Cost) + ' ' +
                     (ConvertTo-PPHtmlText $az.Totals.Currency) + '</div><div class="l">Total, ' +
                     (ConvertTo-PPHtmlText $az.WindowFrom) + ' to ' + (ConvertTo-PPHtmlText $az.WindowTo) + '</div></div>'
            $body += '<div class="card"><div class="n">' + $az.Totals.MeterCount + '</div><div class="l">Billed meters</div></div>'
            $body += '<div class="card"><div class="n">' + $az.Totals.Records + '</div><div class="l">Usage records</div></div>'
            $body += '</div>'
        }

        # Said plainly, because the obvious next question is "so which agent cost this?" and the
        # answer is that Azure structurally cannot say - only the Usage page can.
        $body += '<div class="note">Azure Cost Management reports spend <b>per meter and per Azure resource</b>. It ' +
                 'cannot attribute Power Platform spend to an environment, agent, app or user &mdash; that breakdown ' +
                 'exists only in the credit consumption data on the <a href="usage.html">Usage &amp; credits</a> page. ' +
                 'The two are different units (money against credits) and will not reconcile row for row; use this ' +
                 'table for the bill and that page for attribution.</div>'

        $body += (New-PPTable -Rows $az.Subscriptions -Columns @(
            @{ H='Subscription'; F={ param($r) '<code>' + (ConvertTo-PPHtmlText $r.SubscriptionId) + '</code>' } },
            @{ H='Billing policy'; F={ param($r) ConvertTo-PPHtmlText (@($r.Policies) -join ', ') } },
            @{ H='State'; F={ param($r)
                $cls = 'muted'
                if ([string]$r.State -eq 'Collected') { $cls = 'ok' }
                elseif ([string]$r.State -like 'Collected*') { $cls = 'warn' }
                elseif ([string]$r.State -like 'HTTP 40*') { $cls = 'bad' }
                '<span class="pill ' + $cls + '">' + (ConvertTo-PPHtmlText $r.State) + '</span>' } },
            @{ H='Records'; P='RowCount' },
            @{ H='Cost'; F={ param($r)
                if ($null -eq $r.Cost) { return '<span class="dim">unknown</span>' }
                return (ConvertTo-PPHtmlText $r.Cost) + ' ' + (ConvertTo-PPHtmlText $r.Currency) } }
        ) -EmptyMessage 'No subscriptions were queried.')

        if (@($az.Meters).Count -gt 0) {
            $body += '<h3>By meter</h3>'
            $body += (New-PPTable -Rows $az.Meters -Columns @(
                @{ H='Category'; P='MeterCategory' },
                @{ H='Meter';    F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.MeterName) + '</b>' } },
                @{ H='Quantity'; F={ param($r) if ($null -eq $r.Quantity) { '<span class="dim">unknown</span>' } else { [string][math]::Round([double]$r.Quantity, 2) } } },
                @{ H='Unit';     P='UnitOfMeasure' },
                @{ H='Cost';     F={ param($r) (ConvertTo-PPHtmlText $r.Cost) + ' ' + (ConvertTo-PPHtmlText $r.Currency) } }
            ))
        }

        if (@($az.Resources).Count -gt 0) {
            $body += '<h3>By Azure resource</h3>'
            $body += (New-PPTable -Rows $az.Resources -Columns @(
                @{ H='Resource'; F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.ResourceName) + '</b>' } },
                @{ H='Resource group'; P='ResourceGroup' },
                @{ H='Meters';   P='Meters' },
                @{ H='Cost';     F={ param($r) (ConvertTo-PPHtmlText $r.Cost) + ' ' + (ConvertTo-PPHtmlText $r.Currency) } }
            ))
        }

        if (@($az.Gaps).Count -gt 0) {
            $body += (New-PPTable -Rows $az.Gaps -Columns @(
                @{ H='Item'; F={ param($r) '<b>' + (ConvertTo-PPHtmlText $r.Item) + '</b>' } },
                @{ H='Reason'; P='Reason' }
            ))
        }
    }

    $body += '<div class="note dim">Credit and capacity consumption &mdash; per meter, per agent and per user &mdash; ' +
             'is on the <a href="usage.html">Usage &amp; credits</a> page. See DESIGN.md &sect;2.3.3 for the route ' +
             'inventory behind it and &sect;2.3.4 for why Azure cost cannot carry the attribution.</div>'
    Write-Page 'billing' 'Pay-as-you-go billing' ("$(@($bp).Count) billing policy/policies.") $body

    # ---------------- integrity ----------------
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<div class="note">A report that silently omits a source is worse than no report. Everything this run could not read is listed here.</div>')

    $gaps = @()
    foreach ($g in @($Data.Tenant.Gaps))          { $gaps += [PSCustomObject]@{ Scope='Tenant';   Item=$g.Item; Reason=$g.Reason } }
    foreach ($g in @($Data.Identity.Gaps))        { $gaps += [PSCustomObject]@{ Scope='Identity'; Item=$g.Item; Reason=$g.Reason } }
    # Usage gaps belong here as well as on the Usage page: a reader who opens Integrity to ask
    # "what is missing from this report" must see the cost gaps without having to know to look
    # for them elsewhere.
    if ($Data.Usage)     { foreach ($g in @($Data.Usage.Gaps))     { $gaps += [PSCustomObject]@{ Scope='Usage';      Item=$g.Item; Reason=$g.Reason } } }
    if ($Data.AzureCost) { foreach ($g in @($Data.AzureCost.Gaps)) { $gaps += [PSCustomObject]@{ Scope='Azure cost'; Item=$g.Item; Reason=$g.Reason } } }
    foreach ($dv in @($Data.Dataverse | Where-Object { -not $_.Reachable })) {
        $gaps += [PSCustomObject]@{ Scope='Dataverse'; Item=$dv.EnvironmentName; Reason=$dv.Reason }
    }
    foreach ($e in @($Data.Environments | Where-Object { $_.BackupStatus -like 'Unavailable*' })) {
        $gaps += [PSCustomObject]@{ Scope='Backups'; Item=$e.DisplayName; Reason=$e.BackupStatus }
    }

    [void]$sb.AppendLine('<h2>Coverage gaps</h2>')
    [void]$sb.AppendLine((New-PPTable -Rows $gaps -Columns @(
        @{ H='Scope'; P='Scope' }, @{ H='Item'; P='Item' }, @{ H='Reason'; P='Reason' }
    ) -EmptyMessage 'No gaps: every source was readable.'))

    $dvCols = @(
        @{ H='Environment'; P='EnvironmentName' },
        @{ H='Reachable';   F={ param($r) if($r.Reachable){'<span class="pill ok">yes</span>'}else{'<span class="pill bad">no</span>'} } },
        @{ H='Agents';      F={ param($r) [string]@($r.Agents).Count } },
        @{ H='Solutions';   F={ param($r) [string]@($r.Solutions).Count } },
        @{ H='Sys admins';  F={ param($r) [string]@($r.AdminUsers).Count } },
        @{ H='Reason';      P='Reason' }
    )
    [void]$sb.AppendLine('<h2>Dataverse access per environment</h2>')
    [void]$sb.AppendLine((New-PPTable -Rows $Data.Dataverse -Columns $dvCols -EmptyMessage 'Dataverse collection was skipped.'))

    $failed = @($Data.Meta.Calls | Where-Object { -not $_.Success })
    [void]$sb.AppendLine('<h2>Requests</h2>')
    [void]$sb.AppendLine('<p class="sub">' + $Data.Meta.CallCount + ' requests, all GET. ' + $failed.Count + ' did not succeed.</p>')
    [void]$sb.AppendLine('<details><summary>Show failed requests</summary>')
    [void]$sb.AppendLine((New-PPTable -Rows $failed -Columns @(
        @{ H='Label'; P='Label' },
        @{ H='HTTP';  F={ param($r) '<span class="pill bad">' + $r.StatusCode + '</span>' } },
        @{ H='URI';   F={ param($r) '<span class="dim" style="font-size:11.5px;word-break:break-all">' + (ConvertTo-PPHtmlText $r.Uri) + '</span>' } }
    ) -EmptyMessage 'All requests succeeded.'))
    [void]$sb.AppendLine('</details>')

    Write-Page 'integrity' 'Collection integrity' 'What was read, what was not, and why.' $sb.ToString()

    return (Join-Path $OutputDir 'index.html')
}

