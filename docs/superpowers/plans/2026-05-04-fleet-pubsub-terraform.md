# Fleet PubSub Terraform Modules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create two Terraform addon modules — `addons/gcp/fleet-pubsub/` (topics + Fleet env vars) and `addons/gcp/pubsub-to-bigquery/` (subscriptions + BQ + Cloud Run) — and wire them into `gcp/main.tf`.

**Architecture:** `fleet-pubsub` is consumer-agnostic: it creates 3 PubSub topics, grants the Fleet Cloud Run service account publisher rights, and outputs the Fleet env vars needed to enable PubSub logging. `pubsub-to-bigquery` takes topic names as input and creates the push subscriptions, BigQuery dataset/tables, Cloud Run ingest service, and all IAM. Both modules are wired together in `gcp/main.tf`.

**Tech Stack:** Terraform ~> 1.11, hashicorp/google >= 6.35.0, Google Cloud PubSub, BigQuery, Cloud Run v2.

---

## File Map

**New files:**
- `addons/gcp/fleet-pubsub/versions.tf` — provider requirements
- `addons/gcp/fleet-pubsub/variables.tf` — project_id, fleet_sa_email, topic name overrides
- `addons/gcp/fleet-pubsub/main.tf` — 3 PubSub topics + publisher IAM bindings
- `addons/gcp/fleet-pubsub/outputs.tf` — topic names + fleet_env_vars map
- `addons/gcp/pubsub-to-bigquery/versions.tf` — provider requirements
- `addons/gcp/pubsub-to-bigquery/variables.tf` — project_id, bq_project_id, region, image, topic names, dataset id
- `addons/gcp/pubsub-to-bigquery/iam.tf` — 2 service accounts + all IAM bindings
- `addons/gcp/pubsub-to-bigquery/main.tf` — push subscriptions, BQ dataset+tables, Cloud Run service
- `addons/gcp/pubsub-to-bigquery/outputs.tf` — bq_dataset_id, service_url

**Modified files:**
- `gcp/main.tf` — add `module "fleet_pubsub"`, `module "pubsub_to_bigquery"`, merge `fleet_env_vars` into Fleet module
- `gcp/variables.tf` — add `pubsub_to_bigquery_image` variable

---

### Task 1: `addons/gcp/fleet-pubsub/` — versions and variables

**Files:**
- Create: `addons/gcp/fleet-pubsub/versions.tf`
- Create: `addons/gcp/fleet-pubsub/variables.tf`

- [ ] **Step 1: Create versions.tf**

```hcl
# addons/gcp/fleet-pubsub/versions.tf
terraform {
  required_version = "~> 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.35.0"
    }
  }
}
```

- [ ] **Step 2: Create variables.tf**

```hcl
# addons/gcp/fleet-pubsub/variables.tf
variable "project_id" {
  description = "GCP project ID where PubSub topics are created"
  type        = string
}

variable "fleet_sa_email" {
  description = "Email of the Fleet Cloud Run service account (fleet-run-sa). Granted pubsub.publisher on all topics."
  type        = string
}

variable "result_topic_name" {
  description = "Name of the PubSub topic for osquery result logs"
  type        = string
  default     = "fleet-result-logs"
}

variable "status_topic_name" {
  description = "Name of the PubSub topic for osquery status logs"
  type        = string
  default     = "fleet-status-logs"
}

variable "audit_topic_name" {
  description = "Name of the PubSub topic for Fleet audit logs"
  type        = string
  default     = "fleet-audit-logs"
}
```

- [ ] **Step 3: Commit**

```bash
git add addons/gcp/fleet-pubsub/versions.tf addons/gcp/fleet-pubsub/variables.tf
git commit -m "feat(fleet-pubsub): add versions and variables"
```

---

### Task 2: `addons/gcp/fleet-pubsub/` — topics, IAM, and outputs

**Files:**
- Create: `addons/gcp/fleet-pubsub/main.tf`
- Create: `addons/gcp/fleet-pubsub/outputs.tf`

- [ ] **Step 1: Create main.tf**

```hcl
# addons/gcp/fleet-pubsub/main.tf
resource "google_pubsub_topic" "result" {
  project = var.project_id
  name    = var.result_topic_name
}

resource "google_pubsub_topic" "status" {
  project = var.project_id
  name    = var.status_topic_name
}

resource "google_pubsub_topic" "audit" {
  project = var.project_id
  name    = var.audit_topic_name
}

resource "google_pubsub_topic_iam_member" "fleet_result_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.result.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.fleet_sa_email}"
}

resource "google_pubsub_topic_iam_member" "fleet_status_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.status.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.fleet_sa_email}"
}

resource "google_pubsub_topic_iam_member" "fleet_audit_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.audit.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.fleet_sa_email}"
}
```

