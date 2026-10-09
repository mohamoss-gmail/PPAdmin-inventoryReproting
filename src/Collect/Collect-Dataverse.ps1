# Collect-Dataverse.ps1 - per-environment depth: agents, solutions, security, failures.
#
# Column semantics for `bot` are mirrored from the Copilot Studio Kit's published "Agent
# Details" derivation rules, so our output is comparable to the Kit's rather than a parallel
# invention. See DESIGN.md 2.3.1.

# bot.accesscontrolpolicy
$script:BotAccessPolicy = @{ 0 = 'Any (anonymous)'; 1 = 'Copilot readers'; 2 = 'Group membership'; 3 = 'Any (multi-tenant)' }
# bot.authenticationmode
$script:BotAuthMode     = @{ 0 = 'Unspecified'; 1 = 'None'; 2 = 'Integrated'; 3 = 'Custom Entra ID'; 4 = 'Generic OAuth2' }
# bot.statuscode
$script:BotStatus       = @{ 1 = 'Provisioned'; 2 = 'Deprovisioned'; 3 = 'Provisioning'; 4 = 'ProvisionFailed'; 5 = 'MissingLicense' }
# workflow.category
$script:WorkflowCategory = @{ 0 = 'Classic workflow'; 1 = 'Dialog'; 2 = 'Business rule'; 3 = 'Action'; 4 = 'Business process flow'; 5 = 'Cloud flow'; 6 = 'Desktop flow'; 7 = 'AI flow' }

function Get-PPLookupLabel {
    param($Map, $Value, $Fallback = 'Unknown')
    if ($null -eq $Value) { return $Fallback }
    if ($Map.ContainsKey([int]$Value)) { return $Map[[int]$Value] }
    return "$Fallback ($Value)"
}

