# Collect-AzureCost.ps1 - the money figure, from Azure Consumption.
#
# WHY THIS IS A SEPARATE, OPT-IN MODULE
#
# Everything else in this tool runs on a Power Platform Administrator's authority. This does
# not. Azure Consumption needs an https://management.azure.com token and Azure RBAC (Reader or
# better) on the subscription behind each pay-as-you-go billing policy - a different permission
# set entirely. A Power Platform Admin with no Azure role will get 403 here all day, and that is
# normal, not a defect. So the module is behind -IncludeAzureCost and it degrades loudly: it
# reports exactly which subscription refused and why.
#
# WHAT IT CAN AND CANNOT ANSWER
#
# It answers "how many real currency units did pay-as-you-go cost", per meter and per Azure
# resource. It CANNOT answer "which agent, app or user drove it": Azure Cost Management
# explicitly does not break Power Platform spend down by environment, asset or user. That
# breakdown lives in the Licensing API (see Collect-Usage.ps1), which is why both exist and why
# the report keeps them in separate tables rather than implying one reconciles into the other.
#
# Read-only by construction: this uses the Consumption usageDetails GET. It deliberately does
# NOT use POST /Microsoft.CostManagement/query, which is the more capable route but a write verb
# this tool refuses on principle.

<#
.SYNOPSIS
    Collects Azure pay-as-you-go spend for the subscriptions behind Power Platform billing policies.
.PARAMETER BillingPolicies
    Collected billing policies; their billingInstrument subscription IDs are the scopes queried.
.PARAMETER WindowDays
    Look-back window. Azure bills on usage date, so this is a usage-date filter, not an invoice filter.
.OUTPUTS
    PSCustomObject: Subscriptions, Meters, Resources, Totals, Gaps, Attempted