- [ ] **Step 2: Create outputs.tf**

```hcl
# addons/gcp/fleet-pubsub/outputs.tf
output "result_topic_name" {
  description = "Name of the PubSub topic for osquery result logs"
  value       = google_pubsub_topic.result.name
}

output "status_topic_name" {
  description = "Name of the PubSub topic for osquery status logs"
  value       = google_pubsub_topic.status.name
}

output "audit_topic_name" {
  description = "Name of the PubSub topic for Fleet audit logs"
  value       = google_pubsub_topic.audit.name
}

output "fleet_env_vars" {
  description = "Map of Fleet env vars to enable PubSub logging. Merge into fleet_config.extra_env_vars."
  value = {
    FLEET_OSQUERY_RESULT_LOG_PLUGIN = "pubsub"
    FLEET_OSQUERY_STATUS_LOG_PLUGIN = "pubsub"
    FLEET_ACTIVITY_ENABLE_AUDIT_LOG = "true"
    FLEET_PUBSUB_PROJECT            = var.project_id
    FLEET_PUBSUB_RESULT_TOPIC       = google_pubsub_topic.result.name
    FLEET_PUBSUB_STATUS_TOPIC       = google_pubsub_topic.status.name
    FLEET_PUBSUB_AUDIT_TOPIC        = google_pubsub_topic.audit.name
    FLEET_PUBSUB_ADD_ATTRIBUTES     = "true"
  }
}
```

- [ ] **Step 3: Validate module syntax**

```bash
cd addons/gcp/fleet-pubsub && terraform init -backend=false && terraform validate
```

Expected output: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add addons/gcp/fleet-pubsub/main.tf addons/gcp/fleet-pubsub/outputs.tf
git commit -m "feat(fleet-pubsub): add topics, IAM, and outputs"
```

---

### Task 3: `addons/gcp/pubsub-to-bigquery/` — versions and variables

**Files:**
- Create: `addons/gcp/pubsub-to-bigquery/versions.tf`
- Create: `addons/gcp/pubsub-to-bigquery/variables.tf`

- [ ] **Step 1: Create versions.tf**

```hcl
# addons/gcp/pubsub-to-bigquery/versions.tf
terraform {
  required_version = "~> 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.35.0"
    }
  }
}
```

- [ ] **Step 2: Create variables.tf**

```hcl
# addons/gcp/pubsub-to-bigquery/variables.tf
variable "project_id" {
  description = "GCP project ID for PubSub subscriptions and Cloud Run service"
  type        = string
}

variable "bq_project_id" {
  description = "GCP project ID for BigQuery dataset and tables. Defaults to project_id."
  type        = string
  default     = null
}

variable "region" {
  description = "GCP region for Cloud Run service"
  type        = string
  default     = "us-central1"
}

variable "image" {
  description = "Full Artifact Registry image URL and tag for the fleet-pubsub-bq service (e.g. us-central1-docker.pkg.dev/PROJECT/fleet/fleet-pubsub-bq:v1.0.0)"
  type        = string
}

variable "bq_dataset_id" {
  description = "BigQuery dataset ID"
  type        = string
  default     = "fleet_logs"
}

variable "result_topic_name" {
  description = "Name of the PubSub topic for osquery result logs. Use fleet-pubsub module output."
  type        = string
}

variable "status_topic_name" {
  description = "Name of the PubSub topic for osquery status logs. Use fleet-pubsub module output."
  type        = string
}

variable "audit_topic_name" {
  description = "Name of the PubSub topic for Fleet audit logs. Use fleet-pubsub module output."
  type        = string
}

locals {
  bq_project_id            = coalesce(var.bq_project_id, var.project_id)
  result_subscription_name = "${var.result_topic_name}-sub"
  status_subscription_name = "${var.status_topic_name}-sub"
  audit_subscription_name  = "${var.audit_topic_name}-sub"
}
```

- [ ] **Step 3: Commit**

```bash
git add addons/gcp/pubsub-to-bigquery/versions.tf addons/gcp/pubsub-to-bigquery/variables.tf
git commit -m "feat(pubsub-to-bigquery): add versions and variables"
```

---

### Task 4: `addons/gcp/pubsub-to-bigquery/` — IAM

**Files:**
- Create: `addons/gcp/pubsub-to-bigquery/iam.tf`

- [ ] **Step 1: Create iam.tf**

```hcl
# addons/gcp/pubsub-to-bigquery/iam.tf

