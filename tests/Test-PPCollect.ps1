<#
.SYNOPSIS
    Offline tests for Phase 1 collection: findings rules and report rendering.
.DESCRIPTION
    No tenant, no network, no credentials. The fixture is built to trip specific rules so a
    regression in the rules engine fails loudly rather than silently reporting a clean tenant -
    which is the most dangerous failure mode this tool has.
#>

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

. (Join-Path $root 'src\Core\PPLog.ps1')
. (Join-Path $root 'src\Core\PPHttp.ps1')
. (Join-Path $root 'src\Core\PPAuth.ps1')
. (Join-Path $root 'src\Core\PPDataverse.ps1')
. (Join-Path $root 'src\Collect\Collect-Identity.ps1')
. (Join-Path $root 'src\Collect\Collect-Usage.ps1')
. (Join-Path $root 'src\Collect\Import-PPUsageReport.ps1')
. (Join-Path $root 'src\Analyze\Invoke-PPFindings.ps1')
. (Join-Path $root 'src\Render\PPHtml.ps1')
. (Join-Path $root 'src\Render\Render-Report.ps1')

$pass = 0; $fail = 0
function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail)
    if ($Condition) { $script:pass++; Write-Host ("  PASS  " + $Name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  FAIL  " + $Name) -ForegroundColor Red
           if ($Detail) { Write-Host ("        " + $Detail) -ForegroundColor DarkGray } }
}

# ---------------------------------------------------------------------------------------
# Fixture: one production environment with deliberately bad posture, one developer
# environment where the same conditions should NOT raise production-only findings.
# ---------------------------------------------------------------------------------------
$userIndex = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
$userIndex['1111'] = [PSCustomObject]@{ Id='1111'; DisplayName='Active Alice'; UPN='alice@c.com'; AccountEnabled=$true }
$userIndex['2222'] = [PSCustomObject]@{ Id='2222'; DisplayName='Departed Dave'; UPN='dave@c.com'; AccountEnabled=$false }

