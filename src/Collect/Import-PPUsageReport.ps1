# Import-PPUsageReport.ps1 - ingest the PPAC consumption reports an admin downloads by hand.
#
# WHY THIS EXISTS
#
# `/licensing/entitlements/{id}/resources` - the route that answers "which agent is spending the
# credits" - returns 403 for an operator who reads every other route in the Licensing namespace at
# 200, including the per-USER consumption route. It is a permission boundary specific to
# resource-level consumption, it returns no error body naming the required permission, and no
# re-run fixes it.
#
# The same breakdown IS available to a Power Platform Administrator, by hand:
#   PPAC > Licensing > Products > Copilot Studio > Summary > Download report > environment|agent|user
#   PPAC > Licensing > Capacity add-ons > Download reports        (AI Builder, PP requests)
#   PPAC > the Billing plan page                                  (pay-as-you-go report)
#
# So this module reads that file and feeds it into the same pipeline the API feeds, which is why
# the Usage page and the findings engine need no knowledge of where a row came from - beyond the
# Source column, which they do show, because a hand-exported file and a live API read have very
# different staleness and must never be presented as equivalent.
#
# DESIGN CONSTRAINTS
#
#  1. COLUMN NAMES ARE NOT STABLE and differ per report type (agent vs user vs environment vs
#     pay-as-you-go), per product, and across service updates. So nothing here is positional:
#     every logical field is resolved from a candidate list of header spellings, the same
#     defensive approach the API collector uses for payload fields. Unmapped headers are kept and
#     reported rather than dropped, so a renamed column shows up as a visible gap instead of a
#     silently empty table.
#
#  2. NO EXTERNAL MODULES. These reports arrive as .csv or .xlsx. The xlsx reader here unzips the
#     package and parses the sheet XML directly - no ImportExcel, no Excel COM, no Office install.
#     The tool stays self-contained and air-gap safe, which is a project-wide rule.
#
#  3. ONE SOURCE OF TRUTH PER METER. If the API already returned per-resource rows for a meter,
#     imported rows for that same meter are dropped rather than appended. Summing both would
#     double-count spend, and a cost report that double-counts is worse than one that is missing
#     a section.
#
# Read-only: this module touches the filesystem only, and only for reading.

# Logical field -> header spellings seen across the PPAC report family. Matching is
# case-insensitive and ignores spaces, underscores and punctuation, so "Billed credits",
# "billed_credits" and "BilledCredits" all resolve. Longest/most specific candidates first:
# 'Non-billed credits' must win over 'credits' before 'Billed credits' can claim it.
$script:PPReportColumnMap = [ordered]@{
    ResourceName    = @('agentname','agentdisplayname','resourcename','botname','appname','flowname','copilotname','agent','resource')
    ResourceId      = @('agentid','agentschemaname','resourceid','botid','appid','flowid','objectid','agentguid')
    ResourceType    = @('resourcetype','assettype','type')
    EnvironmentName = @('environmentname','environmentdisplayname','environment')
    EnvironmentId   = @('environmentid','environmentguid','envid')
    Billed          = @('billedcredits','billedquantity','billedmessages','billedsessions','billed')
    NonBillable     = @('nonbilledcredits','nonbillablecredits','nonbilledquantity','nonbillable','nonbilled')
    Consumed        = @('creditsconsumed','creditsused','totalcredits','consumedquantity','consumedcredits','consumption','consumed','quantity','usage')
    Overage         = @('overagequantity','overage')
    Product         = @('product','productname')
    Feature         = @('aifeature','featurename','billablefeature','productaifeature','metercategory','meter','feature')
    Channel         = @('channel','channelname')
    Model           = @('llmmodel','modelname','model')
    Knowledge       = @('knowledgesources','knowledgesource','toolused','toolsused','tool')
    UserName        = @('username','userdisplayname','callername','displayname','user')
    UPN             = @('userprincipalname','upn','useremail','email')
    UserId          = @('userid','callerid','userguid','userobjectid')
    CallerType      = @('callertype')
    Currency        = @('currencytype','currency','entitlement','entitlementid')
    Date            = @('usagedate','consumptiondate','date','day')
}

function Get-PPNormalizedHeader {
    param([string]$Header)
    if ($null -eq $Header) { return '' }
    # Strip everything that varies cosmetically between exports: case, spaces, underscores,
    # hyphens, slashes, parentheses, and a trailing unit hint like "(credits)".
    return ([string]$Header).ToLower() -replace '[^a-z0-9]', ''
}