# Service account used as the Cloud Run service identity.
# Needs BQ dataEditor + jobUser to write rows.
resource "google_service_account" "ingest_sa" {
  project      = var.project_id
  account_id   = "fleet-pubsub-bq-sa"
  display_name = "Fleet PubSub→BQ Ingest Service"
  description  = "Identity for the fleet-pubsub-bq Cloud Run service"
}

# Service account that PubSub uses to generate OIDC tokens for push auth.
resource "google_service_account" "pubsub_invoker_sa" {
  project      = var.project_id
  account_id   = "fleet-pubsub-invoker-sa"
  display_name = "Fleet PubSub Push Invoker"
  description  = "Used by PubSub push subscriptions to authenticate against the ingest Cloud Run service"
}

# Allow PubSub service agent to create OIDC tokens for the invoker SA.
# Required for projects created before April 8, 2021; harmless for newer projects.
resource "google_service_account_iam_member" "pubsub_token_creator" {
  service_account_id = google_service_account.pubsub_invoker_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

data "google_project" "project" {
  project_id = var.project_id
}

# BQ dataEditor on the dataset lets the ingest SA insert rows.
resource "google_bigquery_dataset_iam_member" "ingest_sa_editor" {
  project    = local.bq_project_id
  dataset_id = google_bigquery_dataset.fleet_logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.ingest_sa.email}"
}

# BQ jobUser at project level lets the ingest SA run jobs (needed for streaming inserts).
resource "google_project_iam_member" "ingest_sa_bq_job_user" {
  project = local.bq_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.ingest_sa.email}"
}

# Standard Cloud Run logging
resource "google_project_iam_member" "ingest_sa_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.ingest_sa.email}"
}
```

- [ ] **Step 2: Commit**

```bash
git add addons/gcp/pubsub-to-bigquery/iam.tf
git commit -m "feat(pubsub-to-bigquery): add service accounts and IAM"
```

---

### Task 5: `addons/gcp/pubsub-to-bigquery/` — BigQuery dataset and tables

**Files:**
- Create: `addons/gcp/pubsub-to-bigquery/main.tf` (partial — BQ section)

> Note: This task creates `main.tf` with BQ resources only. Task 6 adds PubSub and Cloud Run to the same file.

- [ ] **Step 1: Create main.tf with BQ dataset and tables**

```hcl
# addons/gcp/pubsub-to-bigquery/main.tf

# -------------------------------------
# BigQuery
# -------------------------------------

resource "google_bigquery_dataset" "fleet_logs" {
  project    = local.bq_project_id
  dataset_id = var.bq_dataset_id
  location   = "US"

  labels = {
    managed-by = "terraform"
    app        = "fleet"
  }
}

resource "google_bigquery_table" "result_logs" {
  project             = local.bq_project_id
  dataset_id          = google_bigquery_dataset.fleet_logs.dataset_id
  table_id            = "result_logs"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "unix_time"
  }

  clustering = ["query_name", "host_identifier"]

  schema = jsonencode([
    { name = "inserted_at",    type = "TIMESTAMP", mode = "REQUIRED", description = "Time the Cloud Run service received the message" },
    { name = "query_name",     type = "STRING",    mode = "REQUIRED", description = "Osquery query name (name field)" },
    { name = "query_id",       type = "INTEGER",   mode = "NULLABLE", description = "Fleet query ID injected by Fleet when query is known" },
    { name = "host_identifier",type = "STRING",    mode = "REQUIRED", description = "Osquery hostIdentifier" },
    { name = "calendar_time",  type = "STRING",    mode = "NULLABLE", description = "Human-readable calendarTime from osquery" },
    { name = "unix_time",      type = "TIMESTAMP", mode = "NULLABLE", description = "unixTime epoch converted to TIMESTAMP" },
    { name = "action",         type = "STRING",    mode = "NULLABLE", description = "snapshot, added, or removed" },
    { name = "epoch",          type = "INTEGER",   mode = "NULLABLE", description = "Schedule epoch marker" },
    { name = "counter",        type = "INTEGER",   mode = "NULLABLE", description = "Execution counter" },
    { name = "host_uuid",      type = "STRING",    mode = "NULLABLE", description = "decorations.host_uuid extracted for easy filtering" },
    { name = "decorations",    type = "STRING",    mode = "NULLABLE", description = "Full decorations map as JSON string" },
    { name = "row",            type = "STRING",    mode = "REQUIRED", description = "One result row as JSON string (one element from snapshot[], or columns, or one diffResults element)" }
  ])
}

