terraform {
  required_version = "~> 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.35.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = ">= 3.0.2"
    }
  }
}

provider "google" {
  # Credentials used here need Org/Folder level permissions
  default_labels = var.labels
}

provider "docker" {
  registry_auth {
    address     = "us-central1-docker.pkg.dev"
    config_file = pathexpand("~/.docker/config.json")
  }
}


module "project_factory" {
  source  = "terraform-google-modules/project-factory/google"
  version = "~> 18.0.0"

  name              = var.project_name
  random_project_id = var.random_project_id
  org_id            = var.org_id
  billing_account   = var.billing_account_id

  default_service_account = "delete"

  # Enable baseline APIs needed by most projects + your app stack
  activate_apis = [
    "compute.googleapis.com",
    "sqladmin.googleapis.com",
    "redis.googleapis.com",
    "run.googleapis.com",
    "vpcaccess.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "servicenetworking.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "memorystore.googleapis.com",
    "serviceconsumermanagement.googleapis.com",
    "networkconnectivity.googleapis.com",
    "networksecurity.googleapis.com",
    "certificatemanager.googleapis.com",
    "dataflow.googleapis.com",
    "pubsub.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudscheduler.googleapis.com"
  ]

  labels = var.labels
}

# -------------------------------------
# Google Calendar Integration
# -------------------------------------

resource "google_service_account" "fleet_calendar" {
  project      = module.project_factory.project_id
  account_id   = "fleet-calendar-events"
  display_name = "Fleet Calendar Events"
  description  = "Service account for Fleet to create calendar events for end users with failing policies"
}

resource "google_service_account_key" "fleet_calendar" {
  service_account_id = google_service_account.fleet_calendar.name
}

resource "google_secret_manager_secret" "fleet_calendar_key" {
  project   = module.project_factory.project_id
  secret_id = "fleet-calendar-service-account-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "fleet_calendar_key" {
  secret      = google_secret_manager_secret.fleet_calendar_key.name
  secret_data = base64decode(google_service_account_key.fleet_calendar.private_key)
}

output "fleet_calendar_service_account_key_json" {
  description = "Google Calendar service account key JSON — set this as FLEET_GOOGLE_CALENDAR_SERVICE_ACCOUNT_KEY in GitHub Actions secrets"
  value       = base64decode(google_service_account_key.fleet_calendar.private_key)
  sensitive   = true
}

# -------------------------------------
# Windows MDM WSTEP Secrets
# -------------------------------------

