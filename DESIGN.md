# Power Platform Tenant Reporting Tool — Design

**Goal:** a read-only tool a Power Platform Administrator runs from their own workstation that
inventories an entire tenant and renders self-contained HTML reports.

**Non-goal:** anything that writes to the tenant. Every call is a GET/read. This is a hard
constraint — it is what makes the tool approvable to run in a customer production tenant.

---

## 1. Tool selection

### Recommendation: PowerShell 7 core + REST, JSON intermediate, PowerShell HTML renderer

| Option | Verdict | Why |
|---|---|---|
| **PowerShell 7** | ✅ **Chosen** | Admin's box already has PS; the official admin module exists; `ForEach-Object -Parallel` matters a lot at 100+ environments; no build/dist step; enterprise-approvable |
| PowerShell 5.1 | ⚠️ fallback only | No parallel, weaker TLS/JSON, `Invoke-RestMethod` lacks `-Retry*`. Currently the only version on this machine — **install PS7** |
| Python | ❌ | Better rendering story (jinja2/pandas), but PP auth libs are weak and admins don't have Python on a locked-down admin workstation |
| C# / .NET tool | ❌ for v1 | Best perf + typed `Dataverse.ServiceClient`, but needs build + code-signing to distribute. Revisit if runtime becomes the bottleneck |
| `pac` CLI | ➕ optional adjunct | Great for solution/ALM detail, but the API surface is too narrow for a full inventory |
| CoE Starter Kit | ➕ complement, not substitute | It's a solution you *install* (Dataverse tables + scheduled flows). Ours is zero-footprint and runs on demand. Mention it in the report as the long-term telemetry option |

### Prerequisites to install
```powershell
winget install Microsoft.PowerShell                       # PS7
Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser   # already: 2.0.217
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser   # token broker for Graph/Dataverse/PPAC
Install-Module ExchangeOnlineManagement -Scope CurrentUser        # optional: unified audit log = usage telemetry
Install-Module MicrosoftPowerBIMgmt -Scope CurrentUser            # optional: Power BI scope
```

### Architecture — the key call: **decouple collection from rendering**

```
┌──────────────┐   ┌───────────────────┐   ┌──────────────┐   ┌───────────────┐
│  Collectors  │──▶│  runs/<ts>/raw/   │──▶│  Analyzers   │──▶│  HTML render  │
│ (slow,       │   │  *.json           │   │ (rules,      │   │ (fast, pure,  │
│  throttled,  │   │  = the data lake  │   │  joins,      │   │  re-runnable) │
│  fragile)    │   │                   │   │  diff vs     │   │               │
└──────────────┘   └───────────────────┘   │  prev run)   │   └───────────────┘
                                            └──────────────┘
```

Why this matters:
- Collection may take **hours** on a large tenant and can fail halfway → raw JSON on disk means
  resume + never re-collect just to fix a chart.
- Iterating on the report is a 2-second loop instead of a 2-hour loop.
- Keeping every run under `runs/<timestamp>/` gives **drift/diff reporting for free** —
  "what changed since last month" is arguably more valuable to an admin than the snapshot itself.
- Raw JSON is auditable: a customer can verify we only read what we claim.

### Proposed layout
```
PPAdmin/
  PPTenantReport.psd1 / .psm1
  src/
    Auth/          Get-PPToken.ps1          # MSAL, one token per audience, silent refresh
    Core/          Invoke-PPApi.ps1         # retry/backoff/Retry-After, paging, checkpointing
                   Write-PPLog.ps1          # structured NDJSON log + per-collector status
    Collect/       Collect-Tenant.ps1  Collect-Environments.ps1  Collect-Apps.ps1
                   Collect-Flows.ps1   Collect-Agents.ps1        Collect-Dlp.ps1
                   Collect-Dataverse.ps1    Collect-Audit.ps1    Collect-Licensing.ps1
    Analyze/       rules/*.ps1              # one file per finding rule
                   Compare-PPRun.ps1        # diff two runs
    Render/        templates/*.html  assets/{app.css,app.js}  Render-Report.ps1
  runs/<yyyyMMdd-HHmmss>/
    raw/*.json  analyzed/*.json  report/index.html + pages/*  export/*.csv  collection.log
  config/scope.psd1                          # what to collect, env allow/deny, depth
```

---

## 2. Data sources and what each yields

Confidence key: **[A]** verified/stable · **[B]** documented but version-sensitive · **[C]** must be
probed against a live tenant in Phase 0 before we commit to it.

### 2.1 `Microsoft.PowerApps.Administration.PowerShell` (BAP APIs) — **[A]** the backbone
Already installed. Interactive auth via `Add-PowerAppsAccount`.

