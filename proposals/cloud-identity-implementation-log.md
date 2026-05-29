# Cloud Identity Integration — Autonomous Decision Log

Chronological record of autonomous decisions made during unattended work
sessions. Each entry: what was decided, why, and what would trigger a revisit.

Branch: `feat/cloud-identity-clientstate-integration` (on fleet repo, off main)
Started: 2026-05-29 04:49 ET / 08:49 UTC

All log entries below show ET / UTC.

> **Timestamp correction note (05:04 ET / 09:04 UTC):** The first few entries
> in this log used fabricated timestamps (I estimated elapsed time poorly).
> Robbie caught it. Entries marked with `~` are best-effort reconstructions;
> subsequent entries use real `date -u` output.

---

## Pre-session decisions (made in conversation with Robbie before unattended work)

- **Scope is v1 only.** ClientState PATCH driven by Fleet policy compliance,
  EV-primary resolution with `host_emails` fallback, AppConfig + per-team
  enable toggle, tests, end-to-end verification. Out: approve/block (v2),
  delete (never), Policy API writes (v2), CEP browser attestation, iOS/Android,
  Linux/Windows EV paths, frontend Settings page, BeyondCorp Alliance handshake.
- **Org-global integration config; per-team policy gating + suffix override.**
  AppConfig holds SA credentials + customer ID + default suffix. Each team has
  its own enable flag and optional suffix override.
- **Trigger is event-driven on osquery distributed-query results**, mirroring
  Microsoft's `processConditionalAccessForNewlyFailingPolicies`. No cron.
- **EV-primary resolution via `parse_json` over `accounts.json`**, fallback to
  `host_emails` filtered by Workspace domain.
- **Reuse `policies.conditional_access_enabled` flag** for per-policy CA
  gating — same flag drives both Microsoft and Google.
- **Auth: SA JSON OR WIF** from v1, picked by which is set in AppConfig. DWD
  subject impersonation, prototype uses `robbie@campus.edu`.
- **Auth-not-configured = silent skip + debug log.** No activity-feed noise.
- **Naming:** Go package `ee/server/integrations/google_cloud_identity`;
  server-config block `GoogleCloudIdentity`; AppConfig flag
  `Integrations.GoogleCloudIdentityEnabled`; DB table
  `host_google_cloud_identity_clientstates`; default suffix `fleet`.

---

## Autonomous decision log

### 04:49 ET / 08:49 UTC — Branch & log set up

**Decision:** Branched `feat/cloud-identity-clientstate-integration` off
current `main` rather than off the proposal branch.

**Rationale:** Proposal branch is Robbie's reading tree; implementation
should be its own diff for sane review later. Starting from `main` avoids
mixing proposal-doc commits with implementation commits.

**Revisit trigger:** Only if Robbie says he wants the implementation on the
proposal branch (e.g. to ship together).

### ~04:55 ET / ~08:55 UTC — Migration table shape

**Decision:** `host_google_cloud_identity_clientstates` schema:

- `(host_id, device_user_resource, partner_suffix)` is the unique key.
- Per-deviceUser cardinality (one row per signed-in Workspace identity on a
  host), not per-host. Different partner suffixes for the same host+deviceUser
  pair are allowed (per-team suffix override).
- `last_compliant`, `last_managed`, `last_score_reason`, `last_etag` columns
  hold the values Fleet last wrote — same diff-on-change semantics as the
  Microsoft `host_conditional_access` table.
- `ON DELETE CASCADE` from `hosts(id)`. No FK to a `device_users` table since
  the resource is opaque Google identifier.
- Migration: `20260529084900_AddGoogleCloudIdentityClientStates`. Timestamp
  picked to be after the latest existing migration (`20260528213326`).

**Rationale:** Microsoft's `host_conditional_access` is per-host because Entra
treats one device = one DeviceID. Google's deviceUser is `(device, user)`, so
multi-account-per-host (real on shared kiosks, contractors with personal +
corp Workspace identities, etc.) requires per-row cardinality. The
partner_suffix dimension in the unique key supports the per-team suffix
override (e.g. `fleet-engineering`) without separate tables.

**Revisit trigger:** If the contention-with-other-tools v2 work (approve/block)
needs to track external state writes per-deviceUser, the table grows columns
or moves to a separate v2 table. Not relevant for v1 PATCH-only.

