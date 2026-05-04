# Fleet PubSub → BigQuery Pipeline — Design Spec

**DRAFT** — 2026-05-04

## Overview

Fleet publishes osquery result logs, osquery status logs, and audit logs to three Google Cloud PubSub topics. This pipeline consumes those topics via PubSub push subscriptions and writes the data to BigQuery for analytics and compliance purposes.

Direct PubSub → BigQuery subscriptions are not viable because the message shape changes per-message (especially result logs, where the query result columns vary per query). A Cloud Run service handles transformation.

---

## Repositories

### `fleet-terraform` (this repo)
Terraform-only. Provisions all GCP infrastructure: PubSub topics, push subscriptions, BigQuery dataset and tables, Cloud Run service, IAM, and Fleet env var wiring via the `addons/gcp/pubsub-to-bigquery/` module.

### `campus-it/fleet-pubsub-bq` (new repo)
Go service + Dockerfile + CI. Builds versioned Docker images pushed to Artifact Registry. Image tags are referenced by the Terraform module's `image` variable.

---

## Architecture

```
Fleet (Cloud Run, gcp/byo-project)
  │
  ├── FLEET_PUBSUB_RESULT_TOPIC ──► fleet-result-logs (PubSub topic)
  ├── FLEET_PUBSUB_STATUS_TOPIC ──► fleet-status-logs (PubSub topic)
  └── FLEET_PUBSUB_AUDIT_TOPIC  ──► fleet-audit-logs  (PubSub topic)
                                          │
                              3 push subscriptions
                              (OIDC auth via fleet-pubsub-invoker-sa)
                                          │
                                          ▼
                              fleet-pubsub-bq (Cloud Run service)
                              POST /ingest
                                          │
                              route by subscription name
                                          │
                    ┌─────────────────────┼──────────────────────┐
                    ▼                     ▼                      ▼
             result handler        status handler          audit handler
             (explode snapshot)    (typed columns)         (typed envelope)
                    │                     │                      │
                    └─────────────────────┴──────────────────────┘
                                          │
                                          ▼
                              BigQuery dataset: fleet_logs
                              Tables: result_logs, status_logs, audit_logs
```

---

## Message Schemas (Source)

### Result Logs

Fleet publishes osquery result logs as-is, with a `query_id` field injected by Fleet when the query is known. Two sub-formats exist:

**Snapshot format** (periodic full table dump):
```json
{
  "name": "pack/Global/process_snapshot",
  "hostIdentifier": "hostname.local",
  "calendarTime": "Mon May  2 22:27:32 2016 UTC",
  "unixTime": 1462228052,
  "epoch": 314159265,
  "counter": 1,
  "numerics": false,
  "decorations": { "host_uuid": "abc-123", "hostname": "macbook.local" },
  "action": "snapshot",
  "snapshot": [
    { "pid": "1", "path": "/sbin/launchd", "parent": "0" },
    { "pid": "97", "path": "/usr/sbin/syslogd", "parent": "1" }
  ],
  "query_id": 42
}
```

**Differential/event format** (one row per event):
```json
{
  "name": "pack/Global/process_events",
  "hostIdentifier": "hostname.local",
  "calendarTime": "Tue Sep 30 17:37:30 2014",
  "unixTime": 1412123850,
  "action": "added",
  "columns": { "pid": "97830", "name": "osqueryd", "path": "/opt/osquery/bin/osqueryd" },
  "decorations": { "host_uuid": "abc-123" },
  "query_id": 42
}
```

**Batch differential format** (less common):
```json
{
  "name": "pack/Global/processes",
  "diffResults": {
    "added": [{ "pid": "1", "name": "launchd" }],
    "removed": [{ "pid": "99", "name": "old" }]
  },
  "hostIdentifier": "hostname.local",
  "unixTime": 1412123850
}
```

The `snapshot[]` and `columns` objects have arbitrary keys per query — this is the variable schema problem.

### Status Logs

