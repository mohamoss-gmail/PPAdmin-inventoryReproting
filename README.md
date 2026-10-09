?# Power Platform tenant reporting tool

A read-only tool a Power Platform Administrator runs from their own workstation to inventory a
tenant and render self-contained HTML reports.

**Status: Phase 1 (collection + findings + HTML report) complete.**

- [USER-GUIDE.md](USER-GUIDE.md) — components, how to run a collection, and the report page by page
- [DESIGN.md](DESIGN.md) — the full design, data sources and report structure

```powershell
.\Invoke-PPCollect.ps1                 # collect and report
.\Invoke-PPCollect.ps1 -Depth Deep     # + per-app sharing, async failure history
.\Invoke-PPCollect.ps1 -RenderOnly     # rebuild the report, zero tenant calls
.\Invoke-PPProbe.ps1                   # Phase 0 capability probe
```

---

## Phase 1: collection

Collects environments (with backups), apps, flows, connections, custom connectors, DLP
policies, Copilot Studio agents, solutions, Dataverse security, and Microsoft Graph identity.
Also collects **credit and capacity consumption** from the Licensing API -- Copilot Studio
credits, AI Builder credits and every other currency meter -- attributed to the agent, app or
flow that burned them and to the user who drove it, plus optional **Azure pay-as-you-go cost**.
Where the per-agent route is refused by role, a downloaded PPAC consumption report can be imported
instead (`-UsageReport`), joined to the same inventory and clearly marked as imported.
Resolves owner GUIDs to people, runs the findings engine, writes a twelve-page HTML report.

**Depth** controls cost: `Quick` (tenant + assets only), `Standard` (adds Dataverse and Graph,
the default), `Deep` (adds per-app sharing resolution and 7-day async failure history).
Usage collection runs at every depth unless `-SkipUsage`; `-IncludeAzureCost` adds the Azure
money figure, and needs Azure RBAC that Power Platform Administrator does not grant.

**Collection and rendering are decoupled.** Raw JSON lands in `runs/<timestamp>/raw/data.json`
before anything renders, so `-RenderOnly` rebuilds the report in seconds without re-collecting.
That matters because collection is the slow, throttled, permission-dependent half — and it
means iterating on the report is a 2-second loop, not a 15-minute one.

### The findings engine

Everything else is a table dump; this is the payload. 40 rules across Security, Governance,
Continuity, ALM, Reliability, Compliance, Cost and Hygiene — each finding carrying the record
that produced it, why it matters, and the fix. Highlights:

- Agents reachable **cross-tenant** or **anonymously**, or with authentication disabled
- **Autonomous agents** (external trigger) — escalated when combined with weak access control
- Agents permitted to answer from **general model knowledge** rather than approved sources
- Apps shared with the **entire tenant**; assets owned by **disabled or deleted accounts**
- Environments with **no DLP coverage**, **no restore points**, or **no security group**
- **Service principals holding System Administrator**; expired or expiring credentials
- Unmanaged solutions and agents authored directly in production
- Environments running agents with **no pay-as-you-go billing policy**, or covered by a
  **disabled** one — the cliff where overage enforcement takes agents offline
- Credit meters **in overage** or inside 10% of their limit; storage capacity nearly full
- A **single agent driving most of a meter** — the cheapest thing to tune before buying capacity
- Credits burned by **departed accounts** or by **resource IDs matching nothing in inventory**
- **No spend threshold configured** on a meter that is actively consuming
- Credit attribution **refused by role** — reported as a visibility finding, because "we cannot
  tell you which agent spent this" is itself worth escalating

Production-only rules deliberately exempt Developer, Trial, Teams and Sandbox environments.

---

## Why Phase 0 exists

Several of the things an admin most wants to report on — backups, disaster recovery posture,
environment groups, agent usage — sit behind APIs that are either version-sensitive or, in a few
cases, not confirmed to exist publicly at all. Equally, whether a tenant admin can actually *read*
any given environment's Dataverse is inconsistent in practice.

Rather than bake guesses into collectors and discover the gaps later, the probe asks the tenant
directly and produces a report of what is genuinely collectable. Phase 1 collectors are then
written only against confirmed routes.

## Running it

```powershell
.\Invoke-PPProbe.ps1
```

Common options:

```powershell
.\Invoke-PPProbe.ps1 -TenantId contoso.onmicrosoft.com -MaxEnvironments 25
.\Invoke-PPProbe.ps1 -SkipTranscripts      # agents only, no conversation data
.\Invoke-PPProbe.ps1 -SkipDataverse        # tenant-level surface only, fastest
```

One interactive device-code sign-in. Tokens for every other audience (Power Platform API, Graph,
and each Dataverse org) are obtained silently by refresh, so you are not prompted per environment.

Output lands in `runs/<timestamp>-probe/`:

| File | Contents |
|---|---|
| `probe-report.html` | The report. Self-contained, no CDN, opens automatically |
| `raw/probe.json` | Everything collected, for diffing or feeding Phase 1 |
| `probe.log` | NDJSON run log |

### Requirements

- Windows PowerShell 5.1 (present) — PowerShell 7 recommended for Phase 1 parallelism
- Power Platform Administrator (or Global Admin)
- No app registration and no module installs required for the probe itself

### Optional, for fuller coverage

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser   # unified audit log = app usage
winget install Microsoft.PowerShell                          # PowerShell 7
```

## What the probe answers

- Which API audiences issue tokens to this operator
- Whether the uncertain `api.powerplatform.com` routes (backups, DR, environment groups, agent
  consumption) exist — and at which `api-version`
- Whether Dataverse is reachable **per environment**, table by table
- Whether Copilot Studio agents are readable, plus a preview of the risky ones: anonymous access,
  no authentication, cross-tenant reachable, missing licence, unmanaged in production
- Whether conversation transcripts are readable, and **the real retention** — measured from the
  oldest surviving row, not assumed from the 30-day default
- Whether Graph can resolve owner GUIDs to people (without it, orphaned-asset detection is impossible)

Each capability comes with a stated consequence: what the final report gains or loses.

## The read-only guarantee

Everything is a `GET`. The HTTP client refuses any other verb before opening a socket, and the
test suite asserts it. The only `POST` in the codebase is the token exchange with
`login.microsoftonline.com`, which is credential exchange rather than tenant data — also asserted.

Every request issued during a run is recorded and printed in a "collection integrity" section at
the foot of the report, so a security team can verify exactly what was touched before approving a
production run.

## Tests

```powershell
.\tests\Test-PPProbe.ps1      # 27 tests - read-only guarantee, probe rendering
.\tests\Test-PPCollect.ps1    # 54 tests - findings rules, report rendering
```

81 offline tests. No tenant, network or credentials required.

The Phase 1 fixture is built to trip specific rules, so a regression fails loudly instead of
silently reporting a clean tenant — the most dangerous failure mode this tool has. It also
asserts the negative cases: developer environments must stay exempt from production-only rules,
and a DLP-covered environment must not be flagged.

## Known gap: POST-only read operations

Tenant settings (environment-creation restrictions, sharing limits) are exposed only as
`POST /providers/Microsoft.BusinessAppPlatform/listtenantsettings`. It is semantically a read,
but it is a POST, and this tool refuses POST by design — so tenant settings are currently
**uncollectable** and reported as a gap on the Integrity page rather than quietly omitted.

Resolving it means either accepting the gap or widening the guarantee to a narrow, published
allowlist of documented read-only POST operations. That is a deliberate decision, not an
oversight.

## Handling sensitive output

The report maps the governance and security posture of the tenant and should be treated as
confidential. It carries a banner saying so.

Note in particular that Copilot Studio conversation transcripts contain verbatim user
conversation text. The probe reads only counts and timestamps and never persists transcript
content — a constraint Phase 3 must preserve when it starts deriving usage metrics.

## Layout

```
Invoke-PPProbe.ps1          entry point
src/Core/                   auth (device code + cross-resource refresh), read-only HTTP, logging
src/Probe/                  platform APIs, PPAC candidate routes, Dataverse, identity
src/Collect/                tenant, environments, assets, Dataverse, identity, usage, Azure cost,
                            PPAC report import
src/Analyze/                the findings engine
src/Render/                 HTML renderer
tests/                      offline tests
runs/                       output, one directory per run
```

Phase 1 grows into this skeleton rather than replacing it: `src/Collect/` alongside `src/Probe/`,
with the same HTTP client, auth and run-directory conventions.