| Cmdlet | Yields |
|---|---|
| `Get-AdminPowerAppEnvironment` | env id/name/type(SKU)/region/state, Dataverse org URL + version, created by/on, security group id, protection status |
| `Get-AdminPowerAppEnvironmentCapacity` | DB / File / Log capacity actual vs entitled, per env |
| `Get-AdminPowerApp` | canvas apps: owner, display name, created/modified, app version, embedded connections, shared-user count |
| `Get-AdminPowerAppRoleAssignment` | app sharing — principal, type (User/Group/Tenant), CanView/CanEdit ⇒ **"shared with Everyone"** detection |
| `Get-AdminFlow` | flows tenant-wide: state (Started/Stopped/Suspended), owner, trigger, env |
| `Get-AdminFlowOwnerRole` | flow owners/co-owners ⇒ orphan detection |
| `Get-AdminPowerAppConnection` | connections + owner + status (Connected/Error) ⇒ **broken connections** |
| `Get-AdminPowerAppConnector` | custom connectors, publisher, host |
| `Get-DlpPolicy` / `Get-AdminDlpPolicy` | DLP: connector classification (Business/Non-Business/Blocked), env scoping, custom-connector patterns, endpoint rules |
| `Get-TenantSettings` | tenant-wide toggles: who can create envs/trials, sharing limits, Dataverse env creation restrictions |
| `Get-PowerAppTenantIsolationPolicy` | cross-tenant inbound/outbound isolation + allow-list |
| `Get-AdminPowerAppLicenses` | async CSV export of every PP-licensed user + license type + assigned plan |
| `Get-AdminPowerAppsUserDetails` | per-user PP profile |

**Gap:** this module has **no usage/telemetry** (launch counts, run counts). That comes from §2.5/§2.7.

### 2.2 Power Platform Admin API — `api.powerplatform.com` — **[B]/[C]** the modern surface
Bearer token, audience `https://api.powerplatform.com`. Richer than BAP; this is what PPAC itself calls.

- Environment detail incl. **lifecycle, managed-environment status, governance config** — [B]
- **Backups**: list system + manual restore points, retention window, last backup time — [B]
  (prod ≈ 28 days system backups, sandbox ≈ 7 — **verify per tenant**)
- **Copy / restore / reset operation history** — who reset what, when — [B]
- **Managed Environments** settings: sharing limits, usage insights, maker welcome, solution checker enforcement — [B]
- **Environment Groups + rules** (newer) — [C]
- **BCDR / disaster recovery** config, secondary geo, failover readiness — [C] *this is the one I am
  least sure has a stable public API; Phase 0 must confirm, else we report only what PPAC exposes*
- Licensing/capacity add-on allocation per environment — [B]
- Data policies v2 (the successor to `Get-DlpPolicy`) — [B]

> **Action:** Phase 0 writes a probe script that hits each candidate route with several `api-version`
> values and records status codes into `raw/_capability-probe.json`. The report then only renders
> sections the tenant actually supports. No guessing baked into the collector.

### 2.3 Dataverse Web API (per environment) — **[A]** by far the richest source
`https://<org>.crm<N>.dynamics.com/api/data/v9.2/`. Only for environments *with* Dataverse.

| Table | Yields |
|---|---|
| `solution` + `solutioncomponent` + `publisher` | solution inventory, managed vs **unmanaged in prod** (top ALM red flag), version, publisher prefix |
| `systemuser` | users, business unit, **disabled/deleted owners**, access mode, **application users (SPNs)** |
| `role`, `systemuserroles`, `team`, `teamroles` | who has System Administrator; SPNs with sysadmin; role sprawl |
| `workflow` | cloud flows (category 5), classic workflows (0), business rules (2), actions (3), **BPFs (4)** — the only place classic/BPF assets show up |
| `bot`, `botcomponent`, `botcomponentcollection` | **Copilot Studio agents** — see §2.3.1, verified |
| `conversationtranscript` | **agent usage telemetry** — see §2.3.2, verified |
| `asyncoperation` | failed system jobs, failed flow-of-record ops — a strong error feed |
| `plugintracelog` | plugin/custom-code exceptions (if trace logging on) |
| `sdkmessageprocessingstep`, `plugintype` | registered plugins, incl. third-party |
| `importjob` | solution deployment history — who deployed what, when, success/fail |
| `mailbox` | server-side sync state + errors (a top real-world support driver) |
| `connectionreference`, `environmentvariabledefinition/value` | ALM hygiene, unbound conn refs |
| `organization` | org version, base currency, audit enabled, feature flags |
| `msdyn_aiconfiguration` / `msdyn_aimodel` | AI Builder models + credit consumption signals |
| `RetrieveTotalRecordCount` | row counts per table ⇒ storage attribution |
| `audit` | change auditing (huge — sample/count only, never bulk pull) |

#### 2.3.1 Copilot Studio agents — **[A] verified against MS Learn**

`GET /api/data/v9.2/bots`. Confirmed columns:

| Column | Value for the report |
|---|---|
| `botid`, `name`, `schemaname` | identity |
| `ownerid` (systemuser *or* team), `createdby`/`createdon`, `modifiedby`/`modifiedon` | ownership + orphan detection |
| `publishedon`, `publishedby` | **published vs never-published** (draft agents sitting in prod) |
| `statecode` | 0 Active / 1 Inactive |
| `statuscode` | 1 Provisioned · 2 Deprovisioned · 3 Provisioning · 4 **ProvisionFailed** · 5 **MissingLicense** |
| `accesscontrolpolicy` | 0 **Any** · 1 Copilot readers · 2 Group membership · 3 **Any (multi-tenant)** ⇒ top security finding |
| `authenticationmode` | 0 Unspecified · 1 **None** · 2 Integrated · 3 Custom Entra ID · 4 Generic OAuth2 |
| `authenticationtrigger`, `authorizedsecuritygroupids` | who may talk to the agent (≤20 group IDs, CSV) |
| `ismanaged`, `solutionid`, `componentstate` | ALM posture — unmanaged agent in prod |
| `language`, `supportedlanguages` | LCID picklists |
| `providerconnectionreferenceid` | → `connectionreference` |
| `configuration` (JSON, ≤1 MB) | **the payoff** — see below |
| `synchronizationstatus` (JSON) | contains `applicationId` |
| `template`, `origin`, `runtimeprovider` | provenance |

`configuration` JSON keys worth parsing: `GenerativeActionsEnabled` (generative vs classic orchestration),
`useModelKnowledge` (agent may answer from general model knowledge), `isSemanticSearchEnabled`,
`optInUseLatestModels` (deep reasoning), `isFileAnalysisEnabled` (file upload).

`botcomponent` (`parentbotid` → bot) holds topics/tools/knowledge. Known `componenttype` values:
**15 = Custom GPT** (description + YAML `instructions`), **17 = External Trigger** ⇒ **autonomous agent**.
Topic-v2 `data` YAML is grep-able for capability detection: `TaskDialog` (tools), `HttpRequestAction`,
`InvokeSkillAction`, `InvokeAIBuilderModelAction` (prompts), `InvokeExternalAgentTaskAction` (**MCP**),
`AnswerQuestionWithAI`, `KnowledgeSourceConfiguration`, and
`connectionProperties.mode = maker` ⇒ **connector runs as the maker, not the invoker** — a genuine
privilege-escalation risk worth its own finding.

> **Reuse, don't reinvent:** Microsoft publishes the full derivation ruleset for all of the above as the
> **Copilot Studio Kit → Agent Inventory "Agent Details"** table. Same relationship as the CoE Kit: it's an
> installed solution, not a portable script, but the *rules* are authoritative and public. Mirror its
> column semantics so our output is comparable to the Kit's.
> `learn.microsoft.com/microsoft-copilot-studio/guidance/kit-agent-inventory-data-source`

**Agent findings this unlocks:** anonymous agents (`accesscontrolpolicy` 0/3 + `authenticationmode` 1) ·
cross-tenant-reachable agents · agents in `MissingLicense`/`ProvisionFailed` · autonomous agents with
maker-mode connections · unmanaged agents in production · never-published or orphaned agents ·
generative agents allowed to use general model knowledge (grounding/compliance risk).

#### 2.3.2 Agent usage telemetry — **[A] real, but heavily caveated**

`conversationtranscript` columns: `content` (full activity log JSON, **1 MB cap**),
`conversationstarttime`, `name` (= conversationId + botId), `metadata`
(`{BotId, AADTenantId, BotName, BatchId}`), `bot_conversationtranscriptid` → agent, `createdon`.

A session is written **30 minutes after inactivity** (3 min for Telephony after End Conversation).
Records >1 MB are **split** — merge on identical `name` + `conversationstarttime`, ordered by
`metadata.BatchId`.

Crucially, **you do not have to invent the metric definitions** — Copilot Studio writes them into the
activity stream as `valueType` records inside `content`:

| `valueType` | Yields |
|---|---|
| **`SessionInfo`** | `type` = engaged \| unengaged · `outcome` = **Escalated \| Resolved \| Abandon** · `startTimeUtc`/`endTimeUtc` · turn count |
| `CSATSurveyRequest` / `CSATSurveyResponse` | satisfaction scores |
| `PRRSurveyRequest` / `PRRSurveyResponse` | "did this answer your question" |
| `IntentRecognition` | topic triggered ⇒ **topic usage / unrecognized-intent rate** |
| `DialogRedirect`, `ImpliedSuccess`, `VariableAssignment` | flow analysis |
| `from.role` (0 = agent, 1 = user), `from.id` | active-user counts — **id is hashed**; if the canvas passes no user id, it's per-conversation |
| `channelId` | `directline`, `msteams`, … ⇒ channel mix |

Optional **enhanced transcripts** (per-agent setting) add `nodeTraceData` with `nodeID`, `nodeType`,
`startTime`/`endTime`, `topicDisplayName` ⇒ node-level latency and drop-off.

**Caveats the report must state explicitly — these are the whole story:**