$data = [PSCustomObject]@{
    Meta = [PSCustomObject]@{
        TenantId='t1'; Account='admin@c.com'; StartedUtc='2026-08-11 10:00:00'; ElapsedSeconds=42
        Depth='Standard'; PSVersion='5.1'; CallCount=3
        Calls=@([PSCustomObject]@{ Label='x'; Uri='https://a/b'; Method='GET'; StatusCode=403; Success=$false; DurationMs=10 })
    }
    Tenant = [PSCustomObject]@{
        TenantId='t1'
        IsolationPolicy=$null
        DlpPolicies=@(
            [PSCustomObject]@{ Id='p1'; DisplayName='Prod only'; Type='OnlyEnvironments'
                               Environments=@('env-prod'); CreatedBy='Alice'; CreatedOn='2026-01-01'; LastModified='2026-02-01'
                               ConnectorGroups=@([PSCustomObject]@{ Classification='Business'; ConnectorCount=12; Connectors=@() }) }
        )
        EnvironmentGroups=@()
        BillingPolicies=@(
            [PSCustomObject]@{ Id='bp1'; Name='Finance PAYG'; Status='Enabled'; Location='europe'
                               SubscriptionId='00000000-0000-0000-0000-000000000001'; ResourceGroup='rg-pp'
                               CreatedOn='2026-01-01'; CreatedBy='alice'; LastModifiedOn='2026-01-01'
                               Environments=@('env-billed'); EnvironmentCount=1; EnvironmentStatus='Collected' },
            [PSCustomObject]@{ Id='bp2'; Name='Legacy PAYG'; Status='Disabled'; Location='europe'
                               SubscriptionId='00000000-0000-0000-0000-000000000002'; ResourceGroup='rg-old'
                               CreatedOn='2025-01-01'; CreatedBy='alice'; LastModifiedOn='2026-01-01'
                               Environments=@('env-stale'); EnvironmentCount=1; EnvironmentStatus='Collected' }
        )
        Gaps=@([PSCustomObject]@{ Item='Tenant settings'; Reason='POST-only' })
    }
    Environments = @(
        [PSCustomObject]@{ Name='env-prod'; DisplayName='HR Production'; Sku='Production'; Region='europe'
                           State='Succeeded'; HasDataverse=$true; OrgUrl='https://hr.crm4.dynamics.com'; OrgVersion='9.2'
                           SecurityGroupId=$null; IsDefault=$false; CreatedTime='2025-01-01'
                           BackupStatus='Collected'; BackupCount=0; LatestBackup=$null; DrStatus='Unknown' },
        [PSCustomObject]@{ Name='env-nodlp'; DisplayName='Marketing'; Sku='Production'; Region='europe'
                           State='Succeeded'; HasDataverse=$true; OrgUrl='https://mk.crm4.dynamics.com'; OrgVersion='9.2'
                           SecurityGroupId='sg-1'; IsDefault=$false; CreatedTime='2025-01-01'
                           BackupStatus='Collected'; BackupCount=5; LatestBackup=(Get-Date).AddDays(-1).ToString('o'); DrStatus='Unknown' },
        [PSCustomObject]@{ Name='env-dev'; DisplayName='Dev sandbox'; Sku='Developer'; Region='europe'
                           State='Succeeded'; HasDataverse=$true; OrgUrl='https://dev.crm4.dynamics.com'; OrgVersion='9.2'
                           SecurityGroupId=$null; IsDefault=$false; CreatedTime='2025-01-01'
                           BackupStatus='Collected'; BackupCount=0; LatestBackup=$null; DrStatus='Unknown' },
        # Billing coverage cases: one properly covered, one covered by a disabled policy.
        [PSCustomObject]@{ Name='env-billed'; DisplayName='Finance'; Sku='Production'; Region='europe'
                           State='Succeeded'; HasDataverse=$true; OrgUrl='https://fin.crm4.dynamics.com'; OrgVersion='9.2'
                           SecurityGroupId='sg-2'; IsDefault=$false; CreatedTime='2025-01-01'
                           BackupStatus='Collected'; BackupCount=5; LatestBackup=(Get-Date).AddDays(-1).ToString('o'); DrStatus='Unknown' },
        [PSCustomObject]@{ Name='env-stale'; DisplayName='Ops'; Sku='Production'; Region='europe'
                           State='Succeeded'; HasDataverse=$true; OrgUrl='https://ops.crm4.dynamics.com'; OrgVersion='9.2'
                           SecurityGroupId='sg-3'; IsDefault=$false; CreatedTime='2025-01-01'
                           BackupStatus='Collected'; BackupCount=5; LatestBackup=(Get-Date).AddDays(-1).ToString('o'); DrStatus='Unknown' }
    )
    Apps = @(
        [PSCustomObject]@{ Id='a1'; DisplayName='Expenses'; EnvironmentId='env-prod'; EnvironmentName='HR Production'
                           OwnerId='2222'; OwnerName='Departed Dave'; SharedWithTenant=$true; SharedUsers=400
                           CreatedTime='2025-01-01'; LastModified='2025-06-01'; Permissions=@() }
    )
    Flows = @(
        [PSCustomObject]@{ Id='f1'; DisplayName='Nightly sync'; EnvironmentId='env-prod'; EnvironmentName='HR Production'
                           State='Suspended'; OwnerId='2222'; TriggerType='Recurrence'; ActionCount=9
                           CreatedTime='2025-01-01'; LastModified='2025-06-01' }
    )
    Connections = @(
        [PSCustomObject]@{ Id='c1'; DisplayName='SQL prod'; EnvironmentId='env-prod'; EnvironmentName='HR Production'
                           ConnectorName='sql'; Status='Error'; OwnerName='Alice'; CreatedTime='2025-01-01' }
    )
    CustomConnectors = @()
    Dataverse = @(
        [PSCustomObject]@{
            EnvironmentId='env-prod'; EnvironmentName='HR Production'; OrgUrl='https://hr.crm4.dynamics.com'
            Sku='Production'; Reachable=$true; Reason=$null
            Agents=@(
                [PSCustomObject]@{ Id='b1'; Name='Public HR bot'; EnvironmentId='env-prod'; EnvironmentName='HR Production'
                                   State='Active'; Status='Provisioned'; StatusCode=1
                                   AccessPolicy='Any (multi-tenant)'; AccessPolicyCode=3
                                   AuthMode='None'; AuthModeCode=1
                                   IsPublished=$true; PublishedOn='2026-01-01'; IsManaged=$false
                                   OwnerId='2222'; UsesModelKnowledge=$true; GenerativeOrch=$true; IsAutonomous=$true
                                   ModifiedOn='2026-06-01' },
                [PSCustomObject]@{ Id='b2'; Name='Draft bot'; EnvironmentId='env-prod'; EnvironmentName='HR Production'
                                   State='Active'; Status='MissingLicense'; StatusCode=5
                                   AccessPolicy='Copilot readers'; AccessPolicyCode=1
                                   AuthMode='Integrated'; AuthModeCode=2
                                   IsPublished=$false; IsManaged=$true
                                   OwnerId='1111'; UsesModelKnowledge=$false; GenerativeOrch=$false; IsAutonomous=$false
                                   ModifiedOn='2026-06-01' }
            )
            Solutions=@([PSCustomObject]@{ UniqueName='CustomHR'; IsManaged=$false; FriendlyName='Custom HR'; Version='1.0' })
            SystemUsers=@(); ApplicationUsers=@()
            AdminUsers=@(
                [PSCustomObject]@{ Id='u1'; FullName='Integration SPN'; UPN=$null; ApplicationId='app-123'
                                   IsAppUser=$true; IsDisabled=$false; EnvironmentName='HR Production' },
                [PSCustomObject]@{ Id='u2'; FullName='Departed Dave'; UPN='dave@c.com'; ApplicationId=$null
                                   IsAppUser=$false; IsDisabled=$true; EnvironmentName='HR Production' }
            )
            Workflows=@(); AsyncFailures=@()
        },
        [PSCustomObject]@{
            EnvironmentId='env-dev'; EnvironmentName='Dev sandbox'; OrgUrl='https://dev.crm4.dynamics.com'
            Sku='Developer'; Reachable=$false; Reason='No Dataverse security role in this environment'
            Agents=@(); Solutions=@(); SystemUsers=@(); ApplicationUsers=@(); AdminUsers=@(); Workflows=@(); AsyncFailures=@()
        },
        # Deliberately unremarkable agents: they exist only to make the billing rules decidable,
        # so any other finding raised against them is a regression, not fixture noise.
        [PSCustomObject]@{
            EnvironmentId='env-billed'; EnvironmentName='Finance'; OrgUrl='https://fin.crm4.dynamics.com'
            Sku='Production'; Reachable=$true; Reason=$null
            Agents=@(
                [PSCustomObject]@{ Id='b3'; Name='Invoice helper'; EnvironmentId='env-billed'; EnvironmentName='Finance'
                                   State='Active'; Status='Provisioned'; StatusCode=1
                                   AccessPolicy='Copilot readers'; AccessPolicyCode=1
                                   AuthMode='Integrated'; AuthModeCode=2
                                   IsPublished=$true; PublishedOn='2026-02-01'; IsManaged=$true
                                   OwnerId='1111'; UsesModelKnowledge=$false; GenerativeOrch=$false; IsAutonomous=$false
                                   ModifiedOn='2026-06-01' }
            )
            Solutions=@(); SystemUsers=@(); ApplicationUsers=@(); AdminUsers=@(); Workflows=@(); AsyncFailures=@()
        },
        [PSCustomObject]@{
            EnvironmentId='env-stale'; EnvironmentName='Ops'; OrgUrl='https://ops.crm4.dynamics.com'
            Sku='Production'; Reachable=$true; Reason=$null
            Agents=@(
                [PSCustomObject]@{ Id='b4'; Name='Ops assistant'; EnvironmentId='env-stale'; EnvironmentName='Ops'
                                   State='Active'; Status='Provisioned'; StatusCode=1
                                   AccessPolicy='Copilot readers'; AccessPolicyCode=1
                                   AuthMode='Integrated'; AuthModeCode=2
                                   IsPublished=$true; PublishedOn='2026-02-01'; IsManaged=$true
                                   OwnerId='1111'; UsesModelKnowledge=$false; GenerativeOrch=$false; IsAutonomous=$false
                                   ModifiedOn='2026-06-01' }
            )
            Solutions=@(); SystemUsers=@(); ApplicationUsers=@(); AdminUsers=@(); Workflows=@(); AsyncFailures=@()
        }
    )
    Agents = @()
    Identity = [PSCustomObject]@{
        Users=@($userIndex['1111'], $userIndex['2222']); Groups=@()
        ServicePrincipals=@(
            [PSCustomObject]@{ Id='sp1'; AppId='app-123'; DisplayName='Integration SPN'; CredentialCount=1
                               SoonestExpiry=(Get-Date).AddDays(-5).ToString('o'); DaysToExpiry=-5 },
            [PSCustomObject]@{ Id='sp2'; AppId='app-456'; DisplayName='Reporting SPN'; CredentialCount=1
                               SoonestExpiry=(Get-Date).AddDays(30).ToString('o'); DaysToExpiry=30 }
        )
        Skus=@(); UserIndex=$userIndex; Gaps=@()
    }
    # ---- Usage fixture --------------------------------------------------------------------
    # Built to exercise the cost rules AND their refusals: one meter in overage, one near the
    # cliff, one meter whose per-resource attribution was refused (403), a leaver consuming
    # credits, an unmatched resource ID, and a readable-but-empty threshold set. The 403 case
    # is the important one: it must raise a visibility finding and NOT a "no consumption" one.
    Usage = [PSCustomObject]@{
        WindowFrom='2026-07-12'; WindowTo='2026-08-11'; WindowDays=30
        CurrencyReports=@(
            [PSCustomObject]@{ Currency='MCSMessages'; Label='Copilot Studio credits'
                               Purchased=25000.0; Allocated=25000.0; Consumed=26500.0; Remaining=-1500.0
                               PctConsumed=106.0; Overage=$true; LastUpdated='2026-08-10'; Unit='credits' },
            [PSCustomObject]@{ Currency='AI'; Label='AI Builder credits'
                               Purchased=10000.0; Allocated=8000.0; Consumed=9200.0; Remaining=800.0
                               PctConsumed=92.0; Overage=$false; LastUpdated='2026-08-10'; Unit='credits' },
            [PSCustomObject]@{ Currency='PAUnattendedRPA'; Label='Unattended RPA'
                               Purchased=100.0; Allocated=100.0; Consumed=12.0; Remaining=88.0
                               PctConsumed=12.0; Overage=$false; LastUpdated='2026-08-10'; Unit='runs' }
        )
        TenantCapacity=@(
            [PSCustomObject]@{ CapacityType='Database'; Entitled=100.0; Actual=98.0; Rated=98.0; Overflow=0.0
                               Unit='GB'; PctConsumed=98.0; LastUpdated='2026-08-10' }
        )
        EnvironmentAllocations=@(
            [PSCustomObject]@{ EnvironmentId='env-prod'; EnvironmentName='Contoso Prod'; Currency='MCSMessages'
                               CurrencyLabel='Copilot Studio credits'; Allocated=5000.0; Consumed=7400.0
                               TenantPool=$true; Enforcement='TenantPool' },
            [PSCustomObject]@{ EnvironmentId='env-billed'; EnvironmentName='Finance'; Currency='MCSMessages'
                               CurrencyLabel='Copilot Studio credits'; Allocated=5000.0; Consumed=1200.0
                               TenantPool=$false; Enforcement=$null }
        )
        Meters=@(
            [PSCustomObject]@{ Id='MCSMessages'; Label='Copilot Studio credits'; Meters='Agent messages.'
                               Detail=$null; ResourceCount=4; UserCount=2
                               ResourceState='Collected'; UserState='Collected'; ThresholdState='Collected' },
            # Attribution refused: totals readable, breakdown not.
            [PSCustomObject]@{ Id='AI'; Label='AI Builder credits'; Meters='AI Builder.'
                               Detail=$null; ResourceCount=$null; UserCount=$null
                               ResourceState='HTTP 403'; UserState='HTTP 403'; ThresholdState='HTTP 404' }
        )
        Resources=@(
            [PSCustomObject]@{ Currency='MCSMessages'; CurrencyLabel='Copilot Studio credits'
                               ResourceId='b1'; ResourceName='Public HR bot'; ResourceKind='Agent'; Matched=$true
                               EnvironmentId='env-prod'; EnvironmentName='Contoso Prod'
                               Consumed=18000.0; NonBillable=2000.0; Billed=16000.0; Unit='credits'
                               Feature='GenerativeAnswers'; ProductName='Copilot Studio'; LastConsumed='2026-08-10' },
            [PSCustomObject]@{ Currency='MCSMessages'; CurrencyLabel='Copilot Studio credits'
                               ResourceId='b3'; ResourceName='Invoice helper'; ResourceKind='Agent'; Matched=$true
                               EnvironmentId='env-billed'; EnvironmentName='Finance'
                               Consumed=4200.0; NonBillable=200.0; Billed=4000.0; Unit='credits'
                               Feature='Messages'; ProductName='Copilot Studio'; LastConsumed='2026-08-09' },
            [PSCustomObject]@{ Currency='MCSMessages'; CurrencyLabel='Copilot Studio credits'
                               ResourceId='b4'; ResourceName='Ops assistant'; ResourceKind='Agent'; Matched=$true
                               EnvironmentId='env-stale'; EnvironmentName='Ops'
                               Consumed=1300.0; NonBillable=0.0; Billed=1300.0; Unit='credits'
                               Feature='Messages'; ProductName='Copilot Studio'; LastConsumed='2026-08-08' },
            # Spending under an ID that matches nothing we inventoried.
            [PSCustomObject]@{ Currency='MCSMessages'; CurrencyLabel='Copilot Studio credits'
                               ResourceId='ghost-9999'; ResourceName=$null; ResourceKind='Unmatched'; Matched=$false
                               EnvironmentId='env-unknown'; EnvironmentName=$null
                               Consumed=3000.0; NonBillable=0.0; Billed=3000.0; Unit='credits'
                               Feature=$null; ProductName=$null; LastConsumed='2026-08-07' }
        )
        Users=@(
            [PSCustomObject]@{ Currency='MCSMessages'; CurrencyLabel='Copilot Studio credits'
                               UserId='1111'; UserName='Active Alice'; UPN='alice@c.com'; Department='Finance'
                               JobTitle='Analyst'; AccountEnabled=$true; Orphaned=$false; KnownInDirectory=$true
                               EnvironmentId='env-prod'; EnvironmentName='Contoso Prod'
                               Consumed=1200.0; NonBillable=0.0; Unit='credits'; LastConsumed='2026-08-10' },
            [PSCustomObject]@{ Currency='MCSMessages'; CurrencyLabel='Copilot Studio credits'
                               UserId='2222'; UserName='Departed Dave'; UPN='dave@c.com'; Department='Operations'
                               JobTitle='Manager'; AccountEnabled=$false; Orphaned=$true; KnownInDirectory=$true
                               EnvironmentId='env-prod'; EnvironmentName='Contoso Prod'
                               Consumed=900.0; NonBillable=0.0; Unit='credits'; LastConsumed='2026-08-09' }
        )
        Departments=@(
            [PSCustomObject]@{ Currency='MCSMessages'; CurrencyLabel='Copilot Studio credits'; Department='Finance'; Users=1; Consumed=1200.0 },
            [PSCustomObject]@{ Currency='MCSMessages'; CurrencyLabel='Copilot Studio credits'; Department='Operations'; Users=1; Consumed=900.0 }
        )
        # Readable and empty: the only state in which "nobody set an alarm" is a fair claim.
        Thresholds=@()
        Trends=@()
        RouteMap=@(
            [PSCustomObject]@{ Dataset='Currency report'; Path='/licensing/tenantCapacity/currencyReports?includeAllocations=true'; Version='2024-10-01'; Status=200; Verdict='Available' },
            [PSCustomObject]@{ Dataset='Consumption by resource (AI Builder credits)'; Path='/licensing/entitlements/AI/resources'; Version=$null; Status=403; Verdict='Blocked (role)' }
        )
        Gaps=@(
            [PSCustomObject]@{ Item='Consumption by resource (AI Builder credits)'
                               Reason='HTTP 403 - the route exists but this operator lacks the role for it. Per-agent and per-app credit attribution is unavailable for this meter.' }
        )
    }
    AzureCost = [PSCustomObject]@{
        WindowFrom='2026-07-12'; WindowTo='2026-08-11'; Attempted=$true
        Subscriptions=@(
            [PSCustomObject]@{ SubscriptionId='00000000-0000-0000-0000-000000000001'; Policies=@('Finance PAYG')
                               State='Collected'; RowCount=42; Cost=1234.56; Currency='USD' },
            # A policy pointing at a subscription that is gone: looks covered, bills nothing.
            [PSCustomObject]@{ SubscriptionId='00000000-0000-0000-0000-000000000002'; Policies=@('Legacy PAYG')
                               State='HTTP 404'; RowCount=0; Cost=$null; Currency=$null }
        )
        Meters=@(
            [PSCustomObject]@{ MeterCategory='Power Platform'; MeterName='Copilot Studio Credits'; Records=30
                               Quantity=1500.0; UnitOfMeasure='1 Credit'; Cost=1100.00; Currency='USD' },
            [PSCustomObject]@{ MeterCategory='Power Platform'; MeterName='AI Builder Credits'; Records=12
                               Quantity=400.0; UnitOfMeasure='1 Credit'; Cost=134.56; Currency='USD' }
        )
        Resources=@(
            [PSCustomObject]@{ SubscriptionId='00000000-0000-0000-0000-000000000001'
                               ResourceId='/subscriptions/0.../providers/Microsoft.PowerPlatform/accounts/pp-finance'
                               ResourceName='pp-finance'; ResourceGroup='rg-pp'; Meters=2; Cost=1234.56; Currency='USD' }
        )
        Totals=[PSCustomObject]@{ Cost=1234.56; Currency='USD'; Records=42; MeterCount=2 }
        Gaps=@(
            [PSCustomObject]@{ Item='Azure cost (00000000-0000-0000-0000-000000000002)'
                               Reason='HTTP 404 - the subscription was not found.' }
        )
    }
}
$data.Agents = @($data.Dataverse | ForEach-Object { $_.Agents })

