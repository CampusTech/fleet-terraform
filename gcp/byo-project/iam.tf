
# -------------------------------------
# Service Account for Cloud Run Service & Job
# -------------------------------------

resource "google_service_account" "fleet_run_sa" {
  project      = var.project_id
  account_id   = "${var.prefix}-run-sa"
  display_name = "Service Account for Fleet Cloud Run Service and Jobs"
}

resource "google_project_iam_member" "fleet_run_sa_sql_instance_user" {
  project = var.project_id
  role    = "roles/cloudsql.instanceUser"
  member  = "serviceAccount:${google_service_account.fleet_run_sa.email}"
}

# Recommended for Cloud Run standard logging
resource "google_project_iam_member" "fleet_run_sa_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.fleet_run_sa.email}"
}

# Recommended for Cloud Run standard metrics
resource "google_project_iam_member" "fleet_run_sa_monitoring_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.fleet_run_sa.email}"
}


# Upstream's named grants for the module-managed secrets (the lifecycle
# module's prerequisites reference them). Our fork used to grant these via the
# for_each below; moved.tf carries the old keys over.
resource "google_secret_manager_secret_iam_member" "fleet_run_sa_db_secret_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.database_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.fleet_run_sa.email}"

  depends_on = [google_secret_manager_secret.database_password]
}

resource "google_secret_manager_secret_iam_member" "fleet_run_sa_private_key_secret_access" {
  project   = var.project_id
  secret_id = local.fleet_private_key_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.fleet_run_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "fleet_run_sa_hmac_secret_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.hmac_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.fleet_run_sa.email}"

  depends_on = [google_secret_manager_secret.hmac_secret]
}

# Caller-supplied secrets (extra_secret_env_vars, e.g. Windows MDM WSTEP).
# Secret names are not secret; fleet_config is sensitive as a whole.
resource "google_secret_manager_secret_iam_member" "fleet_run_sa_secret_access" {
  for_each = nonsensitive(coalesce(var.fleet_config.extra_secret_env_vars, {}))

  project   = var.project_id
  secret_id = each.value.secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.fleet_run_sa.email}"
}

# Sidecar containers may reference their own secrets (e.g. Datadog API key for
# the DDOT sidecar). The Cloud Run SA runs every container in the service, so
# it needs accessor on each sidecar secret too. Iterating the sidecar list and
# its env_secret_vars map keeps this grant in sync with whatever's wired in.
resource "google_secret_manager_secret_iam_member" "fleet_run_sa_sidecar_secret_access" {
  for_each = merge([
    for c in var.sidecar_containers : c.env_secret_vars
  ]...)

  project   = var.project_id
  secret_id = each.value.secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.fleet_run_sa.email}"
}
