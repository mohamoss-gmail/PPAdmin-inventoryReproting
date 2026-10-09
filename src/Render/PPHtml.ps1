# PPHtml.ps1 - shared rendering primitives for all reports.
#
# Self-contained by policy: no CDN, no external fonts, no remote images. Enterprise and
# air-gapped safe, and every page survives being emailed as a single file.

function ConvertTo-PPHtmlText {
    param($Text)
    if ($null -eq $Text) { return '' }
    $s = [string]$Text
    return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Get-PPVerdictClass {
    param([string]$Verdict)
    switch -Regex ($Verdict) {
        'Available|Readable|OK|Reachable|Yes|Collected' { return 'ok' }
        'Blocked|Denied|Insufficient|Unauthorised'      { return 'bad' }
        'Not found|Not present|Missing|Unavailable'     { return 'muted' }
        default { return 'warn' }
    }
}

function Get-PPRiskCell {
    param($Count)
    if ($Count -gt 0) { return '<span class="pill bad">' + $Count + '</span>' }
    return '<span class="dim">0</span>'
}

function Get-PPSeverityClass {
    param([string]$Severity)
    switch ($Severity) {
        'Critical' { return 'crit' }
        'High'     { return 'bad' }
        'Medium'   { return 'warn' }
        'Low'      { return 'info' }
        default    { return 'muted' }
    }
}

function Get-PPReportCss {
@'
<style>
:root{--bg:#fbfbfa;--fg:#1a1a18;--muted:#6b6b66;--line:#e3e3df;--card:#fff;
--ok:#1a7f4b;--okbg:#e8f5ee;--bad:#b3261e;--badbg:#fdeceb;--warn:#8a6100;--warnbg:#fdf3e0;
--crit:#fff;--critbg:#8c1d18;--info:#2f5fd0;--infobg:#e9eefb;--accent:#2f5fd0;}
@media (prefers-color-scheme:dark){:root{--bg:#16161a;--fg:#e8e8e4;--muted:#9a9a94;--line:#2e2e34;--card:#1e1e23;
--ok:#5ec98d;--okbg:#12291d;--bad:#f08079;--badbg:#2e1614;--warn:#e0b25e;--warnbg:#2c2314;
--crit:#fff;--critbg:#a3261e;--info:#8fb0ff;--infobg:#151d33;--accent:#7ba0ff;}}
:root[data-theme=dark]{--bg:#16161a;--fg:#e8e8e4;--muted:#9a9a94;--line:#2e2e34;--card:#1e1e23;
--ok:#5ec98d;--okbg:#12291d;--bad:#f08079;--badbg:#2e1614;--warn:#e0b25e;--warnbg:#2c2314;
--crit:#fff;--critbg:#a3261e;--info:#8fb0ff;--infobg:#151d33;--accent:#7ba0ff;}
:root[data-theme=light]{--bg:#fbfbfa;--fg:#1a1a18;--muted:#6b6b66;--line:#e3e3df;--card:#fff;
--ok:#1a7f4b;--okbg:#e8f5ee;--bad:#b3261e;--badbg:#fdeceb;--warn:#8a6100;--warnbg:#fdf3e0;
--crit:#fff;--critbg:#8c1d18;--info:#2f5fd0;--infobg:#e9eefb;--accent:#2f5fd0;}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:1280px;margin:0 auto;padding:28px 24px 80px}
nav{display:flex;flex-wrap:wrap;gap:4px;margin:0 0 24px;padding:10px 0;border-bottom:1px solid var(--line)}
nav a{color:var(--muted);text-decoration:none;font-size:13px;padding:5px 11px;border-radius:6px}
nav a:hover{background:var(--card);color:var(--fg)}
nav a.on{background:var(--accent);color:#fff}
h1{font-size:25px;margin:0 0 4px;letter-spacing:-.02em}
h2{font-size:17px;margin:34px 0 12px;padding-bottom:7px;border-bottom:1px solid var(--line)}
h3{font-size:13px;margin:20px 0 8px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}
p{margin:0 0 12px}.sub{color:var(--muted);font-size:13.5px}
.meta{display:flex;flex-wrap:wrap;gap:22px;margin:16px 0;padding:14px 18px;background:var(--card);border:1px solid var(--line);border-radius:8px}
.meta div{font-size:13px}.meta b{display:block;color:var(--muted);font-weight:500;font-size:11px;text-transform:uppercase;letter-spacing:.05em;margin-bottom:2px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:16px 0}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:14px 16px}
.card .n{font-size:26px;font-weight:600;letter-spacing:-.02em}
.card .l{font-size:12px;color:var(--muted);margin-top:2px}
.card.sev{border-left:3px solid var(--line)}
.card.sev.crit{border-left-color:var(--critbg)}.card.sev.bad{border-left-color:var(--bad)}
.card.sev.warn{border-left-color:var(--warn)}.card.sev.info{border-left-color:var(--info)}
.tw{overflow-x:auto;border:1px solid var(--line);border-radius:8px;background:var(--card);margin:12px 0}
table{border-collapse:collapse;width:100%;font-size:13.5px}
th{text-align:left;font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);padding:10px 12px;border-bottom:1px solid var(--line);white-space:nowrap;cursor:pointer;user-select:none}
th:hover{color:var(--fg)}th::after{content:'';opacity:.4;margin-left:5px}
th.asc::after{content:'\2191';opacity:1}th.desc::after{content:'\2193';opacity:1}
td{padding:9px 12px;border-bottom:1px solid var(--line);vertical-align:top}
tr:last-child td{border-bottom:none}
code{font:12.5px ui-monospace,SFMono-Regular,Consolas,monospace;background:var(--bg);padding:1px 5px;border-radius:4px;border:1px solid var(--line)}
.pill{display:inline-block;padding:2px 9px;border-radius:99px;font-size:11.5px;font-weight:600;white-space:nowrap}
.ok{background:var(--okbg);color:var(--ok)}.bad{background:var(--badbg);color:var(--bad)}
.warn{background:var(--warnbg);color:var(--warn)}.muted{background:var(--line);color:var(--muted)}
.crit{background:var(--critbg);color:var(--crit)}.info{background:var(--infobg);color:var(--info)}
.note{background:var(--card);border:1px solid var(--line);border-left:3px solid var(--accent);border-radius:6px;padding:12px 16px;margin:12px 0;font-size:13.5px}
.note.bad{border-left-color:var(--bad)}.note.warn{border-left-color:var(--warn)}
.banner{background:var(--warnbg);color:var(--warn);border:1px solid var(--warn);border-radius:8px;padding:11px 18px;margin:16px 0;font-size:13px;font-weight:500}
.filter{width:100%;max-width:340px;padding:8px 12px;border:1px solid var(--line);border-radius:7px;background:var(--card);color:var(--fg);font-size:13.5px;margin:10px 0}
.finding{background:var(--card);border:1px solid var(--line);border-left:3px solid var(--line);border-radius:8px;padding:14px 18px;margin:10px 0}
.finding.crit{border-left-color:var(--critbg)}.finding.bad{border-left-color:var(--bad)}
.finding.warn{border-left-color:var(--warn)}.finding.info{border-left-color:var(--info)}
.finding h4{margin:0 0 6px;font-size:15px}
.finding .loc{font-size:12px;color:var(--muted);margin-bottom:8px}
.finding .ev{font:12px ui-monospace,SFMono-Regular,Consolas,monospace;background:var(--bg);border:1px solid var(--line);border-radius:5px;padding:7px 10px;margin:8px 0;word-break:break-word}
.finding .why{font-size:13.5px;margin:6px 0}
.finding .fix{font-size:13.5px;color:var(--muted)}
.finding .fix b{color:var(--fg);font-weight:600}
ul{margin:6px 0 12px;padding-left:20px}li{margin:3px 0;font-size:13.5px}
.dim{color:var(--muted)}
details{margin:10px 0}summary{cursor:pointer;font-size:13.5px;color:var(--accent);padding:6px 0}
footer{margin-top:56px;padding-top:16px;border-top:1px solid var(--line);color:var(--muted);font-size:12px}
</style>
'@
}

function Get-PPReportJs {
@'
<script>
// Column sort + free-text filter. No framework: the page must work from a file:// path
// with no network, which rules out anything loaded remotely.
document.addEventListener('click', function(e){
  var th = e.target.closest('th'); if(!th) return;
  var table = th.closest('table'); if(!table || !table.tBodies.length) return;
  var idx = Array.prototype.indexOf.call(th.parentNode.children, th);
  var dir = th.classList.contains('asc') ? -1 : 1;
  Array.prototype.forEach.call(th.parentNode.children, function(o){ o.classList.remove('asc','desc'); });
  th.classList.add(dir === 1 ? 'asc' : 'desc');
  var body = table.tBodies[0];
  var rows = Array.prototype.slice.call(body.rows);
  rows.sort(function(a,b){
    var x = (a.cells[idx]||{}).innerText || '', y = (b.cells[idx]||{}).innerText || '';
    var nx = parseFloat(x.replace(/[^0-9.\-]/g,'')), ny = parseFloat(y.replace(/[^0-9.\-]/g,''));
    var bothNum = !isNaN(nx) && !isNaN(ny) && x.trim() !== '' && y.trim() !== '';
    if (bothNum) return (nx - ny) * dir;
    return x.localeCompare(y, undefined, {numeric:true}) * dir;
  });
  rows.forEach(function(r){ body.appendChild(r); });
});
document.addEventListener('input', function(e){
  if(!e.target.classList.contains('filter')) return;
  var q = e.target.value.toLowerCase();
  var scope = document.getElementById(e.target.getAttribute('data-target'));
  if(!scope) return;
  var rows = scope.querySelectorAll('tbody tr, .finding');
  Array.prototype.forEach.call(rows, function(r){
    r.style.display = r.innerText.toLowerCase().indexOf(q) > -1 ? '' : 'none';
  });
});
</script>
'@
}

<#
.SYNOPSIS
    Builds a sortable HTML table from objects and a column specification.
.PARAMETER Columns
    Array of hashtables: @{ H = 'Header'; P = 'PropertyName'; F = { param($row) '<html>' } }
    F (formatter) wins over P when supplied.
#>
function New-PPTable {
    param(
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)]$Columns,
        [string]$Id,
        [string]$EmptyMessage = 'No records.'
    )

    $rows = @($Rows)
    if ($rows.Count -eq 0) {
        return '<div class="note dim">' + (ConvertTo-PPHtmlText $EmptyMessage) + '</div>'
    }

    $sb = New-Object System.Text.StringBuilder
    $idAttr = ''
    if ($Id) { $idAttr = ' id="' + $Id + '"' }
    [void]$sb.AppendLine('<div class="tw"' + $idAttr + '><table><thead><tr>')
    foreach ($c in $Columns) { [void]$sb.AppendLine('<th>' + (ConvertTo-PPHtmlText $c.H) + '</th>') }
    [void]$sb.AppendLine('</tr></thead><tbody>')

    foreach ($r in $rows) {
        [void]$sb.Append('<tr>')
        foreach ($c in $Columns) {
            $cell = ''
            if ($c.F) { $cell = & $c.F $r }
            elseif ($c.P) { $cell = ConvertTo-PPHtmlText $r.($c.P) }
            [void]$sb.Append('<td>' + $cell + '</td>')
        }
        [void]$sb.AppendLine('</tr>')
    }
    [void]$sb.AppendLine('</tbody></table></div>')
    return $sb.ToString()
}

function New-PPPageShell {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)]$Nav,
        [string]$Current,
        [string]$Subtitle,
        [string]$GeneratedUtc
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.AppendLine('<title>' + (ConvertTo-PPHtmlText $Title) + '</title>')
    [void]$sb.AppendLine((Get-PPReportCss))
    [void]$sb.AppendLine('<div class="wrap"><nav>')
    foreach ($n in $Nav) {
        $cls = ''
        if ($n.Key -eq $Current) { $cls = ' class="on"' }
        [void]$sb.AppendLine('<a href="' + $n.File + '"' + $cls + '>' + (ConvertTo-PPHtmlText $n.Label) + '</a>')
    }
    [void]$sb.AppendLine('</nav>')
    [void]$sb.AppendLine('<h1>' + (ConvertTo-PPHtmlText $Title) + '</h1>')
    if ($Subtitle) { [void]$sb.AppendLine('<p class="sub">' + (ConvertTo-PPHtmlText $Subtitle) + '</p>') }
    [void]$sb.AppendLine($Body)
    [void]$sb.AppendLine('<footer>Generated ' + (ConvertTo-PPHtmlText $GeneratedUtc) + ' UTC &middot; read-only collection &middot; Power Platform tenant reporting tool</footer>')
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine((Get-PPReportJs))
    return $sb.ToString()
}