Fixed schema. Emitted by the osquery agent for diagnostics.

```json
{
  "severity": "0",
  "filename": "tls.cpp",
  "line": "216",
  "message": "some message",
  "version": "1.8.2",
  "decorations": { "host_uuid": "uuid_foobar", "username": "zwass" }
}
```

`severity`: `"0"` = INFO, `"1"` = WARNING, `"2"` = ERROR.

### Audit Logs

Fixed envelope, variable `details` blob per activity `type`. Fleet Premium feature.

```json
{
  "id": 123,
  "uuid": "abc-def-456",
  "created_at": "2024-01-15T10:30:00Z",
  "type": "created_user",
  "actor_id": 5,
  "actor_full_name": "Robbie Trencheny",
  "actor_email": "robbie@campus.edu",
  "actor_gravatar": "https://gravatar.com/...",
  "actor_api_only": false,
  "fleet_initiated": false,
  "details": { "user_id": 99, "user_email": "new@campus.edu" }
}
```

---

## BigQuery Layout

**Dataset:** `fleet_logs` (default, overridable via `bq_dataset_id` variable).  
By default lives in the Fleet GCP project; overridable to a separate analytics project via `bq_project_id`.

### Table: `result_logs`

One BQ row per result row (snapshot array exploded). This avoids large JSON cells and keeps row sizes consistent.

| Column | Type | Notes |
|---|---|---|
| `inserted_at` | TIMESTAMP | Cloud Run ingestion time |
| `query_name` | STRING | `name` field |
| `query_id` | INTEGER | `query_id` injected by Fleet (nullable) |
| `host_identifier` | STRING | `hostIdentifier` |
| `calendar_time` | STRING | `calendarTime` (human-readable, kept as string) |
| `unix_time` | TIMESTAMP | `unixTime` converted from epoch seconds |
| `action` | STRING | `snapshot`, `added`, or `removed` |
| `epoch` | INTEGER | `epoch` |
| `counter` | INTEGER | `counter` |
| `host_uuid` | STRING | `decorations.host_uuid` extracted for easy filtering |
| `decorations` | STRING | Full `decorations` map as JSON string |
| `row` | STRING | One result row as JSON string — one element from `snapshot[]`, or `columns`, or one element from `diffResults.added/removed` |

**Partitioned** by `unix_time` (DAY). **Clustered** by `query_name`, `host_identifier`.

### Table: `status_logs`

Fully typed — fixed schema.

| Column | Type | Notes |
|---|---|---|
| `inserted_at` | TIMESTAMP | Cloud Run ingestion time |
| `severity` | INTEGER | 0=INFO, 1=WARNING, 2=ERROR |
| `filename` | STRING | Source file from osquery agent |
| `line` | INTEGER | Line number |
| `message` | STRING | Log message |
| `version` | STRING | osquery agent version |
| `host_uuid` | STRING | `decorations.host_uuid` |
| `decorations` | STRING | Full `decorations` map as JSON string |

**Partitioned** by `inserted_at` (DAY). **Clustered** by `severity`.

### Table: `audit_logs`

Typed envelope, JSON `details` blob.

| Column | Type | Notes |
|---|---|---|
| `inserted_at` | TIMESTAMP | Cloud Run ingestion time |
| `id` | INTEGER | Fleet activity ID |
| `uuid` | STRING | Fleet activity UUID |
| `created_at` | TIMESTAMP | `created_at` from Fleet |
| `type` | STRING | Activity type (e.g. `created_user`, `installed_software`) |
| `actor_id` | INTEGER | Fleet user ID (nullable for automation) |
| `actor_full_name` | STRING | Nullable |
| `actor_email` | STRING | Nullable |
| `actor_api_only` | BOOLEAN | Nullable |
| `fleet_initiated` | BOOLEAN | True if triggered by automation/cron |
| `details` | STRING | Full `details` blob as JSON string — varies by `type` |

**Partitioned** by `created_at` (DAY). **Clustered** by `type`, `actor_email`.