Write-Host ''
Write-Host '  Findings engine' -ForegroundColor White

$findings = Invoke-PPFindings -Data $data
function Has-Rule { param($R) return [bool](@($findings | Where-Object { $_.Rule -eq $R }).Count) }

Assert-True 'Cross-tenant agent detected (Critical)' `
    ((Has-Rule 'AGENT-XTENANT') -and (@($findings | Where-Object { $_.Rule -eq 'AGENT-XTENANT' })[0].Severity -eq 'Critical'))
Assert-True 'Agent with auth disabled detected'        (Has-Rule 'AGENT-NOAUTH')
Assert-True 'Agent using model knowledge detected'     (Has-Rule 'AGENT-MODELKNOWLEDGE')
Assert-True 'Autonomous agent escalated to High' `
    ((Has-Rule 'AGENT-AUTONOMOUS') -and (@($findings | Where-Object { $_.Rule -eq 'AGENT-AUTONOMOUS' })[0].Severity -eq 'High'))
Assert-True 'Unlicensed agent detected'                (Has-Rule 'AGENT-MISSINGLIC')
Assert-True 'Never-published agent detected'           (Has-Rule 'AGENT-UNPUBLISHED')
Assert-True 'Unmanaged agent in production detected'   (Has-Rule 'AGENT-UNMANAGED-PROD')
Assert-True 'Orphaned agent owner detected'            (Has-Rule 'AGENT-ORPHAN')
Assert-True 'Tenant-wide app share detected'           (Has-Rule 'APP-TENANTSHARE')
Assert-True 'Orphaned app owner detected'              (Has-Rule 'APP-ORPHAN')
Assert-True 'Suspended flow detected'                  (Has-Rule 'FLOW-SUSPENDED')
Assert-True 'Orphaned flow owner detected'             (Has-Rule 'FLOW-ORPHAN')
Assert-True 'Environment without DLP coverage detected' (Has-Rule 'ENV-NODLP')
Assert-True 'Production without restore points detected' (Has-Rule 'ENV-NOBACKUP')
Assert-True 'Missing security group detected'          (Has-Rule 'ENV-NOSECGROUP')
Assert-True 'Unmanaged solution in production detected' (Has-Rule 'SOL-UNMANAGED-PROD')
Assert-True 'Service principal with sysadmin detected' (Has-Rule 'SEC-SPN-SYSADMIN')
Assert-True 'Disabled account with sysadmin detected'  (Has-Rule 'SEC-DISABLED-ADMIN')
Assert-True 'Expired SPN credential detected'          (Has-Rule 'SEC-SPN-EXPIRED')
Assert-True 'Expiring SPN credential detected'         (Has-Rule 'SEC-SPN-EXPIRING')
Assert-True 'Broken connection detected'               (Has-Rule 'CONN-ERROR')