resource "google_bigquery_table" "status_logs" {
  project             = local.bq_project_id
  dataset_id          = google_bigquery_dataset.fleet_logs.dataset_id
  table_id            = "status_logs"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "inserted_at"
  }

  clustering = ["severity"]

  schema = jsonencode([
    { name = "inserted_at", type = "TIMESTAMP", mode = "REQUIRED", description = "Time the Cloud Run service received the message" },
    { name = "severity",    type = "INTEGER",   mode = "REQUIRED", description = "0=INFO, 1=WARNING, 2=ERROR" },
    { name = "filename",    type = "STRING",    mode = "NULLABLE", description = "Source file from osquery agent" },
    { name = "line",        type = "INTEGER",   mode = "NULLABLE", description = "Line number in source file" },
    { name = "message",     type = "STRING",    mode = "NULLABLE", description = "Log message" },
    { name = "version",     type = "STRING",    mode = "NULLABLE", description = "Osquery agent version" },
    { name = "host_uuid",   type = "STRING",    mode = "NULLABLE", description = "decorations.host_uuid" },
    { name = "decorations", type = "STRING",    mode = "NULLABLE", description = "Full decorations map as JSON string" }
  ])
}

resource "google_bigquery_table" "audit_logs" {
  project             = local.bq_project_id
  dataset_id          = google_bigquery_dataset.fleet_logs.dataset_id
  table_id            = "audit_logs"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "created_at"
  }

  clustering = ["type", "actor_email"]

  schema = jsonencode([
    { name = "inserted_at",     type = "TIMESTAMP", mode = "REQUIRED", description = "Time the Cloud Run service received the message" },
    { name = "id",              type = "INTEGER",   mode = "NULLABLE", description = "Fleet activity ID" },
    { name = "uuid",            type = "STRING",    mode = "NULLABLE", description = "Fleet activity UUID" },
    { name = "created_at",      type = "TIMESTAMP", mode = "NULLABLE", description = "Fleet activity created_at timestamp" },
    { name = "type",            type = "STRING",    mode = "REQUIRED", description = "Activity type (e.g. created_user, installed_software)" },
    { name = "actor_id",        type = "INTEGER",   mode = "NULLABLE", description = "Fleet user ID (null for automation)" },
    { name = "actor_full_name", type = "STRING",    mode = "NULLABLE", description = "Actor full name" },
    { name = "actor_email",     type = "STRING",    mode = "NULLABLE", description = "Actor email" },
    { name = "actor_api_only",  type = "BOOLEAN",   mode = "NULLABLE", description = "True if actor is an API-only user" },
    { name = "fleet_initiated", type = "BOOLEAN",   mode = "NULLABLE", description = "True if triggered by Fleet automation" },
    { name = "details",         type = "STRING",    mode = "NULLABLE", description = "Full details blob as JSON string — varies by type" }
  ])
}
```

- [ ] **Step 2: Commit**

```bash
git add addons/gcp/pubsub-to-bigquery/main.tf
git commit -m "feat(pubsub-to-bigquery): add BigQuery dataset and tables"
```

---

### Task 6: `addons/gcp/pubsub-to-bigquery/` — Cloud Run service and push subscriptions

**Files:**
- Modify: `addons/gcp/pubsub-to-bigquery/main.tf` (append Cloud Run + subscriptions)

- [ ] **Step 1: Append Cloud Run service and subscriptions to main.tf**

```hcl
# addons/gcp/pubsub-to-bigquery/main.tf (append below BQ resources)

# -------------------------------------
# Cloud Run — ingest service
# -------------------------------------

resource "google_cloud_run_v2_service" "ingest" {
  project             = var.project_id
  name                = "fleet-pubsub-bq"
  location            = var.region
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.ingest_sa.email

    containers {
      image = var.image

      ports {
        container_port = 8080
      }

      env {
        name  = "BQ_PROJECT_ID"
        value = local.bq_project_id
      }
      env {
        name  = "BQ_DATASET_ID"
        value = var.bq_dataset_id
      }
      env {
        name  = "RESULT_SUBSCRIPTION"
        value = local.result_subscription_name
      }
      env {
        name  = "STATUS_SUBSCRIPTION"
        value = local.status_subscription_name
      }
      env {
        name  = "AUDIT_SUBSCRIPTION"
        value = local.audit_subscription_name
      }
    }
  }
}