1. **30-day default retention.** A recurring bulk-delete job ("Bulk Delete Conversation Transcript
   Records Older Than 1 Month") purges anything older. A point-in-time run therefore sees **≤30 days**
   unless the customer already extended it. → The collector should *read the bulk-delete job config* and
   report actual retention per environment; "retention not extended" is itself a finding.
2. **Transcripts are not written at all for:** Dataverse-for-Teams environments, **developer
   environments**, and **Microsoft 365 Copilot agents**. Those agents will show usage = unknown, not zero.
3. **Requires the `Bot Transcript Viewer` security role** — Environment Maker does *not* have it, and it
   isn't implied by tenant admin. Expect 403s; degrade per environment.
4. **Admins can disable transcript storage entirely** (`admin-transcript-controls`). Detect and report.
5. **Copilot Studio's own Analytics page uses a separate data service**, not Dataverse. Numbers will not
   tie out exactly, and changing Dataverse retention does not affect that page. Say so in the report.
6. **Volume + privacy.** `content` contains verbatim user conversation text (and, with SharePoint
   knowledge, source-document content). **Aggregate at collection time; never persist raw transcripts
   into the report.** Store only derived counts. This is the single most sensitive data the tool touches.
7. Long-horizon trending is out of scope for a point-in-time tool — the documented path is
   Azure Synapse Link → ADLS Gen2 in **append-only** mode (default mirror mode propagates the
   bulk-delete). Recommend it; don't build it.

**Lead chased and resolved:** the Kit sources agent entitlement/consumption ("billed sessions") from
**Licensing API endpoints**, not Dataverse. That API is real, documented and GET-only — see §2.3.3.
It gives billed and non-billed credit consumption per agent and per user, which transcripts cannot.

**Risk — [C]:** whether a Power Platform Admin can call the Dataverse Web API on an environment
where they hold no security role is inconsistent. Mitigation: attempt, catch 401/403, mark that
environment `dataverseDepth: "denied"`, keep going, and surface a report section
**"environments we could not fully inspect and why"**. Degradation must be visible, never silent.

### 2.3.3 Credit and capacity consumption — `api.powerplatform.com/licensing` — **[B] BUILT**

The lead chased in §2.3.2 resolved, and it resolved better than expected. Copilot credit
consumption is *not* only in Dataverse or the Copilot Studio analytics service — the Licensing
namespace exposes it as documented, tenant-scoped **GET** routes. That matters more here than
elsewhere: cost data is the one area where the read-only guarantee usually forces a POST-shaped
"query" API, and it does not here.

| Route (all GET, `api-version=2024-10-01`) | Yields |
|---|---|
| `/licensing/tenantCapacity/currencyReports?includeAllocations=true&includeConsumptions=true` | **The headline table.** Per currency: purchased, allocated, consumed, last-updated day |
| `/licensing/tenantCapacity` | Storage/API capacity: entitled vs actual vs rated, overflow, per-licence breakdown |
| `/licensing/allocationsByEnvironment` | Which environment holds which slice of each credit pool |
| `/licensing/entitlements/{id}` | Per-meter capacity **and pay-as-you-go split**, overage status, contributing licences |
| `/licensing/entitlements/{id}/resources?fromDate&toDate` | **Consumption per resource across all environments** — `resourceId`, `environmentId`, `consumed`, `unit`, and `metadata` carrying `Feature`, `ProductName` and **`nonBillableConsumed`** for `MCSMessages` |
| `/licensing/entitlements/{id}/users?fromDate&toDate` | **Consumption per user** — `userId`, `environmentId`, `consumed` |
| `/licensing/entitlements/{id}/resources/{resourceId}/users?fromDate&toDate` | Users who drove one specific agent/app |
| `/licensing/entitlements/{id}/users/{userId}/resources?fromDate&toDate` | Resources one specific user drove |
| `/licensing/entitlements/{id}/environments/{env}/resources?fromDate&toDate` | Same, scoped to one environment — cheaper than the tenant fan-out |
| `/licensing/entitlements/{id}/resourceThresholds` | Configured spend alarms. **Absence is a finding** |
| `/licensing/entitlements/{id}/licenses?fromDate&toDate` | Entitlement trend rather than a snapshot |
| `/licensing/environments/{env}/entitlements` | Which meters an environment is entitled to |
| `/licensing/environments/{env}/billingPolicy` | Environment → Azure subscription link. 404 = not on pay-as-you-go |

`{id}` is an entitlement ID. There is no documented "list entitlements" route; the only public
vocabulary is the `ExternalCurrencyType` enum published with the allocation and currency-report
models: `AI` (AI Builder credits), `MCSMessages` (**Copilot Studio credits** — the API kept the
pre-September-2025 "messages" name), `MCSSessions`, `SCMessages`, `VAConversations`, `AppPass`,
`AppPassForTeams`, `PAHostedRPA`, `PAUnattendedRPA`, `PowerAutomatePerProcess`, `PerFlowPlan`,
`PortalLogins`, `PortalViews`, `PowerPagesAuthenticated`, `PowerPagesAnonymous`,
`ProcessMiningDataStorage`, `PortalAddOns`, `Invoice`. Phase 0 probes `MCSMessages` and `AI` and
cross-checks the spelling against `/licensing/environments/{env}/entitlements`.

**Caveats the report must state:**

1. Data is **aggregated daily** and can lag; `lastRefreshedDate`/`asOfDate` must be printed, not hidden.
2. `resourceId` is an ID, not a name. Joining it to the agent/app/flow inventory we already collect
   is what turns it into a report — an unjoined GUID is worthless to an admin.
3. Credit consumption is not the same as *sessions*. `conversationtranscript` (§2.3.2) counts
   conversations; this counts money. They will not tie out, and both belong on the page.
4. `nonBillableConsumed` matters: an agent burning mostly non-billable credits is a very different
   cost conversation from one burning billed credits at the same volume.

**Built as `src/Collect/Collect-Usage.ps1`.** Renders to the **Usage & credits** page, with the
Azure money figure on **Billing**. Three findings from building it that the design did not
anticipate:

1. **The api-version separator bug invalidated most of the Phase 0 verdicts for this namespace.**
   `Probe-PPApi.ps1` computed its query separator with `$path -like '*?*'`. In PowerShell `-like`
   treats `?` as a *single-character wildcard*, so `'*?*'` is true for every non-empty string and
   every path without a query string was requested as `/licensing/billingPolicies&api-version=...`.
   The service answered `404 RouteNotFound`, indistinguishable from a route that does not exist.
   That is why `tenantCapacity`, `allocationsByEnvironment`, `resourceThresholds`,
   `environments/{env}/entitlements` and `billingPolicies` all read "Not found" in the first probe
   report — while `Collect-Tenant.ps1`, which hardcodes `?api-version=`, gets **200** from
   `billingPolicies` in the same tenant. Fixed to `.Contains('?')`. **Lesson: never use `-like`
   to test for a literal `?` or `*`.** Re-probe before trusting any "Not found" verdict written
   before this fix.

2. **api-version is per-route, not per-namespace.** In the same tenant, `currencyReports` answers
   at `2024-10-01` while `entitlements/{id}/users` and `.../licenses` answer only at
   `2026-05-01-preview`. The collector therefore probes versions per route, newest first, and
   harvests the service's own `Supported API versions are: ...` response rather than guessing.

3. **Attribution is gated separately from totals.** `entitlements/{id}/resources` — the route that
   answers *which agent* — returns **403** for an operator who reads the tenant currency report
   fine. So "which agent is spending" can be unavailable while the headline number is perfect.
   The report must never render that as zero consumption, and a blocked attribution route raises
   its own finding (`COST-ATTRIBUTION-BLIND`), because "we cannot tell you which agent spent this"
   is itself worth escalating.

**Verified against the tenant after the fix (probe run `20261004-220951`, 91 calls).** Everything
that answers, answers at **`2024-10-01` on the first attempt**:

| Route | Before fix | After fix |
|---|---|---|
| `/licensing/billingPolicies` | 404 | **200** |
| `/licensing/tenantCapacity` | 404 | **200** |
| `/licensing/allocationsByEnvironment` | 404 | **200** |
| `/licensing/entitlements/{m}` | 400 | **200** |
| `/licensing/entitlements/{m}/resourceThresholds` | 404 | **200** (both MCSMessages and AI) |
| `/licensing/environments/{env}/allocations` | 404 | **200** |
| `/licensing/environments/{env}/entitlements` | 404 | **200** |
| `/licensing/tenantCapacity/currencyReports` | 200 | 200 |
| `/licensing/entitlements/MCSMessages/users` | 200 | 200 |
| `/licensing/entitlements/{m}/resources` | 403 | **403 — still** |
| `/licensing/entitlements/AI/users` | — | 404 (the AI meter has no per-user route) |
| `/licensing/environments/{env}/billingPolicy` | 404 | 404 |
| `/licensing/tenantCapacityDetails`, `.../tenantCapacity/details` | — | 404 (so the plain spelling is the real one; candidate order in the collector reflects this) |

**The 403 on per-resource attribution is real and is not the separator bug.** It survives the fix
at every api-version, with an **empty response body** naming no required permission, in a tenant
where the same token reads the currency report, entitlement detail, thresholds, environment
entitlements *and the per-USER consumption route* at 200. That asymmetry — per-user 200,
per-resource 403 — is the whole finding: this is a permission boundary specific to resource-level
consumption, not a wrong route, a wrong version or a missing parameter.

Consequences baked into the tool:
- `COST-ATTRIBUTION-BLIND` points at the route that a Power Platform Administrator demonstrably
  *does* have for the same data: **PPAC → Licensing → Products → Copilot Studio → Summary →
  Download report → agent** (also per-environment and per-user). That report carries agent name,
  product/feature, channel, LLM model, knowledge source and billed-vs-non-billed credits.
- The probe no longer collapses the two attribution halves into one verdict. It previously OR-ed
  "by resource" and "by user" into a single `$usageWho` count, so a blocked per-agent route
  rendered as *"attribution is Available"* — precisely the false reassurance this design forbids.
  They are now separate verdicts, and a 403 reports as **Blocked**, not Unavailable.
- **Resolved via ingestion** (`src/Collect/Import-PPUsageReport.ps1`, `-UsageReport`). There is
  still no documented API that generates or fetches those PPAC reports (§2.3.4), so the tool reads
  the downloaded file instead and normalises it into exactly the shape the API collector produces.
  Four rules make that safe rather than merely convenient:
  1. **One source of truth per meter.** If the API answered per-resource for a meter, a file for
     that meter is refused, with the refusal shown. Appending both would double-count spend, and a
     cost report that double-counts is worse than one missing a section.
  2. **Provenance on every row.** `Source` is `imported` or `API`; the page names the files and
     states that imported figures are frozen at export time. `COST-ATTRIBUTION-BLIND` (Medium) is
     replaced by `COST-ATTRIBUTION-IMPORTED` (Info) so the register cannot contradict the page.
  3. **Headers are mapped by name against a candidate list, never by position**, because these
     exports differ per report type and across service updates. Unrecognised headers are listed in
     the report rather than dropped — an unmapped column is how a rename surfaces before it becomes
     a missing number. Candidate order matters: `Non-billed credits` contains `billed`, so it must
     be claimed before `Billed credits` can take it.
  4. **No external dependency.** `.xlsx` is read by unzipping the package and parsing the sheet XML
     directly — no ImportExcel, no Excel COM. Cell *references* are decoded rather than cells
     counted, because empty cells are omitted from the XML and a position-based reader would shift
     every later value in the row. Zip entry names are matched with separators normalised: the OPC
     spec and Excel use `/`, but .NET Framework's `ZipFile.CreateFromDirectory` on Windows writes
     `\`, so a package that has been through intermediate tooling can arrive either way.
  The imported report is in one respect *better* than the blocked route: it carries **channel, LLM
  model and knowledge source**, which `/licensing/entitlements/{id}/resources` does not return.

Route spellings were cross-checked against the `pac licensing` command reference, which is the
closest thing to a published contract for this namespace. Where the REST spelling is not
published (`get-tenant-capacity-details`), the collector tries an ordered candidate list and
records which one answered in the report's route map — a consumption figure whose provenance is
unknown is not auditable.

### 2.3.4 Pay-as-you-go and Azure cost — **[C] BUILT, opt-in** (`src/Collect/Collect-AzureCost.ps1`)

Where a billing policy links environments to an Azure subscription, spend lands on a
**Power Platform account resource** in that subscription, one per billing policy.

- **Azure Cost Management** shows amount billed per meter and per resource, but explicitly
  **cannot break down which environment, app/agent or user drove it**.
- That breakdown exists only in the **downloadable pay-as-you-go report** on the Billing plan page
  in PPAC — fields include `Caller ID`, `Caller Type` (User / Non Licensed User / Application /
  Microsoft), `Resource Type`, `Resource ID`, `Meter Category`, `Consumed`/`Overage`/`Billed
  Quantity`. No documented API for generating or fetching it: **probe candidate, else a manual
  download the tool ingests**.
- Azure-side, the read-only path is `GET .../providers/Microsoft.Consumption/usageDetails` (a GET),
  **not** `POST .../Microsoft.CostManagement/query` (which this tool refuses). It needs an
  `https://management.azure.com` token and Azure RBAC on the subscription — a **different
  permission set from Power Platform Administrator**, so it must be an opt-in module that degrades
  loudly, never a hard dependency.

Given §2.3.3 already answers "which agent, which user" for credits, Azure cost is worth collecting
for the **money figure** and the environment→subscription→billing-policy chain, not for attribution.

### 2.4 Microsoft Graph — **[A]** the identity join
Fixes the pervasive "owner is a bare GUID" problem, and is the only way to detect leavers.

- `users` — UPN, display name, department, manager, **accountEnabled=false ⇒ orphaned assets**
- `groups` — resolve env security groups and group-based app sharing to real membership counts
- `servicePrincipals` — identify S2S app users, owner app registrations, **expiring secrets/certs**
- `subscribedSkus` — tenant license inventory (Power Apps per-user/per-app, Automate Premium, Copilot Studio)
- `directoryAudits` / `signIns` — optional, for admin-role changes

### 2.5 Microsoft 365 Unified Audit Log — **[B]** the real usage telemetry
Via `Search-UnifiedAuditLog` (ExchangeOnlineManagement) or the O365 Management Activity API.

- **App launches** (`LaunchPowerApp`) ⇒ MAU/DAU per app, last-used date, **unused-app detection**
- App/flow created, edited, deleted, **shared**
- DLP policy created/updated/deleted, environment created/deleted
- Connector and connection creation
- Dataverse record operations (if org auditing on)

Caveats to state in the report: requires unified auditing enabled; retention 90 d (E3) / 180 d+ (E5);
requires the *Audit Logs* / *View-Only Audit Logs* role — **a Power Platform Admin alone does not have
this**. It will frequently be unavailable → treat as an optional module, and when it's missing say so
loudly, because "we have no usage data" is itself a governance finding.

### 2.6 Power Automate / Flow management API — **[B]** flow reliability
Admin-scoped run history per flow: `.../scopes/admin/environments/{env}/flows/{flow}/runs`.
Gives success/failure counts, last run, failure reasons ⇒ **top failing flows**, **zombie flows**
(enabled, never run). Expensive: one call per flow. Gate behind `-Depth Deep` and cap
(e.g. top N flows by env, last 30 days).

### 2.7 Application Insights — **[C]** optional deep telemetry
Where environments/apps are wired to App Insights, KQL against the workspace yields real app session
counts, exceptions, and dependency failures. Only viable if the admin has Log Analytics reader.
Report it as *configured vs not configured per environment* even when we can't query it — App Insights
coverage is itself a maturity metric.

### 2.8 Power BI admin API — **➕ optional scope**
Workspaces, datasets, dataflows, refresh failures. Include only if the engagement covers BI.

---

## 3. Report structure

Two artifacts from every run:
1. **Full static site** — `report/index.html` + `pages/*.html`, self-contained folder, zippable.
2. **Single-file executive summary** — one emailable `.html` with everything inlined.

Plus **CSV exports** per table for admins who want to pivot in Excel.

| # | Page | Contents |
|---|---|---|
| 00 | **Executive summary** | Tenant scorecard, asset counts, geo map, top 10 risks, capacity headroom, delta vs previous run |
| 01 | **Tenant & governance** | Tenant settings, isolation policy, env-creation restrictions, admin roster, license inventory |
| 02 | **Environments** | Full grid: type, geo/region, Dataverse version, managed-env status, security group, state, created by/on, capacity, **last backup / restore points / DR posture** |
| 03 | **Capacity & licensing** | DB/File/Log actual vs entitled, per-env attribution, top storage tables, add-on allocation, licenses assigned vs consumed, trial expiry |
| 03a | **Credits & cost** ✅ BUILT | Per meter: purchased / allocated / consumed (Copilot credits, AI Builder, RPA, per-app passes) · credit burn **per agent** and **per user**, billed vs non-billed · allocation vs consumption per environment · pay-as-you-go billing policies and their Azure subscriptions · spend thresholds configured, or not (§2.3.3, §2.3.4) |
| 04 | **Apps** | Canvas + model-driven: owner (resolved name), env, created/modified, sharing scope, **last launch + MAU**, connections used, orphan/unused flags |
| 05 | **Flows** | State, owner, trigger type, connections, run success rate, last run, failures, orphans, suspended |
| 06 | **Agents (Copilot Studio)** | Agent inventory, owner, publish state, channels, sessions/engagement from `conversationtranscript`, knowledge sources |
| 07 | **Connectors & connections** | Custom connectors, connection ownership + broken connections, connections on personal accounts, connector usage frequency |
| 08 | **DLP** | Policy matrix, connector classification per policy, env coverage, **environments with no policy**, default-env exemptions, recent policy changes |
| 09 | **Security** | Env admins, Dataverse System Administrators, SPNs/app users and their roles, guest users with maker access, apps shared tenant-wide, expiring SPN secrets |
| 10 | **Solutions & ALM** | Per-env solutions, managed vs unmanaged, publisher hygiene, import history, environment variables / connection references, solution-checker posture |
| 11 | **Usage & adoption** | MAU/DAU trends, maker leaderboard, adoption by department, dormant assets, sprawl indicators (per §2.5 availability) |
| 12 | **Errors & reliability** | Failed flow runs, `asyncoperation` failures, plugin exceptions, mailbox sync errors, broken connections — ranked by blast radius |
| 13 | **Findings / risk register** | ⭐ the payload — see §4 |
| 14 | **Change since last run** | Added/removed/changed environments, apps, flows, DLP policies, admins |
| 15 | **Collection integrity** | What ran, what was skipped, what was denied and why, elapsed time, API errors, coverage % |

Page 15 is not optional. A tenant report that silently omits three environments is worse than no report.

### Rendering approach
- **No CDN.** Enterprise/air-gapped safe: all CSS/JS inlined or vendored locally, no external fetch.
- Data embedded as JSON in a `<script type="application/json">` block; small hand-rolled JS for
  sort / filter / search / column-toggle / CSV-download. No framework.
- Client-side pagination + virtualized rendering for big grids; hard cap inline rows (e.g. 5k) and
  link out to the CSV beyond that.
- Light/dark aware, print-friendly stylesheet for the exec summary.
- Deterministic output (stable sort, no timestamps inside cells) so runs diff cleanly in git.

---

## 4. The findings engine — where the actual value is

Everything above is table dumps. The differentiator is a rules engine that turns inventory into a
prioritized, evidence-linked risk register. One rule = one file = one testable unit.

Severity ×  category, each finding carrying: what, where, evidence (deep link into the grid page),
why it matters, and remediation.

**Governance** — environments with no DLP policy · default environment unrestricted · everyone can
create trial/production environments · no tenant isolation with external sharing on · unmanaged
solutions in production · producer environments without a security group (open to all makers).

**Security** — apps/flows shared with the entire tenant · guest users holding maker or sysadmin ·
service principals with System Administrator · SPN secrets expiring < 60 days · connections bound to
personal/consumer accounts · sysadmin role sprawl beyond N users.

**Continuity / DR** — environments with no recent backup · production environments with no DR
configuration · single-geo concentration · sandbox environments holding production data patterns ·
long-running environments never restore-tested.

**Cost / hygiene** — environments hosting agents with **no pay-as-you-go billing policy**, or
covered by a **disabled** one (prepaid-only agents stop serving users at overage enforcement, they
do not degrade) · apps with zero launches in 90 days · flows enabled but never run · orphaned
assets whose owner is disabled or deleted · trial environments near expiry · capacity > 80 % entitled ·
licenses assigned but unused.

**Reliability** — flows with < 90 % success rate · connections in error state · mailboxes not syncing ·
recurring plugin exceptions · high `asyncoperation` failure rate.

**Compliance / residency** — environments outside the approved geo list · auditing disabled on
environments handling regulated data · DLP policies with blocked connectors nonetheless in use.

Rules are configurable (thresholds in `config/scope.psd1`) and every finding must cite the raw record
that produced it — no unexplainable red boxes.

---

## 5. Hard constraints to design for up front

1. **Throttling.** BAP/PPAC/Dataverse all throttle aggressively. Central `Invoke-PPApi` with
   exponential backoff, honoring `Retry-After`, per-audience concurrency caps, and a global rate budget.
2. **Runtime.** 200 environments × Dataverse queries = hours. Needs `-Parallel` (PS7), per-collector
   checkpoints, `-Resume`, and `-Depth Quick|Standard|Deep` so a first run can finish in minutes.
3. **Partial permissions are the norm, not the exception.** Every collector degrades gracefully and
   records *why*. Never fail the whole run on one environment's 403.
4. **Output is highly sensitive** — it is a complete attack map of the tenant. Ship a
   `-RedactPii` mode (hash UPNs, drop display names) and stamp a confidentiality banner on the report.
5. **Read-only, provably.** Whitelist HTTP verbs to GET/HEAD in the API wrapper; assert in a unit test.
   Publish the full list of endpoints touched so a security team can pre-approve the tool.
6. **Multi-cloud / sovereign.** GCC, GCC High, DoD, China have different endpoints. Parameterize the
   cloud from the start — retrofitting is painful.

---

## 6. Suggested phasing

- **Phase 0 — capability probe. ✅ BUILT** (`Invoke-PPProbe.ps1`, 27 offline tests passing).
  Auth to all audiences, enumerate environments, probe every uncertain endpoint from §2.2, per-env
  Dataverse + agent + transcript reachability, observed transcript retention, Graph consent. Output:
  a self-contained HTML "what this tenant will actually let us collect" report plus `raw/probe.json`.
  De-risks everything marked [C] before a collector is written. **Run this against the real tenant
  next — its output determines what Phase 1 builds.**
- **Phase 1 — breadth.** BAP module collectors (envs, apps, flows, DLP, connections, tenant settings,
  capacity) + JSON store + basic grid rendering + findings engine v1. Genuinely useful on its own.
- **Phase 2 — depth.** Graph identity join, Dataverse per-env collectors (solutions, security, agents,
  errors), backups/DR.
- **Phase 3 — telemetry.** Unified audit log, flow run history, App Insights, adoption pages.
  **Credit and capacity consumption landed early** (§2.3.3) rather than waiting for this phase:
  it needs no audit-log role, it is the question admins ask first, and the Licensing routes turned
  out to be plain GETs. What remains here is *activity* telemetry — app launches, flow runs,
  MAU/DAU — which still depends on the audit log and is still frequently unavailable.
- **Phase 4 — trend.** Run-over-run diffing, scheduled runs, historical charts.

---

## 7. Open questions for the admin

1. Which roles will the operator actually hold — Power Platform Admin only, or also Global Reader /
   Audit Logs reader / Exchange role? This decides whether §2.5 usage telemetry exists at all.
2. Interactive device-code sign-in per run, or a dedicated app registration with app-only consent?
   (Interactive = zero setup, but Dataverse per-env access is spotty. App registration = reliable and
   schedulable, but needs a consent conversation.)
3. Commercial cloud, or GCC/GCC High/DoD/China?
4. Rough tenant size — environments / apps / flows? Drives whether parallelism and resume are v1 or v2.
5. Is the CoE Starter Kit already installed? If so we can read its Dataverse tables for historical
   telemetry instead of reconstructing it.
6. Should Power BI be in scope?
