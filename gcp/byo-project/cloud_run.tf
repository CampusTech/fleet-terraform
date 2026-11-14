
locals {
  # --- Shared Container Configuration ---
  fleet_image_tag = var.fleet_config.image_tag
  fleet_resources_limits = {
    cpu    = var.fleet_config.fleet_cpu
    memory = var.fleet_config.fleet_memory
  }
  fleet_secrets_env_vars = merge(var.fleet_config.extra_secret_env_vars, {
    FLEET_MYSQL_PASSWORD = {
      secret  = google_secret_manager_secret.database_password.secret_id
      version = "latest"
    },
    FLEET_SERVER_PRIVATE_KEY = {
      secret  = local.fleet_private_key_secret_name
      version = "latest"
    },
    FLEET_S3_SOFTWARE_INSTALLERS_SECRET_ACCESS_KEY = {
      secret  = google_secret_manager_secret.hmac_secret.secret_id
      version = "latest"
    },
    FLEET_S3_CARVES_SECRET_ACCESS_KEY = {
      secret  = google_secret_manager_secret.hmac_secret.secret_id
      version = "latest"
    }
  })
  fleet_env_vars = merge(var.fleet_config.extra_env_vars, {
    FLEET_LICENSE_KEY                       = var.fleet_config.license_key
    FLEET_SERVER_FORCE_H2C                  = var.fleet_config.use_h2c
    FLEET_MYSQL_PROTOCOL                    = "tcp"
    FLEET_MYSQL_ADDRESS                     = "${module.mysql.private_ip_address}:3306"
    FLEET_MYSQL_USERNAME                    = var.database_config.database_user
    FLEET_MYSQL_DATABASE                    = var.database_config.database_name
    FLEET_MYSQL_MAX_OPEN_CONNS              = tostring(var.fleet_config.mysql_max_open_conns)
    FLEET_MYSQL_MAX_IDLE_CONNS              = tostring(var.fleet_config.mysql_max_idle_conns)
    FLEET_MYSQL_TLS_CONFIG                  = var.fleet_config.mysql_tls_config
    FLEET_REDIS_ADDRESS                     = "${module.memstore.host}:${module.memstore.port}"
    FLEET_REDIS_USE_TLS                     = "false"
    FLEET_UPGRADES_ALLOW_MISSING_MIGRATIONS = "1"
    FLEET_LOGGING_JSON                      = "true"
    FLEET_LOGGING_DEBUG                     = var.fleet_config.debug_logging
    FLEET_SERVER_TLS                        = "false"
    # Software installers (also stores software title icons and MDM
    # bootstrap packages under hard-coded sub-prefixes).
    FLEET_S3_SOFTWARE_INSTALLERS_BUCKET              = google_storage_bucket.software_installers.id
    FLEET_S3_SOFTWARE_INSTALLERS_ACCESS_KEY_ID       = google_storage_hmac_key.key.access_id
    FLEET_S3_SOFTWARE_INSTALLERS_ENDPOINT_URL        = "https://storage.googleapis.com"
    FLEET_S3_SOFTWARE_INSTALLERS_FORCE_S3_PATH_STYLE = "true"
    FLEET_S3_SOFTWARE_INSTALLERS_REGION              = var.region
    # Hand clients a presigned GCS URL instead of streaming installer /
    # in-house app / bootstrap package bytes through Fleet. The GCLB in front
    # of Cloud Run severs any response stream at 100s, which failed every
    # installer larger than ~100MB (the Okta Verify pkg). Presigning needs the
    # https storage.googleapis.com endpoint + HMAC creds set above.
    FLEET_S3_SOFTWARE_INSTALLERS_SIGNED_URL = "true"
    # File carves. Reuses the same HMAC key — one key per service account
    # covers every GCS bucket in the project.
    FLEET_S3_CARVES_BUCKET              = google_storage_bucket.carves.id
    FLEET_S3_CARVES_ACCESS_KEY_ID       = google_storage_hmac_key.key.access_id
    FLEET_S3_CARVES_ENDPOINT_URL        = "https://storage.googleapis.com"
    FLEET_S3_CARVES_FORCE_S3_PATH_STYLE = "true"
    FLEET_S3_CARVES_REGION              = var.region
    # Allow user-authored DDM declarations of type
    # com.apple.configuration.softwareupdate.enforcement.specific so we can
    # pin iPad Zoom Rooms to a specific iPadOS target version with a hard
    # deadline (built-in ipados_updates always targets Apple's latest, which
    # blocked Setup Assistant on factory-fresh iPads). Side-effect: also
    # un-blocks custom FileVault2 / FDEFileVaultOptions mobileconfig
    # payloads, but we only use Fleet's built-in enable_disk_encryption on
    # every fleet, so there is no conflict today.
    FLEET_MDM_ENABLE_CUSTOM_OS_UPDATES_AND_FILEVAULT = "true"
  })
  # fleet_env_vars is the safe baseline that works in any execution context.
  # The migration job uses it directly (Cloud Run Job, no sidecars, no OTLP
  # endpoint). The services layer service_only_env_vars on top (fleet-api via
  # the lifecycle module's service_env) — that's where things like OTel
  # exporter endpoints live, which the job can't reach.
  fleet_service_env_vars = merge(local.fleet_env_vars, var.service_only_env_vars)
  fleet_bulk_env_vars = merge(local.fleet_service_env_vars, {
    FLEET_SERVER_FORCE_H2C = "true"
  })

  # Literal: the lifecycle module's stop/restore REST calls address the
  # service by name before the service resource is applied.
  fleet_service_name = "fleet-api"

  fleet_vpc_network_id = module.vpc.network_id
  # Use the subnet name from vpc_config variable
  fleet_vpc_subnet_id = var.vpc_config.subnets[0].subnet_name

  sidecar_container_names = [for c in var.sidecar_containers : c.container_name]
}