# Grant the PubSub invoker SA permission to invoke the Cloud Run service.
resource "google_cloud_run_v2_service_iam_member" "pubsub_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.ingest.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.pubsub_invoker_sa.email}"
}

# -------------------------------------
# PubSub push subscriptions
# -------------------------------------

resource "google_pubsub_subscription" "result" {
  project = var.project_id
  name    = local.result_subscription_name
  topic   = var.result_topic_name

  ack_deadline_seconds = 600

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.ingest.uri}/ingest"

    oidc_token {
      service_account_email = google_service_account.pubsub_invoker_sa.email
    }
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  depends_on = [google_cloud_run_v2_service_iam_member.pubsub_invoker]
}

resource "google_pubsub_subscription" "status" {
  project = var.project_id
  name    = local.status_subscription_name
  topic   = var.status_topic_name

  ack_deadline_seconds = 600

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.ingest.uri}/ingest"

    oidc_token {
      service_account_email = google_service_account.pubsub_invoker_sa.email
    }
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  depends_on = [google_cloud_run_v2_service_iam_member.pubsub_invoker]
}

resource "google_pubsub_subscription" "audit" {
  project = var.project_id
  name    = local.audit_subscription_name
  topic   = var.audit_topic_name

  ack_deadline_seconds = 600

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.ingest.uri}/ingest"

    oidc_token {
      service_account_email = google_service_account.pubsub_invoker_sa.email
    }
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  depends_on = [google_cloud_run_v2_service_iam_member.pubsub_invoker]
}
```

- [ ] **Step 2: Create outputs.tf**

```hcl
# addons/gcp/pubsub-to-bigquery/outputs.tf
output "bq_dataset_id" {
  description = "BigQuery dataset ID"
  value       = google_bigquery_dataset.fleet_logs.dataset_id
}

output "service_url" {
  description = "URL of the fleet-pubsub-bq Cloud Run service"
  value       = google_cloud_run_v2_service.ingest.uri
}
```

- [ ] **Step 3: Validate module syntax**

```bash
cd addons/gcp/pubsub-to-bigquery && terraform init -backend=false && terraform validate
```

Expected output: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add addons/gcp/pubsub-to-bigquery/main.tf addons/gcp/pubsub-to-bigquery/outputs.tf
git commit -m "feat(pubsub-to-bigquery): add Cloud Run service and push subscriptions"
```

---

### Task 7: Wire modules into `gcp/main.tf` and `gcp/variables.tf`

**Files:**
- Modify: `gcp/variables.tf`
- Modify: `gcp/main.tf`

- [ ] **Step 1: Add `pubsub_to_bigquery_image` variable to `gcp/variables.tf`**

Add this block at the end of `gcp/variables.tf`:

```hcl
variable "pubsub_to_bigquery_image" {
  description = "Full Artifact Registry image URL and tag for the fleet-pubsub-bq ingest service (e.g. us-central1-docker.pkg.dev/PROJECT/fleet/fleet-pubsub-bq:v1.0.0). Set to null to skip provisioning the pubsub-to-bigquery addon."
  type        = string
  default     = null
}
```

- [ ] **Step 2: Add `fleet_pubsub` module to `gcp/main.tf`**

Add after the `module "okta_conditional_access"` block and before `module "fleet"` in `gcp/main.tf`:

```hcl
# -------------------------------------
# Fleet PubSub Topics
# -------------------------------------

module "fleet_pubsub" {
  source         = "../addons/gcp/fleet-pubsub"
  project_id     = module.project_factory.project_id
  fleet_sa_email = module.fleet.fleet_service_account_email
}
```

- [ ] **Step 3: Add `pubsub_to_bigquery` module to `gcp/main.tf`**

Add immediately after the `fleet_pubsub` module block:

```hcl
# -------------------------------------
# PubSub → BigQuery Pipeline
# -------------------------------------

module "pubsub_to_bigquery" {
  count  = var.pubsub_to_bigquery_image != null ? 1 : 0
  source = "../addons/gcp/pubsub-to-bigquery"

  project_id        = module.project_factory.project_id
  result_topic_name = module.fleet_pubsub.result_topic_name
  status_topic_name = module.fleet_pubsub.status_topic_name
  audit_topic_name  = module.fleet_pubsub.audit_topic_name
  image             = var.pubsub_to_bigquery_image
  region            = var.region
}
```