# Rules that must NOT fire: developer environments are exempt from production-only checks.
$devFindings = @($findings | Where-Object { $_.Environment -eq 'Dev sandbox' -and $_.Rule -in @('ENV-NOBACKUP','ENV-NOSECGROUP') })
Assert-True 'Developer env exempt from production-only rules' ($devFindings.Count -eq 0) `
    ("Unexpected: " + (($devFindings | ForEach-Object { $_.Rule }) -join ', '))

# The environment covered by a DLP policy must not be flagged.
$prodDlp = @($findings | Where-Object { $_.Rule -eq 'ENV-NODLP' -and $_.Environment -eq 'HR Production' })
Assert-True 'DLP-covered environment not flagged' ($prodDlp.Count -eq 0)

Write-Host ''
Write-Host '  Copilot billing coverage' -ForegroundColor White

$noBill = @($findings | Where-Object { $_.Rule -eq 'COST-AGENT-NOBILLING' })
Assert-True 'Agent environment with no billing policy flagged' `
    (@($noBill | Where-Object { $_.Environment -eq 'HR Production' }).Count -eq 1)
Assert-True 'Production agents without billing escalated to High' `
    ((@($noBill | Where-Object { $_.Environment -eq 'HR Production' })[0]).Severity -eq 'High')
Assert-True 'Disabled billing policy flagged' `
    (@($findings | Where-Object { $_.Rule -eq 'COST-BILLING-DISABLED' -and $_.Environment -eq 'Ops' }).Count -eq 1)

