terraform {
  required_version = "~> 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.35.0"
    }
  }
}

provider "google" {
  # Credentials used here need Org/Folder level permissions
  default_labels = var.labels
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
    "certificatemanager.googleapis.com"
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

module "fleet" {
  source          = "./byo-project"
  project_id      = module.project_factory.project_id
  dns_record_name = var.dns_record_name
  dns_zone_name   = var.dns_zone_name
  vpc_config      = var.vpc_config
  fleet_config    = merge(var.fleet_config, {
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
