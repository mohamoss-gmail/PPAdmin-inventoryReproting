# PPAuth.ps1 - interactive device-code auth with cross-resource token refresh.
#
# Design note: we deliberately use the **v1.0** Entra ID endpoint (/oauth2/devicecode,
# /oauth2/token with a `resource` parameter) rather than v2.0. Reason: v2.0 forbids requesting
# scopes across multiple resources, which would mean re-prompting the admin once per audience
# (BAP, api.powerplatform.com, Graph, and once per Dataverse org URL - potentially dozens of
# prompts). The v1.0 flow returns a refresh token that can be redeemed for any other resource
# silently, so the admin signs in exactly once.
#
# Windows PowerShell 5.1 compatible.

# Azure CLI's well-known public client. Chosen because it is a first-party pre-authorized
# client present in every tenant and consented for a broad set of resources, so the probe
# works with zero app-registration setup. Override with -ClientId if your tenant blocks it.
$script:PPDefaultClientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'

# Fallbacks worth trying if the default is blocked by Conditional Access / app restrictions.
$script:PPFallbackClientIds = @(
    @{ Id = '1950a258-227b-4e31-a9cf-717495945fc2'; Name = 'Microsoft Azure PowerShell' },
    @{ Id = '51f81489-12ee-4a9e-aaae-a2591f45987d'; Name = 'Microsoft Dataverse / D365 client' }
)

$script:PPAuthState = @{
    TenantId     = $null
    ClientId     = $null
    RefreshToken = $null
    Tokens       = @{}   # resource -> @{ AccessToken; ExpiresOn }
    Account      = $null
}

function Get-PPAuthState { return $script:PPAuthState }

function Get-PPKnownResources {
    # Audiences the tool needs. Dataverse orgs are added dynamically at runtime.
    return [ordered]@{
        'BAP (legacy admin APIs)'      = 'https://service.powerapps.com/'
        'BAP (api.bap.microsoft.com)'  = 'https://api.bap.microsoft.com/'
        'Power Platform API'           = 'https://api.powerplatform.com/'
        'Microsoft Graph'              = 'https://graph.microsoft.com/'
    }
}

function Read-PPJwtClaims {
    param([Parameter(Mandatory)][string]$Token)
    try {
        $payload = $Token.Split('.')[1]
        # base64url -> base64
        $payload = $payload.Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
            1 { return $null }
        }
        $bytes = [Convert]::FromBase64String($payload)
        return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
    Signs the admin in once via device code and stores a refresh token for later resources.
#>
function Connect-PPTenant {
    param(
        [string]$TenantId = 'organizations',
        [string]$ClientId,
        [string]$InitialResource = 'https://graph.microsoft.com/'
    )

    if (-not $ClientId) { $ClientId = $script:PPDefaultClientId }

    $script:PPAuthState.TenantId = $TenantId
    $script:PPAuthState.ClientId = $ClientId

    $deviceUri = "https://login.microsoftonline.com/$TenantId/oauth2/devicecode"
    $body      = "client_id=$ClientId&resource=$([uri]::EscapeDataString($InitialResource))"

    try {
        $dc = Invoke-RestMethod -Uri $deviceUri -Method Post -Body $body `
                                -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    } catch {
        $msg = Get-PPErrorBody -ErrorRecord $_
        Write-PPLog -Level ERROR -Message "Device code request failed: $msg"
        return $false
    }

    Write-Host ''
    Write-Host '  ------------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host '   SIGN IN REQUIRED' -ForegroundColor Yellow
    Write-Host ''
    Write-Host ("   1. Open: {0}" -f $dc.verification_url) -ForegroundColor White
    Write-Host ("   2. Code: {0}" -f $dc.user_code) -ForegroundColor White
    Write-Host ''
    Write-Host '   Sign in as a Power Platform Administrator.' -ForegroundColor Gray
    Write-Host '  ------------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host ''

    # Also record the code so it is recoverable when the console is not visible (background
    # run, remote session, CI). It is a short-lived one-time code, not a credential.
    Write-PPLog -Message ("Device code {0} - sign in at {1}" -f $dc.user_code, $dc.verification_url) `
                -Data @{ user_code = $dc.user_code; verification_url = $dc.verification_url }

    # Best-effort clipboard + browser launch; harmless if either is unavailable.
    try { Set-Clipboard -Value $dc.user_code -ErrorAction SilentlyContinue } catch { }
    try { Start-Process $dc.verification_url -ErrorAction SilentlyContinue | Out-Null } catch { }

    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/token"
    $interval = 5
    if ($dc.interval) { $interval = [int]$dc.interval }
    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)

    Write-PPLog -Message 'Waiting for sign-in to complete...'

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        $pollBody = "grant_type=urn:ietf:params:oauth:grant-type:device_code" +
                    "&client_id=$ClientId&code=$($dc.device_code)"
        try {
            $tok = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $pollBody `
                                     -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop

            $script:PPAuthState.RefreshToken = $tok.refresh_token
            $script:PPAuthState.Tokens[$InitialResource] = @{
                AccessToken = $tok.access_token
                ExpiresOn   = (Get-Date).AddSeconds(3300)
            }

            $claims = Read-PPJwtClaims -Token $tok.access_token
            if ($claims) {
                $script:PPAuthState.Account  = $claims.upn
                if (-not $script:PPAuthState.Account) { $script:PPAuthState.Account = $claims.unique_name }
                $script:PPAuthState.TenantId = $claims.tid
            }

            Write-PPLog -Level OK -Message ("Signed in as {0} (tenant {1})" -f `
                $script:PPAuthState.Account, $script:PPAuthState.TenantId)
            return $true
        }
        catch {
            $bodyText = Get-PPErrorBody -ErrorRecord $_
            if ($bodyText -match 'authorization_pending') { continue }
            if ($bodyText -match 'slow_down') { $interval += 5; continue }
            Write-PPLog -Level ERROR -Message "Sign-in failed: $bodyText"
            return $false
        }
    }

    Write-PPLog -Level ERROR -Message 'Device code expired before sign-in completed.'
    return $false
}