# The whole point of collecting policy->environment coverage: a covered environment is silent.
Assert-True 'Billed environment not flagged' `
    (@($noBill | Where-Object { $_.Environment -eq 'Finance' }).Count -eq 0)
# An environment covered by a disabled policy gets the disabled finding, not both.
Assert-True 'Stale-policy environment not double-flagged' `
    (@($noBill | Where-Object { $_.Environment -eq 'Ops' }).Count -eq 0)
# Agent-free environments have nothing to bill, so they must stay quiet.
Assert-True 'Environment without agents not flagged for billing' `
    (@($noBill | Where-Object { $_.Environment -eq 'Marketing' }).Count -eq 0)

# Unreadable billing must not masquerade as absent billing.
$blindData = $data.PSObject.Copy()
$blindData.Tenant = [PSCustomObject]@{
    TenantId=$data.Tenant.TenantId; IsolationPolicy=$null; DlpPolicies=$data.Tenant.DlpPolicies
    EnvironmentGroups=@(); BillingPolicies=@()
    Gaps=@([PSCustomObject]@{ Item='Billing policies'; Reason='HTTP 403' })
}
# Usage and Azure cost are cleared too: this fixture is about the billing-policy API being
# unreadable, and leaving the usage fixture in place would let the consumption rules fire and
# mask what is being tested.
$blindData.Usage     = $null
$blindData.AzureCost = $null
$blindFindings = Invoke-PPFindings -Data $blindData
# Scoped to the billing-policy rules specifically. The broader COST-* family now also covers
# consumption rules, which are driven by a different dataset and gated separately.
Assert-True 'No billing finding when the billing API was unreadable' `
    (@($blindFindings | Where-Object { $_.Rule -eq 'COST-AGENT-NOBILLING' -or $_.Rule -eq 'COST-BILLING-DISABLED' }).Count -eq 0)

Write-Host ''
Write-Host '  Usage, credits and cost rules' -ForegroundColor White

Assert-True 'Meter in overage raised as Critical' `
    ((Has-Rule 'COST-METER-OVERAGE') -and (@($findings | Where-Object { $_.Rule -eq 'COST-METER-OVERAGE' })[0].Severity -eq 'Critical'))
Assert-True 'Meter at 92% raised as High' `
    (@($findings | Where-Object { $_.Rule -eq 'COST-METER-NEARCAP' -and $_.Severity -eq 'High' }).Count -ge 1)
# A meter with plenty of headroom must stay silent, or the rule trains the reader to ignore it.
Assert-True 'Meter at 12% not flagged' `
    (@($findings | Where-Object { $_.Rule -eq 'COST-METER-NEARCAP' -and $_.Asset -eq 'Unattended RPA' }).Count -eq 0)
Assert-True 'Storage capacity at 98% flagged'          (Has-Rule 'COST-CAPACITY-FULL')
Assert-True 'Environment over its allocation flagged'  (Has-Rule 'COST-ENV-OVERALLOC')
Assert-True 'Environment inside its allocation not flagged' `
    (@($findings | Where-Object { $_.Rule -eq 'COST-ENV-OVERALLOC' -and $_.Environment -eq 'Finance' }).Count -eq 0)
Assert-True 'Blocked attribution raised as a visibility finding' (Has-Rule 'COST-ATTRIBUTION-BLIND')
Assert-True 'Credit concentration in one agent flagged' (Has-Rule 'COST-CONCENTRATION')
Assert-True 'Unmatched consuming resource flagged'      (Has-Rule 'COST-UNMATCHED-RESOURCE')
Assert-True 'Leaver consuming credits raised as High' `
    ((Has-Rule 'COST-LEAVER-CONSUMING') -and (@($findings | Where-Object { $_.Rule -eq 'COST-LEAVER-CONSUMING' })[0].Severity -eq 'High'))
Assert-True 'Missing spend threshold flagged'           (Has-Rule 'COST-NO-THRESHOLD')
# The threshold route was refused for AI Builder, so its absence must NOT be asserted there.
Assert-True 'No threshold finding where thresholds were unreadable' `
    (@($findings | Where-Object { $_.Rule -eq 'COST-NO-THRESHOLD' -and $_.Asset -eq 'AI Builder credits' }).Count -eq 0)
Assert-True 'Dead billing subscription raised as High'  (Has-Rule 'COST-AZURE-SUBMISSING')

# The single most important negative in this file: when usage was never collected, every cost
# rule must stay silent. A tool that invents cost findings from absent data is worse than one
# that reports none, because the reader cannot tell which figures to trust.
$noUsage = $data.PSObject.Copy()
$noUsage.Usage = $null
$noUsage.AzureCost = $null
$noUsageFindings = Invoke-PPFindings -Data $noUsage
Assert-True 'No usage findings when usage was not collected' `
    (@($noUsageFindings | Where-Object { $_.Rule -like 'COST-METER*' -or $_.Rule -like 'COST-ATTRIB*' -or $_.Rule -like 'COST-LEAVER*' -or $_.Rule -like 'COST-NO-THRESHOLD' -or $_.Rule -like 'COST-CONCENTRATION' -or $_.Rule -like 'COST-UNMATCHED*' -or $_.Rule -like 'COST-CAPACITY*' -or $_.Rule -like 'COST-ENV-OVERALLOC' }).Count -eq 0)

# Unknown must never be treated as zero: a meter with no denominator gets no percentage rule.
$unknownUsage = $data.PSObject.Copy()
$unknownUsage.Usage = [PSCustomObject]@{
    WindowFrom='2026-07-12'; WindowTo='2026-08-11'; WindowDays=30
    CurrencyReports=@(
        [PSCustomObject]@{ Currency='MCSMessages'; Label='Copilot Studio credits'; Purchased=$null
                           Allocated=$null; Consumed=5000.0; Remaining=$null; PctConsumed=$null
                           Overage=$null; LastUpdated=$null; Unit='credits' }
    )
    TenantCapacity=@(); EnvironmentAllocations=@(); Meters=@(); Resources=@(); Users=@()
    Departments=@(); Thresholds=@(); Trends=@(); RouteMap=@(); Gaps=@()
}
$unknownFindings = Invoke-PPFindings -Data $unknownUsage
Assert-True 'Consumption with no denominator raises no headroom finding' `
    (@($unknownFindings | Where-Object { $_.Rule -eq 'COST-METER-OVERAGE' -or $_.Rule -eq 'COST-METER-NEARCAP' }).Count -eq 0)

