# Collect-Identity.ps1 - Microsoft Graph.
#
# Without this, every owner in the report is a bare GUID and the highest-value finding class -
# assets owned by people who have left - cannot be produced at all.

function Invoke-PPCollectIdentity {
    param(
        [Parameter(Mandatory)][string]$Token,
        [int]$MaxUserPages = 20
    )

    $out = [PSCustomObject]@{
        Users             = @()
        Groups            = @()
        ServicePrincipals = @()
        Skus              = @()
        UserIndex         = @{}
        Gaps              = New-Object System.Collections.ArrayList
    }

    # --- Users -------------------------------------------------------------------------
    $users = New-Object System.Collections.ArrayList
    $next  = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,accountEnabled,department,jobTitle&$top=999'
    $pages = 0
    while ($next -and $pages -lt $MaxUserPages) {
        $pages++
        $r = Invoke-PPRequest -Uri $next -Token $Token -Label 'graph:users'
        if (-not $r.Success) {
            [void]$out.Gaps.Add([PSCustomObject]@{ Item = 'Directory users'; Reason = "HTTP $($r.StatusCode)" })
            break
        }
        foreach ($u in @($r.Content.value)) { [void]$users.Add($u) }
        $next = $r.Content.'@odata.nextLink'
    }

    $out.Users = @($users | ForEach-Object {
        [PSCustomObject]@{
            Id             = $_.id
            DisplayName    = $_.displayName
            UPN            = $_.userPrincipalName
            AccountEnabled = $_.accountEnabled
            Department     = $_.department
            JobTitle       = $_.jobTitle
        }
    })

    # Index for owner resolution. Case-insensitive: GUIDs arrive in mixed case across APIs.
    $idx = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($u in $out.Users) { if ($u.Id) { $idx[$u.Id] = $u } }
    $out.UserIndex = $idx

    Write-PPLog -Level OK -Message ("  {0} directory user(s); {1} disabled" -f `
        $out.Users.Count, @($out.Users | Where-Object { $_.AccountEnabled -eq $false }).Count)

    # --- Groups ------------------------------------------------------------------------
    $g = Invoke-PPRequest -Label 'graph:groups' -Token $Token `
        -Uri 'https://graph.microsoft.com/v1.0/groups?$select=id,displayName,mail,securityEnabled&$top=999'
    if ($g.Success) {
        $out.Groups = @($g.Content.value | ForEach-Object {
            [PSCustomObject]@{ Id = $_.id; DisplayName = $_.displayName; Mail = $_.mail; SecurityEnabled = $_.securityEnabled }
        })
        Write-PPLog -Level OK -Message ("  {0} group(s)" -f $out.Groups.Count)
    }

    # --- Service principals + credential expiry -----------------------------------------
    $sp = Invoke-PPRequest -Label 'graph:servicePrincipals' -Token $Token `
        -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals?$select=id,appId,displayName,accountEnabled,passwordCredentials,keyCredentials&$top=999'
    if ($sp.Success) {
        $now = Get-Date
        $out.ServicePrincipals = @($sp.Content.value | ForEach-Object {
            $creds = @()
            foreach ($c in @($_.passwordCredentials)) { $creds += [PSCustomObject]@{ Type='Secret'; EndDate=$c.endDateTime } }
            foreach ($c in @($_.keyCredentials))      { $creds += [PSCustomObject]@{ Type='Certificate'; EndDate=$c.endDateTime } }

            $soonest = $null; $daysLeft = $null
            $valid = @($creds | Where-Object { $_.EndDate })
            if ($valid.Count -gt 0) {
                $soonest = ($valid | Sort-Object { [datetime]$_.EndDate } | Select-Object -First 1).EndDate
                try { $daysLeft = [int](([datetime]$soonest) - $now).TotalDays } catch { }
            }

            [PSCustomObject]@{
                Id              = $_.id
                AppId           = $_.appId
                DisplayName     = $_.displayName
                AccountEnabled  = $_.accountEnabled
                CredentialCount = $creds.Count
                SoonestExpiry   = $soonest
                DaysToExpiry    = $daysLeft
            }
        })
        Write-PPLog -Level OK -Message ("  {0} service principal(s)" -f $out.ServicePrincipals.Count)
    } else {
        [void]$out.Gaps.Add([PSCustomObject]@{ Item = 'Service principals'; Reason = "HTTP $($sp.StatusCode)" })
    }

    # --- Licences ----------------------------------------------------------------------
    $sku = Invoke-PPRequest -Label 'graph:subscribedSkus' -Token $Token `
        -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus'
    if ($sku.Success) {
        $out.Skus = @($sku.Content.value | ForEach-Object {
            [PSCustomObject]@{
                SkuPartNumber = $_.skuPartNumber
                Enabled       = $_.prepaidUnits.enabled
                Consumed      = $_.consumedUnits
                Available     = ($_.prepaidUnits.enabled - $_.consumedUnits)
            }
        })
        Write-PPLog -Level OK -Message ("  {0} licence SKU(s)" -f $out.Skus.Count)
    }

    return $out
}

<#
.SYNOPSIS
    Resolves an Entra object ID to a display label, marking owners who have left.
#>
function Resolve-PPOwner {
    param($UserIndex, $OwnerId, $FallbackName)

    if (-not $OwnerId) {
        return [PSCustomObject]@{ Name = $FallbackName; UPN = $null; Enabled = $null; Orphaned = $false; Known = $false }
    }
    if ($UserIndex -and $UserIndex.ContainsKey($OwnerId)) {
        $u = $UserIndex[$OwnerId]
        return [PSCustomObject]@{
            Name = $u.DisplayName; UPN = $u.UPN; Enabled = $u.AccountEnabled
            # A disabled account still owning assets is the classic orphan.
            Orphaned = ($u.AccountEnabled -eq $false); Known = $true
        }
    }
    # Not in the directory at all: usually a deleted user, sometimes a service principal.
    return [PSCustomObject]@{
        Name = $FallbackName; UPN = $null; Enabled = $null; Orphaned = $true; Known = $false
    }
}