<#
.SYNOPSIS
    Returns an access token for a resource, redeeming the cached refresh token silently.
.OUTPUTS
    PSCustomObject: Success, AccessToken, Error, Resource
#>
function Get-PPToken {
    param(
        [Parameter(Mandatory)][string]$Resource,
        [switch]$Force
    )

    if (-not $script:PPAuthState.RefreshToken) {
        return [PSCustomObject]@{
            Success = $false; AccessToken = $null; Resource = $Resource
            Error   = 'Not signed in. Call Connect-PPTenant first.'
        }
    }

    $cached = $script:PPAuthState.Tokens[$Resource]
    if (-not $Force -and $cached -and $cached.ExpiresOn -gt (Get-Date).AddMinutes(5)) {
        return [PSCustomObject]@{
            Success = $true; AccessToken = $cached.AccessToken; Resource = $Resource; Error = $null
        }
    }

    $tokenUri = "https://login.microsoftonline.com/$($script:PPAuthState.TenantId)/oauth2/token"
    $body     = "grant_type=refresh_token&client_id=$($script:PPAuthState.ClientId)" +
                "&refresh_token=$($script:PPAuthState.RefreshToken)" +
                "&resource=$([uri]::EscapeDataString($Resource))"

    try {
        $tok = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $body `
                                 -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop

        $script:PPAuthState.Tokens[$Resource] = @{
            AccessToken = $tok.access_token
            ExpiresOn   = (Get-Date).AddSeconds(3300)
        }
        # Entra rotates refresh tokens; keep the newest so long runs don't expire mid-collection.
        if ($tok.refresh_token) { $script:PPAuthState.RefreshToken = $tok.refresh_token }

        return [PSCustomObject]@{
            Success = $true; AccessToken = $tok.access_token; Resource = $Resource; Error = $null
        }
    }
    catch {
        $msg = Get-PPErrorBody -ErrorRecord $_
        # Condense the very verbose AADSTS payloads to the first useful sentence.
        if ($msg -match '(AADSTS\d+)[:\s]*([^\r\n\.]*)') { $msg = "$($matches[1]): $($matches[2])" }
        return [PSCustomObject]@{
            Success = $false; AccessToken = $null; Resource = $Resource; Error = $msg
        }
    }
}