Write-Host ''
Write-Host '  PPAC report import' -ForegroundColor White

$impDir = Join-Path $env:TEMP 'pp-usage-import-test'
if (Test-Path $impDir) { Remove-Item $impDir -Recurse -Force }
New-Item -ItemType Directory -Path $impDir -Force | Out-Null

# Header spellings deliberately mix separators and casing, and the file carries two preamble
# lines above the real header, which is how these exports actually arrive.
$agentCsv = Join-Path $impDir 'copilot-agent-report.csv'
@(
    'Copilot Studio credit consumption'
    'Generated 2026-08-11'
    'Agent name,Environment name,Product,AI feature,Channel,LLM model,Knowledge sources,Billed credits,Non-billed credits'
    'Public HR bot,Contoso Prod,Copilot Studio,Generative answers,Teams,gpt-4o,SharePoint,16000,2000'
    'Ops assistant,Ops,Copilot Studio,Messages,Web,gpt-4o-mini,None,1300,0'
    'Ghost agent,Unknown env,Copilot Studio,Messages,Web,gpt-4o,None,3000,0'
) | Set-Content -Path $agentCsv -Encoding utf8

# AI Builder is the meter whose per-resource route is 403 and whose per-user route is 404, so an
# import is the only attribution available for it.
$aiCsv = Join-Path $impDir 'ai-builder-report.csv'
@(
    'Agent name,Environment name,Credits consumed'
    'Invoice helper,Finance,4200'
) | Set-Content -Path $aiCsv -Encoding utf8

$usageForImport = $data.Usage.PSObject.Copy()
# AI Builder's per-resource route was 403, so nothing in Resources carries Currency='AI'.
$usageForImport.Resources = @($data.Usage.Resources)
$usageForImport = Import-PPUsageReport -Path @($aiCsv) -Usage $usageForImport `
                    -Agents $data.Agents -Apps $data.Apps -Flows $data.Flows `
                    -Environments $data.Environments -UserIndex $userIndex -DefaultCurrency 'AI'

$aiRows = @($usageForImport.Resources | Where-Object { $_.Currency -eq 'AI' })
Assert-True 'CSV import produced rows for the blocked meter' ($aiRows.Count -eq 1)
Assert-True 'Imported row is tagged with its provenance' `
    ($aiRows.Count -ge 1 -and $aiRows[0].Source -eq 'PPAC report')
Assert-True 'Imported row joined to the inventory by name' `
    ($aiRows.Count -ge 1 -and $aiRows[0].Matched -and $aiRows[0].ResourceKind -eq 'Agent')
Assert-True 'Imported row carries the resource ID from the join' `
    ($aiRows.Count -ge 1 -and $aiRows[0].ResourceId -eq 'b3')
# Existing API rows must be labelled too, or the Source column would be blank for half the table.
$apiRows = @($usageForImport.Resources | Where-Object { $_.Currency -eq 'MCSMessages' })
Assert-True 'Existing API rows labelled as API-sourced' `
    (@($apiRows | Where-Object { $_.Source -eq 'Licensing API' }).Count -eq $apiRows.Count)

# Double-counting guard: MCSMessages already came from the API, so an import for it is refused.
$usageDupe = $data.Usage.PSObject.Copy()
$usageDupe.Resources = @($data.Usage.Resources)
$usageDupe = Import-PPUsageReport -Path @($agentCsv) -Usage $usageDupe `
                -Agents $data.Agents -Apps $data.Apps -Flows $data.Flows `
                -Environments $data.Environments -UserIndex $userIndex -DefaultCurrency 'MCSMessages'
Assert-True 'Import refused for a meter the API already answered' `
    (@($usageDupe.Resources | Where-Object { $_.Source -eq 'PPAC report' }).Count -eq 0)
Assert-True 'Refusal is recorded with a reason, not silent' `
    (@($usageDupe.Imports | Where-Object { $_.Skipped -gt 0 -and $_.Reason -match 'double-count' }).Count -eq 1)

# Same file against a tenant where the API returned nothing for that meter: now it must import,
# including the three columns the API route does not return at all.
$usageBlind = $data.Usage.PSObject.Copy()
$usageBlind.Resources = @()
$usageBlind = Import-PPUsageReport -Path @($impDir) -Usage $usageBlind `
                -Agents $data.Agents -Apps $data.Apps -Flows $data.Flows `
                -Environments $data.Environments -UserIndex $userIndex -DefaultCurrency 'MCSMessages'
$hr = @($usageBlind.Resources | Where-Object { $_.ResourceName -eq 'Public HR bot' })
Assert-True 'Folder import reads every report in the directory' (@($usageBlind.Imports).Count -eq 2)
Assert-True 'Preamble lines above the header are skipped' ($hr.Count -eq 1)
Assert-True 'Billed and non-billed are kept separate' `
    ($hr.Count -ge 1 -and $hr[0].Billed -eq 16000 -and $hr[0].NonBillable -eq 2000)
# Total is derived from the two halves; the split itself is never invented.
Assert-True 'Total consumed derived from billed + non-billed' `
    ($hr.Count -ge 1 -and $hr[0].Consumed -eq 18000)
Assert-True 'Import captures channel, model and knowledge source' `
    ($hr.Count -ge 1 -and $hr[0].Channel -eq 'Teams' -and $hr[0].Model -eq 'gpt-4o' -and $hr[0].Knowledge -eq 'SharePoint')
$ghost = @($usageBlind.Resources | Where-Object { $_.ResourceName -eq 'Ghost agent' })
Assert-True 'Unknown agent in an import stays flagged as unmatched' `
    ($ghost.Count -eq 1 -and -not $ghost[0].Matched)