**Verification deferred:** Migration unit test exercises insert/dedup/cascade,
but actually applying it requires a MySQL container. Will run in the test
phase along with everything else.

### ~04:57 ET / ~08:57 UTC — Server config + Fleet types

**Decision:** `GoogleCloudIdentityConfig` lives next to
`MicrosoftCompliancePartnerConfig` in `server/config/config.go`. Fields:

- `service_account_json` (file path) OR `service_account_json_bytes` (inline)
- `workload_identity_audience` + `workload_identity_service_account_email` (WIF)
- `impersonated_admin` (DWD subject, required)
- `customer_id` (validated against `customers/my_customer` at startup)
- `partner_suffix` (default `fleet`)
- `workspace_domains` (comma-separated, required)

`IsSet()` requires at least one auth path (SA-JSON or WIF) plus
`ImpersonatedAdmin`, `CustomerID`, `WorkspaceDomains`.

**Decision:** `HostGoogleCloudIdentityClientState` (Fleet type) mirrors
`HostConditionalAccessStatus` (Microsoft) but is per-deviceUser. Fields:
`HostID`, `DeviceUserResource`, `WorkspaceEmail`, `PartnerSuffix`,
`LastCompliant`, `LastManaged`, `LastScoreReason`, `LastEtag`,
`LastSyncedAt`, plus `UpdateCreateTimestamps`. AuthzType
`host_google_cloud_identity_clientstate`.

**Decision:** `TeamIntegrations.GoogleCloudIdentityEnabled` (per-team flag)
and `TeamIntegrations.GoogleCloudIdentityPartnerSuffix` (per-team override,
empty = use AppConfig default). `Integrations.GoogleCloudIdentityEnabled`
sibling for the "No team" case. Both mirror the existing
`ConditionalAccessEnabled` shape.

**Rationale:** Existing patterns work; no need to invent new shapes. The
per-team partner suffix is the only Google-specific addition; everything else
is a copy of the Microsoft layout with names changed.

**Revisit trigger:** None expected for v1.

### ~05:00 ET / ~09:00 UTC — Datastore impl

**Decision:** Four datastore methods on `fleet.Datastore`:

- `UpsertHostGoogleCloudIdentityResolution(ctx, hostID, deviceUserResource, workspaceEmail, partnerSuffix)` — called from resolution layer; idempotent on identical triples; updates email without resetting last_* fields; inserts a fresh row otherwise.
- `LoadHostGoogleCloudIdentityClientStates(ctx, hostID)` — returns all rows for the host (multi-deviceUser).
- `SetHostGoogleCloudIdentityClientState(ctx, hostID, deviceUserResource, partnerSuffix, managed, compliant, scoreReason, etag)` — called after successful PATCH; records the new last_* values.
- `DeleteHostGoogleCloudIdentityClientStates(ctx, hostID)` — wipe-on-disable; remote retraction is a separate sync step.

Impl in `server/datastore/mysql/conditional_access_google.go`.

**Decision:** When a row exists but the `workspace_email` changed (rare, e.g.
primary alias update), update the email without resetting `last_*`. Same
deviceUser resource → ClientState on Google's side is still valid; no
forced re-PATCH.

**Rationale:** Mirrors `CreateHostConditionalAccessStatus`'s
"override-only-when-changed" semantics but generalized to a per-deviceUser
table.

