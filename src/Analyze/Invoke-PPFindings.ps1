# Invoke-PPFindings.ps1 - the rules engine.
#
# Everything else in this tool is a table dump. This is where inventory becomes a prioritised,
# evidence-linked risk register. Every finding must cite the record that produced it: no
# unexplainable red boxes.
#
# Rules never invent severity from nothing. Where a judgement depends on context we do not
# have (is this environment really production? is anonymous access intentional?), the finding
# says so rather than overstating confidence.

$script:PPSeverityRank = @{ 'Critical' = 0; 'High' = 1; 'Medium' = 2; 'Low' = 3; 'Info' = 4 }

function New-PPFinding {
    param(
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][ValidateSet('Critical','High','Medium','Low','Info')][string]$Severity,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [string]$Environment,
        [string]$Asset,
        [string]$Evidence,
        [string]$Why,
        [string]$Remediation
    )
    return [PSCustomObject]@{
        Rule = $Rule; Severity = $Severity; Category = $Category; Title = $Title
        Environment = $Environment; Asset = $Asset; Evidence = $Evidence
        Why = $Why; Remediation = $Remediation
    }
}

function Test-PPIsProduction {
    param($Environment)
    # Developer/Trial/Teams environments carry different expectations; treat everything else
    # as production-like for rule purposes.
    $sku = [string]$Environment.Sku
    return -not ($sku -match 'Developer|Trial|Teams|Sandbox')
}

function Test-PPPayAsYouGoEligible {
    param($Environment)
    # Pay-as-you-go supports production and sandbox environments only, so a developer or Teams
    # environment without a billing policy is correct, not a finding. Flagging it would train
    # the reader to ignore the rule.
    $sku = [string]$Environment.Sku
    return ($sku -match 'Production|Sandbox')
}

function Get-PPBillingPolicyFor {
    param($Policies, [string]$EnvironmentId)
    if (-not $EnvironmentId) { return $null }
    foreach ($p in @($Policies)) {
        if (@($p.Environments) -contains $EnvironmentId) { return $p }
    }
    return $null
}

function Test-PPDlpCovers {
    param($Policy, [string]$EnvironmentId)
    switch ([string]$Policy.Type) {
        'AllEnvironments'    { return $true }
        'OnlyEnvironments'   { return ($Policy.Environments -contains $EnvironmentId) }
        'ExceptEnvironments' { return (-not ($Policy.Environments -contains $EnvironmentId)) }
        default              { return $false }
    }
}