# Header mapping: a renamed column must surface as unmapped rather than vanish.
$cols = Resolve-PPReportColumns -Headers @('Agent name','Billed credits','Non-billed credits','Mystery column')
Assert-True 'Header mapping resolves agent name'      ($cols.Map['ResourceName'] -eq 'Agent name')
Assert-True 'Header mapping resolves billed credits'  ($cols.Map['Billed'] -eq 'Billed credits')
# The ordering trap: 'Non-billed credits' contains 'billed', so a naive matcher maps it to Billed.
Assert-True 'Non-billed is not mistaken for billed'   ($cols.Map['NonBillable'] -eq 'Non-billed credits')
Assert-True 'Unrecognised columns are reported'       ($cols.Unmapped -contains 'Mystery column')
Assert-True 'Header mapping tolerates separators' `
    ((Resolve-PPReportColumns -Headers @('agent_name','billed_credits')).Map['ResourceName'] -eq 'agent_name')

# A real .xlsx, built here as a zip of XML, to prove the reader works without Excel or any module.
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$xlsxDir = Join-Path $impDir 'xlsx-src'
New-Item -ItemType Directory -Path (Join-Path $xlsxDir '_rels') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $xlsxDir 'xl\worksheets') -Force | Out-Null
$ct = '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>'
$ct | Set-Content (Join-Path $xlsxDir '[Content_Types].xml') -Encoding utf8
$ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
# Shared strings, exactly as Excel emits them: cells reference these by index.
$strings = @('Agent name','Environment name','Billed credits','Non-billed credits','Xlsx bot','Contoso Prod')
$ssXml = '<?xml version="1.0"?><sst xmlns="' + $ns + '" count="6" uniqueCount="6">' +
         (($strings | ForEach-Object { '<si><t>' + $_ + '</t></si>' }) -join '') + '</sst>'
$ssXml | Set-Content (Join-Path $xlsxDir 'xl\sharedStrings.xml') -Encoding utf8
# Row 2 deliberately omits cell C: an empty cell is absent from the XML, so a reader that counts
# cells instead of decoding references would shift D's value into C and misreport the money.
$sheet = '<?xml version="1.0"?><worksheet xmlns="' + $ns + '"><sheetData>' +
  '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c></row>' +
  '<row r="2"><c r="A2" t="s"><v>4</v></c><c r="B2" t="s"><v>5</v></c><c r="D2"><v>777</v></c></row>' +
  '</sheetData></worksheet>'
$sheet | Set-Content (Join-Path $xlsxDir 'xl\worksheets\sheet1.xml') -Encoding utf8
$xlsxPath = Join-Path $impDir 'agent-report.xlsx'
[System.IO.Compression.ZipFile]::CreateFromDirectory($xlsxDir, $xlsxPath)

$xlTable = Get-PPReportTable -Path $xlsxPath
Assert-True 'xlsx reader finds the header row' `
    ($null -ne $xlTable -and ($xlTable.Headers -contains 'Agent name'))
Assert-True 'xlsx reader resolves shared strings' `
    ($null -ne $xlTable -and @($xlTable.Rows)[0].'Agent name' -eq 'Xlsx bot')
# The real test: the omitted C cell must leave Billed empty and keep 777 in Non-billed.
Assert-True 'xlsx reader honours cell references over position' `
    ($null -ne $xlTable -and
     [string]@($xlTable.Rows)[0].'Billed credits' -eq '' -and
     [string]@($xlTable.Rows)[0].'Non-billed credits' -eq '777')

# A file that is not a consumption report at all must be refused, not half-parsed.
$junk = Join-Path $impDir 'not-a-report.csv'
@('Fruit,Colour', 'Apple,Red') | Set-Content -Path $junk -Encoding utf8
$usageJunk = $data.Usage.PSObject.Copy()
$usageJunk.Resources = @()
$usageJunk = Import-PPUsageReport -Path @($junk) -Usage $usageJunk -Agents $data.Agents `
                -Environments $data.Environments -UserIndex $userIndex
Assert-True 'Unrecognisable file imports nothing' (@($usageJunk.Resources).Count -eq 0)
Assert-True 'Unrecognisable file is recorded as a gap' `
    (@($usageJunk.Gaps | Where-Object { $_.Item -match 'report import' }).Count -ge 1)

# Findings must flip from "blocked" to "imported" once the gap is filled, or the register
# contradicts the page.
$impFindings = Invoke-PPFindings -Data ([PSCustomObject]@{
    Meta = $data.Meta; Tenant = $data.Tenant; Environments = $data.Environments
    Apps = $data.Apps; Flows = $data.Flows; Connections = @(); CustomConnectors = @()
    Dataverse = $data.Dataverse; Agents = $data.Agents; Identity = $data.Identity
    Usage = $usageForImport; AzureCost = $null
})
Assert-True 'Imported attribution reported as Info, not as blocked' `
    (@($impFindings | Where-Object { $_.Rule -eq 'COST-ATTRIBUTION-IMPORTED' }).Count -ge 1)
Assert-True 'Blocked-attribution finding withdrawn once the import covers that meter' `
    (@($impFindings | Where-Object { $_.Rule -eq 'COST-ATTRIBUTION-BLIND' -and $_.Asset -eq 'AI Builder credits' }).Count -eq 0)

Write-Host ''
Write-Host '  Severity ordering and summary' -ForegroundColor White
$sevOrder = @($findings | ForEach-Object { $script:PPSeverityRank[$_.Severity] })
$sorted = $true
for ($i = 1; $i -lt $sevOrder.Count; $i++) { if ($sevOrder[$i] -lt $sevOrder[$i-1]) { $sorted = $false } }
Assert-True 'Findings sorted most-severe first' $sorted

