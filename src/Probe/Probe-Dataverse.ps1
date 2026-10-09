# Probe-Dataverse.ps1 - per-environment Dataverse reachability, agents, and transcript retention.
#
# This answers the three questions gating agent reporting (DESIGN.md 2.3.1 / 2.3.2):
#   1. Can this admin reach Dataverse per environment at all? (Documented as inconsistent -
#      a Power Platform Admin is not automatically a Dataverse user in every environment.)
#   2. Can they read `conversationtranscript`? Requires the Bot Transcript Viewer role, which
#      is NOT implied by tenant admin - expect 403s.
#   3. What is the ACTUAL transcript retention? The 30-day default is enforced by a recurring
#      bulk-delete job the customer may or may not have extended.
#
# Note on (3): we report retention two ways. The bulk-delete job definition is the *intent*;
# the oldest surviving transcript row is the *observed* truth. Observed wins - it needs no
# introspection of job schedules and cannot be fooled by a cancelled-but-not-replaced job.

# Invoke-DvQuery now lives in src/Core/PPDataverse.ps1 so collectors and the probe share it.

function Test-DvTable {
    param($OrgUrl, $Token, $Table, $Select, $Label)

    $q = "$Table" + '?$top=1'
    if ($Select) { $q = "$Table" + '?$select=' + $Select + '&$top=1' }

    $res = Invoke-DvQuery -OrgUrl $OrgUrl -Token $Token -Query $q -Label $Label

    $verdict = 'Denied'
    if ($res.Success)                  { $verdict = 'Readable' }
    elseif ($res.StatusCode -eq 404)   { $verdict = 'Not present' }
    elseif ($res.StatusCode -eq 401)   { $verdict = 'Unauthorised' }

    return [PSCustomObject]@{
        Table      = $Table
        Verdict    = $verdict
        StatusCode = $res.StatusCode
        Success    = $res.Success
        Error      = $res.Error
    }
}

function Get-DvTableCount {
    param($OrgUrl, $Token, $Table, $Label, $Filter)

    $q = "$Table" + '?$count=true&$top=1&$select=' + $(if ($Table -eq 'bots') { 'botid' } else { 'createdon' })
    if ($Filter) { $q += '&$filter=' + $Filter }

    $res = Invoke-DvQuery -OrgUrl $OrgUrl -Token $Token -Query $q -Label $Label
    if ($res.Success -and $res.Content) {
        $c = $res.Content.'@odata.count'
        if ($null -ne $c) { return [int]$c }
    }
    return $null
}