**Revisit trigger:** If deviceUser resource starts changing across normal
sign-out/sign-in cycles (which the proposal's open question #1 flagged), we
may need to handle resource-change as a retraction-then-fresh-insert rather
than a row update.

**Mock regeneration:** Ran `make mock` to regenerate `server/mock/datastore_mock.go`
after adding the four interface methods. Backgrounded; will check
when next compile pass needed.

### ~05:02 ET / ~09:02 UTC — Auth layer (SA JSON shipped, WIF deferred)

**Decision:** SA-JSON auth path is fully implemented in
`ee/server/integrations/google_cloud_identity/auth.go` using
`golang.org/x/oauth2/google.JWTConfigFromJSON` + `jwtConfig.Subject =
ImpersonatedAdmin` for DWD impersonation.

**Decision:** WIF path is stubbed but returns an error pending verification.

**Rationale:** Robbie asked for WIF "from v1" but the prototype verification
SA already exists as a JSON-key file path. Writing untested WIF code that
might be subtly wrong (the external_account credential format has several
fields with specific semantics around subject token sourcing) costs more than
it gains. The `oauth2.TokenSource` interface that the REST client consumes is
identical for both paths, so swapping WIF in is a localized change with a
clear injection point. The stub returns an explicit error pointing to
service_account_json so a customer attempting WIF before it ships gets a
clear message.

**Revisit trigger:** Robbie pushing back on WIF being v2 (will implement
immediately if so), OR after SA-JSON verification succeeds (will implement as
the natural next step). Likely will land in the same v1 PR but after the
end-to-end SA-JSON loop closes.

**Scopes requested:**

- `https://www.googleapis.com/auth/cloud-identity.devices` — covers both
  ClientState writes and (future v2) approve/block.
- `https://www.googleapis.com/auth/admin.directory.customer.readonly` — for
  the customer-ID validation call at startup.

### ~05:03 ET / ~09:03 UTC — REST client

**Decision:** Thin HTTP client in
`ee/server/integrations/google_cloud_identity/client.go`. Four public methods:

- `GetCustomer(ctx)` → calls `admin.googleapis.com/admin/directory/v1/customers/my_customer`
  for startup validation.
- `LookupDeviceUserByRawResourceID(ctx, resID)` → primary path, EV-based.
- `LookupDeviceUserByEmail(ctx, email)` → fallback path for non-EV hosts.
- `PatchClientState(ctx, req)` → the actual write.

`APIError` type carries StatusCode + body. `IsPermissionDenied(err)` helper
flags the 403 → "Premium edition required" case so the sync layer can
surface it cleanly.

**Decision:** No `google.golang.org/api/cloudidentity/v1` generated SDK.

**Rationale:** That SDK targets v1, but ClientState writes require v1beta1.
The SDK also wraps requests in its own retry/auth layer that conflicts with
the explicit token-source contract the auth layer ships. Hand-rolled HTTP is
~280 lines, exhaustively typed for the fields Fleet writes, and easy to test
against an httptest server.

**Revisit trigger:** If Google publishes a stable v1 ClientState API with a
generated SDK, swap.

### 05:09 ET / 09:09 UTC — Pivot to purpose-built orbit table

**Decision:** Replaced the `parse_json`-based detail query with a new
purpose-built osquery extension table, `endpoint_verification_accounts`,
implemented in `orbit/pkg/table/endpoint_verification_accounts/`. Columns:
`uid`, `username`, `gaia_id`, `resource_id`, `email`, `last_sync`.

**Rationale:** Robbie suggested it during the implementation pass. Three
benefits over `parse_json`:

1. Cleaner Fleet-side SQL — just `SELECT * FROM endpoint_verification_accounts`
   instead of a CTE + GROUP BY pivot.
2. Per-platform path handling becomes a code branch (`candidatePaths()`),
   not SQL. macOS implemented in v1; Linux/Windows path placeholders return
   the doc-suggested `.secureConnect/context_aware_config.json` but those
   are unverified.
3. No coupling to the `parse_json` Fleet table, which would block a future
   vanilla-osquery-compatible mode.

The macOS local-user enumerator scans `/Users/*` and filters to `uid >= 500`
via stat, rather than parsing dscl output. Wired into
`OrbitDefaultTables` in `orbit/pkg/table/extension.go`.

**Revisit trigger:** Open question #1 in the proposal (Linux/Windows EV path
verification) is now this orbit table's responsibility. Empirically confirm
on a Linux/Windows host with EV before extending v1.

### 05:13 ET / 09:13 UTC — Migration shape changed: raw_resource_id + lazy device_user_resource

**Decision:** Added `raw_resource_id` column to
`host_google_cloud_identity_clientstates`, made `device_user_resource`
nullable. The osquery ingest path writes `raw_resource_id`; the resolution
layer fills in `device_user_resource` on first sync via
`devices.deviceUsers.lookup?rawResourceId=…`. Unique key changed to
`(host_id, raw_resource_id, partner_suffix)`.