resource "google_secret_manager_secret" "mdm_wstep_cert" {
  project   = module.project_factory.project_id
  secret_id = "fleet-mdm-wstep-identity-cert"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "mdm_wstep_cert" {
  secret                 = google_secret_manager_secret.mdm_wstep_cert.name
  secret_data_wo         = var.windows_mdm_wstep_identity_cert
  secret_data_wo_version = 2
}

resource "google_secret_manager_secret" "mdm_wstep_key" {
  project   = module.project_factory.project_id
  secret_id = "fleet-mdm-wstep-identity-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "mdm_wstep_key" {
  secret                 = google_secret_manager_secret.mdm_wstep_key.name
  secret_data_wo         = var.windows_mdm_wstep_identity_key
  secret_data_wo_version = 2
}

locals {
  windows_mdm_secret_env_vars = {
    FLEET_MDM_WINDOWS_WSTEP_IDENTITY_CERT_BYTES = {
      secret  = google_secret_manager_secret.mdm_wstep_cert.secret_id
      version = "latest"
    }
    FLEET_MDM_WINDOWS_WSTEP_IDENTITY_KEY_BYTES = {
      secret  = google_secret_manager_secret.mdm_wstep_key.secret_id
      version = "latest"
    }
  }
}

# -------------------------------------
# Okta Conditional Access
# -------------------------------------

module "okta_conditional_access" {
  source                  = "../addons/gcp/okta-conditional-access"
  project_id              = module.project_factory.project_id
  ca_certificate_pem_file = "${path.module}/resources/conditional-ca.pem"
  fleet_domain            = "fleet.campusgroup.co"
}

# -------------------------------------
# Pub/Sub Logging Destination
# -------------------------------------

module "logging_destination_pubsub" {
  source     = "../addons/gcp/logging-destination-pubsub"
  project_id = module.project_factory.project_id
  labels     = var.labels

  add_attributes                   = true
  create_publisher_service_account = false
}

resource "google_pubsub_topic_iam_member" "fleet_run_sa_publisher" {
  for_each = module.logging_destination_pubsub.topic_names

  project = module.project_factory.project_id
  topic   = each.value
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${module.fleet.fleet_service_account_email}"
}

module "fleet" {
  source          = "./byo-project"
  project_id      = module.project_factory.project_id
  dns_record_name = var.dns_record_name
  dns_zone_name   = var.dns_zone_name
  vpc_config      = var.vpc_config
  fleet_config = merge(var.fleet_config, {
    # Pin to the pushed manifest digest, not the tag. The kreuzwerker/docker
    # provider pushes the manifest before the tag reference settles, so a
    # tag-based reference would race; the digest output is published only
    # after the push is fully complete.
    image_tag = module.geolite2.image_digest
    extra_env_vars = merge(
      coalesce(var.fleet_config.extra_env_vars, {}),
      module.logging_destination_pubsub.fleet_extra_environment_variables,
      module.geolite2.extra_environment_variables,
    )
    extra_secret_env_vars = merge(
      coalesce(var.fleet_config.extra_secret_env_vars, {}),
      local.windows_mdm_secret_env_vars,
    )
  })
  # OTel env vars only on the Cloud Run services — not on the migration job.
  # The job runs as a Cloud Run Job (no sidecars), so localhost:4317 has no
  # listener and the exporter would log retry errors during the brief job run.
  service_only_env_vars = local.fleet_otel_env_vars
  sidecar_containers    = [local.datadog_sidecar]

  cache_config    = var.cache_config
  database_config = var.database_config
  region          = var.region
  location        = var.location

  server_tls_policy              = module.okta_conditional_access.server_tls_policy
  backend_custom_request_headers = [module.okta_conditional_access.client_cert_header]
  okta_subdomain                 = "okta.fleet.campusgroup.co"
}

# -------------------------------------
# Pub/Sub → Datadog Logs (Dataflow) — REMOVED 2026-05-30 (cost)
# -------------------------------------
# The 3 streaming Cloud_PubSub_to_Datadog Dataflow jobs were removed because
# they each pinned ≥1 n1-standard-2 worker (~$50/mo idle, ~$150/mo floor) and
# the log volume didn't justify it. Removed along with their supporting infra:
# the dataflow-staging bucket + UDF objects, the dataflow-pubsub-to-datadog
# worker SA and its IAM, the per-topic deadletter topics, the pull
# subscriptions, and the datadog-api-key secret.
#
# The logging_destination_pubsub module (Fleet's log topics) is intentionally
# kept — Fleet still publishes to those topics, and a consumer can be
# re-attached later. Cloud Run telemetry (traces/metrics/logs) still flows to
# Datadog via the DDOT sidecar in datadog.tf.
#
# To restore, see git history for this block (commit before 2026-05-30).

# -------------------------------------
# GeoLite2 Custom Fleet Image
# -------------------------------------
# Builds a Fleet image with MaxMind GeoLite2-City baked in, pushes to a
# dedicated Artifact Registry repo, and overrides fleet_config.image_tag
# so Cloud Run pulls the geo-enabled image instead of the upstream one.
#
# The MaxMind license is stored in Secret Manager (sourced from
# var.maxmind_license_key) so the Cloud Build refresh trigger can fetch
# it monthly without re-running Terraform.

locals {
  fleet_upstream_image = var.fleet_config.image_tag
  fleet_geolite2_image = "${google_artifact_registry_repository.fleet.location}-docker.pkg.dev/${module.project_factory.project_id}/${google_artifact_registry_repository.fleet.repository_id}/fleet-geolite2:${replace(local.fleet_upstream_image, "/.*:/", "")}"
}

resource "google_artifact_registry_repository" "fleet" {
  project       = module.project_factory.project_id
  location      = var.region
  repository_id = "fleet"
  format        = "DOCKER"
  description   = "Custom Fleet images (GeoLite2-enabled)"
  labels        = var.labels
}

resource "google_artifact_registry_repository_iam_member" "fleet_run_sa_reader" {
  project    = google_artifact_registry_repository.fleet.project
  location   = google_artifact_registry_repository.fleet.location
  repository = google_artifact_registry_repository.fleet.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${module.fleet.fleet_service_account_email}"
}

module "geolite2" {
  source            = "../addons/geolite2"
  fleet_image       = local.fleet_upstream_image
  destination_image = local.fleet_geolite2_image
  license_key       = var.maxmind_license_key

  depends_on = [google_artifact_registry_repository.fleet]
}

resource "google_secret_manager_secret" "maxmind_license_key" {
  project   = module.project_factory.project_id
  secret_id = "maxmind-license-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "maxmind_license_key" {
  secret      = google_secret_manager_secret.maxmind_license_key.name
  secret_data = var.maxmind_license_key
}

# -------------------------------------
# Monthly GeoLite2 Refresh via Cloud Build
# -------------------------------------

resource "google_service_account" "geolite2_refresh" {
  project      = module.project_factory.project_id
  account_id   = "geolite2-refresh"
  display_name = "GeoLite2 image refresh"
  description  = "Service account Cloud Scheduler uses to trigger monthly GeoLite2 image rebuilds"
}

resource "google_secret_manager_secret_iam_member" "geolite2_refresh_secret_access" {
  project   = google_secret_manager_secret.maxmind_license_key.project
  secret_id = google_secret_manager_secret.maxmind_license_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:service-${module.project_factory.project_number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
}

resource "google_artifact_registry_repository_iam_member" "cloudbuild_writer" {
  project    = google_artifact_registry_repository.fleet.project
  location   = google_artifact_registry_repository.fleet.location
  repository = google_artifact_registry_repository.fleet.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${module.project_factory.project_number}@cloudbuild.gserviceaccount.com"
}

resource "google_project_iam_member" "geolite2_refresh_run_builds" {
  project = module.project_factory.project_id
  role    = "roles/cloudbuild.builds.editor"
  member  = "serviceAccount:${google_service_account.geolite2_refresh.email}"
}

resource "google_project_iam_member" "geolite2_refresh_service_account_user" {
  project = module.project_factory.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.geolite2_refresh.email}"
}

# Build config that Cloud Scheduler submits each month. Fetches the
# Dockerfile inline so we don't need a source repo for it.
locals {
  geolite2_build_payload = jsonencode({
    steps = [
      {
        name       = "gcr.io/cloud-builders/docker"
        entrypoint = "bash"
        args = [
          "-c",
          <<-EOT
            cat > Dockerfile <<'DOCKERFILE'
            ARG FLEET_IMAGE
            FROM $${FLEET_IMAGE}
            ARG LICENSE_KEY
            USER root
            RUN mkdir -p /opt/GeoLite2 && cd /opt/GeoLite2 && \
                wget "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=$${LICENSE_KEY}&suffix=tar.gz" -O GeoLite2-City.tar.gz && \
                wget "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=$${LICENSE_KEY}&suffix=tar.gz.sha256" -O GeoLite2-City.tar.gz.sha256 && \
                [ "$$(awk '{ print $$1 }' GeoLite2-City.tar.gz.sha256)" = "$$(sha256sum GeoLite2-City.tar.gz | awk '{ print $$1 }')" ] && \
                (tar -xzvf GeoLite2-City.tar.gz "*/GeoLite2-City.mmdb" --strip-components 1 2>/dev/null || true) && \
                rm -f GeoLite2-City.tar.gz*
            USER fleet
            CMD ["fleet", "serve"]
            DOCKERFILE
            docker build \
              --build-arg FLEET_IMAGE=${local.fleet_upstream_image} \
              --build-arg LICENSE_KEY="$$(cat /workspace/license_key)" \
              -t ${local.fleet_geolite2_image} \
              -t ${replace(local.fleet_geolite2_image, "/:[^:]+$/", ":latest")} \
              .
            docker push ${local.fleet_geolite2_image}
            docker push ${replace(local.fleet_geolite2_image, "/:[^:]+$/", ":latest")}
          EOT
        ]
        secretEnv = ["LICENSE_KEY"]
      }
    ]
    availableSecrets = {
      secretManager = [
        {
          versionName = "projects/${module.project_factory.project_id}/secrets/${google_secret_manager_secret.maxmind_license_key.secret_id}/versions/latest"
          env         = "LICENSE_KEY"
        }
      ]
    }
    options = {
      logging = "CLOUD_LOGGING_ONLY"
    }
  })
}

resource "google_cloud_scheduler_job" "geolite2_refresh" {
  project     = module.project_factory.project_id
  region      = var.region
  name        = "geolite2-refresh"
  description = "Rebuild Fleet GeoLite2 image on the first of each month (MaxMind license requires monthly refresh)."
  schedule    = "0 6 1 * *" # 06:00 UTC on the 1st
  time_zone   = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://cloudbuild.googleapis.com/v1/projects/${module.project_factory.project_id}/builds"
    headers = {
      "Content-Type" = "application/json"
    }
    body = base64encode(local.geolite2_build_payload)
    oauth_token {
      service_account_email = google_service_account.geolite2_refresh.email
    }
  }

  depends_on = [
    google_project_iam_member.geolite2_refresh_run_builds,
    google_project_iam_member.geolite2_refresh_service_account_user,
    google_secret_manager_secret_iam_member.geolite2_refresh_secret_access,
    google_artifact_registry_repository_iam_member.cloudbuild_writer,
  ]
}