<#
.SYNOPSIS
    Maps the report's actual headers onto logical field names.
.OUTPUTS
    PSCustomObject: Map (logical -> actual header), Unmapped (headers we did not recognise)
#>
function Resolve-PPReportColumns {
    param([Parameter(Mandatory)][string[]]$Headers)

    $map    = @{}
    $claimed = @{}

    foreach ($logical in $script:PPReportColumnMap.Keys) {
        foreach ($candidate in $script:PPReportColumnMap[$logical]) {
            $hit = $null
            foreach ($h in $Headers) {
                if ($claimed.ContainsKey($h)) { continue }
                $n = Get-PPNormalizedHeader $h
                # Exact first, then contains - 'Billed credits (billed)' should still map, but an
                # exact match must always beat a substring one.
                if ($n -eq $candidate) { $hit = $h; break }
            }
            if (-not $hit) {
                foreach ($h in $Headers) {
                    if ($claimed.ContainsKey($h)) { continue }
                    $n = Get-PPNormalizedHeader $h
                    if ($n -and $n.Contains($candidate)) { $hit = $h; break }
                }
            }
            if ($hit) {
                $map[$logical]   = $hit
                $claimed[$hit]   = $true
                break
            }
        }
    }

    $unmapped = @($Headers | Where-Object { $_ -and -not $claimed.ContainsKey($_) })
    return [PSCustomObject]@{ Map = $map; Unmapped = $unmapped }
}

function Get-PPReportValue {
    param($Row, $Columns, [string]$Logical)
    if (-not $Columns.Map.ContainsKey($Logical)) { return $null }
    $v = $Row.($Columns.Map[$Logical])
    if ($null -eq $v -or "$v" -eq '') { return $null }
    return $v
}

<#
.SYNOPSIS
    Reads a CSV export, skipping any preamble above the real header row.
.DESCRIPTION
    PPAC exports sometimes carry title/date lines above the header. Import-Csv would take the
    first line as headers and produce one garbage column, so the header row is located by looking
    for the first line that yields a recognisable column.
#>
function Get-PPCsvTable {
    param([Parameter(Mandatory)][string]$Path)

    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    if ($lines.Count -eq 0) { return $null }

    $start = -1
    for ($i = 0; $i -lt [Math]::Min($lines.Count, 25); $i++) {
        $line = $lines[$i]
        if (-not $line -or -not ($line -match ',|;|\t')) { continue }
        # Parse this single line as a header and see whether anything maps. A real header row
        # always resolves at least one known field; a title line does not.
        $candidateHeaders = @(($line -split ',') | ForEach-Object { $_.Trim(' ', '"') })
        $probe = Resolve-PPReportColumns -Headers $candidateHeaders
        if ($probe.Map.Count -ge 2) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }

    $body = $lines[$start..($lines.Count - 1)] -join "`r`n"
    $rows = @($body | ConvertFrom-Csv)
    if (@($rows).Count -eq 0) { return $null }

    $headers = @($rows[0].PSObject.Properties.Name)
    return [PSCustomObject]@{ Headers = $headers; Rows = $rows; PreambleLines = $start }
}

function ConvertFrom-PPCellRef {
    param([string]$Ref)
    # "BC12" -> 55. Needed because sheet XML omits empty cells: without decoding the column
    # letters, every row with a blank cell would shift its remaining values one column left.
    $letters = ($Ref -replace '[^A-Za-z]', '')
    if (-not $letters) { return 0 }
    $n = 0
    foreach ($ch in $letters.ToUpper().ToCharArray()) { $n = ($n * 26) + ([int][char]$ch - 64) }
    return $n
}

<#
.SYNOPSIS
    Reads the first worksheet of an .xlsx without Excel, COM or any external module.
.DESCRIPTION
    An .xlsx is a zip of XML. Shared strings live in xl/sharedStrings.xml and cells reference them
    by index when t="s". Empty cells are omitted from the XML entirely, so cell references are
    decoded rather than counted.