#>
function Invoke-PPCollectAzureCost {
    param(
        [Parameter(Mandatory)][string]$Token,
        $BillingPolicies,
        [int]$WindowDays = 30,
        [int]$MaxPages = 10,
        [int]$TopPerPage = 1000
    )

    $toDate   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    $fromDate = (Get-Date).ToUniversalTime().AddDays(-$WindowDays).ToString('yyyy-MM-dd')

    $out = [ordered]@{
        WindowFrom    = $fromDate
        WindowTo      = $toDate
        Subscriptions = @()
        Meters        = @()
        Resources     = @()
        Totals        = $null
        Attempted     = $false
        Gaps          = New-Object System.Collections.ArrayList
    }

    # One subscription may back several policies; query each subscription once.
    $subs = @(@($BillingPolicies) | ForEach-Object { $_.SubscriptionId } | Where-Object { $_ } | Select-Object -Unique)
    if ($subs.Count -eq 0) {
        [void]$out.Gaps.Add([PSCustomObject]@{
            Item   = 'Azure cost'
            Reason = 'No billing policy names an Azure subscription, so there is no pay-as-you-go spend to query. This is the expected result on a prepaid-only tenant.'
        })
        return [PSCustomObject]$out
    }

    $out.Attempted = $true
    $rows = New-Object System.Collections.ArrayList
    $subOut = New-Object System.Collections.ArrayList

    foreach ($sub in $subs) {
        $policies = @(@($BillingPolicies) | Where-Object { $_.SubscriptionId -eq $sub })
        Write-PPLog -Message ("  Subscription {0}" -f $sub)

        # usageStart/usageEnd is the documented filter shape. $expand is required to get
        # meterDetails, which is where the meter name lives - without it every row is an
        # unlabelled charge.
        $filter = "properties/usageStart ge '$fromDate' and properties/usageEnd le '$toDate'"
        $uri = 'https://management.azure.com/subscriptions/' + $sub +
               '/providers/Microsoft.Consumption/usageDetails' +
               '?$expand=properties/meterDetails' +
               '&$filter=' + [uri]::EscapeDataString($filter) +
               '&$top=' + $TopPerPage +
               '&api-version=2021-10-01'

        $subRows  = New-Object System.Collections.ArrayList
        $pages    = 0
        $status   = 0
        $failed   = $null
        $truncated = $false

        while ($uri -and $pages -lt $MaxPages) {
            $pages++
            $res = Invoke-PPRequest -Uri $uri -Token $Token -Label 'azure:usageDetails' -MaxRetries 2
            $status = $res.StatusCode
            if (-not $res.Success) { $failed = $res; break }

            foreach ($r in @($res.Content.value)) { [void]$subRows.Add($r) }
            $uri = $null
            if ($res.Content -and $res.Content.nextLink) { $uri = $res.Content.nextLink }
        }
        if ($uri) { $truncated = $true }

        if ($failed) {
            # 403 here is the common, expected case: Power Platform Admin is not an Azure role.
            $reason = "HTTP $($failed.StatusCode)"
            if ($failed.StatusCode -eq 403 -or $failed.StatusCode -eq 401) {
                $reason += ' - the operator holds no Azure RBAC role on this subscription. Power Platform Administrator does not grant Azure cost access; this is expected unless the role was granted separately.'
            } elseif ($failed.StatusCode -eq 404) {
                $reason += ' - the subscription was not found. The billing policy may point at a deleted or moved subscription, which would mean pay-as-you-go overage is not actually being billed.'
            }
            [void]$out.Gaps.Add([PSCustomObject]@{ Item = "Azure cost ($sub)"; Reason = $reason })
            Write-PPLog -Level WARN -Message ("    Unavailable (HTTP {0})" -f $failed.StatusCode)

            [void]$subOut.Add([PSCustomObject]@{
                SubscriptionId = $sub
                Policies       = @($policies | ForEach-Object { $_.Name })
                State          = "HTTP $($failed.StatusCode)"
                RowCount       = 0
                Cost           = $null
                Currency       = $null
            })
            continue
        }

        # Legacy and modern billing accounts return different field names for the same figure.
        # Read both rather than pick one and silently report zero on the other account type.
        $subCost = 0.0
        $haveCost = $false
        $currency = $null

        foreach ($r in $subRows) {
            $p = $r.properties
            if (-not $p) { continue }

            $cost = Get-PPNumberOrNull (Get-PPFirstProp $p @('cost','costInBillingCurrency','costInUSD','paygCostInBillingCurrency'))
            $cur  = [string](Get-PPFirstProp $p @('billingCurrency','currency','billingCurrencyCode'))
            if (-not $currency -and $cur) { $currency = $cur }
            if ($null -ne $cost) { $subCost += $cost; $haveCost = $true }

            $md = $p.meterDetails
            $meterName = [string](Get-PPFirstProp $p @('meterName'))
            if (-not $meterName -and $md) { $meterName = [string](Get-PPFirstProp $md @('meterName','meterSubCategory')) }
            $meterCat = [string](Get-PPFirstProp $p @('meterCategory'))
            if (-not $meterCat -and $md) { $meterCat = [string](Get-PPFirstProp $md @('meterCategory')) }

            [void]$rows.Add([PSCustomObject]@{
                SubscriptionId = $sub
                Date           = Get-PPFirstProp $p @('date','usageStart','usageDateTime')
                MeterCategory  = $meterCat
                MeterName      = $meterName
                ResourceId     = [string](Get-PPFirstProp $p @('resourceId','instanceId','instanceName'))
                ResourceName   = [string](Get-PPFirstProp $p @('resourceName','instanceName'))
                ResourceGroup  = [string](Get-PPFirstProp $p @('resourceGroup','resourceGroupName'))
                Quantity       = Get-PPNumberOrNull (Get-PPFirstProp $p @('quantity','usageQuantity'))
                UnitOfMeasure  = [string]$(if ($md) { Get-PPFirstProp $md @('unitOfMeasure') } else { Get-PPFirstProp $p @('unitOfMeasure') })
                Cost           = $cost
                Currency       = $cur
                ChargeType     = [string](Get-PPFirstProp $p @('chargeType'))
            })
        }

        if ($truncated) {
            [void]$out.Gaps.Add([PSCustomObject]@{
                Item   = "Azure cost ($sub)"
                Reason = 'Paging stopped at the page guard with more usage records outstanding. The cost total for this subscription is a floor, not a total.'
            })
        }

        Write-PPLog -Level OK -Message ("    {0} usage record(s), {1} {2}" -f `
            $subRows.Count, [math]::Round($subCost, 2), $(if ($currency) { $currency } else { '' }))

        [void]$subOut.Add([PSCustomObject]@{
            SubscriptionId = $sub
            Policies       = @($policies | ForEach-Object { $_.Name })
            State          = $(if ($truncated) { 'Collected (truncated)' } else { 'Collected' })
            RowCount       = $subRows.Count
            Cost           = $(if ($haveCost) { [math]::Round($subCost, 2) } else { $null })
            Currency       = $currency
        })
    }

    $out.Subscriptions = @($subOut)

    # Roll up by meter: this is the shape an admin takes to a finance conversation.
    if (@($rows).Count -gt 0) {
        $out.Meters = @($rows | Group-Object -Property MeterCategory, MeterName | ForEach-Object {
            $g = @($_.Group)
            [PSCustomObject]@{
                MeterCategory = $g[0].MeterCategory
                MeterName     = $g[0].MeterName
                Records       = $g.Count
                Quantity      = @($g | Where-Object { $null -ne $_.Quantity } | Measure-Object -Property Quantity -Sum).Sum
                UnitOfMeasure = $g[0].UnitOfMeasure
                Cost          = [math]::Round((@($g | Where-Object { $null -ne $_.Cost } | Measure-Object -Property Cost -Sum).Sum), 2)
                Currency      = $g[0].Currency
            }
        } | Sort-Object -Property @{ Expression = 'Cost'; Descending = $true })

        $out.Resources = @($rows | Where-Object { $_.ResourceId } |
            Group-Object -Property ResourceId | ForEach-Object {
                $g = @($_.Group)
                [PSCustomObject]@{
                    SubscriptionId = $g[0].SubscriptionId
                    ResourceId     = $g[0].ResourceId
                    ResourceName   = $(if ($g[0].ResourceName) { $g[0].ResourceName } else { ($g[0].ResourceId -split '/')[-1] })
                    ResourceGroup  = $g[0].ResourceGroup
                    Meters         = @($g | ForEach-Object { $_.MeterName } | Where-Object { $_ } | Select-Object -Unique).Count
                    Cost           = [math]::Round((@($g | Where-Object { $null -ne $_.Cost } | Measure-Object -Property Cost -Sum).Sum), 2)
                    Currency       = $g[0].Currency
                }
            } | Sort-Object -Property @{ Expression = 'Cost'; Descending = $true })

        $totalCost = @($rows | Where-Object { $null -ne $_.Cost } | Measure-Object -Property Cost -Sum).Sum
        $out.Totals = [PSCustomObject]@{
            Cost      = [math]::Round($totalCost, 2)
            Currency  = @($rows | Where-Object { $_.Currency } | Select-Object -First 1).Currency
            Records   = @($rows).Count
            MeterCount = @($out.Meters).Count
        }
    }

    return [PSCustomObject]$out
}