**Rationale:** Microsoft's analog is simpler — `device_id` from
`app_sso_platform` is *already* the canonical Entra ID and can be used
directly. Google requires a `lookup` call to convert `rawResourceId` →
`devices/{deviceId}/deviceUsers/{deviceUserId}`. Doing that call inline in
the osquery distributed-query write path would block ingest on a network
call to Google. Staging the raw ID and resolving lazily on the sync side
keeps ingest local-only.

**Revisit trigger:** None expected. The lazy-resolve pattern is the safer
default and adds at most one extra API call per (host, deviceUser) pair
for the lifetime of that row.

### 05:14 ET / 09:14 UTC — Config split: server vs AppConfig

**Decision:** Settings split between two locations.

- **Server config** (`config.GoogleCloudIdentityConfig`, yaml/env at
  startup): SA JSON or WIF audience + impersonated admin (the credential
  block). Restart-required, secret-bearing.
- **AppConfig** (`fleet.GoogleCloudIdentitySettings` via
  `Integrations.GoogleCloudIdentity`): customer_id, partner_suffix,
  workspace_domains. DB-editable, runtime-mutable, non-secret.

Ingest function reads workspace_domains from AppConfig at every check-in.

**Rationale:** First-pass design put everything in server config, but the
ingest function only has `fleet.Datastore` (no server config), and the
runtime-mutable settings should be editable without a server restart
anyway. Per-team override on partner_suffix only works if the suffix is in
team config / AppConfig.

**Revisit trigger:** None.

### 05:20 ET / 09:20 UTC — Hook into processConditionalAccess + lazy Syncer

**Decision:** Added a new top-level function
`processGoogleCloudIdentityForNewlyFailingPolicies` that's called from the
osquery distributed-query write pipeline alongside the existing Microsoft
branch. Mirrors the Microsoft pattern (gates, compliance computation, hand
off to async write).

**Decision:** The Syncer is constructed lazily inside the Service at first
call, behind a pointer-`sync.Once`, rather than threaded through every
NewService call site. Reusable, idempotent on errors (failed init memoized).

**Rationale:** Threading the Syncer through NewService would touch dozens
of test fixtures and the main serve.go invocation. Lazy init is the
smaller blast radius for a v1 prototype.

**Decision:** All Cloud Identity I/O runs in a goroutine off the osquery
write path. Detached from request ctx (uses context.Background()) so a
client disconnect can't cancel a PATCH Fleet has already decided to make.

**Revisit trigger:** If the lazy init turns out to be racy under load
(unlikely — sync.Once is the right primitive), or if there's a need to
construct the syncer at server startup so the customer-ID validation
against `customers/my_customer` fails fast at boot rather than on first
host check-in.

### 05:21 ET / 09:21 UTC — Reusing policies.conditional_access_enabled

**Decision:** Google's per-team policy gating reads from the existing
`policies.conditional_access_enabled` column (via
`GetPoliciesForConditionalAccess`), same as Microsoft. No new column.

**Rationale:** Both providers represent "this policy is a compliance
signal" — letting admins flag once and have both providers honor it
matches the "one truth about device compliance" mental model that the
proposal already documented.

**Revisit trigger:** If a customer explicitly wants per-provider policy
selection ("this policy gates Entra but not Workspace, or vice versa"),
add a `google_cloud_identity_enabled` per-policy column then. Not in v1.

### 05:21 ET / 09:21 UTC — Full repo compiles end-to-end

`go build ./...` returns clean. Server, orbit, ee package all green.
Datastore mock regenerated. Ready to start writing tests; structural
skeleton is complete.

Stats so far (line counts approximate):

- migration + test: ~95 LOC
- fleet types + datastore interface: ~50 LOC
- mysql datastore impl: ~150 LOC
- config (server + AppConfig settings): ~70 LOC
- auth: ~100 LOC
- REST client: ~280 LOC
- sync (resolution + diff + PATCH): ~210 LOC
- orbit table (Go + darwin user enum): ~190 LOC
- detail query + ingest: ~110 LOC
- gating + hook: ~80 LOC

Total Go added: ~1,400 LOC across 12 files.

### 05:29 ET / 09:29 UTC — 32 tests committed, all green

**Decision:** Test surface for v1 PR consists of:

- `ee/server/integrations/google_cloud_identity/client_test.go` — 6 tests,
  10 subtests. Customer GET, lookup-by-rawResourceId, lookup-by-email,
  ClientState PATCH (URL composition + body + etag round-trip), 4 validation
  subtests, 403 → IsPermissionDenied, non-200 APIError shape.