# The database and user created by the sql-db module are not module outputs.
# This ordering-only node waits for the whole module (instance, database,
# user) and is fed into the lifecycle prerequisites, so the migration job and
# the service never run before them. It never triggers a migration.
resource "terraform_data" "fleet_database_ready" {
  depends_on = [module.mysql]
}

# --- Fleet service + provider-only migration lifecycle ---
# Adopts main's module.fleet-service in place, declares scaling_mode directly,
# and replaces the fixed-name google_cloud_run_v2_job.fleet_migration_job and
# terracurl_request.exec trigger. See modules/fleet-lifecycle.
# Apply path: providers only.
module "fleet_lifecycle" {
  source = "./modules/fleet-lifecycle"

  project_id   = var.project_id
  region       = var.region
  service_name = local.fleet_service_name

  # The image tag is not secret; fleet_config is marked sensitive as a whole.
  image                 = nonsensitive(local.fleet_image_tag)
  service_account_email = google_service_account.fleet_run_sa.email
  encryption_key        = local.cmek_cloud_run_key_id
  vpc_network           = local.fleet_vpc_network_id
  vpc_subnetwork        = local.fleet_vpc_subnet_id
  ingress               = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  request_timeout       = "300s"
  use_h2c               = nonsensitive(var.fleet_config.use_h2c)
  cpu                   = local.fleet_resources_limits.cpu
  memory                = local.fleet_resources_limits.memory
  env                   = local.fleet_env_vars
  secret_env            = local.fleet_secrets_env_vars
  service_env           = var.service_only_env_vars
  sidecar_containers    = var.sidecar_containers
  min_instance_count    = var.fleet_config.min_instance_count
  max_instance_count    = var.fleet_config.max_instance_count

  migration_enabled = nonsensitive(var.fleet_config.exec_migration)
  # connection_name is computed-only: planned unknown on (same-name)
  # replacement => new migration identity.
  database_identity = {
    sql_connection_name = module.mysql.instance_connection_name
    database_name       = var.database_config.database_name
  }

  # Ordering only: database, secrets/IAM and CMEK readiness.
  prerequisites = concat(
    [
      google_service_account.fleet_run_sa.id,
      google_secret_manager_secret_version.database_password.id,
      google_secret_manager_secret_version.hmac_secret.id,
      google_secret_manager_secret_iam_member.fleet_run_sa_db_secret_access.etag,
      google_secret_manager_secret_iam_member.fleet_run_sa_hmac_secret_access.etag,
      google_secret_manager_secret_iam_member.fleet_run_sa_private_key_secret_access.etag,
      terraform_data.fleet_database_ready.id,
    ],
    google_secret_manager_secret_version.private_key[*].id,
    google_kms_crypto_key_iam_member.cloud_run_cmek[*].etag,
    time_sleep.cmek_iam_propagation[*].id,
  )
}