---

## Cloud Run Service (`campus-it/fleet-pubsub-bq`)

### Repository Structure

```
fleet-pubsub-bq/
  cmd/server/main.go           - HTTP server, env config, BQ client init
  internal/handler/
    handler.go                 - /ingest endpoint, subscription routing
    result.go                  - result log transform + BQ write
    status.go                  - status log transform + BQ write
    audit.go                   - audit log transform + BQ write
  Dockerfile
  .github/workflows/
    build.yml                  - build + push to Artifact Registry on tag
```

### Handler Logic

1. Receive `POST /ingest` from PubSub push subscription
2. Cloud Run validates OIDC token automatically (via `fleet-pubsub-invoker-sa`)
3. Parse PubSub envelope: `{ "message": { "data": "<base64>", "attributes": {...} }, "subscription": "..." }`
4. Base64-decode `message.data` to get raw Fleet JSON
5. Inspect `subscription` field to route: result / status / audit handler
6. Handler unmarshals JSON, transforms to BQ row(s)
7. Write to BQ via streaming insert (`tabledata.insertAll`)
8. Return `HTTP 200` on success → PubSub acks message
9. Return `HTTP 500` on BQ write failure → PubSub retries with exponential backoff

### Result Handler Detail

- If `action == "snapshot"`: iterate `snapshot[]`, emit one BQ row per element with `row = JSON(element)`
- If `action == "added"` or `"removed"`: emit one BQ row with `row = JSON(columns)`
- If `diffResults` present: iterate `diffResults.added` (action=`"added"`) and `diffResults.removed` (action=`"removed"`), emit one row per element
- Extract `decorations.host_uuid` into `host_uuid` column for all formats

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | HTTP listen port |
| `BQ_PROJECT_ID` | (required) | BigQuery project ID |
| `BQ_DATASET_ID` | `fleet_logs` | BigQuery dataset ID |
| `RESULT_SUBSCRIPTION` | (required) | Full PubSub subscription name for routing |
| `STATUS_SUBSCRIPTION` | (required) | Full PubSub subscription name for routing |
| `AUDIT_SUBSCRIPTION` | (required) | Full PubSub subscription name for routing |

Authentication to BigQuery uses Application Default Credentials (the Cloud Run service identity `fleet-pubsub-bq-sa`).

---

## Terraform Module (`addons/gcp/pubsub-to-bigquery/`)

### Files

```
addons/gcp/pubsub-to-bigquery/
  main.tf        - PubSub topics, subscriptions, BQ dataset+tables, Cloud Run service
  iam.tf         - service accounts, IAM bindings
  variables.tf   - inputs
  outputs.tf     - topic names, dataset ID, service URL
```

### Resources

| Resource | Type | Notes |
|---|---|---|
| `fleet-result-logs` | `google_pubsub_topic` | |
| `fleet-status-logs` | `google_pubsub_topic` | |
| `fleet-audit-logs` | `google_pubsub_topic` | |
| `fleet-result-logs-sub` | `google_pubsub_subscription` | push → Cloud Run `/ingest`, OIDC auth |
| `fleet-status-logs-sub` | `google_pubsub_subscription` | push → Cloud Run `/ingest`, OIDC auth |
| `fleet-audit-logs-sub` | `google_pubsub_subscription` | push → Cloud Run `/ingest`, OIDC auth |
| `fleet_logs` | `google_bigquery_dataset` | |
| `result_logs` | `google_bigquery_table` | partitioned + clustered |
| `status_logs` | `google_bigquery_table` | partitioned + clustered |
| `audit_logs` | `google_bigquery_table` | partitioned + clustered |
| `fleet-pubsub-bq` | `google_cloud_run_v2_service` | runs `fleet-pubsub-bq` image |
| `fleet-pubsub-bq-sa` | `google_service_account` | Cloud Run identity, BQ dataEditor |
| `fleet-pubsub-invoker-sa` | `google_service_account` | PubSub push auth, Cloud Run invoker |