function Invoke-PPFindings {
    param([Parameter(Mandatory)]$Data)

    $f = New-Object System.Collections.ArrayList
    function Add-F { param($Finding) [void]$f.Add($Finding) }

    $userIndex = @{}
    if ($Data.Identity -and $Data.Identity.UserIndex) { $userIndex = $Data.Identity.UserIndex }

    # ================= Agents =================
    foreach ($dv in @($Data.Dataverse)) {
        foreach ($a in @($dv.Agents)) {

            if ($a.AccessPolicyCode -eq 3) {
                Add-F (New-PPFinding -Rule 'AGENT-XTENANT' -Severity 'Critical' -Category 'Security' `
                    -Title 'Agent reachable from any tenant' -Environment $a.EnvironmentName -Asset $a.Name `
                    -Evidence "accesscontrolpolicy = 3 (Any, multi-tenant)" `
                    -Why 'Anyone in any Entra tenant can converse with this agent, including its knowledge sources and connected actions.' `
                    -Remediation 'Set the access control policy to Copilot readers or Group membership unless external reach is a deliberate, reviewed decision.')
            }
            elseif ($a.AccessPolicyCode -eq 0) {
                Add-F (New-PPFinding -Rule 'AGENT-ANON' -Severity 'High' -Category 'Security' `
                    -Title 'Agent allows anonymous access' -Environment $a.EnvironmentName -Asset $a.Name `
                    -Evidence "accesscontrolpolicy = 0 (Any)" `
                    -Why 'No authentication is required to interact with the agent, so anything it can retrieve or act on is effectively public.' `
                    -Remediation 'Restrict to Copilot readers or a security group, and confirm the agent has no access to sensitive knowledge or actions.')
            }

            if ($a.AuthModeCode -eq 1) {
                Add-F (New-PPFinding -Rule 'AGENT-NOAUTH' -Severity 'High' -Category 'Security' `
                    -Title 'Agent has authentication disabled' -Environment $a.EnvironmentName -Asset $a.Name `
                    -Evidence 'authenticationmode = 1 (None)' `
                    -Why 'End-user identity is never established, so per-user authorisation cannot be enforced on anything the agent does.' `
                    -Remediation 'Switch to Integrated authentication, or Custom Entra ID where a specific token audience is required.')
            }

            if ($a.UsesModelKnowledge -eq $true) {
                Add-F (New-PPFinding -Rule 'AGENT-MODELKNOWLEDGE' -Severity 'Medium' -Category 'Compliance' `
                    -Title 'Agent may answer from general model knowledge' -Environment $a.EnvironmentName -Asset $a.Name `
                    -Evidence 'configuration.useModelKnowledge = true' `
                    -Why 'Responses are not restricted to approved knowledge sources, so the agent can assert content the organisation has not sanctioned.' `
                    -Remediation 'Disable general knowledge for agents serving regulated or customer-facing scenarios, and rely on grounded sources.')
            }

            if ($a.IsAutonomous -eq $true) {
                $sev = 'Medium'
                if ($a.AuthModeCode -eq 1 -or $a.AccessPolicyCode -eq 0 -or $a.AccessPolicyCode -eq 3) { $sev = 'High' }
                Add-F (New-PPFinding -Rule 'AGENT-AUTONOMOUS' -Severity $sev -Category 'Security' `
                    -Title 'Autonomous agent (external trigger)' -Environment $a.EnvironmentName -Asset $a.Name `
                    -Evidence 'botcomponent componenttype = 17 (External Trigger)' `
                    -Why 'The agent acts without a user in the loop. Combined with weak access control this becomes an unattended path into connected systems.' `
                    -Remediation 'Review the trigger, the connections it uses and the authentication context those connections run under.')
            }

            if ($a.StatusCode -eq 5) {
                Add-F (New-PPFinding -Rule 'AGENT-MISSINGLIC' -Severity 'Medium' -Category 'Cost' `
                    -Title 'Agent is unlicensed' -Environment $a.EnvironmentName -Asset $a.Name `
                    -Evidence 'statuscode = 5 (MissingLicense)' `
                    -Why 'The agent cannot serve users in this state and has likely been broken without anyone noticing.' `
                    -Remediation 'Assign the required Copilot Studio capacity, or decommission the agent.')
            }
            if ($a.StatusCode -eq 4) {
                Add-F (New-PPFinding -Rule 'AGENT-PROVFAIL' -Severity 'Medium' -Category 'Reliability' `
                    -Title 'Agent provisioning failed' -Environment $a.EnvironmentName -Asset $a.Name `
                    -Evidence 'statuscode = 4 (ProvisionFailed)' `
                    -Why 'The agent never came up correctly and is not serving traffic.' `
                    -Remediation 'Reprovision or delete. A failed agent left in place obscures real inventory.')
            }

            if (-not $a.IsPublished) {
                Add-F (New-PPFinding -Rule 'AGENT-UNPUBLISHED' -Severity 'Low' -Category 'Hygiene' `
                    -Title 'Agent has never been published' -Environment $a.EnvironmentName -Asset $a.Name `
                    -Evidence 'publishedon is empty' `
                    -Why 'Abandoned drafts accumulate, consume capacity and confuse inventory.' `
                    -Remediation 'Publish it or delete it.')
            }

            $env = @($Data.Environments | Where-Object { $_.Name -eq $a.EnvironmentId })[0]
            if ($a.IsManaged -eq $false -and $env -and (Test-PPIsProduction $env)) {
                Add-F (New-PPFinding -Rule 'AGENT-UNMANAGED-PROD' -Severity 'Medium' -Category 'ALM' `
                    -Title 'Unmanaged agent in a production environment' -Environment $a.EnvironmentName -Asset $a.Name `
                    -Evidence 'ismanaged = false' `
                    -Why 'The agent was built directly in production rather than deployed through a managed solution, so there is no reliable path to reproduce or roll it back.' `
                    -Remediation 'Move authoring to a development environment and deploy via managed solutions.')
            }

            $owner = Resolve-PPOwner -UserIndex $userIndex -OwnerId $a.OwnerId
            if ($owner.Orphaned -and $userIndex.Count -gt 0) {
                Add-F (New-PPFinding -Rule 'AGENT-ORPHAN' -Severity 'High' -Category 'Hygiene' `
                    -Title 'Agent owned by a disabled or deleted account' -Environment $a.EnvironmentName -Asset $a.Name `
                    -Evidence "ownerid $($a.OwnerId) is not an enabled directory user" `
                    -Why 'Nobody can maintain the agent, and any connection it holds continues running under a departed identity.' `
                    -Remediation 'Reassign ownership to an active owner or a service principal.')
            }
        }
    }

    # ================= Apps =================
    foreach ($app in @($Data.Apps)) {
        if ($app.SharedWithTenant) {
            Add-F (New-PPFinding -Rule 'APP-TENANTSHARE' -Severity 'High' -Category 'Security' `
                -Title 'App shared with the entire tenant' -Environment $app.EnvironmentName -Asset $app.DisplayName `
                -Evidence 'A permission entry has principal type = Tenant' `
                -Why 'Every licensed user in the organisation can open the app and whatever data its connections expose.' `
                -Remediation 'Replace tenant-wide sharing with a security group scoped to the intended audience.')
        }
        $owner = Resolve-PPOwner -UserIndex $userIndex -OwnerId $app.OwnerId -FallbackName $app.OwnerName
        if ($owner.Orphaned -and $userIndex.Count -gt 0) {
            Add-F (New-PPFinding -Rule 'APP-ORPHAN' -Severity 'High' -Category 'Hygiene' `
                -Title 'App owned by a disabled or deleted account' -Environment $app.EnvironmentName -Asset $app.DisplayName `
                -Evidence "owner $($app.OwnerId) ($($app.OwnerName)) is not an enabled directory user" `
                -Why 'The app has no maintainer, and its connections keep running under a departed identity until they break.' `
                -Remediation 'Reassign the app to an active owner.')
        }
    }

    # ================= Flows =================
    foreach ($flow in @($Data.Flows)) {
        if ($flow.State -eq 'Suspended') {
            Add-F (New-PPFinding -Rule 'FLOW-SUSPENDED' -Severity 'Medium' -Category 'Reliability' `
                -Title 'Flow is suspended' -Environment $flow.EnvironmentName -Asset $flow.DisplayName `
                -Evidence "state = Suspended" `
                -Why 'Power Automate suspends flows after repeated failures. Whatever process depended on it has silently stopped.' `
                -Remediation 'Investigate the failure history, fix the cause and re-enable, or retire the flow.')
        }
        $owner = Resolve-PPOwner -UserIndex $userIndex -OwnerId $flow.OwnerId
        if ($owner.Orphaned -and $userIndex.Count -gt 0) {
            Add-F (New-PPFinding -Rule 'FLOW-ORPHAN' -Severity 'High' -Category 'Hygiene' `
                -Title 'Flow owned by a disabled or deleted account' -Environment $flow.EnvironmentName -Asset $flow.DisplayName `
                -Evidence "creator $($flow.OwnerId) is not an enabled directory user" `
                -Why 'The flow keeps executing under a departed identity and will fail unpredictably when its connections expire.' `
                -Remediation 'Add an active co-owner and re-authenticate the connections.')
        }
    }

    # ================= Environments =================
    $policies       = @($Data.Tenant.DlpPolicies)
    $billingPolicies = @($Data.Tenant.BillingPolicies)
    $allAgents       = @($Data.Agents)

    # Distinguish "no billing policies exist" from "we could not read them". Only the first is
    # a fact about the tenant; the second is a fact about our permissions.
    $billingReadable = -not (@($Data.Tenant.Gaps) | Where-Object { $_.Item -eq 'Billing policies' })

    foreach ($env in @($Data.Environments)) {

        if ($policies.Count -gt 0) {
            $covered = $false
            foreach ($p in $policies) { if (Test-PPDlpCovers -Policy $p -EnvironmentId $env.Name) { $covered = $true; break } }
            if (-not $covered) {
                Add-F (New-PPFinding -Rule 'ENV-NODLP' -Severity 'High' -Category 'Governance' `
                    -Title 'Environment not covered by any DLP policy' -Environment $env.DisplayName -Asset $env.DisplayName `
                    -Evidence "No policy among $($policies.Count) scopes to this environment" `
                    -Why 'Makers can freely combine business and non-business connectors, which is the standard route for data to leave the organisation.' `
                    -Remediation 'Extend an existing policy to cover this environment, or apply a tenant-wide default policy.')
            }
        }

        if ($env.BackupStatus -eq 'Collected' -and (Test-PPIsProduction $env)) {
            if ($env.BackupCount -eq 0) {
                Add-F (New-PPFinding -Rule 'ENV-NOBACKUP' -Severity 'High' -Category 'Continuity' `
                    -Title 'Production environment has no restore points' -Environment $env.DisplayName -Asset $env.DisplayName `
                    -Evidence 'Backup API returned zero restore points' `
                    -Why 'There is nothing to restore from after data loss or a bad deployment.' `
                    -Remediation 'Confirm system backups are enabled and take a manual backup before the next major change.')
            }
            elseif ($env.LatestBackup) {
                try {
                    $age = [int]((Get-Date) - [datetime]$env.LatestBackup).TotalDays
                    if ($age -gt 7) {
                        Add-F (New-PPFinding -Rule 'ENV-STALEBACKUP' -Severity 'Medium' -Category 'Continuity' `
                            -Title "Most recent restore point is $age days old" -Environment $env.DisplayName -Asset $env.DisplayName `
                            -Evidence "Latest backup $($env.LatestBackup)" `
                            -Why 'Recovery point objective is worse than the backup cadence implies.' `
                            -Remediation 'Verify system backups are running; take manual backups before significant changes.')
                    }
                } catch { }
            }
        }

        if ((Test-PPIsProduction $env) -and $env.HasDataverse -and -not $env.SecurityGroupId) {
            Add-F (New-PPFinding -Rule 'ENV-NOSECGROUP' -Severity 'Medium' -Category 'Security' `
                -Title 'Environment has no security group' -Environment $env.DisplayName -Asset $env.DisplayName `
                -Evidence 'linkedEnvironmentMetadata.securityGroupId is empty' `
                -Why 'Every licensed user in the tenant is provisioned into the environment, widening access far beyond the intended team.' `
                -Remediation 'Assign a security group so membership is explicit.')
        }

        # --- Pay-as-you-go coverage for agent-bearing environments ---
        # Only meaningful once we know both sides: which agents exist here, and whether billing
        # policies were readable at all. If the billing collector failed, say nothing - a missing
        # billing policy and an unreadable billing API look identical from here, and guessing
        # would produce a false "no plan" on a tenant that has one.
        if ($billingReadable) {
            $envAgents = @($allAgents | Where-Object { $_.EnvironmentId -eq $env.Name })
            if ($envAgents.Count -gt 0 -and (Test-PPPayAsYouGoEligible $env)) {
                $policy = Get-PPBillingPolicyFor -Policies $billingPolicies -EnvironmentId $env.Name
                $published = @($envAgents | Where-Object { $_.PublishedOn }).Count

                if (-not $policy) {
                    # Production carries the consequence; sandbox is a warning about the same cliff.
                    $sev = 'Medium'
                    if ((Test-PPIsProduction $env) -and $published -gt 0) { $sev = 'High' }
                    Add-F (New-PPFinding -Rule 'COST-AGENT-NOBILLING' -Severity $sev -Category 'Cost' `
                        -Title 'Agents run here with no pay-as-you-go billing policy' -Environment $env.DisplayName -Asset $env.DisplayName `
                        -Evidence "$($envAgents.Count) agent(s), $published published; environment is not listed in any of the $(@($billingPolicies).Count) billing policy/policies" `
                        -Why 'These agents draw solely on the tenant''s prepaid Copilot credit pool. When consumption exceeds capacity the environment goes into overage and enforcement makes agents unavailable to users: "This agent is currently unavailable. It has reached its usage limit." A billing policy is the documented way to absorb overage instead of stopping.' `
                        -Remediation 'Either attach this environment to a pay-as-you-go billing policy backed by an Azure subscription, or purchase capacity packs sized to observed consumption. Check consumption first on the Billing page before choosing.')
                }
                elseif ([string]$policy.Status -eq 'Disabled') {
                    Add-F (New-PPFinding -Rule 'COST-BILLING-DISABLED' -Severity 'High' -Category 'Cost' `
                        -Title 'Billing policy covering this environment is disabled' -Environment $env.DisplayName -Asset $policy.Name `
                        -Evidence "Policy '$($policy.Name)' status = Disabled, Azure subscription $($policy.SubscriptionId)" `
                        -Why 'The environment looks covered on paper but the policy is not billing. Overage enforcement applies as if there were no plan at all, and agents stop when prepaid credits run out.' `
                        -Remediation 'Re-enable the policy, or confirm the Azure subscription behind it is still active and correctly linked.')
                }
            }
        }

        if ($env.IsDefault) {
            Add-F (New-PPFinding -Rule 'ENV-DEFAULT' -Severity 'Info' -Category 'Governance' `
                -Title 'Default environment is present and open to all makers' -Environment $env.DisplayName -Asset $env.DisplayName `
                -Evidence 'isDefault = true' `
                -Why 'Every user in the tenant is a maker here by design and it cannot be restricted with a security group. It is where sprawl accumulates.' `
                -Remediation 'Apply a restrictive DLP policy and route real projects to purpose-built environments.')
        }
    }

    # ================= Solutions and security =================
    foreach ($dv in @($Data.Dataverse)) {
        $env = @($Data.Environments | Where-Object { $_.Name -eq $dv.EnvironmentId })[0]
        $isProd = $env -and (Test-PPIsProduction $env)

        if ($isProd) {
            $unmanaged = @($dv.Solutions | Where-Object { -not $_.IsManaged -and $_.UniqueName -ne 'Default' -and $_.UniqueName -ne 'Active' })
            if ($unmanaged.Count -gt 0) {
                Add-F (New-PPFinding -Rule 'SOL-UNMANAGED-PROD' -Severity 'Medium' -Category 'ALM' `
                    -Title "$($unmanaged.Count) unmanaged solution(s) in production" -Environment $dv.EnvironmentName -Asset $dv.EnvironmentName `
                    -Evidence ("Unmanaged: " + (($unmanaged | Select-Object -First 8 | ForEach-Object { $_.UniqueName }) -join ', ')) `
                    -Why 'Customisations were made directly in production, so changes cannot be reliably promoted, reproduced or rolled back.' `
                    -Remediation 'Move authoring into a development environment and deploy managed solutions forward.')
            }
        }

        foreach ($adm in @($dv.AdminUsers | Where-Object { $_.IsAppUser })) {
            Add-F (New-PPFinding -Rule 'SEC-SPN-SYSADMIN' -Severity 'High' -Category 'Security' `
                -Title 'Service principal holds System Administrator' -Environment $dv.EnvironmentName -Asset $adm.FullName `
                -Evidence "applicationid $($adm.ApplicationId)" `
                -Why 'A non-interactive identity has unrestricted access to all data in the environment; a leaked secret is a full compromise.' `
                -Remediation 'Replace with a least-privilege custom security role scoped to the tables the integration actually needs.')
        }

        foreach ($adm in @($dv.AdminUsers | Where-Object { $_.IsDisabled -and -not $_.IsAppUser })) {
            Add-F (New-PPFinding -Rule 'SEC-DISABLED-ADMIN' -Severity 'Medium' -Category 'Security' `
                -Title 'Disabled account still holds System Administrator' -Environment $dv.EnvironmentName -Asset $adm.FullName `
                -Evidence "systemuser $($adm.UPN) isdisabled = true with System Administrator" `
                -Why 'Re-enabling the account, or restoring it from a directory backup, silently restores full administrative access.' `
                -Remediation 'Remove the role assignment as part of the leaver process.')
        }

        if (@($dv.AsyncFailures).Count -ge 10) {
            Add-F (New-PPFinding -Rule 'DV-ASYNCFAIL' -Severity 'Medium' -Category 'Reliability' `
                -Title "$(@($dv.AsyncFailures).Count) failed system jobs in the last 7 days" -Environment $dv.EnvironmentName -Asset $dv.EnvironmentName `
                -Evidence ("Most recent: " + (@($dv.AsyncFailures)[0].Name)) `
                -Why 'Sustained asynchronous failures usually mean a broken integration, plugin or scheduled process nobody is watching.' `
                -Remediation 'Review the system jobs view and address the most frequent failure signature.')
        }
    }

    # ================= Service principal credentials =================
    foreach ($sp in @($Data.Identity.ServicePrincipals)) {
        if ($null -ne $sp.DaysToExpiry -and $sp.DaysToExpiry -lt 0) {
            Add-F (New-PPFinding -Rule 'SEC-SPN-EXPIRED' -Severity 'Medium' -Category 'Reliability' `
                -Title 'Service principal credential has expired' -Asset $sp.DisplayName `
                -Evidence "Soonest credential expiry $($sp.SoonestExpiry)" `
                -Why 'Any integration still relying on this credential is already failing.' `
                -Remediation 'Roll the secret or certificate, or remove the registration if unused.')
        }
        elseif ($null -ne $sp.DaysToExpiry -and $sp.DaysToExpiry -le 60) {
            Add-F (New-PPFinding -Rule 'SEC-SPN-EXPIRING' -Severity 'Low' -Category 'Reliability' `
                -Title "Service principal credential expires in $($sp.DaysToExpiry) days" -Asset $sp.DisplayName `
                -Evidence "Expiry $($sp.SoonestExpiry)" `
                -Why 'Unrotated credentials cause outages that are hard to diagnose because nothing changed in the app.' `
                -Remediation 'Schedule rotation before the expiry date.')
        }
    }

    # ================= Credits, capacity and consumption =================
    # Every rule here is gated on the specific dataset that feeds it having actually been read.
    # The Licensing routes are gated per-route: an operator can read tenant currency totals and
    # still be refused the per-agent breakdown. Treating a 403 as "no consumption" would invert
    # the meaning of the entire cost section, so a blocked dataset raises a visibility finding
    # and nothing else.
    $usage = $Data.Usage
    if ($usage) {
        $usageGap = { param($Item) [bool](@($usage.Gaps) | Where-Object { $_.Item -eq $Item }) }

        # --- Meter headroom: the cliff that stops agents working ---
        foreach ($c in @($usage.CurrencyReports)) {
            if ($null -eq $c.PctConsumed) { continue }   # no denominator, no judgement

            if ($c.Overage -eq $true) {
                Add-F (New-PPFinding -Rule 'COST-METER-OVERAGE' -Severity 'Critical' -Category 'Cost' `
                    -Title "$($c.Label): consumption has exceeded purchased capacity" -Asset $c.Label `
                    -Evidence ("consumed {0} of {1} purchased ({2}%), remaining {3}, as of {4}" -f `
                        $c.Consumed, $c.Purchased, $c.PctConsumed, $c.Remaining, $c.LastUpdated) `
                    -Why 'The tenant is past its prepaid entitlement on this meter. Without a pay-as-you-go billing policy to absorb the overage, enforcement makes the affected resources unavailable to users rather than billing the excess - for agents that surfaces as "This agent is currently unavailable. It has reached its usage limit."' `
                    -Remediation 'Confirm a billing policy covers the consuming environments, or purchase capacity sized to the observed burn. The per-resource table on the Usage page names what to look at first.')
            }
            elseif ($c.PctConsumed -ge 90) {
                Add-F (New-PPFinding -Rule 'COST-METER-NEARCAP' -Severity 'High' -Category 'Cost' `
                    -Title "$($c.Label): $($c.PctConsumed)% of purchased capacity consumed" -Asset $c.Label `
                    -Evidence ("consumed {0} of {1} purchased, remaining {2}, as of {3}" -f `
                        $c.Consumed, $c.Purchased, $c.Remaining, $c.LastUpdated) `
                    -Why 'At this rate the meter runs out inside the current period, and the failure mode is enforcement rather than a bill. The figure is also a daily aggregate that lags, so real consumption is at least this high.' `
                    -Remediation 'Decide now between additional capacity and a pay-as-you-go policy. Leaving it to the enforcement cliff turns a cost decision into an outage.')
            }
            elseif ($c.PctConsumed -ge 75) {
                Add-F (New-PPFinding -Rule 'COST-METER-NEARCAP' -Severity 'Medium' -Category 'Cost' `
                    -Title "$($c.Label): $($c.PctConsumed)% of purchased capacity consumed" -Asset $c.Label `
                    -Evidence ("consumed {0} of {1} purchased, as of {2}" -f $c.Consumed, $c.Purchased, $c.LastUpdated) `
                    -Why 'Still inside entitlement, but close enough that an unplanned new agent or a usage spike would cross it.' `
                    -Remediation 'Set a spend threshold on this meter so the next move is a notification rather than a surprise.')
            }
        }

        # --- Storage and API capacity ---
        foreach ($t in @($usage.TenantCapacity)) {
            if ($null -eq $t.PctConsumed) { continue }
            if ($t.PctConsumed -ge 95) {
                Add-F (New-PPFinding -Rule 'COST-CAPACITY-FULL' -Severity 'High' -Category 'Cost' `
                    -Title "$($t.CapacityType) capacity is $($t.PctConsumed)% consumed" -Asset $t.CapacityType `
                    -Evidence ("actual {0} of {1} entitled {2}" -f $t.Actual, $t.Entitled, $t.Unit) `
                    -Why 'Exhausted storage capacity blocks environment creation and copy operations, and Dataverse begins refusing writes. It fails as an outage, not as a bill.' `
                    -Remediation 'Reclaim capacity by deleting unused environments and trimming log/file storage, or buy an add-on.')
            }
        }

        # --- Per-environment allocation overrun ---
        foreach ($a in @($usage.EnvironmentAllocations)) {
            if ($null -eq $a.Allocated -or $null -eq $a.Consumed) { continue }
            if ($a.Allocated -gt 0 -and $a.Consumed -gt $a.Allocated) {
                Add-F (New-PPFinding -Rule 'COST-ENV-OVERALLOC' -Severity 'Medium' -Category 'Cost' `
                    -Title 'Environment has consumed more than its allocated credits' `
                    -Environment $a.EnvironmentName -Asset $(if ($a.CurrencyLabel) { $a.CurrencyLabel } else { $a.Currency }) `
                    -Evidence ("consumed {0} against an allocation of {1} ({2})" -f $a.Consumed, $a.Allocated, $a.Currency) `
                    -Why 'The environment is drawing on the shared tenant pool beyond its own allocation, so it can exhaust capacity other environments were relying on.' `
                    -Remediation 'Either raise this environment''s allocation deliberately, or cap it so the overspend surfaces here instead of in another team''s outage.')
            }
        }

        # --- Attribution we were refused: "we cannot tell you who spent it" is a finding ---
        foreach ($m in @($usage.Meters)) {
            $blocked = ([string]$m.ResourceState -like 'HTTP 40*')

            # A hand-imported PPAC report closes the gap the 403 left. The finding must then
            # change rather than persist: claiming attribution is unavailable while the page
            # shows a full per-agent table would discredit the whole register. But it does not
            # simply disappear either - imported data is a point-in-time export that will go
            # stale silently, which is worth its own Info note.
            $importedForMeter = @(@($usage.Resources) |
                Where-Object { $_.Currency -eq $m.Id -and $_.Source -eq 'PPAC report' })

            if ($blocked -and $importedForMeter.Count -gt 0) {
                $files = @($importedForMeter | ForEach-Object { $_.SourceFile } | Where-Object { $_ } | Select-Object -Unique)
                Add-F (New-PPFinding -Rule 'COST-ATTRIBUTION-IMPORTED' -Severity 'Info' -Category 'Cost' `
                    -Title "$($m.Label): per-agent attribution came from a manual export, not the API" -Asset $m.Label `
                    -Evidence ("per-resource route returned $($m.ResourceState); $($importedForMeter.Count) row(s) imported from $(@($files) -join ', ')") `
                    -Why 'The attribution on the Usage page is correct but frozen at whatever date that file was exported, and nothing will refresh it or warn you when it ages. The API route that would keep it current is still refused for this operator.' `
                    -Remediation 'Re-export the report each time you re-run the collection, or pursue the role that unblocks GET /licensing/entitlements/{id}/resources so the figure refreshes itself.')
            }
            elseif ($blocked) {
                Add-F (New-PPFinding -Rule 'COST-ATTRIBUTION-BLIND' -Severity 'Medium' -Category 'Cost' `
                    -Title "$($m.Label): credit consumption cannot be attributed to an agent or app" -Asset $m.Label `
                    -Evidence "per-resource consumption route returned $($m.ResourceState)" `
                    -Why 'Tenant totals are readable but the breakdown is not, so when this meter approaches its limit there is no way to identify which agent or app to act on. Note this is an absence of access, not an absence of consumption.' `
                    -Remediation 'Download the agent-level breakdown by hand - Power Platform admin center > Licensing > Products > Copilot Studio > Summary > Download report > agent - then re-run with -UsageReport <file> to import it into this page. Observed behaviour is a 403 at every api-version on the per-resource routes while the per-user routes return 200 with the same token, and the service returns no error body naming the required permission, so this is a permission boundary to raise with support rather than a route to retry.')
            }
        }

        # --- Concentration: one resource carrying most of a meter ---
        # Only meaningful where the breakdown was actually readable and the total is non-trivial.
        $byMeter = @($usage.Resources | Where-Object { $null -ne $_.Consumed } | Group-Object -Property Currency)
        foreach ($g in $byMeter) {
            $rows  = @($g.Group)
            $total = (@($rows | Measure-Object -Property Consumed -Sum).Sum)
            if (-not $total -or $total -le 0) { continue }
            $top = @($rows | Sort-Object Consumed -Descending)[0]
            $share = [math]::Round(($top.Consumed / $total) * 100, 1)

            # One resource in a one-resource tenant is 100% by definition and says nothing.
            if ($rows.Count -ge 3 -and $share -ge 50) {
                $name = $(if ($top.ResourceName) { $top.ResourceName } else { $top.ResourceId })
                Add-F (New-PPFinding -Rule 'COST-CONCENTRATION' -Severity 'Medium' -Category 'Cost' `
                    -Title "One $($top.ResourceKind.ToLower()) drives $share% of $($top.CurrencyLabel) consumption" `
                    -Environment $top.EnvironmentName -Asset $name `
                    -Evidence ("{0} consumed {1} of {2} total across {3} resources" -f $name, $top.Consumed, $total, $rows.Count) `
                    -Why 'Cost is concentrated in a single asset, so this one resource decides whether the tenant hits its limit. It is also the cheapest thing to tune: a prompt or trigger change here moves the whole meter.' `
                    -Remediation 'Review this resource''s design and traffic before buying more capacity, and set a resource-level spend threshold on it.')
            }
        }

        # --- Credits burned by resources we cannot identify ---
        $unmatched = @($usage.Resources | Where-Object { -not $_.Matched -and $null -ne $_.Consumed -and $_.Consumed -gt 0 })
        if ($unmatched.Count -gt 0) {
            $sum = (@($unmatched | Measure-Object -Property Consumed -Sum).Sum)
            Add-F (New-PPFinding -Rule 'COST-UNMATCHED-RESOURCE' -Severity 'Medium' -Category 'Cost' `
                -Title "$($unmatched.Count) consuming resource(s) match nothing in the inventory" `
                -Evidence ("{0} credit(s) consumed by unidentified resource IDs, e.g. {1}" -f $sum, (@($unmatched | Select-Object -First 3 | ForEach-Object { $_.ResourceId }) -join ', ')) `
                -Why 'Something is spending credits that this collection cannot name. The usual causes are an asset in an environment we could not read, a deleted asset still billing for the period, or a resource kind not inventoried here - each of which is worth knowing before the next capacity purchase.' `
                -Remediation 'Cross-check these IDs in the Power Platform admin center. Start with the environments listed as unreadable on the Integrity page.')
        }

        # --- A leaver still spending money ---
        $leavers = @($usage.Users | Where-Object { $_.Orphaned -and $null -ne $_.Consumed -and $_.Consumed -gt 0 })
        foreach ($u in $leavers) {
            $who = $(if ($u.UserName) { $u.UserName } else { $u.UserId })
            Add-F (New-PPFinding -Rule 'COST-LEAVER-CONSUMING' -Severity 'High' -Category 'Cost' `
                -Title 'Credits are being consumed under a departed or unknown account' `
                -Environment $u.EnvironmentName -Asset $who `
                -Evidence ("{0} consumed {1} {2}; directory lookup: {3}" -f $who, $u.Consumed, $u.CurrencyLabel, `
                    $(if ($u.KnownInDirectory) { 'account is disabled' } else { 'not found in the directory' })) `
                -Why 'Either an automation is still running under a leaver''s identity, or consumption is being attributed to a principal the directory does not know. Both mean spend nobody owns, and the first is also a standing access risk.' `
                -Remediation 'Identify what runs as this principal, reassign it to an active owner, and confirm the account''s access was actually revoked rather than just its licence removed.')
        }

        # --- No spend alarm anywhere on a meter that is actually being consumed ---
        foreach ($m in @($usage.Meters)) {
            if ($m.ThresholdState -ne 'Collected') { continue }   # unreadable: say nothing
            $hasThreshold = [bool](@($usage.Thresholds) | Where-Object { $_.Currency -eq $m.Id })
            $spent = @($usage.CurrencyReports | Where-Object { $_.Currency -eq $m.Id -and $null -ne $_.Consumed -and $_.Consumed -gt 0 })
            if (-not $hasThreshold -and $spent.Count -gt 0) {
                Add-F (New-PPFinding -Rule 'COST-NO-THRESHOLD' -Severity 'Medium' -Category 'Cost' `
                    -Title "$($m.Label): no spend threshold or alert is configured" -Asset $m.Label `
                    -Evidence "consumption present on this meter; resourceThresholds returned no configured threshold" `
                    -Why 'Nothing will warn anyone before this meter reaches its limit. The first signal will be users reporting that an agent stopped working.' `
                    -Remediation 'Configure a notification threshold, and a stop-at-capacity rule where an outage is preferable to unbounded spend.')
            }
        }
    }

    # ================= Azure pay-as-you-go cost =================
    $az = $Data.AzureCost
    if ($az -and $az.Attempted) {
        $denied = @($az.Subscriptions | Where-Object { [string]$_.State -like 'HTTP 40*' })
        if ($denied.Count -gt 0) {
            Add-F (New-PPFinding -Rule 'COST-AZURE-NOACCESS' -Severity 'Info' -Category 'Cost' `
                -Title 'Azure cost for pay-as-you-go could not be read' `
                -Evidence ("{0} subscription(s) refused: {1}" -f $denied.Count, (@($denied | ForEach-Object { "$($_.SubscriptionId) ($($_.State))" }) -join ', ')) `
                -Why 'Credit consumption is visible but the currency cost of the overage is not. Power Platform Administrator does not grant Azure RBAC, so this is expected rather than a misconfiguration - it just means nobody can see the bill from here.' `
                -Remediation 'Grant the operator Cost Management Reader on those subscriptions if the money figure needs to be in this report, or take it from the Azure portal separately.')
        }
        # A policy pointing at a subscription that does not exist is a real billing failure: the
        # environment looks covered while nothing can actually absorb the overage.
        $missing = @($az.Subscriptions | Where-Object { [string]$_.State -eq 'HTTP 404' })
        foreach ($s in $missing) {
            Add-F (New-PPFinding -Rule 'COST-AZURE-SUBMISSING' -Severity 'High' -Category 'Cost' `
                -Title 'Billing policy points at a subscription that cannot be found' `
                -Asset $s.SubscriptionId `
                -Evidence ("policy/policies {0} reference subscription {1}, which returned 404" -f (@($s.Policies) -join ', '), $s.SubscriptionId) `
                -Why 'The environments under this policy appear covered for pay-as-you-go while the billing instrument behind it is gone. Overage would be enforced rather than billed, exactly as if no policy existed.' `
                -Remediation 'Repoint the billing policy at a live subscription, or confirm the 404 is only a permissions artefact before trusting the coverage table.')
        }
    }

    # ================= Connections =================
    foreach ($c in @($Data.Connections)) {
        if ($c.Status -and $c.Status -ne 'Connected') {
            Add-F (New-PPFinding -Rule 'CONN-ERROR' -Severity 'Medium' -Category 'Reliability' `
                -Title 'Connection is not in a connected state' -Environment $c.EnvironmentName -Asset $c.DisplayName `
                -Evidence "status = $($c.Status), connector $($c.ConnectorName)" `
                -Why 'Every app and flow depending on this connection is failing or about to.' `
                -Remediation 'Re-authenticate the connection or repoint the dependants.')
        }
    }

    # Sort by severity, then category, so the register reads worst-first.
    $sorted = @($f | Sort-Object `
        @{ Expression = { $script:PPSeverityRank[$_.Severity] } }, `
        @{ Expression = { $_.Category } }, `
        @{ Expression = { $_.Rule } })

    return $sorted
}

function Get-PPFindingSummary {
    param($Findings)
    $summary = [ordered]@{}
    foreach ($sev in @('Critical','High','Medium','Low','Info')) {
        $summary[$sev] = @($Findings | Where-Object { $_.Severity -eq $sev }).Count
    }
    return $summary
}