#>
function Get-PPXlsxTable {
    param([Parameter(Mandatory)][string]$Path)

    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)

        # Entry names are matched with separators normalised. The OPC spec says '/', and Excel
        # writes '/', but .NET Framework's ZipFile.CreateFromDirectory on Windows writes '\' -
        # so a package that has been through some intermediate tooling can arrive either way.
        # Matching on '/' alone silently finds no sheet and reports the file as unreadable.
        $norm = { param($S) ([string]$S).Replace('\', '/') }

        $readEntry = {
            param($Name)
            $e = $zip.Entries | Where-Object { (& $norm $_.FullName) -eq $Name } | Select-Object -First 1
            if (-not $e) { return $null }
            $sr = New-Object System.IO.StreamReader($e.Open())
            try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
        }

        # Shared strings. A cell can hold several runs (<r><t>..</t></r>), so concatenate all <t>.
        $shared = @()
        $ssXml = & $readEntry 'xl/sharedStrings.xml'
        if ($ssXml) {
            $ss = [xml]$ssXml
            $ns = New-Object System.Xml.XmlNamespaceManager($ss.NameTable)
            $ns.AddNamespace('d', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
            foreach ($si in $ss.SelectNodes('//d:si', $ns)) {
                $parts = @($si.SelectNodes('.//d:t', $ns) | ForEach-Object { $_.InnerText })
                $shared += ,(($parts -join ''))
            }
        }

        # First worksheet by part name. Sorting matters: sheet10 must not beat sheet2.
        $sheetEntry = @($zip.Entries |
            Where-Object { (& $norm $_.FullName) -match '^xl/worksheets/sheet\d+\.xml$' } |
            Sort-Object { [int]([regex]::Match((& $norm $_.FullName), 'sheet(\d+)\.xml$').Groups[1].Value) } |
            Select-Object -First 1)
        if (-not $sheetEntry) { return $null }

        $sheetXml = & $readEntry (& $norm $sheetEntry[0].FullName)
        if (-not $sheetXml) { return $null }

        $doc = [xml]$sheetXml
        $ns2 = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
        $ns2.AddNamespace('d', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')

        $matrix = New-Object System.Collections.ArrayList
        $width  = 0
        foreach ($row in $doc.SelectNodes('//d:sheetData/d:row', $ns2)) {
            $cells = @{}
            foreach ($c in $row.SelectNodes('d:c', $ns2)) {
                $idx = ConvertFrom-PPCellRef $c.GetAttribute('r')
                if ($idx -le 0) { continue }
                $t = $c.GetAttribute('t')
                $val = $null
                if ($t -eq 's') {
                    $vNode = $c.SelectSingleNode('d:v', $ns2)
                    if ($vNode) {
                        $si = 0
                        if ([int]::TryParse($vNode.InnerText, [ref]$si) -and $si -lt $shared.Count) { $val = $shared[$si] }
                    }
                } elseif ($t -eq 'inlineStr') {
                    $isNode = $c.SelectSingleNode('d:is', $ns2)
                    if ($isNode) { $val = (@($isNode.SelectNodes('.//d:t', $ns2) | ForEach-Object { $_.InnerText }) -join '') }
                } else {
                    $vNode = $c.SelectSingleNode('d:v', $ns2)
                    if ($vNode) { $val = $vNode.InnerText }
                }
                $cells[$idx] = $val
                if ($idx -gt $width) { $width = $idx }
            }
            [void]$matrix.Add($cells)
        }
        if ($matrix.Count -lt 2 -or $width -lt 1) { return $null }

        # Header row: the first row that resolves at least two known fields, so a title row above
        # the table is skipped the same way as in CSV.
        $headerRow = -1
        $headers   = $null
        for ($i = 0; $i -lt [Math]::Min($matrix.Count, 25); $i++) {
            $cand = @(1..$width | ForEach-Object { [string]$matrix[$i][$_] })
            if (@($cand | Where-Object { $_ }).Count -lt 2) { continue }
            $probe = Resolve-PPReportColumns -Headers @($cand | Where-Object { $_ })
            if ($probe.Map.Count -ge 2) { $headerRow = $i; $headers = $cand; break }
        }
        if ($headerRow -lt 0) { return $null }

        # Blank or duplicate header cells would collide as property names; give them stable
        # placeholders so the row objects stay well-formed and the columns stay reportable.
        $final = @()
        $seen  = @{}
        for ($c = 0; $c -lt $headers.Count; $c++) {
            $h = [string]$headers[$c]
            if (-not $h) { $h = "column$($c + 1)" }
            if ($seen.ContainsKey($h)) { $h = "$h($($c + 1))" }
            $seen[$h] = $true
            $final += $h
        }

        $rows = New-Object System.Collections.ArrayList
        for ($i = $headerRow + 1; $i -lt $matrix.Count; $i++) {
            $o = [ordered]@{}
            for ($c = 1; $c -le $width; $c++) { $o[$final[$c - 1]] = $matrix[$i][$c] }
            if (@($o.Values | Where-Object { $_ }).Count -eq 0) { continue }   # skip blank rows
            [void]$rows.Add([PSCustomObject]$o)
        }
        if ($rows.Count -eq 0) { return $null }

        return [PSCustomObject]@{ Headers = $final; Rows = @($rows); PreambleLines = $headerRow }
    }
    catch {
        Write-PPLog -Level WARN -Message ("    Could not read xlsx: {0}" -f $_.Exception.Message)
        return $null
    }
    finally { if ($zip) { $zip.Dispose() } }
}

function Get-PPReportTable {
    param([Parameter(Mandatory)][string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLower()
    switch ($ext) {
        '.xlsx' { return Get-PPXlsxTable -Path $Path }
        '.xlsm' { return Get-PPXlsxTable -Path $Path }
        default { return Get-PPCsvTable  -Path $Path }
    }
}

<#
.SYNOPSIS
    Decides what kind of consumption report this is, from the columns it carries.
#>
function Get-PPReportKind {
    param($Columns)
    $hasResource = ($Columns.Map.ContainsKey('ResourceName') -or $Columns.Map.ContainsKey('ResourceId'))
    $hasUser     = ($Columns.Map.ContainsKey('UserName') -or $Columns.Map.ContainsKey('UPN') -or $Columns.Map.ContainsKey('UserId'))
    # Resource wins when both are present: the agent-and-user pair report is still, for our
    # purposes, an attribution-by-agent table, and that is the gap we are filling.
    if ($hasResource) { return 'Resource' }
    if ($hasUser)     { return 'User' }
    if ($Columns.Map.ContainsKey('EnvironmentName') -or $Columns.Map.ContainsKey('EnvironmentId')) { return 'Environment' }
    return 'Unknown'
}

<#
.SYNOPSIS
    Imports one or more downloaded PPAC consumption reports into a collected Usage object.
.DESCRIPTION
    Rows are normalised into exactly the shape Collect-Usage produces, joined to the asset
    inventory by resource ID and - because these exports often carry only a display name - by
    name as a fallback. Imported rows are tagged Source = 'PPAC report' so the renderer can show
    provenance and so a hand export is never presented as a live API read.
.PARAMETER Path
    A report file, or a folder of them. Folders are scanned non-recursively for csv/xlsx.
.OUTPUTS
    The same Usage object, with Resources/Users/ImportedEnvironments extended and Imports
    describing what was read.
#>
function Import-PPUsageReport {
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)]$Usage,
        $Agents,
        $Apps,
        $Flows,
        $Environments,
        $UserIndex,
        [string]$DefaultCurrency = 'MCSMessages'
    )

    if (-not $Usage) {
        Write-PPLog -Level WARN -Message '  No usage object to import into; skipping report import.'
        return $Usage
    }

    # Collect-Usage returns a PSCustomObject; these members may not exist on it yet.
    foreach ($m in @('Imports', 'ImportedEnvironments')) {
        if (-not ($Usage.PSObject.Properties.Name -contains $m)) {
            $Usage | Add-Member -NotePropertyName $m -NotePropertyValue @() -Force
        }
    }

    # Resolve the file list first so a bad path fails loudly before anything is parsed.
    $files = New-Object System.Collections.ArrayList
    foreach ($p in $Path) {
        if (-not (Test-Path -LiteralPath $p)) {
            Write-PPLog -Level WARN -Message ("  Report path not found: {0}" -f $p)
            $Usage.Gaps += [PSCustomObject]@{
                Item = 'Usage report import'; Reason = "Path not found: $p"
            }
            continue
        }
        $item = Get-Item -LiteralPath $p
        if ($item.PSIsContainer) {
            foreach ($f in @(Get-ChildItem -LiteralPath $p -File | Where-Object { $_.Extension -match '^\.(csv|xlsx|xlsm|tsv|txt)$' })) {
                [void]$files.Add($f.FullName)
            }
        } else {
            [void]$files.Add($item.FullName)
        }
    }
    if ($files.Count -eq 0) {
        Write-PPLog -Level WARN -Message '  No importable report files found.'
        return $Usage
    }

    # Two indexes: by ID (authoritative) and by name (what these exports usually carry).
    $byId   = New-PPResourceIndex -Agents $Agents -Apps $Apps -Flows $Flows
    $byName = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    $addName = {
        param($Name, $Id, $Kind, $EnvId, $EnvName)
        if (-not $Name) { return }
        $k = [string]$Name
        # Ambiguous names are recorded as ambiguous rather than resolved to a coin-flip: two
        # agents called "HR bot" in different environments must not silently become one.
        if ($byName.ContainsKey($k)) { $byName[$k] = $null; return }
        $byName[$k] = [PSCustomObject]@{ Id = $Id; Kind = $Kind; EnvironmentId = $EnvId; EnvironmentName = $EnvName }
    }
    foreach ($a in @($Agents)) { & $addName $a.Name        $a.Id 'Agent' $a.EnvironmentId $a.EnvironmentName }
    foreach ($a in @($Apps))   { & $addName $a.DisplayName $a.Id 'App'   $a.EnvironmentId $a.EnvironmentName }
    foreach ($f in @($Flows))  { & $addName $f.DisplayName $f.Id 'Flow'  $f.EnvironmentId $f.EnvironmentName }

    $envByName = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    $envById   = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in @($Environments)) {
        if ($e.DisplayName) { $envByName[[string]$e.DisplayName] = $e }
        if ($e.Name)        { $envById[[string]$e.Name] = $e }
    }

    # Meters the API already attributed per resource. Importing on top of these would double-count.
    $apiMeters = @(@($Usage.Resources) | ForEach-Object { $_.Currency } | Where-Object { $_ } | Select-Object -Unique)

    $imports   = New-Object System.Collections.ArrayList
    $newRes    = New-Object System.Collections.ArrayList
    $newUsers  = New-Object System.Collections.ArrayList
    $newEnvs   = New-Object System.Collections.ArrayList

    foreach ($file in $files) {
        $name = Split-Path $file -Leaf
        Write-PPLog -Message ("  Importing {0}" -f $name)

        $table = Get-PPReportTable -Path $file
        if (-not $table) {
            Write-PPLog -Level WARN -Message '    No recognisable header row found - skipped.'
            [void]$imports.Add([PSCustomObject]@{
                File = $name; Kind = 'Unreadable'; Rows = 0; Imported = 0; Skipped = 0
                Currency = $null; Unmapped = @(); Mapped = @()
                Reason = 'No header row resolved to known consumption columns. Either this is not a consumption export, or the column names have changed - compare its headers against the candidate list in Import-PPUsageReport.ps1.'
            })
            $Usage.Gaps += [PSCustomObject]@{
                Item = "Usage report import ($name)"
                Reason = 'No recognisable consumption columns. The file was not imported, so per-agent attribution is still missing rather than wrong.'
            }
            continue
        }

        $cols = Resolve-PPReportColumns -Headers $table.Headers
        $kind = Get-PPReportKind -Columns $cols

        # Currency: from the file if it says, else the caller's default. Copilot Studio exports
        # usually do not name the meter because the page you downloaded them from implied it.
        $fileCurrency = $null
        foreach ($r in @($table.Rows)) {
            $c = Get-PPReportValue $r $cols 'Currency'
            if ($c) { $fileCurrency = [string]$c; break }
        }
        if (-not $fileCurrency) { $fileCurrency = $DefaultCurrency }
        $curLabel = Get-PPCurrencyLabel $fileCurrency

        Write-PPLog -Message ("    {0} report, {1} row(s), {2} column(s) mapped, meter {3}" -f `
            $kind, @($table.Rows).Count, $cols.Map.Count, $fileCurrency)

        if ($kind -eq 'Resource' -and ($apiMeters -contains $fileCurrency)) {
            # Single source of truth per meter: the API already answered for this one.
            Write-PPLog -Level WARN -Message ("    Skipped: the API already returned per-resource rows for {0}" -f $fileCurrency)
            [void]$imports.Add([PSCustomObject]@{
                File = $name; Kind = $kind; Rows = @($table.Rows).Count; Imported = 0
                Skipped = @($table.Rows).Count; Currency = $fileCurrency
                Unmapped = $cols.Unmapped; Mapped = @($cols.Map.Keys)
                Reason = "Not imported: the Licensing API already returned per-resource consumption for $curLabel. Appending this file would double-count the same spend."
            })
            continue
        }

        $imported = 0
        foreach ($r in @($table.Rows)) {
            $billed      = Get-PPNumberOrNull (Get-PPReportValue $r $cols 'Billed')
            $nonBillable = Get-PPNumberOrNull (Get-PPReportValue $r $cols 'NonBillable')
            $consumed    = Get-PPNumberOrNull (Get-PPReportValue $r $cols 'Consumed')

            # These reports often give billed and non-billed but no total. Derive the total, and
            # only the total: never invent a billed figure from a total, because the billed/
            # non-billed split is the whole point of the column and guessing it misstates cost.
            if ($null -eq $consumed -and ($null -ne $billed -or $null -ne $nonBillable)) {
                $consumed = 0.0
                if ($null -ne $billed)      { $consumed += $billed }
                if ($null -ne $nonBillable) { $consumed += $nonBillable }
            }
            if ($null -eq $consumed -and $null -eq $billed) { continue }   # nothing numeric: not a data row

            $envName = [string](Get-PPReportValue $r $cols 'EnvironmentName')
            $envId   = [string](Get-PPReportValue $r $cols 'EnvironmentId')
            if (-not $envId -and $envName -and $envByName.ContainsKey($envName)) { $envId = $envByName[$envName].Name }
            if (-not $envName -and $envId -and $envById.ContainsKey($envId))     { $envName = $envById[$envId].DisplayName }

            if ($kind -eq 'Resource') {
                $rid    = [string](Get-PPReportValue $r $cols 'ResourceId')
                $rname  = [string](Get-PPReportValue $r $cols 'ResourceName')
                $hit    = $null
                if ($rid -and $byId.ContainsKey($rid))        { $hit = $byId[$rid] }
                elseif ($rname -and $byName.ContainsKey($rname)) { $hit = $byName[$rname] }   # $null if ambiguous

                [void]$newRes.Add([PSCustomObject]@{
                    Currency        = $fileCurrency
                    CurrencyLabel   = $curLabel
                    ResourceId      = $(if ($rid) { $rid } elseif ($hit) { $hit.Id } else { $null })
                    ResourceName    = $(if ($rname) { $rname } elseif ($hit) { $hit.Name } else { $null })
                    ResourceKind    = $(if ($hit) { $hit.Kind } elseif (Get-PPReportValue $r $cols 'ResourceType') { [string](Get-PPReportValue $r $cols 'ResourceType') } else { 'Unmatched' })
                    Matched         = [bool]$hit
                    EnvironmentId   = $envId
                    EnvironmentName = $(if ($envName) { $envName } elseif ($hit) { $hit.EnvironmentName } else { $null })
                    Consumed        = $consumed
                    NonBillable     = $nonBillable
                    Billed          = $billed
                    Unit            = [string](Get-PPReportValue $r $cols 'Currency')
                    Feature         = [string](Get-PPReportValue $r $cols 'Feature')
                    ProductName     = [string](Get-PPReportValue $r $cols 'Product')
                    LastConsumed    = Get-PPReportValue $r $cols 'Date'
                    # Columns the API does not return at all - this export is richer than the
                    # route that is blocked, which is worth saying out loud on the page.
                    Channel         = [string](Get-PPReportValue $r $cols 'Channel')
                    Model           = [string](Get-PPReportValue $r $cols 'Model')
                    Knowledge       = [string](Get-PPReportValue $r $cols 'Knowledge')
                    Source          = 'PPAC report'
                    SourceFile      = $name
                })
                $imported++
            }
            elseif ($kind -eq 'User') {
                $uid   = [string](Get-PPReportValue $r $cols 'UserId')
                $uname = [string](Get-PPReportValue $r $cols 'UserName')
                $upn   = [string](Get-PPReportValue $r $cols 'UPN')
                $resolved = Resolve-PPOwner -UserIndex $UserIndex -OwnerId $uid -FallbackName $(if ($uname) { $uname } else { $upn })
                $dir = $null
                if ($UserIndex -and $uid -and $UserIndex.ContainsKey($uid)) { $dir = $UserIndex[$uid] }

                [void]$newUsers.Add([PSCustomObject]@{
                    Currency         = $fileCurrency
                    CurrencyLabel    = $curLabel
                    UserId           = $uid
                    UserName         = $(if ($resolved.Name) { $resolved.Name } elseif ($uname) { $uname } else { $upn })
                    UPN              = $(if ($resolved.UPN) { $resolved.UPN } else { $upn })
                    Department       = $(if ($dir) { $dir.Department } else { $null })
                    JobTitle         = $(if ($dir) { $dir.JobTitle } else { $null })
                    AccountEnabled   = $resolved.Enabled
                    # Only claim orphaned when the directory was actually consulted: without a
                    # user ID there is nothing to look up, and "not found" would be a lie.
                    Orphaned         = $(if ($uid) { $resolved.Orphaned } else { $false })
                    KnownInDirectory = $(if ($uid) { $resolved.Known } else { $false })
                    EnvironmentId    = $envId
                    EnvironmentName  = $envName
                    Consumed         = $consumed
                    NonBillable      = $nonBillable
                    Unit             = [string](Get-PPReportValue $r $cols 'Currency')
                    LastConsumed     = Get-PPReportValue $r $cols 'Date'
                    CallerType       = [string](Get-PPReportValue $r $cols 'CallerType')
                    Source           = 'PPAC report'
                    SourceFile       = $name
                })
                $imported++
            }
            elseif ($kind -eq 'Environment') {
                [void]$newEnvs.Add([PSCustomObject]@{
                    Currency        = $fileCurrency
                    CurrencyLabel   = $curLabel
                    EnvironmentId   = $envId
                    EnvironmentName = $envName
                    Consumed        = $consumed
                    NonBillable     = $nonBillable
                    Billed          = $billed
                    Overage         = Get-PPNumberOrNull (Get-PPReportValue $r $cols 'Overage')
                    LastConsumed    = Get-PPReportValue $r $cols 'Date'
                    Source          = 'PPAC report'
                    SourceFile      = $name
                })
                $imported++
            }
        }

        Write-PPLog -Level OK -Message ("    {0} row(s) imported" -f $imported)
        if (@($cols.Unmapped).Count -gt 0) {
            Write-PPLog -Level DEBUG -Message ("    Unmapped columns: {0}" -f (@($cols.Unmapped) -join ', '))
        }

        [void]$imports.Add([PSCustomObject]@{
            File = $name; Kind = $kind; Rows = @($table.Rows).Count; Imported = $imported
            Skipped = (@($table.Rows).Count - $imported); Currency = $fileCurrency
            Unmapped = @($cols.Unmapped); Mapped = @($cols.Map.Keys)
            Reason = $(if ($kind -eq 'Unknown') { 'No resource, user or environment column was recognised, so these rows could not be attributed to anything.' } else { $null })
        })
    }

    # Tag the API-sourced rows so the two provenances are distinguishable in one table. Done here
    # rather than in Collect-Usage so the API collector stays unaware of imports entirely.
    $tagged = @(@($Usage.Resources) | ForEach-Object {
        if (-not ($_.PSObject.Properties.Name -contains 'Source')) {
            $_ | Add-Member -NotePropertyName Source -NotePropertyValue 'Licensing API' -Force
        }
        $_
    })
    $taggedUsers = @(@($Usage.Users) | ForEach-Object {
        if (-not ($_.PSObject.Properties.Name -contains 'Source')) {
            $_ | Add-Member -NotePropertyName Source -NotePropertyValue 'Licensing API' -Force
        }
        $_
    })

    $Usage.Resources            = @($tagged) + @($newRes)
    $Usage.Users                = @($taggedUsers) + @($newUsers)
    $Usage.ImportedEnvironments = @($Usage.ImportedEnvironments) + @($newEnvs)
    $Usage.Imports              = @($Usage.Imports) + @($imports)

    # Recompute the department rollup: it is derived from Users, which just grew.
    if (@($Usage.Users).Count -gt 0) {
        $Usage.Departments = @($Usage.Users |
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

    Write-PPLog -Level OK -Message ("  Imported {0} resource row(s), {1} user row(s), {2} environment row(s) from {3} file(s)" -f `
        @($newRes).Count, @($newUsers).Count, @($newEnvs).Count, @($files).Count)

    return $Usage
}