function Invoke-PPCollectDataverse {
    param(
        [Parameter(Mandatory)]$Environment,
        [switch]$IncludeAgents,
        [switch]$IncludeSolutions,
        [switch]$IncludeSecurity,
        [switch]$IncludeErrors
    )

    $label = $Environment.DisplayName
    if (-not $label) { $label = $Environment.Name }

    $out = [PSCustomObject]@{
        EnvironmentId   = $Environment.Name
        EnvironmentName = $label
        OrgUrl          = $Environment.OrgUrl
        Sku             = $Environment.Sku
        Reachable       = $false
        Reason          = $null
        Agents          = @()
        Solutions       = @()
        SystemUsers     = @()
        ApplicationUsers = @()
        AdminUsers      = @()
        Workflows       = @()
        AsyncFailures   = @()
    }

    $conn = Connect-DvEnvironment -OrgUrl $Environment.OrgUrl
    if (-not $conn.Success) {
        $out.Reason = $conn.Reason
        Write-PPLog -Level WARN -Message ("  {0}: {1}" -f $label, $conn.Reason)
        return $out
    }
    $out.Reachable = $true
    $token = $conn.Token

    # --- Agents ------------------------------------------------------------------------
    if ($IncludeAgents) {
        $sel = 'botid,name,schemaname,statecode,statuscode,accesscontrolpolicy,authenticationmode,' +
               'authenticationtrigger,authorizedsecuritygroupids,publishedon,createdon,modifiedon,' +
               'ismanaged,language,configuration,_ownerid_value,_createdby_value,_publishedby_value'

        $r = Get-DvRows -OrgUrl $Environment.OrgUrl -Token $token -Label "dv:bots:$($Environment.Name)" `
                        -Query ('bots?$select=' + $sel)

        if ($r.Success) {
            $out.Agents = @($r.Rows | ForEach-Object {
                # `configuration` is a JSON blob holding the generative-AI posture.
                $cfg = $null
                try { if ($_.configuration) { $cfg = $_.configuration | ConvertFrom-Json } } catch { }

                [PSCustomObject]@{
                    Id                = $_.botid
                    Name              = $_.name
                    SchemaName        = $_.schemaname
                    EnvironmentId     = $Environment.Name
                    EnvironmentName   = $label
                    State             = $(if ($_.statecode -eq 0) { 'Active' } else { 'Inactive' })
                    Status            = Get-PPLookupLabel $script:BotStatus $_.statuscode
                    StatusCode        = $_.statuscode
                    AccessPolicy      = Get-PPLookupLabel $script:BotAccessPolicy $_.accesscontrolpolicy
                    AccessPolicyCode  = $_.accesscontrolpolicy
                    AuthMode          = Get-PPLookupLabel $script:BotAuthMode $_.authenticationmode
                    AuthModeCode      = $_.authenticationmode
                    AuthorizedGroups  = $_.authorizedsecuritygroupids
                    PublishedOn       = $_.publishedon
                    IsPublished       = [bool]$_.publishedon
                    CreatedOn         = $_.createdon
                    ModifiedOn        = $_.modifiedon
                    IsManaged         = [bool]$_.ismanaged
                    OwnerId           = $_.'_ownerid_value'
                    CreatedById       = $_.'_createdby_value'
                    PublishedById     = $_.'_publishedby_value'
                    # Generative posture, per the Kit's derivation rules.
                    GenerativeOrch    = $(if ($cfg) { [bool]$cfg.GenerativeActionsEnabled } else { $null })
                    UsesModelKnowledge = $(if ($cfg) { [bool]$cfg.useModelKnowledge } else { $null })
                    SemanticSearch    = $(if ($cfg) { [bool]$cfg.isSemanticSearchEnabled } else { $null })
                    DeepReasoning     = $(if ($cfg) { [bool]$cfg.optInUseLatestModels } else { $null })
                    FileAnalysis      = $(if ($cfg) { [bool]$cfg.isFileAnalysisEnabled } else { $null })
                }
            })
            Write-PPLog -Level OK -Message ("  {0}: {1} agent(s)" -f $label, $out.Agents.Count)
        }

        # componenttype 17 = External Trigger => the agent is autonomous.
        if ($out.Agents.Count -gt 0) {
            $bc = Get-DvRows -OrgUrl $Environment.OrgUrl -Token $token -Label "dv:botcomponents:$($Environment.Name)" `
                    -Query ('botcomponents?$select=botcomponentid,name,componenttype,_parentbotid_value&$filter=componenttype%20eq%2017')
            if ($bc.Success -and $bc.Count -gt 0) {
                $autonomous = @($bc.Rows | ForEach-Object { $_.'_parentbotid_value' } | Select-Object -Unique)
                foreach ($a in $out.Agents) {
                    Add-Member -InputObject $a -NotePropertyName 'IsAutonomous' `
                               -NotePropertyValue ($autonomous -contains $a.Id) -Force
                }
            } else {
                foreach ($a in $out.Agents) {
                    Add-Member -InputObject $a -NotePropertyName 'IsAutonomous' -NotePropertyValue $false -Force
                }
            }
        }
    }

    # --- Solutions ---------------------------------------------------------------------
    if ($IncludeSolutions) {
        $r = Get-DvRows -OrgUrl $Environment.OrgUrl -Token $token -Label "dv:solutions:$($Environment.Name)" `
              -Query ('solutions?$select=solutionid,uniquename,friendlyname,version,ismanaged,installedon,isvisible' +
                      '&$expand=publisherid($select=friendlyname,customizationprefix)' +
                      '&$filter=isvisible%20eq%20true')
        if ($r.Success) {
            $out.Solutions = @($r.Rows | ForEach-Object {
                [PSCustomObject]@{
                    Id              = $_.solutionid
                    UniqueName      = $_.uniquename
                    FriendlyName    = $_.friendlyname
                    Version         = $_.version
                    IsManaged       = [bool]$_.ismanaged
                    InstalledOn     = $_.installedon
                    Publisher       = $(if ($_.publisherid) { $_.publisherid.friendlyname } else { $null })
                    Prefix          = $(if ($_.publisherid) { $_.publisherid.customizationprefix } else { $null })
                    EnvironmentId   = $Environment.Name
                    EnvironmentName = $label
                }
            })
            Write-PPLog -Level OK -Message ("  {0}: {1} solution(s)" -f $label, $out.Solutions.Count)
        }
    }

    # --- Security ----------------------------------------------------------------------
    if ($IncludeSecurity) {
        # accessmode 4 = Non-interactive, applicationid present = service principal user.
        $r = Get-DvRows -OrgUrl $Environment.OrgUrl -Token $token -Label "dv:users:$($Environment.Name)" `
              -Query ('systemusers?$select=systemuserid,fullname,domainname,isdisabled,accessmode,applicationid,azureactivedirectoryobjectid' +
                      '&$filter=isdisabled%20eq%20false')
        if ($r.Success) {
            $out.SystemUsers = @($r.Rows | ForEach-Object {
                [PSCustomObject]@{
                    Id           = $_.systemuserid
                    FullName     = $_.fullname
                    UPN          = $_.domainname
                    IsDisabled   = [bool]$_.isdisabled
                    AccessMode   = $_.accessmode
                    ApplicationId = $_.applicationid
                    AadObjectId  = $_.azureactivedirectoryobjectid
                    IsAppUser    = [bool]$_.applicationid
                }
            })
            $out.ApplicationUsers = @($out.SystemUsers | Where-Object { $_.IsAppUser })
        }

        # Everyone holding System Administrator, including service principals.
        $ra = Get-DvRows -OrgUrl $Environment.OrgUrl -Token $token -Label "dv:sysadmins:$($Environment.Name)" `
               -Query ('roles?$select=roleid,name&$filter=name%20eq%20%27System%20Administrator%27' +
                       '&$expand=systemuserroles_association($select=systemuserid,fullname,domainname,applicationid,isdisabled)')
        if ($ra.Success -and $ra.Count -gt 0) {
            $admins = New-Object System.Collections.ArrayList
            foreach ($role in $ra.Rows) {
                foreach ($u in @($role.systemuserroles_association)) {
                    [void]$admins.Add([PSCustomObject]@{
                        Id            = $u.systemuserid
                        FullName      = $u.fullname
                        UPN           = $u.domainname
                        ApplicationId = $u.applicationid
                        IsAppUser     = [bool]$u.applicationid
                        IsDisabled    = [bool]$u.isdisabled
                        EnvironmentId   = $Environment.Name
                        EnvironmentName = $label
                    })
                }
            }
            $out.AdminUsers = $admins
            Write-PPLog -Level OK -Message ("  {0}: {1} System Administrator(s), {2} of them service principals" -f `
                $label, $admins.Count, @($admins | Where-Object { $_.IsAppUser }).Count)
        }
    }

    # --- Failures ----------------------------------------------------------------------
    if ($IncludeErrors) {
        # statuscode 31 = Failed. Recent window only; asyncoperation is a very large table.
        $since = (Get-Date).AddDays(-7).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $r = Get-DvRows -OrgUrl $Environment.OrgUrl -Token $token -Label "dv:asyncfail:$($Environment.Name)" -MaxPages 3 `
              -Query ('asyncoperations?$select=asyncoperationid,name,operationtype,statuscode,message,createdon' +
                      '&$filter=statuscode%20eq%2031%20and%20createdon%20gt%20' + $since +
                      '&$orderby=createdon%20desc&$top=200')
        if ($r.Success) {
            $out.AsyncFailures = @($r.Rows | ForEach-Object {
                $msg = $_.message
                if ($msg -and $msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '...' }
                [PSCustomObject]@{
                    Id              = $_.asyncoperationid
                    Name            = $_.name
                    OperationType   = $_.operationtype
                    CreatedOn       = $_.createdon
                    Message         = $msg
                    EnvironmentId   = $Environment.Name
                    EnvironmentName = $label
                }
            })
            if ($out.AsyncFailures.Count -gt 0) {
                Write-PPLog -Level WARN -Message ("  {0}: {1} failed system job(s) in the last 7 days" -f $label, $out.AsyncFailures.Count)
            }
        }
    }

    return $out
}
