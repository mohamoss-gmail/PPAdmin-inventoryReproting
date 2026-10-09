# PPDataverse.ps1 - shared Dataverse Web API access.
#
# Dataverse tokens are per-organisation: the resource IS the org URL, so every environment
# needs its own token. Get-PPToken caches per resource, and the cross-resource refresh in
# PPAuth means this costs no extra sign-in prompts.

$script:DvHeaders = @{
    'OData-MaxVersion' = '4.0'
    'OData-Version'    = '4.0'
}

function Invoke-DvQuery {
    param(
        [Parameter(Mandatory)][string]$OrgUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Query,
        [string]$Label,
        [int]$MaxRetries = 2
    )
    $uri = "$OrgUrl/api/data/v9.2/$Query"
    return Invoke-PPRequest -Uri $uri -Token $Token -ExtraHeaders $script:DvHeaders `
                            -Label $Label -MaxRetries $MaxRetries
}

<#
.SYNOPSIS
    Runs a Dataverse query and returns rows, following @odata.nextLink.
.OUTPUTS
    PSCustomObject: Success, StatusCode, Rows, Count, Error
#>
function Get-DvRows {
    param(
        [Parameter(Mandatory)][string]$OrgUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Query,
        [string]$Label,
        [int]$MaxPages = 20
    )

    $all   = New-Object System.Collections.ArrayList
    $next  = "$OrgUrl/api/data/v9.2/$Query"
    $pages = 0
    $last  = $null

    while ($next -and $pages -lt $MaxPages) {
        $pages++
        $last = Invoke-PPRequest -Uri $next -Token $Token -ExtraHeaders $script:DvHeaders `
                                 -Label $Label -MaxRetries 2
        if (-not $last.Success) { break }
        if ($last.Content -and $last.Content.value) {
            foreach ($r in $last.Content.value) { [void]$all.Add($r) }
        }
        $next = $null
        if ($last.Content -and $last.Content.'@odata.nextLink') { $next = $last.Content.'@odata.nextLink' }
    }

    return [PSCustomObject]@{
        Success    = ($last -and $last.Success)
        StatusCode = $(if ($last) { $last.StatusCode } else { 0 })
        Error      = $(if ($last) { $last.Error } else { 'no request issued' })
        Rows       = $all
        Count      = $all.Count
    }
}

<#
.SYNOPSIS
    Acquires a Dataverse token and confirms access with WhoAmI.
.OUTPUTS
    PSCustomObject: Success, Token, UserId, StatusCode, Reason
#>
function Connect-DvEnvironment {
    param([Parameter(Mandatory)][string]$OrgUrl)

    $tok = Get-PPToken -Resource $OrgUrl
    if (-not $tok.Success) {
        return [PSCustomObject]@{
            Success = $false; Token = $null; UserId = $null; StatusCode = 0
            Reason  = "Token acquisition failed: $($tok.Error)"
        }
    }

    $who = Invoke-DvQuery -OrgUrl $OrgUrl -Token $tok.AccessToken -Query 'WhoAmI' -Label 'dv:whoami'
    if (-not $who.Success) {
        $reason = "HTTP $($who.StatusCode)"
        if ($who.StatusCode -eq 403) { $reason = 'No Dataverse security role in this environment' }
        if ($who.StatusCode -eq 404) { $reason = 'Organisation URL did not resolve (environment may not be fully provisioned)' }
        return [PSCustomObject]@{
            Success = $false; Token = $tok.AccessToken; UserId = $null
            StatusCode = $who.StatusCode; Reason = $reason
        }
    }

    return [PSCustomObject]@{
        Success = $true; Token = $tok.AccessToken; UserId = $who.Content.UserId
        StatusCode = 200; Reason = $null
    }
}