function Invoke-PPDataverseProbe {
    param(
        [Parameter(Mandatory)]$Environment,
        [switch]$IncludeTranscripts
    )

    $orgUrl = $Environment.OrgUrl
    $label  = $Environment.DisplayName
    if (-not $label) { $label = $Environment.Name }

    $result = [PSCustomObject]@{
        Environment      = $label
        EnvironmentId    = $Environment.Name
        OrgUrl           = $orgUrl
        Sku              = $Environment.Sku
        TokenAcquired    = $false
        Reachable        = $false
        WhoAmIUserId     = $null
        AccessError      = $null
        Tables           = @()
        AgentCount       = $null
        AgentStats       = $null
        TranscriptAccess = 'Not probed'
        TranscriptCount  = $null
        OldestTranscript = $null
        ObservedRetentionDays = $null
        RetentionJob     = $null
        Notes            = New-Object System.Collections.ArrayList
    }

    # Dataverse tokens are per-org: the resource IS the org URL.
    $tok = Get-PPToken -Resource $orgUrl
    if (-not $tok.Success) {
        $result.AccessError = "Token acquisition failed: $($tok.Error)"
        Write-PPLog -Level ERROR -Message ("  {0}: no token - {1}" -f $label, $tok.Error)
        return $result
    }
    $result.TokenAcquired = $true
    $token = $tok.AccessToken

    # WhoAmI is the cheapest proof of Dataverse access.
    $who = Invoke-DvQuery -OrgUrl $orgUrl -Token $token -Query 'WhoAmI' -Label "dv:whoami:$($Environment.Name)"
    if (-not $who.Success) {
        $result.AccessError = "HTTP $($who.StatusCode)"
        if ($who.StatusCode -eq 403) {
            [void]$result.Notes.Add('Admin has no Dataverse security role in this environment.')
        }
        Write-PPLog -Level WARN -Message ("  {0}: Dataverse denied (HTTP {1})" -f $label, $who.StatusCode)
        return $result
    }

    $result.Reachable    = $true
    $result.WhoAmIUserId = $who.Content.UserId
    Write-PPLog -Level OK -Message ("  {0}: Dataverse reachable" -f $label)

    # --- Table-by-table reachability -----------------------------------------------------
    $tables = @(
        @{ T = 'organizations';   S = 'organizationid,name' },
        @{ T = 'systemusers';     S = 'systemuserid,domainname' },
        @{ T = 'roles';           S = 'roleid,name' },
        @{ T = 'teams';           S = 'teamid,name' },
        @{ T = 'solutions';       S = 'solutionid,uniquename,ismanaged' },
        @{ T = 'workflows';       S = 'workflowid,name,category' },
        @{ T = 'bots';            S = 'botid,name' },
        @{ T = 'botcomponents';   S = 'botcomponentid,name' },
        @{ T = 'asyncoperations'; S = 'asyncoperationid,name' },
        @{ T = 'plugintracelogs'; S = 'plugintracelogid' },
        @{ T = 'importjobs';      S = 'importjobid' },
        @{ T = 'mailboxes';       S = 'mailboxid' },
        @{ T = 'connectionreferences'; S = 'connectionreferenceid' }
    )

    $tableResults = New-Object System.Collections.ArrayList
    foreach ($t in $tables) {
        [void]$tableResults.Add(
            (Test-DvTable -OrgUrl $orgUrl -Token $token -Table $t.T -Select $t.S `
                          -Label "dv:$($t.T):$($Environment.Name)")
        )
    }
    $result.Tables = $tableResults

    # --- Agents (Copilot Studio) ---------------------------------------------------------
    $botTable = $tableResults | Where-Object { $_.Table -eq 'bots' }
    if ($botTable -and $botTable.Success) {
        $result.AgentCount = Get-DvTableCount -OrgUrl $orgUrl -Token $token -Table 'bots' `
                                              -Label "dv:bots:count:$($Environment.Name)"

        # Pull the governance-relevant columns verified in DESIGN.md 2.3.1 and compute a
        # taste of the findings the real report will produce.
        $sel = 'botid,name,schemaname,statecode,statuscode,accesscontrolpolicy,authenticationmode,' +
               'publishedon,createdon,modifiedon,ismanaged,authorizedsecuritygroupids,_ownerid_value'
        $agents = Invoke-DvQuery -OrgUrl $orgUrl -Token $token `
                    -Query ('bots?$select=' + $sel + '&$top=200') `
                    -Label "dv:bots:detail:$($Environment.Name)"

        if ($agents.Success -and $agents.Content.value) {
            $rows = @($agents.Content.value)
            $result.AgentStats = [PSCustomObject]@{
                Total          = $rows.Count
                Published      = @($rows | Where-Object { $_.publishedon }).Count
                NeverPublished = @($rows | Where-Object { -not $_.publishedon }).Count
                # accesscontrolpolicy 0 = Any (anonymous), 3 = Any (multi-tenant)
                AnonymousAccess = @($rows | Where-Object { $_.accesscontrolpolicy -eq 0 -or $_.accesscontrolpolicy -eq 3 }).Count
                CrossTenant     = @($rows | Where-Object { $_.accesscontrolpolicy -eq 3 }).Count
                # authenticationmode 1 = None
                NoAuth          = @($rows | Where-Object { $_.authenticationmode -eq 1 }).Count
                # statuscode 5 = MissingLicense, 4 = ProvisionFailed
                MissingLicense  = @($rows | Where-Object { $_.statuscode -eq 5 }).Count
                ProvisionFailed = @($rows | Where-Object { $_.statuscode -eq 4 }).Count
                Unmanaged       = @($rows | Where-Object { $_.ismanaged -eq $false }).Count
                Inactive        = @($rows | Where-Object { $_.statecode -eq 1 }).Count
            }
            Write-PPLog -Message ("    {0} agent(s): {1} published, {2} anonymous-access, {3} no-auth" -f `
                $rows.Count, $result.AgentStats.Published, $result.AgentStats.AnonymousAccess, $result.AgentStats.NoAuth)
        }
    }

    # --- Conversation transcripts + real retention ---------------------------------------
    if ($IncludeTranscripts) {
        # Transcripts are documented as never written for developer environments or
        # Dataverse-for-Teams, so absence there is expected rather than a finding.
        $isDev = ($Environment.Sku -eq 'Developer' -or $Environment.Sku -eq 'Teams')

        $tr = Invoke-DvQuery -OrgUrl $orgUrl -Token $token `
                -Query 'conversationtranscripts?$select=conversationtranscriptid,conversationstarttime&$top=1' `
                -Label "dv:transcripts:$($Environment.Name)"

        if ($tr.Success) {
            $result.TranscriptAccess = 'Readable'
            $result.TranscriptCount  = Get-DvTableCount -OrgUrl $orgUrl -Token $token `
                                        -Table 'conversationtranscripts' `
                                        -Label "dv:transcripts:count:$($Environment.Name)"

            # Observed retention: oldest surviving row. This is ground truth.
            $oldest = Invoke-DvQuery -OrgUrl $orgUrl -Token $token `
                        -Query 'conversationtranscripts?$select=conversationstarttime&$orderby=conversationstarttime asc&$top=1' `
                        -Label "dv:transcripts:oldest:$($Environment.Name)"

            if ($oldest.Success -and $oldest.Content.value -and @($oldest.Content.value).Count -gt 0) {
                $ts = $oldest.Content.value[0].conversationstarttime
                if ($ts) {
                    $result.OldestTranscript = $ts
                    try {
                        $days = [int]((Get-Date) - [datetime]$ts).TotalDays
                        $result.ObservedRetentionDays = $days
                        if ($days -le 31) {
                            [void]$result.Notes.Add("Transcript history is ~$days days - default 30-day purge appears active. Long-horizon agent usage reporting is not possible from this environment.")
                        }
                    } catch { }
                }
            }

            # The bulk-delete job definition is the stated intent behind that number.
            $job = Invoke-DvQuery -OrgUrl $orgUrl -Token $token `
                     -Query ("bulkdeleteoperations?" + '$select=name,statuscode,recurrencepattern,createdon' +
                             '&$filter=contains(name,%27Conversation%20Transcript%27)&$top=5') `
                     -Label "dv:bulkdelete:$($Environment.Name)"
            if ($job.Success -and $job.Content.value) {
                $result.RetentionJob = @($job.Content.value | ForEach-Object {
                    [PSCustomObject]@{
                        Name              = $_.name
                        StatusCode        = $_.statuscode
                        RecurrencePattern = $_.recurrencepattern
                    }
                })
            }
        }
        elseif ($tr.StatusCode -eq 403) {
            $result.TranscriptAccess = 'Denied (needs Bot Transcript Viewer role)'
            [void]$result.Notes.Add('Transcripts exist but this admin lacks the Bot Transcript Viewer security role. Agent usage metrics unavailable until granted.')
        }
        elseif ($tr.StatusCode -eq 404) {
            $result.TranscriptAccess = 'Table not present'
            if ($isDev) {
                [void]$result.Notes.Add('Developer/Teams environment - transcripts are never written here by design. Usage is UNKNOWN, not zero.')
            }
        }
        else {
            $result.TranscriptAccess = "HTTP $($tr.StatusCode)"
        }

        Write-PPLog -Message ("    transcripts: {0}" -f $result.TranscriptAccess)
    }

    return $result
}