### Key Variables

```hcl
variable "project_id"              {}  # Fleet GCP project (required)
variable "bq_project_id"           {}  # BQ project, defaults to project_id
variable "region"                  { default = "us-central1" }
variable "image"                   {}  # Artifact Registry image URL + tag (required)
variable "bq_dataset_id"           { default = "fleet_logs" }
variable "result_topic_name"       { default = "fleet-result-logs" }
variable "status_topic_name"       { default = "fleet-status-logs" }
variable "audit_topic_name"        { default = "fleet-audit-logs" }
```

### Wiring into `gcp/main.tf`

```hcl
module "pubsub_to_bigquery" {
  source     = "../addons/gcp/pubsub-to-bigquery"
  project_id = module.project_factory.project_id
  image      = "us-central1-docker.pkg.dev/PROJECT/fleet/fleet-pubsub-bq:v1.0.0"
}
```

Fleet Cloud Run gets these added to `extra_env_vars` by merging the module outputs into `fleet_config.extra_env_vars` in `gcp/main.tf`:

```hcl
module "fleet" {
  ...
  fleet_config = merge(var.fleet_config, {
    extra_env_vars = merge(
      coalesce(var.fleet_config.extra_env_vars, {}),
      {
        FLEET_OSQUERY_RESULT_LOG_PLUGIN = "pubsub"
        FLEET_OSQUERY_STATUS_LOG_PLUGIN = "pubsub"
        FLEET_ACTIVITY_ENABLE_AUDIT_LOG = "true"
        FLEET_PUBSUB_PROJECT            = module.project_factory.project_id
        FLEET_PUBSUB_RESULT_TOPIC       = module.pubsub_to_bigquery.result_topic_name
        FLEET_PUBSUB_STATUS_TOPIC       = module.pubsub_to_bigquery.status_topic_name
        FLEET_PUBSUB_AUDIT_TOPIC        = module.pubsub_to_bigquery.audit_topic_name
      }
    )
  })
}
```

### Outputs

```hcl
output "result_topic_name"  { value = google_pubsub_topic.result.name }
output "status_topic_name"  { value = google_pubsub_topic.status.name }
output "audit_topic_name"   { value = google_pubsub_topic.audit.name }
output "bq_dataset_id"      { value = google_bigquery_dataset.fleet_logs.dataset_id }
output "service_url"        { value = google_cloud_run_v2_service.ingest.uri }
```

---

## IAM Summary

| Principal | Resource | Role |
|---|---|---|
| `fleet-pubsub-bq-sa` | BQ dataset `fleet_logs` | `roles/bigquery.dataEditor` |
| `fleet-pubsub-bq-sa` | BQ project | `roles/bigquery.jobUser` |
| `fleet-pubsub-invoker-sa` | Cloud Run service `fleet-pubsub-bq` | `roles/run.invoker` |
| PubSub service agent | `fleet-pubsub-invoker-sa` | `roles/iam.serviceAccountTokenCreator` |
| `fleet-run-sa` (existing Fleet SA) | PubSub topics | `roles/pubsub.publisher` |

---

## Error Handling

- **BQ write failure**: return HTTP 500 → PubSub retries with exponential backoff (up to subscription's `ack_deadline`, default 600s)
- **Malformed message**: log error, return HTTP 200 to avoid infinite retry loop on unprocessable messages
- **Unknown subscription**: log error, return HTTP 200 (same reason)
- **Oversized message**: Fleet already drops messages > 10MB at the PubSub publish layer

---

## CI/CD

`campus-it/fleet-pubsub-bq` GitHub Actions workflow:
- On push to `main`: build image, push to Artifact Registry with `sha-<commit>` tag
- On tag `v*`: additionally push with the version tag
- Terraform in `fleet-terraform` references a pinned version tag — image updates require a Terraform variable update and apply

---

## Open Questions

None — all design decisions resolved during brainstorming.