- [ ] **Step 4: Merge fleet_pubsub env vars into the `module "fleet"` call in `gcp/main.tf`**

Find the existing `module "fleet"` block. It currently has a `fleet_config = merge(...)` expression. Update it to add `module.fleet_pubsub.fleet_env_vars`:

```hcl
module "fleet" {
  source          = "./byo-project"
  project_id      = module.project_factory.project_id
  dns_record_name = var.dns_record_name
  dns_zone_name   = var.dns_zone_name
  vpc_config      = var.vpc_config
  fleet_config    = merge(var.fleet_config, {
    extra_env_vars = merge(
      coalesce(var.fleet_config.extra_env_vars, {}),
      module.fleet_pubsub.fleet_env_vars,
    )
    extra_secret_env_vars = merge(
      coalesce(var.fleet_config.extra_secret_env_vars, {}),
      local.windows_mdm_secret_env_vars,
    )
  })
  cache_config    = var.cache_config
  database_config = var.database_config
  region          = var.region
  location        = var.location

  server_tls_policy              = module.okta_conditional_access.server_tls_policy
  backend_custom_request_headers = [module.okta_conditional_access.client_cert_header]
  okta_subdomain                 = "okta.fleet.campusgroup.co"
}
```

- [ ] **Step 5: Run terraform init and validate in `gcp/`**

```bash
cd gcp && terraform init && terraform validate
```

Expected output: `Success! The configuration is valid.`

- [ ] **Step 6: Run terraform plan to review what will be created**

```bash
cd gcp && terraform plan -var="pubsub_to_bigquery_image=placeholder" 2>&1 | grep -E "will be created|will be updated|# module"
```

Review the plan output. You should see:
- `module.fleet_pubsub` creating 3 topics and 3 IAM bindings
- `module.pubsub_to_bigquery[0]` creating 2 service accounts, IAM bindings, BQ dataset, 3 BQ tables, Cloud Run service, 3 subscriptions

- [ ] **Step 7: Commit**

```bash
git add gcp/main.tf gcp/variables.tf
git commit -m "feat(gcp): wire fleet-pubsub and pubsub-to-bigquery modules"
```

---

### Task 8: Enable required APIs in `gcp/main.tf`

The `pubsub-to-bigquery` addon uses BigQuery and PubSub APIs which may not be enabled in the project factory.

**Files:**
- Modify: `gcp/main.tf`

- [ ] **Step 1: Add missing APIs to the project_factory `activate_apis` list in `gcp/main.tf`**

Find the `activate_apis` list in the `module "project_factory"` block and add:

```hcl
"pubsub.googleapis.com",
"bigquery.googleapis.com",
```

The full list after the edit should include both new entries alongside the existing ones.

- [ ] **Step 2: Validate**

```bash
cd gcp && terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add gcp/main.tf
git commit -m "feat(gcp): enable pubsub and bigquery APIs"
```

---

## Self-Review Checklist

- [x] `fleet-pubsub` creates 3 topics and 3 publisher IAM bindings for Fleet SA
- [x] `fleet-pubsub` outputs `fleet_env_vars` including `FLEET_PUBSUB_ADD_ATTRIBUTES=true`
- [x] `pubsub-to-bigquery` takes topic names as input (consumer-agnostic split)
- [x] `pubsub-to-bigquery` creates BQ dataset + 3 tables with correct partition/cluster fields
- [x] `result_logs` partitioned by `unix_time`, clustered by `query_name`, `host_identifier`
- [x] `status_logs` partitioned by `inserted_at`, clustered by `severity`
- [x] `audit_logs` partitioned by `created_at`, clustered by `type`, `actor_email`
- [x] Push subscriptions use OIDC with `fleet-pubsub-invoker-sa`
- [x] `fleet-pubsub-bq-sa` has `bigquery.dataEditor` + `bigquery.jobUser`
- [x] PubSub service agent gets `serviceAccountTokenCreator` on invoker SA
- [x] `pubsub_to_bigquery_image = null` skips the consumer addon (topics still created)
- [x] `fleet_env_vars` merged into Fleet module `extra_env_vars`
- [x] `pubsub.googleapis.com` and `bigquery.googleapis.com` added to activate_apis
- [x] `module.fleet` references `module.fleet_pubsub` but `fleet_pubsub` doesn't reference `fleet` — no cycle. The `fleet_sa_email` input comes from `module.fleet.fleet_service_account_email` which creates a dependency: fleet SA must exist before fleet_pubsub IAM bindings. Terraform handles this automatically.