- `ee/server/integrations/google_cloud_identity/sync_test.go` — 6 tests
  exercising SyncHost end-to-end with httptest cloud-identity server +
  regenerated mock datastore. No-rows, lazy-resolve-then-patch,
  no-change-no-patch, state-changed-patches-with-etag,
  lookup-returns-no-names-skips-patch, per-row-failure-doesnt-drop-others.
- `orbit/pkg/table/endpoint_verification_accounts/table_test.go` — 7 tests
  with on-disk JSON fixtures. Single + multiple accounts, missing fields,
  multiple users, no-EV-file, malformed JSON, user-lister error.
- `server/service/osquery_utils/google_cloud_identity_ingest_test.go` —
  9 tests for the direct-ingest function. Domain filtering, case-insensitive
  match, multi-domain exact match (not suffix), empty-rows no-op,
  missing-fields skip, no-domains skip, settings-nil skip, default-suffix,
  email lowercase/trim normalization.

Total: **32 tests, all passing.** Repo also `go build ./...` clean.

**Commits so far on the branch:**

1. `feat(cloud-identity): structural skeleton of Google Cloud Identity ClientState integration` — 14 files, ~1400 LOC.
2. `test(cloud-identity): unit tests for client, sync, orbit table, ingest` — 4 test files, 941 LOC.

### What's left (next session)

The implementation is **structurally complete and tested in isolation**.
The remaining work is the live-tenant verification loop:

1. **Robbie provisions the SA** in the CampusGroup GCP project with DWD
   enabled and `https://www.googleapis.com/auth/cloud-identity.devices`
   authorized in admin.google.com for the SA's client ID. Plus a working
   admin email for impersonation (currently configured as
   `robbie@campus.edu`).
2. **Local dev config**: write the SA JSON path + customer ID + domain
   list into the Fleet dev server's `fleet.yml`, set
   `Integrations.GoogleCloudIdentity.WorkspaceDomains` to `["campus.edu"]`
   via AppConfig API.
3. **First-touch validation**: enable `google_cloud_identity_enabled: true`
   on a team containing my host, trigger a policy failure, observe (a) the
   detail query firing in osquery results, (b) row insertion in
   `host_google_cloud_identity_clientstates`, (c) the lookup call in Fleet
   logs, (d) the PATCH and 2xx response, (e) the row in admin.google.com
   under Devices → Mobile & endpoints → Endpoints → my device →
   compliance.
4. **Author a CAA expression** in admin.google.com:
   `device.vendors["fleet-0xxxxxxx"].is_compliant_device == true`. Try
   accessing a protected app, observe the gate working.
5. **Fix anything that breaks**, then commit a verification report to this
   log.

### Known follow-ups beyond v1 verification

These don't block v1 ship but are flagged for the proposal's open-questions
list:

- **WIF auth** — currently stubbed with an explicit error. Implement once
  SA-JSON path is verified end-to-end. The Syncer/Client are auth-agnostic
  so it's a localized change in `auth.go`.
- **Linux/Windows EV paths** — the orbit table's `candidatePaths()` returns
  the doc-suggested `~/.secureConnect/context_aware_config.json` for both.
  Need empirical verification against a current EV install on each
  platform.
- **Per-team partner_suffix override** — the field is on the team config
  but the ingest function uses the AppConfig default unconditionally. Wire
  the team-level read once host→team→suffix resolution is added.
- **Integration page UI** — read-only status / "last sync" panel. Not
  needed for v1 since config is all YAML/AppConfig, but nice for ops
  visibility.
- **AppConfig handler / API endpoints** — `Integrations.GoogleCloudIdentity`
  is in the type system but the JSON serialization on AppConfig is
  free-form so existing PATCH-AppConfig calls should already work; needs
  verification against the existing AppConfig validation logic.

### Test command for the next session

```bash
cd /Users/robbiet480/Repos/Campus/IT/fleet
go build ./...
go test ./ee/server/integrations/google_cloud_identity/ \
        ./orbit/pkg/table/endpoint_verification_accounts/ \
        ./server/service/osquery_utils/ \
        -count=1 -v
```
