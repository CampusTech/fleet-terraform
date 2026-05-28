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
    image_tag = local.fleet_geolite2_image
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
  cache_config    = var.cache_config
  database_config = var.database_config
  region          = var.region
  location        = var.location

  server_tls_policy              = module.okta_conditional_access.server_tls_policy
  backend_custom_request_headers = [module.okta_conditional_access.client_cert_header]
  okta_subdomain                 = "okta.fleet.campusgroup.co"
}

# -------------------------------------
# Pub/Sub → Datadog Logs (Dataflow)
# -------------------------------------
# One streaming Dataflow job per Fleet log topic, using Google's published
# Cloud_PubSub_to_Datadog classic template. Each job reads from its own
# pull subscription and posts to the Datadog Logs intake. Failures go to a
# per-topic deadletter topic.
#
# The Datadog API key is fetched from Secret Manager at job runtime; the
# secret resource is created here but the version must be added out-of-band:
#
#   echo -n "$DD_API_KEY" | gcloud secrets versions add datadog-api-key \
#     --project=campus-fleet-5c43 --data-file=-
#
# The 3 streaming jobs each pin ≥1 n1-standard-2 worker (~$50/mo idle).

locals {
  # Template only accepts PROTOCOL://HOST[:PORT] — it appends the /api/v2/logs path itself.
  datadog_logs_url   = "https://http-intake.logs.us5.datadoghq.com"
  datadog_log_topics = module.logging_destination_pubsub.topic_names
}

resource "google_secret_manager_secret" "datadog_api_key" {
  project   = module.project_factory.project_id
  secret_id = "datadog-api-key"
  replication {
    auto {}
  }
}

resource "google_storage_bucket_object" "datadog_udf" {
  for_each = local.datadog_log_topics

  name    = "udf/${each.key}.js"
  bucket  = google_storage_bucket.dataflow_staging.name
  content = templatefile("${path.module}/resources/udf.js.tftpl", { log_stream = each.key })
}

resource "google_storage_bucket" "dataflow_staging" {
  project                     = module.project_factory.project_id
  name                        = "${module.project_factory.project_id}-dataflow-staging"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_service_account" "dataflow_datadog" {
  project      = module.project_factory.project_id
  account_id   = "dataflow-pubsub-to-datadog"
  display_name = "Dataflow Pub/Sub → Datadog"
  description  = "Worker SA for the Dataflow jobs forwarding Fleet log topics to Datadog"
}

resource "google_project_iam_member" "dataflow_datadog_worker" {
  project = module.project_factory.project_id
  role    = "roles/dataflow.worker"
  member  = "serviceAccount:${google_service_account.dataflow_datadog.email}"
}

# The Dataflow service agent (Google-managed) launches jobs using the worker
# SA's identity. It needs serviceAccountUser on the worker SA to do that.
resource "google_service_account_iam_member" "dataflow_service_agent_uses_worker" {
  service_account_id = google_service_account.dataflow_datadog.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:service-${module.project_factory.project_number}@dataflow-service-producer-prod.iam.gserviceaccount.com"
}

# Required: the Dataflow service agent needs serviceAccountTokenCreator on the
# worker SA in the v1beta3+ Dataflow runner.
resource "google_service_account_iam_member" "dataflow_service_agent_token_creator" {
  service_account_id = google_service_account.dataflow_datadog.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${module.project_factory.project_number}@dataflow-service-producer-prod.iam.gserviceaccount.com"
}

resource "google_storage_bucket_iam_member" "dataflow_datadog_staging" {
  bucket = google_storage_bucket.dataflow_staging.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.dataflow_datadog.email}"
}

resource "google_secret_manager_secret_iam_member" "dataflow_datadog_secret_access" {
  project   = google_secret_manager_secret.datadog_api_key.project
  secret_id = google_secret_manager_secret.datadog_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.dataflow_datadog.email}"
}

# Dead-letter topic per source topic for messages Datadog rejects repeatedly.
resource "google_pubsub_topic" "datadog_deadletter" {
  for_each = local.datadog_log_topics

  project = module.project_factory.project_id
  name    = "${each.value}-datadog-deadletter"
  labels  = var.labels
}

resource "google_pubsub_topic_iam_member" "datadog_deadletter_publisher" {
  for_each = google_pubsub_topic.datadog_deadletter

  project = each.value.project
  topic   = each.value.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.dataflow_datadog.email}"
}

# Pull subscription per topic — Dataflow consumes from these.
resource "google_pubsub_subscription" "datadog_input" {
  for_each = local.datadog_log_topics

  project = module.project_factory.project_id
  name    = "${each.value}-datadog"
  topic   = each.value
  labels  = var.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s" # 7 days

  expiration_policy {
    ttl = "" # never expire
  }
}

resource "google_pubsub_subscription_iam_member" "datadog_input_subscriber" {
  for_each = google_pubsub_subscription.datadog_input

  project      = each.value.project
  subscription = each.value.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.dataflow_datadog.email}"
}

resource "google_dataflow_job" "pubsub_to_datadog" {
  for_each = local.datadog_log_topics

  project           = module.project_factory.project_id
  region            = var.region
  name              = "pubsub-to-datadog-${each.key}"
  template_gcs_path = "gs://dataflow-templates-${var.region}/latest/Cloud_PubSub_to_Datadog"
  temp_gcs_location = "gs://${google_storage_bucket.dataflow_staging.name}/tmp/${each.key}"

  service_account_email = google_service_account.dataflow_datadog.email
  on_delete             = "cancel"
  machine_type          = "n1-standard-2"
  max_workers           = 3

  # Run workers in the Fleet VPC so they share the existing Cloud NAT path
  # (workers have no external IPs; egress to Datadog goes through fleet-vpc-nat).
  network          = module.fleet.vpc_network_name
  subnetwork       = "regions/${var.region}/subnetworks/${module.fleet.vpc_subnets_names[0]}"
  ip_configuration = "WORKER_IP_PRIVATE"

  parameters = {
    inputSubscription                            = google_pubsub_subscription.datadog_input[each.key].id
    url                                          = local.datadog_logs_url
    apiKeySource                                 = "SECRET_MANAGER"
    apiKeySecretId                               = "projects/${module.project_factory.project_id}/secrets/${google_secret_manager_secret.datadog_api_key.secret_id}/versions/latest"
    outputDeadletterTopic                        = google_pubsub_topic.datadog_deadletter[each.key].id
    includePubsubMessage                         = "true"
    batchCount                                   = "100"
    parallelism                                  = "4"
    javascriptTextTransformGcsPath               = "gs://${google_storage_bucket.dataflow_staging.name}/${google_storage_bucket_object.datadog_udf[each.key].name}"
    javascriptTextTransformFunctionName          = "process"
    javascriptTextTransformReloadIntervalMinutes = "60"
  }

  labels = var.labels

  depends_on = [
    google_pubsub_subscription_iam_member.datadog_input_subscriber,
    google_pubsub_topic_iam_member.datadog_deadletter_publisher,
    google_secret_manager_secret_iam_member.dataflow_datadog_secret_access,
    google_storage_bucket_iam_member.dataflow_datadog_staging,
    google_project_iam_member.dataflow_datadog_worker,
  ]
}

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