$summary = Get-PPFindingSummary -Findings $findings
Assert-True 'Summary counts match total' `
    ((($summary.Values | Measure-Object -Sum).Sum) -eq @($findings).Count)
Assert-True 'At least one Critical raised' ($summary['Critical'] -ge 1)

Write-Host ''
Write-Host '  Report rendering' -ForegroundColor White

$outDir = Join-Path $env:TEMP 'pp-collect-test-report'
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
$index = New-PPReport -Data $data -Findings $findings -OutputDir $outDir

Assert-True 'index.html written' (Test-Path $index)
foreach ($page in @('findings','environments','agents','apps','flows','connections','security','dlp','usage','billing','integrity')) {
    Assert-True "$page.html written" (Test-Path (Join-Path $outDir "$page.html"))
}

$idx = Get-Content $index -Raw
Assert-True 'Index has no external references' ($idx -notmatch 'src\s*=\s*"https?://|href\s*=\s*"https?://|@import')
Assert-True 'Index shows confidentiality banner'  ($idx -match 'CONFIDENTIAL')
Assert-True 'Index surfaces critical finding'     ($idx -match 'reachable from any tenant')

$integ = Get-Content (Join-Path $outDir 'integrity.html') -Raw
Assert-True 'Integrity reports unreachable environment' ($integ -match 'No Dataverse security role')
Assert-True 'Integrity reports POST-only gap'           ($integ -match 'POST-only')

$envPage = Get-Content (Join-Path $outDir 'environments.html') -Raw
Assert-True 'DR honestly reported as unknown' ($envPage -match 'absence of evidence')

$billPage = Get-Content (Join-Path $outDir 'billing.html') -Raw
Assert-True 'Billing page lists the Azure subscription' ($billPage -match '00000000-0000-0000-0000-000000000001')
Assert-True 'Billing page marks the disabled policy'    ($billPage -match 'Disabled')
Assert-True 'Billing page shows uncovered agent environment' ($billPage -match '>none<')

$agentPage = Get-Content (Join-Path $outDir 'agents.html') -Raw
Assert-True 'Agent page renders access policy' ($agentPage -match 'Any \(multi-tenant\)')

$usagePage = Get-Content (Join-Path $outDir 'usage.html') -Raw
Assert-True 'Usage page names the top consuming agent'   ($usagePage -match 'Public HR bot')
Assert-True 'Usage page shows the overage meter'         ($usagePage -match '106%')
Assert-True 'Usage page separates non-billable credits'  ($usagePage -match 'Non-billable')
Assert-True 'Usage page names the consuming user'        ($usagePage -match 'Active Alice')
Assert-True 'Usage page flags the departed consumer'     ($usagePage -match 'Departed Dave')
Assert-True 'Usage page rolls up by department'          ($usagePage -match 'Operations')
Assert-True 'Usage page marks the unmatched resource'    ($usagePage -match 'unmatched')
# The refusal must be stated as a refusal, not rendered as an empty table.
Assert-True 'Usage page states blocked attribution is not zero' ($usagePage -match 'unknown, not zero')
Assert-True 'Usage page disclaims group-level attribution' ($usagePage -match 'not</b> security-group attribution')
Assert-True 'Usage page records route provenance'        ($usagePage -match '2024-10-01')
Assert-True 'Usage page states the data lags'            ($usagePage -match 'lags')
Assert-True 'Usage page has no external references' `
    ($usagePage -notmatch 'src\s*=\s*"https?://|href\s*=\s*"https?://|@import')

$billPage2 = Get-Content (Join-Path $outDir 'billing.html') -Raw
Assert-True 'Billing page reports Azure cost total'  ($billPage2 -match '1234\.56')
Assert-True 'Billing page names the billed meter'    ($billPage2 -match 'Copilot Studio Credits')
Assert-True 'Billing page says Azure cannot attribute spend' ($billPage2 -match 'cannot attribute Power Platform spend')

$integ2 = Get-Content (Join-Path $outDir 'integrity.html') -Raw
Assert-True 'Integrity surfaces usage gaps' ($integ2 -match 'Usage')

# A report built with no usage data at all must still render every page and must not claim zero.
$outDir2 = Join-Path $env:TEMP 'pp-collect-test-report-nousage'
if (Test-Path $outDir2) { Remove-Item $outDir2 -Recurse -Force }
$index2 = New-PPReport -Data $noUsage -Findings $noUsageFindings -OutputDir $outDir2
Assert-True 'Usage page renders when usage was not collected' (Test-Path (Join-Path $outDir2 'usage.html'))
$nuPage = Get-Content (Join-Path $outDir2 'usage.html') -Raw
Assert-True 'Uncollected usage page says so rather than showing zeroes' ($nuPage -match 'did not run')

# The load-bearing rendering rule: a figure the API did not supply must read "unknown", never 0.
# A zero in a cost report is a claim about spend, and we are not entitled to make it on no data.
$outDir3 = Join-Path $env:TEMP 'pp-collect-test-report-unknown'
if (Test-Path $outDir3) { Remove-Item $outDir3 -Recurse -Force }
[void](New-PPReport -Data $unknownUsage -Findings $unknownFindings -OutputDir $outDir3)
$unkPage = Get-Content (Join-Path $outDir3 'usage.html') -Raw
Assert-True 'Absent figures render as unknown, not zero' ($unkPage -match 'unknown')
Assert-True 'Absent percentage does not render as 0%'    ($unkPage -notmatch '>0%<')

# An imported run must look visibly different from an API run: provenance on every row, a
# standing warning that the figures are frozen, and the file list that produced them.
$impData = $data.PSObject.Copy()
$impData.Usage = $usageBlind
$outDir4 = Join-Path $env:TEMP 'pp-collect-test-report-imported'
if (Test-Path $outDir4) { Remove-Item $outDir4 -Recurse -Force }
[void](New-PPReport -Data $impData -Findings (Invoke-PPFindings -Data $impData) -OutputDir $outDir4)
$impPage = Get-Content (Join-Path $outDir4 'usage.html') -Raw
Assert-True 'Imported rows are marked as imported'        ($impPage -match '>imported<')
Assert-True 'Imported run warns the figures will not refresh' ($impPage -match 'will not refresh')
Assert-True 'Imported run lists the source files'         ($impPage -match 'copilot-agent-report\.csv')
Assert-True 'Imported run shows the import provenance table' ($impPage -match 'Imported reports')
Assert-True 'Import table reports unmapped columns'       ($impPage -match 'Unmapped columns')
# The columns the blocked API route cannot return are the reason the import is worth having.
Assert-True 'Imported run surfaces channel and model'     ($impPage -match 'Teams' -and $impPage -match 'gpt-4o')
Assert-True 'Imported usage page has no external references' `
    ($impPage -notmatch 'src\s*=\s*"https?://|href\s*=\s*"https?://|@import')

# And an API-only run must NOT grow a blank imports table: $u.Imports is absent there, and
# @($null).Count is 1 in PowerShell, which would have rendered one empty row.
Assert-True 'API-only run renders no imports table' ($usagePage -notmatch 'Imported reports')

Write-Host ''
if ($fail -eq 0) { Write-Host ("  $pass passed, 0 failed") -ForegroundColor Green }
else { Write-Host ("  $pass passed, $fail FAILED") -ForegroundColor Red }
Write-Host ("  Sample report: " + $index) -ForegroundColor DarkGray
Write-Host ''
exit $(if ($fail -gt 0) { 1 } else { 0 })
