# Collect-Tenant.ps1 - tenant-scope governance data.
#
# Routes here were corrected after the Phase 0 probe:
#   - DLP v1 lives on api.bap.microsoft.com (api.powerapps.com returns 404)
#   - tenantIsolationPolicy requires the tenant GUID as a path segment
#   - environment groups confirmed on api.powerplatform.com @ 2022-03-01-preview
#   - billing policies confirmed @ 2024-10-01, which is also the version the documented
#     policy -> environments route requires
#
# Tenant settings remain uncollectable: the operation is POST-only and this tool is GET-only.
# That gap is reported rather than hidden.

function Invoke-PPCollectTenant {
    param(
        [string]$BapToken,
        [string]$PPApiToken,
        [Parameter(Mandatory)][string]$TenantId
    )

    $out = [ordered]@{
        TenantId          = $TenantId
        IsolationPolicy   = $null
        DlpPolicies       = @()
        EnvironmentGroups = @()
        BillingPolicies   = @()
        Gaps              = New-Object System.Collections.ArrayList
    }

    [void]$out.Gaps.Add([PSCustomObject]@{
        Item   = 'Tenant settings'
        Reason = 'Exposed only as POST /providers/Microsoft.BusinessAppPlatform/listtenantsettings. This tool is GET-only by design, so environment-creation restrictions and sharing limits cannot be read.'
    })

    if ($BapToken) {
        $iso = Invoke-PPRequest -Label 'tenant:isolation' -Token $BapToken `
            -Uri "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/tenants/$TenantId/tenantIsolationPolicy?api-version=2020-10-01"
        if ($iso.Success) {
            $out.IsolationPolicy = $iso.Content
            Write-PPLog -Level OK -Message '  Tenant isolation policy collected'
        } else {
            [void]$out.Gaps.Add([PSCustomObject]@{
                Item = 'Tenant isolation policy'; Reason = "HTTP $($iso.StatusCode)"
            })
            Write-PPLog -Level WARN -Message "  Tenant isolation policy unavailable (HTTP $($iso.StatusCode))"
        }

        $dlp = Invoke-PPRequest -Label 'tenant:dlp' -Token $BapToken `
            -Uri 'https://api.bap.microsoft.com/providers/PowerPlatform.Governance/v1/policies?api-version=2016-11-01'
        if ($dlp.Success -and $dlp.Content.value) {
            $out.DlpPolicies = @($dlp.Content.value | ForEach-Object {
                [PSCustomObject]@{
                    Id             = $_.policyName
                    DisplayName    = $_.displayName
                    Type           = $_.environmentType   # AllEnvironments / OnlyEnvironments / ExceptEnvironments
                    Environments   = @($_.environments | ForEach-Object { $_.name })
                    CreatedBy      = $_.createdBy.displayName
                    CreatedOn      = $_.createdTime
                    LastModified   = $_.lastModifiedTime
                    ConnectorGroups = @($_.connectorGroups | ForEach-Object {
                        [PSCustomObject]@{
                            Classification = $_.classification   # General / Confidential / Blocked
                            ConnectorCount = @($_.connectors).Count
                            Connectors     = @($_.connectors | ForEach-Object { $_.name })
                        }
                    })
                }
            })
            Write-PPLog -Level OK -Message ("  {0} DLP policies collected" -f $out.DlpPolicies.Count)
        } else {
            [void]$out.Gaps.Add([PSCustomObject]@{ Item = 'DLP policies'; Reason = "HTTP $($dlp.StatusCode)" })
            Write-PPLog -Level WARN -Message "  DLP policies unavailable (HTTP $($dlp.StatusCode))"
        }
    }

    if ($PPApiToken) {
        # Both confirmed available at 2022-03-01-preview during Phase 0.
        $grp = Invoke-PPRequest -Label 'tenant:envGroups' -Token $PPApiToken `
            -Uri 'https://api.powerplatform.com/environmentmanagement/environmentGroups?api-version=2022-03-01-preview'
        if ($grp.Success -and $grp.Content.value) {
            $out.EnvironmentGroups = @($grp.Content.value)
            Write-PPLog -Level OK -Message ("  {0} environment group(s)" -f @($grp.Content.value).Count)
        }

        # Billing policies are what put an environment on pay-as-you-go. A policy on its own says
        # nothing useful - the question is always "which environments does it cover?", because an
        # environment outside every policy runs on prepaid capacity only. So we follow each policy
        # to its environment list rather than storing the bare policy record.
        $bill = Invoke-PPRequest -Label 'tenant:billingPolicies' -Token $PPApiToken `
            -Uri 'https://api.powerplatform.com/licensing/billingPolicies?api-version=2024-10-01'
        if ($bill.Success) {
            $policies = New-Object System.Collections.ArrayList
            foreach ($p in @($bill.Content.value)) {
                $envIds = @()
                $envStatus = 'Not collected'
                $pe = Invoke-PPRequest -Label 'tenant:billingPolicyEnvs' -Token $PPApiToken `
                    -Uri "https://api.powerplatform.com/licensing/billingPolicies/$($p.id)/environments?api-version=2024-10-01"
                if ($pe.Success) {
                    # The route has returned both a bare id list and objects carrying an
                    # environmentId, depending on api-version. Accept either.
                    $envIds = @(@($pe.Content.value) | ForEach-Object {
                        if ($_ -is [string]) { $_ } elseif ($_.environmentId) { $_.environmentId } else { $_.id }
                    } | Where-Object { $_ })
                    $envStatus = 'Collected'
                } else {
                    $envStatus = "HTTP $($pe.StatusCode)"
                }

                [void]$policies.Add([PSCustomObject]@{
                    Id               = $p.id
                    Name             = $p.name
                    Status           = $p.status          # Enabled / Disabled
                    Location         = $p.location
                    SubscriptionId   = $p.billingInstrument.subscriptionId
                    ResourceGroup    = $p.billingInstrument.resourceGroup
                    CreatedOn        = $p.createdOn
                    CreatedBy        = $p.createdBy.id
                    LastModifiedOn   = $p.lastModifiedOn
                    Environments     = $envIds
                    EnvironmentCount = @($envIds).Count
                    EnvironmentStatus = $envStatus
                })
            }
            $out.BillingPolicies = @($policies)

            if ($policies.Count -eq 0) {
                # Not a collection failure: the tenant genuinely has no pay-as-you-go plan.
                # The findings engine decides whether that matters, based on what is deployed.
                Write-PPLog -Level WARN -Message '  No billing policies - the tenant is prepaid-capacity only'
            } else {
                Write-PPLog -Level OK -Message ("  {0} billing policy/policies covering {1} environment(s)" -f `
                    $policies.Count, (@($policies | ForEach-Object { $_.Environments }) | Select-Object -Unique).Count)
            }
        } else {
            [void]$out.Gaps.Add([PSCustomObject]@{
                Item   = 'Billing policies'
                Reason = "HTTP $($bill.StatusCode). Pay-as-you-go coverage is unknown, so agents cannot be checked against a billing plan."
            })
            Write-PPLog -Level WARN -Message "  Billing policies unavailable (HTTP $($bill.StatusCode))"
        }
    }

    return [PSCustomObject]$out
}