# Single service owner: adopt the module's service in place (no destroy /
# recreate). Same resource type and provider (google-beta).
moved {
  from = module.fleet-service.google_cloud_run_v2_service.main
  to   = module.fleet_lifecycle.google_cloud_run_v2_service.fleet
}

# Main's fixed-name `fleet-migration` job is forgotten, not
# destroyed: deleting a job whose execution might still be running is not
# something an apply should do implicitly. Delete `fleet-migration` by hand
# after review.
removed {
  from = google_cloud_run_v2_job.fleet_migration_job

  lifecycle {
    destroy = false
  }
}

# Main's terracurl_request.exec started that job asynchronously with a
# plan-time OAuth token and without stopping Fleet. Forget it without
# executing a destroy action.
removed {
  from = terracurl_request.exec

  lifecycle {
    destroy = false
  }
}

module "fleet-bulk-service" {
  source = "../vendor/cloud-run-v2"

  # Roll the new image onto bulk only after the lifecycle module has migrated
  # the database and restored fleet-api. Bulk is not stopped during the
  # migration (it is min=0 and only takes uploads/installer traffic).
  depends_on = [module.fleet_lifecycle]

  service_name                  = "fleet-api-bulk"
  project_id                    = var.project_id
  location                      = var.region
  create_service_account        = false
  service_account               = google_service_account.fleet_run_sa.email
  enable_prometheus_sidecar     = false
  cloud_run_deletion_protection = false

  vpc_access = {
    network_interfaces = {
      network    = local.fleet_vpc_network_id
      subnetwork = local.fleet_vpc_subnet_id
    }
    egress = "ALL_TRAFFIC"
  }
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  # Software installers are streamed through this service. A 105MB package on a
  # slow link takes far longer than the 300s default, which severed the transfer
  # at exactly 300.000s and surfaced as "Software installer download failed".
  timeout = "3600s"

  service_scaling = {
    min_instance_count = 0
  }

  template_scaling = {
    min_instance_count = 0
    max_instance_count = var.fleet_config.max_instance_count
  }

  containers = concat([
    {
      container_name       = "fleet"
      container_image      = local.fleet_image_tag
      depends_on_container = local.sidecar_container_names
      ports = {
        name           = "h2c"
        container_port = 8080
      }

      startup_probe = {
        initial_delay_seconds = 30
        timeout_seconds       = 2
        period_seconds        = 60
        failure_threshold     = 3

        tcp_socket = {
          port = 8080
        }
      }

      liveness_probe = {
        initial_delay_seconds = 30
        timeout_seconds       = 2
        failure_threshold     = 3
        period_seconds        = 60
        http_get = {
          path         = "/healthz"
          http_headers = []
        }
      }

      resources = {
        limits = local.fleet_resources_limits
      }

      env_vars        = local.fleet_bulk_env_vars
      env_secret_vars = local.fleet_secrets_env_vars
    }
  ], var.sidecar_containers)
}

resource "google_compute_region_network_endpoint_group" "neg" {
  name                  = "${var.prefix}-neg"
  region                = var.region
  project               = var.project_id
  network_endpoint_type = "SERVERLESS"
  # Literal service name, not module.fleet_lifecycle.service_name: the load
  # balancer's create_before_destroy resources would otherwise propagate
  # create_before_destroy through this NEG to the service and the migration
  # job, and a same-name job re-create would then conflict (409).
  cloud_run {
    service = local.fleet_service_name
  }
}

resource "google_compute_region_network_endpoint_group" "bulk_neg" {
  name                  = "${var.prefix}-bulk-neg"
  region                = var.region
  project               = var.project_id
  network_endpoint_type = "SERVERLESS"
  # Literal for the same create_before_destroy reason as the main NEG.
  cloud_run {
    service = "fleet-api-bulk"
  }
}

resource "google_cloud_run_v2_service_iam_member" "allow_lb_invoker" {
  project  = var.project_id
  location = module.fleet_lifecycle.service_location
  name     = module.fleet_lifecycle.service_name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "allow_lb_bulk_invoker" {
  project  = var.project_id
  location = module.fleet-bulk-service.location
  name     = module.fleet-bulk-service.service_name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
