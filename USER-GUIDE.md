# Power Platform Tenant Reporting Tool — User Guide

A read-only tool a Power Platform Administrator runs from their own workstation to inventory a
tenant and render self-contained HTML reports.

This guide covers three things:

1. [What the solution is made of](#1-components)
2. [How to run a collection](#2-running-a-collection)
3. [What you see in the report, screen by screen](#3-the-report-screen-by-screen)

For the *why* behind the design decisions, see [DESIGN.md](DESIGN.md). For a short overview, see
[README.md](README.md).

---

## The one guarantee that shapes everything

**Every request this tool issues is a `GET`.** The HTTP client refuses any other verb before a
socket is opened, and the test suite asserts it. The only `POST` in the codebase is the token
exchange with `login.microsoftonline.com`, which is credential exchange rather than tenant data.

This is not a stylistic preference — it is what makes the tool approvable to run against a customer
production tenant, and it is why some data (tenant settings, which are exposed only as a POST
operation) is deliberately reported as a gap rather than collected.

---

## 1. Components

### 1.1 Two entry points

The tool has two programs, run in this order the first time you meet a tenant.

| | `Invoke-PPProbe.ps1` | `Invoke-PPCollect.ps1` |
|---|---|---|
| **Phase** | 0 — capability probe | 1 — collection and reporting |
| **Question it answers** | *What will this tenant let us collect?* | *What is actually in this tenant?* |
| **Output** | `probe-report.html` + `raw/probe.json` | 12-page report + `raw/data.json` |
| **Typical runtime** | 2–5 minutes | Minutes to hours, depending on depth and size |
| **When to run** | Once per tenant, before trusting a collection | Whenever you want a current picture |

Phase 0 exists because several things an admin most wants to report on — backups, DR posture,
environment groups, credit consumption — sit behind APIs that are version-sensitive or, in a few
cases, not confirmed to exist publicly. Rather than bake guesses into collectors and discover the
gaps later, the probe asks the tenant directly. Collectors are then written only against confirmed
routes.

### 1.2 Repository layout

```
Invoke-PPProbe.ps1            Phase 0 entry point
Invoke-PPCollect.ps1          Phase 1 entry point

src/Core/                     shared plumbing, used by both phases
  PPAuth.ps1                  device-code sign-in + silent cross-resource token refresh
  PPHttp.ps1                  the read-only HTTP client, retry/backoff, call log
  PPLog.ps1                   NDJSON structured log + console banners
  PPDataverse.ps1             Dataverse Web API helper (token per org, OData paging)

src/Probe/                    Phase 0 only
  Probe-PlatformApi.ps1       BAP / PowerApps / Flow admin surface
  Probe-PPApi.ps1             api.powerplatform.com candidate routes
  Probe-Dataverse.ps1         per-environment Dataverse, agents, transcripts, retention
  Probe-Identity.ps1          Microsoft Graph consent + audit-log capability

src/Collect/                  Phase 1 collectors
  Collect-Tenant.ps1          DLP, isolation, environment groups, billing policies
  Collect-Environments.ps1    environment inventory + backups
  Collect-Assets.ps1          apps, flows, connections, custom connectors
  Collect-Dataverse.ps1       agents, solutions, security, async failures
  Collect-Identity.ps1        Graph users, groups, service principals, SKUs
  Collect-Usage.ps1           credit/capacity consumption per meter, per resource, per user
  Collect-AzureCost.ps1       Azure pay-as-you-go spend (opt-in, needs Azure RBAC)
  Import-PPUsageReport.ps1    ingests PPAC consumption exports (.csv/.xlsx, no Excel needed)

src/Analyze/
  Invoke-PPFindings.ps1       the rules engine — 40 rules

src/Render/
  PPHtml.ps1                  page shell, CSS, tables, client-side sort/filter
  Render-Report.ps1           the 12-page Phase 1 report
  Render-ProbeReport.ps1      the single-page Phase 0 report

tests/
  Test-PPProbe.ps1            27 offline tests
  Test-PPCollect.ps1          123 offline tests

runs/                         output, one directory per run
```

### 1.3 The Core layer

**`PPHttp.ps1`** is the enforcement point. It exposes `Invoke-PPRequest`, which:

- accepts only `GET` and `HEAD`, and throws on anything else *before* opening a socket;
- **never throws on an HTTP error status** — it returns a result object instead, so a 403 on one
  environment can never abort a tenant-wide run;
- retries `429`/`408`/`5xx` with exponential backoff, honouring `Retry-After`;
- records every call — URI, verb, status, duration, attempts, error — into a call log that becomes
  the Integrity page.

**`PPAuth.ps1`** does one interactive device-code sign-in, then obtains tokens for every other
audience silently by refresh. You are not prompted per environment. Audiences used:

| Audience | Used for |
|---|---|
| `api.bap.microsoft.com` | environments, DLP, tenant isolation |
| `service.powerapps.com` | apps, connections, custom connectors |
| `service.flow.microsoft.com` | flows |
| `api.powerplatform.com` | backups, environment groups, billing/licensing |
| `graph.microsoft.com` | users, groups, service principals, SKUs |
| `https://<org>.crm*.dynamics.com` | Dataverse, one token per environment |

### 1.4 Collectors and their sources

| Collector | Source | Yields |
|---|---|---|
| `Collect-Tenant` | BAP `/policies`, `/tenantIsolationPolicy`; PP API `/environmentGroups`, `/licensing/billingPolicies` | DLP policies with connector classification, tenant isolation, environment groups, **billing policies plus the environments each one covers** |
| `Collect-Environments` | BAP environment list; PP API `/environments/{id}/backups` | SKU, region, state, Dataverse org URL and version, security group, default flag, restore points |
| `Collect-Assets` | PowerApps + Flow admin APIs | canvas apps (owner, sharing scope, shared-user count), flows (state, trigger, action count), connections (status, owner), custom connectors (backend host) |
| `Collect-Dataverse` | Dataverse Web API per environment | `bots` + `botcomponents` → agents; `solutions`; `systemusers`; `roles` expanded to System Administrator holders; `asyncoperations` (failures, Deep only) |
| `Collect-Identity` | Graph `/users`, `/groups`, `/servicePrincipals`, `/subscribedSkus` | the identity join that turns owner GUIDs into people, and detects leavers and expiring credentials |
| `Collect-Usage` | PP API `/licensing/tenantCapacity/currencyReports`, `/licensing/allocationsByEnvironment`, `/licensing/entitlements/{meter}` + `/resources`, `/users`, `/licenses`, `/resourceThresholds` | per-meter purchased vs allocated vs consumed; credit burn **per agent/app/flow** and **per user** (billed vs non-billable); per-environment allocation; spend thresholds; the route map proving where each figure came from |
| `Collect-AzureCost` | Azure `Microsoft.Consumption/usageDetails` (opt-in) | the real currency cost of pay-as-you-go, per meter and per Azure resource, for each subscription behind a billing policy |
| `Import-PPUsageReport` | a PPAC consumption export you downloaded (`.csv` / `.xlsx`) | per-agent attribution when the API route for it is refused — plus **channel, LLM model and knowledge source**, which the API does not return at all |

**Graceful degradation is the rule, not the exception.** Any collector that cannot read a source
records *why* and keeps going. Nothing is silently omitted; every gap surfaces on the Integrity
page.

### 1.5 The findings engine

Everything else in the tool is a table dump. This is where inventory becomes a prioritised,
evidence-linked risk register. Every finding carries: what, where, the **evidence record that
produced it**, why it matters, and the fix. No unexplainable red boxes.

Two conventions worth knowing before you read a report:

- **Production-only rules exempt Developer, Trial, Teams and Sandbox environments.** A developer
  environment with no backups is correct, not a finding.
- **A rule stays silent when the underlying source was unreadable.** "No billing policy exists" and
  "we could not read the billing API" are different claims, and only the first is a fact about your
  tenant.
- **Unknown is never rendered as zero.** This matters most on the cost pages: a figure the API did
  not supply reads `unknown`, and a consumption dataset we were *refused* is called out as refused.
  An empty consumption table and a forbidden one mean opposite things, and a zero in a cost report
  is a claim about spend that the tool will not make on no data.

#### Rule catalogue (40 rules)

| Rule | Severity | Category | Fires when |
|---|---|---|---|
| `AGENT-XTENANT` | Critical | Security | Agent reachable from any tenant (`accesscontrolpolicy` = 3) |
| `AGENT-ANON` | High | Security | Agent allows anonymous access |
| `AGENT-NOAUTH` | High | Security | Agent has authentication disabled |
| `AGENT-ORPHAN` | High | Hygiene | Agent owned by a disabled or deleted account |
| `AGENT-AUTONOMOUS` | High / Medium | Security | Autonomous agent (external trigger); escalated when combined with weak access control |
| `AGENT-MODELKNOWLEDGE` | Medium | Compliance | Agent may answer from general model knowledge rather than approved sources |
| `AGENT-MISSINGLIC` | Medium | Cost | Agent is unlicensed (`statuscode` = 5) |
| `AGENT-PROVFAIL` | Medium | Reliability | Agent provisioning failed |
| `AGENT-UNMANAGED-PROD` | Medium | ALM | Unmanaged agent authored directly in production |
| `AGENT-UNPUBLISHED` | Low | Hygiene | Agent has never been published |
| `APP-TENANTSHARE` | High | Security | App shared with the entire tenant |
| `APP-ORPHAN` | High | Hygiene | App owned by a disabled or deleted account |
| `FLOW-ORPHAN` | High | Hygiene | Flow owned by a disabled or deleted account |
| `FLOW-SUSPENDED` | Medium | Reliability | Flow is suspended |
| `ENV-NODLP` | High | Governance | Environment not covered by any DLP policy |
| `ENV-NOBACKUP` | High | Continuity | Production environment has no restore points |
| `ENV-STALEBACKUP` | Medium | Continuity | Most recent restore point is more than 7 days old |
| `ENV-NOSECGROUP` | Medium | Security | Production environment with Dataverse has no security group |
| `ENV-DEFAULT` | Info | Governance | The default environment exists and is open to all makers |
| `COST-AGENT-NOBILLING` | High / Medium | Cost | Agents run in an environment no billing policy reaches; High when production with published agents |
| `COST-BILLING-DISABLED` | High | Cost | A billing policy covers the environment but its status is `Disabled` |
| `COST-METER-OVERAGE` | Critical | Cost | A credit meter has consumed more than was purchased — past the enforcement cliff |
| `COST-METER-NEARCAP` | High / Medium | Cost | Meter at >=90% of purchased capacity (High) or >=75% (Medium) |
| `COST-CAPACITY-FULL` | High | Cost | Storage or API capacity at >=95% of entitlement |
| `COST-ENV-OVERALLOC` | Medium | Cost | An environment consumed more than its own credit allocation, drawing on the shared tenant pool |
| `COST-CONCENTRATION` | Medium | Cost | One agent or app drives >=50% of a meter (only where 3+ resources consume it) |
| `COST-UNMATCHED-RESOURCE` | Medium | Cost | Credits consumed by resource IDs that match nothing in the collected inventory |
| `COST-LEAVER-CONSUMING` | High | Cost | Credits consumed under a disabled account, or one the directory does not know |
| `COST-NO-THRESHOLD` | Medium | Cost | A meter is actively consuming and the threshold route confirmed **no** spend alarm exists |
| `COST-ATTRIBUTION-BLIND` | Medium | Cost | The per-resource consumption route was refused, so spend cannot be attributed to an agent. Visibility finding — *not* a claim of zero consumption |
| `COST-ATTRIBUTION-IMPORTED` | Info | Cost | The route was refused but an imported PPAC report filled the gap. The attribution is correct but frozen at the export date and will not refresh |
| `COST-AZURE-SUBMISSING` | High | Cost | A billing policy points at an Azure subscription that returns 404 — looks covered, bills nothing |
| `COST-AZURE-NOACCESS` | Info | Cost | Azure cost was requested but the operator holds no Azure RBAC. Expected, not a misconfiguration |
| `SOL-UNMANAGED-PROD` | Medium | ALM | Unmanaged solutions in a production environment |
| `SEC-SPN-SYSADMIN` | High | Security | Service principal holds System Administrator |
| `SEC-DISABLED-ADMIN` | Medium | Security | Disabled account still holds System Administrator |
| `SEC-SPN-EXPIRED` | Medium | Reliability | Service principal credential has already expired |
| `SEC-SPN-EXPIRING` | Low | Reliability | Service principal credential expires within 60 days |
| `CONN-ERROR` | Medium | Reliability | Connection is not in a connected state |
| `DV-ASYNCFAIL` | Medium | Reliability | Failed system jobs in the last 7 days (Deep only) |

### 1.6 The renderer

- **No CDN, no framework, no external fetch.** All CSS and JS are inlined. The report opens on an
  air-gapped machine and survives being emailed as a zip.
- **Light and dark aware**, following the viewer's system theme.
- **Client-side sort and filter** on the large grids, hand-rolled in a few dozen lines of JS.
- Pages are separate files sharing a nav, so a large tenant does not produce one unusable
  megabyte-scale document.

### 1.7 What a run directory contains

```
runs/20260817-151717/
  raw/
    data.json        everything collected, before any interpretation
    findings.json    the risk register as data
  report/
    index.html       start here
    findings.html  environments.html  agents.html  apps.html  flows.html
    connections.html  security.html  dlp.html  usage.html  billing.html
    integrity.html
  collect.log        NDJSON run log
```

**Raw JSON is written before anything renders.** Collection is the slow, throttled,
permission-dependent half; rendering is fast and pure. That split is what makes `-RenderOnly` a
2-second loop instead of a 2-hour one, and it means a customer can audit exactly what was read.

### 1.8 Tests

```powershell
.\tests\Test-PPProbe.ps1      # 27 tests - read-only guarantee, probe rendering
.\tests\Test-PPCollect.ps1    # 90 tests - findings rules, report rendering
```

117 offline tests. No tenant, network or credentials required.

The Phase 1 fixture is built to **trip specific rules**, so a regression fails loudly instead of
silently reporting a clean tenant — the most dangerous failure mode this tool has. It also asserts
the negative cases: developer environments stay exempt from production-only rules, a DLP-covered
environment is not flagged, an environment covered by an enabled billing policy is silent, and an
unreadable billing API produces no findings at all.

---

## 2. Running a collection

### 2.1 Prerequisites

| Requirement | Notes |
|---|---|
| Windows PowerShell 5.1 | Present on every Windows admin workstation. PowerShell 7 is recommended for future parallelism |
| Power Platform Administrator or Global Admin | Global Reader is not sufficient for some routes |
| Nothing else | No app registration, no module installs, no local admin rights |

Optional, for fuller coverage:

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser   # unified audit log = app usage
winget install Microsoft.PowerShell                          # PowerShell 7
```

### 2.2 Step 1 — probe the tenant first

```powershell
.\Invoke-PPProbe.ps1
```

You will be prompted once with a device code. Open the URL, enter the code, sign in as the admin
account. Everything after that is silent.

The probe writes `runs/<timestamp>-probe/probe-report.html` and opens it. **Read it before
trusting a collection** — it tells you which environments you can actually see into, and therefore
which parts of the Phase 1 report will be complete.

Useful options:

```powershell
.\Invoke-PPProbe.ps1 -TenantId contoso.onmicrosoft.com -MaxEnvironments 25
.\Invoke-PPProbe.ps1 -SkipTranscripts      # agents only, no conversation data
.\Invoke-PPProbe.ps1 -SkipDataverse        # tenant-level surface only, fastest
```

> **Re-probe if your probe report predates the api-version separator fix.** Earlier builds
> appended `&api-version=` to routes that had no query string of their own, producing
> `404 RouteNotFound` for around a dozen Licensing and Governance routes that are actually
> fine — `billingPolicies`, `tenantCapacity`, `allocationsByEnvironment`, `resourceThresholds`
> and the per-environment entitlement routes among them. A "Not found" verdict from an older
> report is not evidence. See DESIGN.md §2.3.3 for the full account, including a before/after
> table from the re-probe.

**If the probe reports "Credit attribution - which agent or app: Blocked",** that is a permission
boundary, not something a re-run fixes. The per-resource consumption routes return 403 at every
api-version while the per-user routes return 200 with the same token, and the service sends no
error body naming the required permission. You have two options:

1. **Get the same data by hand** — PPAC → **Licensing** → **Products** → **Copilot Studio** →
   **Summary** → **Download report** → *agent* (also *environment* and *user*). This report is
   richer than the API: agent name, product/feature, channel, LLM model, knowledge source, and
   billed vs non-billed credits. Start with the environment report to find where consumption is,
   then the agent report to narrow it.
2. **Raise it with support** — ask specifically which role grants
   `GET /licensing/entitlements/{id}/resources`, quoting that per-user works and per-resource
   does not.

Until one of those happens, the Usage page shows tenant and per-user figures and says in red that
per-agent consumption is **unknown, not zero**.

### 2.3 Step 2 — collect

```powershell
.\Invoke-PPCollect.ps1
```

That is the whole command. It signs in, collects at `Standard` depth, runs the findings engine,
writes the report and opens it.

### 2.4 Choosing a depth

`-Depth` is the main cost control:

| Depth | Collects | Use when |
|---|---|---|
| `Quick` | Tenant governance, environments, apps, flows, connections. No Dataverse, no Graph | First look at a large tenant; you want numbers in minutes |
| `Standard` *(default)* | Adds Dataverse (agents, solutions, security) and Graph identity | Normal use. This is the depth the report is designed around |
| `Deep` | Adds per-app sharing resolution and 7-day async failure history | Detailed audit. Significantly slower: one extra call per app |

At `Quick` depth the Agents and Security pages will be empty and owner names will show as GUIDs —
by design, not by failure. The Integrity page says so.

### 2.5 All parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-Depth` | `Standard` | `Quick` / `Standard` / `Deep`, as above |
| `-MaxEnvironments` | `50` | Cap environments processed for apps, flows, connections and Dataverse |
| `-TenantId` | `organizations` | Tenant GUID or domain; resolved at sign-in if omitted |
| `-ClientId` | Azure CLI first-party client | Override if Conditional Access blocks the default public client |
| `-SkipDataverse` | off | Skip per-environment Dataverse entirely |
| `-SkipGraph` | off | Skip identity resolution |
| `-SkipUsage` | off | Skip credit, capacity and consumption collection entirely |
| `-UsageWindowDays` | `30` | Look-back window for consumption and Azure cost |
| `-AllMeters` | off | Deep-dive every currency meter, not just the ones the tenant reports (plus Copilot Studio and AI Builder credits, which are always checked). ~5 extra calls per meter |
| `-IncludeAzureCost` | off | Also query Azure Consumption for the money figure. **Needs Azure RBAC on the subscriptions behind your billing policies** — Power Platform Administrator does not grant it |
| `-UsageReport` | — | One or more downloaded PPAC consumption reports (`.csv`/`.xlsx`), or a folder of them, to import and join to the inventory. Use when per-agent attribution is 403 |
| `-RenderOnly` | off | Rebuild the report from raw JSON. **Zero tenant calls** |
| `-RunDirectory` | latest run | Which run `-RenderOnly` should rebuild |
| `-OutputRoot` | `.\runs` | Where run directories are created |

### 2.6 Common invocations

```powershell
# Standard run
.\Invoke-PPCollect.ps1

# Large tenant, full detail, first 50 environments
.\Invoke-PPCollect.ps1 -Depth Deep -MaxEnvironments 50

# Fast inventory, no Dataverse or Graph
.\Invoke-PPCollect.ps1 -Depth Quick

# Cost review: 90 days of consumption across every meter, plus the Azure bill
.\Invoke-PPCollect.ps1 -UsageWindowDays 90 -AllMeters -IncludeAzureCost

# Inventory only, no consumption calls at all
.\Invoke-PPCollect.ps1 -SkipUsage

# Per-agent attribution is 403: import the report you downloaded from PPAC instead
.\Invoke-PPCollect.ps1 -UsageReport .\downloads\copilot-agent-report.csv

# Or point at a folder and let it sort out which report is which
.\Invoke-PPCollect.ps1 -UsageReport .\downloads\ppac-exports

# Rebuild the report after changing the renderer or a rule - no tenant calls
.\Invoke-PPCollect.ps1 -RenderOnly

# Rebuild a specific older run
.\Invoke-PPCollect.ps1 -RenderOnly -RunDirectory .\runs\20260817-151717
```

### 2.7 What you see while it runs

The console prints banners per stage, then a severity tally:

```
  Power Platform tenant report - collection
  Depth: Standard   Read-only: no tenant data is modified.

  == Authentication ==
  == Tenant governance ==
    3 DLP policies collected
    2 billing policy/policies covering 2 environment(s)
  == Environments ==
  == Apps, flows and connections ==
  == Dataverse depth ==
    [1/4] HR Production
  == Identity ==
  == Findings ==
    Critical  1
    High      6
    Medium    9
```

If a stage logs a `WARN`, that is a coverage gap, and it will appear on the Integrity page. It is
not a crash: the run continues.

### 2.8 Handling the output

The report maps the governance and security posture of your tenant and should be treated as
confidential — it carries a banner saying so. Note in particular that Copilot Studio conversation
transcripts contain verbatim user conversation text; the tool reads only counts and timestamps and
never persists transcript content.

**The Usage & credits page is the most personally identifying output the tool produces.** It names
individual employees against their consumption, with UPN, department and job title. That is the
whole point — you cannot act on "someone is burning credits" — but it makes the page per-person
usage data, so in many organisations it carries works-council, HR or data-protection obligations
that the rest of the report does not. Treat it accordingly, and use `-SkipUsage` where per-person
attribution is not permitted. The tool stores consumption totals only, never prompts, inputs or
conversation content.

---

## 3. The report, screen by screen

Open `runs/<timestamp>/report/index.html`. Every page shares the same top nav:

```
Summary | Findings | Environments | Agents | Apps | Flows | Connections | Security | DLP | Usage & credits | Billing | Integrity
```

---

### Screen 1 — Summary (`index.html`)

**The page to open first, and the only one most executives will read.**

Four blocks, top to bottom:

1. **Run metadata strip** — tenant ID, the account that collected, run timestamp (UTC), duration,
   and total API calls. This is provenance: it tells a reader whose eyes this data was collected
   through, which matters because a different admin may see a different tenant.
2. **Confidentiality banner** — a standing reminder of what this document is.
3. **Risk register cards** — five counters, Critical through Info. The shape of these five numbers
   is the tenant's posture at a glance.
4. **Inventory cards** — environments, apps, flows, agents, connections, DLP policies.
5. **Most severe findings** — the top 10 Critical and High findings, rendered in full as cards with
   evidence, rationale and fix.

> If there are no findings at all, the page says so *and* tells you to check the Integrity page
> first — because a collector that could not read a source produces no findings from it, and a
> clean report for the wrong reason is the most dangerous output this tool can produce.

---

### Screen 2 — Findings (`findings.html`)

**The full risk register, most severe first.**

A filter box at the top does live text matching across every card. Each finding is a card showing:

| Element | What it gives you |
|---|---|
| Severity pill + title | The claim |
| Location line | Environment · Asset · Rule ID |
| **Evidence** | The actual record that produced the finding — the field value, the count, the date |
| **Why** | Why it matters, in operational terms rather than abstract risk language |
| **Fix** | What to do about it |

The rule ID is on every card so you can trace a finding back to the code that raised it, and so a
customer can dispute one precisely.

---

### Screen 3 — Environments (`environments.html`)

The full environment grid: **Environment** (default flag shown as a pill), **SKU**, **Region**,
**State**, **Dataverse** yes/no, **Version**, **Security group** set/none, **Backups** (restore
point count, red at zero), **Latest backup**, **DR**, **Created**.

> **Note on the DR column:** it shows `unknown` for every environment. The candidate disaster
> recovery API did not resolve during capability probing. That is an absence of evidence, not
> evidence that DR is unconfigured — and the page says exactly that, in a note above the grid,
> rather than letting a blank column imply a finding.

---

### Screen 4 — Agents (`agents.html`)

**The Copilot Studio inventory, and the security-dense page in the report.** Column semantics
follow the Copilot Studio Kit's published Agent Details rules, so output is comparable with the
Kit's.

Columns: **Agent**, **Environment**, **State**, **Status** (green when Provisioned, red otherwise),
**Access policy**, **Auth**, **Published**, **Autonomous**, **Generative**, **Model knowledge**,
**Managed**, **Modified**.

How to read the colour: **Access policy** turns red for `Any` and `Any (multi-tenant)`, **Auth**
turns red for `None`. An agent showing red in both columns is reachable by anyone, from anywhere,
without signing in — that combination is the Critical finding on the Summary page.

**Autonomous** and **Model knowledge** are amber flags rather than errors: both are legitimate
designs, but both change the risk profile enough to warrant a deliberate decision.

Filter box included; the grid is sortable by clicking a header.

---

### Screen 5 — Apps (`apps.html`)

Canvas apps: **App**, **Environment**, **Owner** (resolved to a person by the Graph join, not a
GUID), **Shared with tenant** (red pill when true), **Shared users**, **Created**, **Modified**.

"Shared with tenant = yes" is the column to scan. It means *everyone in the organisation*, which is
almost never what the maker intended.

Per-app sharing detail is only resolved at `-Depth Deep`; at other depths the share count reflects
what the app list itself reports.

---

### Screen 6 — Flows (`flows.html`)

**Flow**, **Environment**, **State** (green Started, red Suspended), **Trigger**, **Actions**,
**Created**, **Modified**.

Suspended flows are the ones to look at: a flow does not suspend itself for a good reason, and a
suspended business-critical flow is usually a live incident nobody has noticed.

---

### Screen 7 — Connections and connectors (`connections.html`)

Two tables.

- **Connections** — **Connection**, **Connector**, **Environment**, **Owner**, **Status**
  (green Connected, red anything else), **Created**. Broken connections are a top real-world
  support driver and they rarely announce themselves.
- **Custom connectors** — **Custom connector**, **Environment**, **Backend host**, **Owner**,
  **Created**. The backend host column is the interesting one: it is where your data is actually
  going.

---

### Screen 8 — Security (`security.html`)

Two tables.

- **System Administrators** — every holder of the role, per environment: **Principal**, **UPN**,
  **Environment**, **Type** (service principals flagged with a red pill), **Disabled**. Two things
  to scan for: service principals holding sysadmin, and disabled accounts that still do.
- **Service principal credentials expiring within 90 days** — **Service principal**, **App ID**,
  **Credentials**, **Soonest expiry**, **Days left** (red when expired, amber at 60 days or fewer).
  This is the page that prevents an integration outage at 3am.

---

### Screen 9 — DLP (`dlp.html`)

Policy matrix: **Policy**, **Scope** (`AllEnvironments` / `OnlyEnvironments` / `ExceptEnvironments`),
**Environments** (count, or "all"), **Connector groups** (classification and connector count per
group), **Created by**, **Modified**.

If tenant isolation was collected, a note points to the raw JSON for the full allow-list.

> The empty state is deliberately blunt: if no DLP policies were collected and the tenant genuinely
> has none, **every environment is unprotected**. Cross-check against the `ENV-NODLP` findings.

---

### Screen 10 — Usage & credits (`usage.html`)

**What the platform is costing, and which agent and which person is driving it.** This is the page
that turns "we are exposed to the credit cliff" into "this agent, in this environment, driven by
these people, is the reason".

Read it top to bottom; it is ordered the way the cost conversation actually goes.

- **Credit and currency meters** — **Meter** (friendly name plus the raw `ExternalCurrencyType`),
  **Purchased**, **Allocated**, **Consumed**, **Remaining**, **Consumed %**, **As of**. This is the
  only table with a denominator, so it is the only place a percentage is shown. The pill goes amber
  at 75%, red at 90%, and crit above 100%. A negative **Remaining** means you are already in overage.
- **Storage and API capacity** — entitled vs actual vs rated per capacity type.
- **Consumption by resource** — the answer to *which agent*. Resource IDs from the Licensing API are
  joined back to the collected agent, app and flow inventory, so rows carry real names rather than
  GUIDs. Columns: **Resource**, **Kind**, **Environment**, **Meter**, **Consumed**,
  **Non-billable**, **Billed**, **Feature**, **Last used**.
  - **Non-billable gets its own column on purpose.** An agent burning 10,000 mostly non-billable
    credits is a completely different cost conversation from one burning 10,000 billed credits.
  - A row tagged **unmatched** is consuming credits under an ID that appears in no inventory —
    usually an asset in an environment you could not read, or one deleted mid-period. That raises
    `COST-UNMATCHED-RESOURCE`, because something is spending money that this run cannot name.
- **Consumption by user** — the answer to *which person*. Joined to Entra ID for name, UPN,
  department and job title. A consumer whose account is **disabled**, or who is **not in the
  directory** at all, is flagged in red and raises `COST-LEAVER-CONSUMING`.
- **Consumption by department** — the closest honest answer to "which group is spending this".
- **Credit allocation per environment** — allocated vs consumed per environment, whether it is
  **over allocation**, and whether it is drawing on the **tenant pool**.
- **Spend thresholds and alerts** — configured limits, notify-at values and whether a resource
  **stops** at capacity.
- **Per-meter collection state** and **Where these numbers came from** — see the caveats below.
- **Usage data we could not read** — the gap list for this page.

#### Four caveats this page states, and why they matter

1. **It is a group *rollup*, not group attribution.** The department table aggregates per-user
   consumption by the Entra ID `department` attribute. The consumption API attributes spend to a
   **user** and never to a group, so security-group chargeback would have to be inferred — and an
   inferred cost split does not belong in a cost report. Users with no department set are grouped
   separately rather than dropped.
2. **Every figure lags.** Consumption is aggregated daily by the service. Each row shows its own
   refresh date where the API supplies one. Treat every number as a **floor**, not a live reading.
3. **Credits are not sessions.** This page counts money; agent transcripts (Screen 4) count
   conversations. They will not tie out, and both are legitimate — they measure different things.
4. **A blocked dataset is not a zero.** The per-resource attribution route is gated *separately*
   from the tenant totals: an operator can read "26,500 of 25,000 credits consumed" perfectly and
   still be refused the breakdown. Where that happens the page says so in red —
   *"consumption on those meters is unknown, not zero"* — and raises `COST-ATTRIBUTION-BLIND`
   rather than rendering a misleading empty table. If you see it, the fix is a role grant, not a
   re-run.

#### If per-agent attribution is refused: import the report instead

When caveat 4 applies — the per-resource route returns 403 — you can supply the breakdown by hand
and the page will use it:

1. In PPAC go to **Licensing** → **Products** → **Copilot Studio** → **Summary** →
   **Download report**, and choose **agent** (the *environment* and *user* reports import too).
   For AI Builder, use **Licensing** → **Capacity add-ons** → **Download reports**.
2. Re-run with the file:

   ```powershell
   .\Invoke-PPCollect.ps1 -UsageReport .\downloads\copilot-agent-report.csv
   ```

   A folder works too, and `.xlsx` is read directly — no Excel, no modules.

What the importer guarantees:

- **It never double-counts.** If the API already answered for a meter, a file for that same meter
  is refused and the refusal is shown in the **Imported reports** table with its reason. One source
  of truth per meter.
- **Provenance is on every row.** The **Source** column reads `imported` or `API`, and a standing
  note names the files and warns that imported figures are frozen at their export date and **will
  not refresh** on a later run. The matching finding softens from `COST-ATTRIBUTION-BLIND` (Medium)
  to `COST-ATTRIBUTION-IMPORTED` (Info) so the register stops contradicting the page.
- **Columns are matched by name, not position**, against a list of known spellings. Any header it
  does not recognise is listed in the **Imported reports** table rather than dropped — that is how
  a renamed column shows up before it becomes a missing number.
- **It joins by ID, then by name.** These exports usually carry only a display name, so names are
  matched against the agent/app/flow inventory to recover the kind and environment. A name shared
  by two assets is treated as ambiguous rather than resolved to a coin-flip.
- **The import is richer than the API route.** It carries **channel**, **LLM model** and
  **knowledge source / tool**, which `/licensing/entitlements/{id}/resources` does not return at
  all. Those columns appear only for imported rows.

#### Where these numbers came from

The Licensing API is in preview, and some datasets answer under more than one path or api-version
in the same tenant. The expandable **route map** records the exact path, api-version and HTTP
status behind every dataset, so any figure here can be re-derived and audited rather than taken on
trust. If a number looks wrong, that table is where you start.

---

### Screen 11 — Billing (`billing.html`)

**Pay-as-you-go posture, and whether it reaches the environments where agents actually run.**

Two tables and, depending on your tenant, a note at the top.

- **Billing policies** — **Policy**, **Status** (green Enabled, red anything else), **Azure
  subscription**, **Resource group**, **Region**, **Environments** (count), **Created**.
- **Copilot billing coverage** — every environment that hosts agents: **Environment**, **SKU**,
  **Agents**, **Published**, **Billing policy** (or a red `none`), **Status**.

How to read it: an environment with published agents and a red `none` draws solely on the tenant's
prepaid Copilot credit pool. When consumption exceeds capacity, overage enforcement makes those
agents **unavailable to users** — *"This agent is currently unavailable. It has reached its usage
limit."* They do not degrade; they stop. That is what the `COST-AGENT-NOBILLING` finding is warning
about.

A policy showing `Disabled` is worse than no policy, because the environment looks covered on
paper. That raises `COST-BILLING-DISABLED` at High.

Note that pay-as-you-go supports production and sandbox environments only, so developer and Teams
environments are deliberately absent from the coverage judgement.

**Azure pay-as-you-go cost** closes the page when you run with `-IncludeAzureCost`: a total in real
currency, then a breakdown **by meter** and **by Azure resource**, per subscription behind a policy.

Two things to know about it:

- **Azure cannot attribute the spend.** Cost Management reports per meter and per Azure resource;
  it structurally cannot break Power Platform spend down by environment, agent, app or user. That
  breakdown exists only in the credit data on Screen 10. The two use different units — money versus
  credits — and will not reconcile row for row. Use this table for the bill and Screen 10 for blame.
- **A 403 here is normal.** Power Platform Administrator grants no Azure RBAC, so without a separate
  grant the subscriptions simply refuse. That raises `COST-AZURE-NOACCESS` at Info, not an error.
  A **404**, on the other hand, is serious: the policy points at a subscription that is gone, so the
  environment looks covered while nothing can absorb the overage (`COST-AZURE-SUBMISSING`, High).

> How close an environment is to the cliff — per meter, per agent, per user — is on
> **Screen 10, Usage & credits**.

---

### Screen 12 — Integrity (`integrity.html`)

**Not optional, and not an appendix. Read this before you act on anything else.**

A tenant report that silently omits three environments is worse than no report. This page exists so
that never happens.

- **Coverage gaps** — **Scope**, **Item**, **Reason**. Everything the run could not read: tenant
  settings (POST-only by design), environments whose Dataverse refused access, backups that could
  not be listed, Graph permissions that were not consented.
- **Dataverse access per environment** — **Environment**, **Reachable** yes/no, **Agents**,
  **Solutions**, **Sys admins**, **Reason**. If an environment shows `Reachable: no`, then every
  agent, solution and admin in it is missing from this report, and the reason is printed next to it.
- **Requests** — the total call count, all GET, and how many did not succeed. Expand
  *Show failed requests* for the label, HTTP status and full URI of each one.

That request list is what a security team reviews to verify exactly what the tool touched before
approving a production run.

---

## Reading the report in the right order

1. **Integrity** — establish what you are actually looking at. How many environments were
   unreachable? Was Graph consented?
2. **Summary** — the five severity counters and the top findings.
3. **Findings** — the full register, working down from Critical.
4. **The grids** — Agents, Usage & credits, Billing and Security first; they carry the highest
   density of consequence. On the cost pages, check the per-meter collection state before trusting
   a low number: a meter whose breakdown was refused will show tenant totals and nothing beneath
   them, and that is an access gap rather than a quiet tenant.

Reversing steps 1 and 2 is the single most common way to misread a Power Platform tenant report.
