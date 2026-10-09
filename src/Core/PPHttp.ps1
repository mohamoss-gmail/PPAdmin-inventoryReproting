# PPHttp.ps1 - read-only HTTP wrapper.
#
# Two jobs:
#   1. Guarantee this tool never writes to a tenant. Only GET/HEAD are permitted; anything
#      else throws before a socket is opened. This is asserted in tests and is what makes the
#      tool approvable to run against production.
#   2. Record every single call (url, status, duration, error). For the Phase 0 probe that
#      recording *is* the deliverable.
#
# Windows PowerShell 5.1 compatible.

$script:PPCalls = New-Object System.Collections.ArrayList

# 5.1 defaults to SSL3/TLS1.0 in some hosts; Microsoft endpoints require 1.2+.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol
} catch { }

function Reset-PPCallLog {
    $script:PPCalls = New-Object System.Collections.ArrayList
}

function Get-PPCallLog {
    return $script:PPCalls
}

function Get-PPErrorBody {
    param($ErrorRecord)

    # PS7 surfaces the response body here; 5.1 usually does not.
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return $ErrorRecord.ErrorDetails.Message
    }
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp -and $resp.GetResponseStream) {
            $stream = $resp.GetResponseStream()
            $stream.Position = 0
            $reader = New-Object System.IO.StreamReader($stream)
            $body   = $reader.ReadToEnd()
            $reader.Close()
            return $body
        }
    } catch { }
    return $ErrorRecord.Exception.Message
}

function Get-PPStatusCode {
    param($ErrorRecord)
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp -and $null -ne $resp.StatusCode) { return [int]$resp.StatusCode.value__ }
    } catch { }
    return 0
}

<#
.SYNOPSIS
    Performs a read-only HTTP request, never throwing on HTTP error status.
.DESCRIPTION
    Returns a result object rather than throwing, so a 403 on one environment can never abort
    a tenant-wide run. Retries 429/5xx with backoff, honouring Retry-After.
.OUTPUTS
    PSCustomObject: Success, StatusCode, Content, Error, DurationMs, Uri, Label, Attempts
#>
function Invoke-PPRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Token,
        [ValidateSet('GET','HEAD')][string]$Method = 'GET',
        [hashtable]$ExtraHeaders,
        [string]$Label,
        [int]$TimeoutSec  = 100,
        [int]$MaxRetries  = 3,
        [switch]$Quiet
    )

    # Read-only guarantee. Defence in depth: ValidateSet above already blocks this, but an
    # explicit throw documents the intent and survives someone widening the ValidateSet.
    if ($Method -ne 'GET' -and $Method -ne 'HEAD') {
        throw "PPHttp is read-only. Refusing method '$Method' for $Uri"
    }

    $headers = @{ 'Accept' = 'application/json' }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] } }

    $attempt   = 0
    $sw        = [System.Diagnostics.Stopwatch]::StartNew()
    $status    = 0
    $content   = $null
    $errMsg    = $null
    $succeeded = $false

    while ($attempt -le $MaxRetries) {
        $attempt++
        try {
            $content = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers `
                                         -TimeoutSec $TimeoutSec -ErrorAction Stop
            $status    = 200
            $succeeded = $true
            $errMsg    = $null
            break
        }
        catch {
            $status = Get-PPStatusCode -ErrorRecord $_
            $errMsg = Get-PPErrorBody   -ErrorRecord $_

            $retryable = ($status -eq 429 -or $status -eq 408 -or $status -ge 500 -or $status -eq 0)
            if (-not $retryable -or $attempt -gt $MaxRetries) { break }

            # Honour Retry-After when the service tells us how long to wait.
            $wait = [Math]::Min([Math]::Pow(2, $attempt), 30)
            try {
                $ra = $_.Exception.Response.Headers['Retry-After']
                if ($ra) {
                    $parsed = 0
                    if ([int]::TryParse($ra, [ref]$parsed) -and $parsed -gt 0) {
                        $wait = [Math]::Min($parsed, 60)
                    }
                }
            } catch { }

            if (-not $Quiet) {
                Write-PPLog -Level DEBUG -Message ("retry {0}/{1} after {2}s (HTTP {3}) {4}" -f `
                    $attempt, $MaxRetries, $wait, $status, $Uri)
            }
            Start-Sleep -Seconds $wait
        }
    }

    $sw.Stop()

    $result = [PSCustomObject]@{
        Success    = $succeeded
        StatusCode = $status
        Content    = $content
        Error      = $errMsg
        DurationMs = [int]$sw.ElapsedMilliseconds
        Uri        = $Uri
        Label      = $Label
        Attempts   = $attempt
    }

    # Truncate error bodies before they go into the call log; some services return HTML pages.
    $loggedErr = $errMsg
    if ($loggedErr -and $loggedErr.Length -gt 600) { $loggedErr = $loggedErr.Substring(0, 600) + '...' }

    [void]$script:PPCalls.Add([PSCustomObject]@{
        Label      = $Label
        Uri        = $Uri
        Method     = $Method
        StatusCode = $status
        Success    = $succeeded
        DurationMs = $result.DurationMs
        Attempts   = $attempt
        Error      = $loggedErr
        Timestamp  = (Get-Date).ToUniversalTime().ToString('o')
    })

    return $result
}

<#
.SYNOPSIS
    Follows OData @odata.nextLink paging and returns the accumulated 'value' array.
#>
function Invoke-PPODataQuery {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        [hashtable]$ExtraHeaders,
        [string]$Label,
        [int]$MaxPages = 20
    )

    $all      = New-Object System.Collections.ArrayList
    $next     = $Uri
    $pages    = 0
    $last     = $null

    while ($next -and $pages -lt $MaxPages) {
        $pages++
        $last = Invoke-PPRequest -Uri $next -Token $Token -ExtraHeaders $ExtraHeaders -Label $Label
        if (-not $last.Success) { break }

        if ($last.Content -and $last.Content.value) {
            foreach ($row in $last.Content.value) { [void]$all.Add($row) }
        }
        $next = $null
        if ($last.Content -and $last.Content.'@odata.nextLink') {
            $next = $last.Content.'@odata.nextLink'
        }
    }

    return [PSCustomObject]@{
        Success    = ($last -and $last.Success)
        StatusCode = $(if ($last) { $last.StatusCode } else { 0 })
        Error      = $(if ($last) { $last.Error } else { 'no request issued' })
        Rows       = $all
        Count      = $all.Count
        Pages      = $pages
    }
}
