variable "project_name" {
  default = "fleet"
}

variable "windows_mdm_wstep_identity_cert" {
  description = "PEM-encoded certificate for Windows MDM WSTEP identity (FLEET_MDM_WINDOWS_WSTEP_IDENTITY_CERT_BYTES)"
  type        = string
  sensitive   = true
}

variable "windows_mdm_wstep_identity_key" {
  description = "PEM-encoded private key for Windows MDM WSTEP identity (FLEET_MDM_WINDOWS_WSTEP_IDENTITY_KEY_BYTES)"
  type        = string
  sensitive   = true
}

variable "org_id" {
  description = "organization id"
}

variable "billing_account_id" {
  description = "billing account id"
}

variable "labels" {
  description = "resource labels"
  default     = { application = "fleet" }
  type        = map(string)
}

variable "fleet_image" {
  default = "v4.67.3"
}

variable "dns_zone_name" {
  description = "The DNS name of the managed zone (e.g., 'my-fleet-infra.com.')"
  type        = string
}

variable "dns_record_name" {
  description = "The DNS record for Fleet (e.g., 'fleet.my-fleet-infra.com.')"
  type        = string
}

variable "random_project_id" {
  default = true
}
variable "location" {
  description = "The general location for resources, e.g., 'us' for GCS buckets."
  type        = string
  default     = "us"
}

variable "region" {
  description = "The GCP region for regional resources."
  type        = string
  default     = "us-central1"
}

variable "prefix" {
  description = "A prefix used for naming resources within the byo-project module."
  type        = string
  default     = "fleet"
}

variable "cache_config" {
  description = "Configuration for the Memorystore (Redis) instance."
  type = object({
    name           = string
    tier           = string
    engine_version = string
    connect_mode   = string
    memory_size    = number
  })
  default = {
    name           = "fleet-cache"
    tier           = "STANDARD_HA"
    engine_version = null // defaults to version 7
    connect_mode   = "PRIVATE_SERVICE_ACCESS"
    memory_size    = 1
  }
}

variable "database_config" {
  description = "Configuration for the Cloud SQL (MySQL) instance."
  type = object({
    name                = string
    database_name       = string
    database_user       = string
    collation           = string
    charset             = string
    deletion_protection = bool
    database_version    = string
    tier                = string
    # API/console-level delete guard, distinct from the Terraform-level
    # deletion_protection above. Both are needed to satisfy the Cloud SQL
    # "Deletion protection not enabled" recommendation.
    deletion_protection_enabled = optional(bool, true)
    query_insights_enabled      = optional(bool, true)
    # ENCRYPTED_ONLY is Google's documented encrypted-only setting, and
    # sslMode has priority over the deprecated requireSsl field (which stays
    # false -- ENCRYPTED_ONLY + requireSsl=false is the canonical pair; only
    # TRUSTED_CLIENT_CERTIFICATE_REQUIRED pairs with requireSsl=true, and that
    # needs client certs Fleet does not have).
    #
    # Verified 2026-08-19: Fleet connects with TLS (real cipher on a live
    # session) but the server still reports require_secure_transport=OFF, and a
    # forced-plaintext client reached authentication rather than being refused
    # at connect time. So this encrypts Fleet's traffic; it is not proven to
    # refuse plaintext. Hard enforcement needs client certs, or a support case
    # on the ENCRYPTED_ONLY / require_secure_transport discrepancy.
    #
    # The module has no require_ssl input (v25 dropped it for ssl_mode) and the
    # google provider removed the attribute entirely, so the old
    # require_ssl = false in database.tf was dead code and unfixable there.
    ssl_mode = optional(string, "ENCRYPTED_ONLY")
    # CMEK. Cannot be set on an existing instance -- Cloud SQL: "You can't
    # enable customer-managed encryption keys on existing instances." Setting
    # this on a live instance forces replacement. It exists here for the
    # CMEK migration (clone or replica-then-promote onto a new instance).
    encryption_key_name = optional(string, null)
    # Instance-level password validation policy (Cloud SQL recommendation
    # "No password policy").
    #
    # min_length is pinned to 28 on purpose. The sql-db module derives the
    # generated password from this block:
    #   length  = min_length != null ? min_length + 4 : 32
    #   special = complexity == "COMPLEXITY_DEFAULT"
    # The live password is length 32 / special false, so 28 + 4 = 32 with
    # complexity left unset keeps random_password byte-identical and avoids
    # rotating the credential Fleet is currently using. Setting complexity =
    # COMPLEXITY_DEFAULT would regenerate it and break Fleet until every Cloud
    # Run instance restarted -- do that deliberately, with a rollout, not here.
    password_validation_policy_config = optional(object({
      enable_password_policy      = bool
      min_length                  = optional(number)
      complexity                  = optional(string)
      disallow_username_substring = optional(bool)
      reuse_interval              = optional(number)
      }), {
      enable_password_policy      = true
      min_length                  = 28
      disallow_username_substring = true
      reuse_interval              = 5
    })
    database_flags = optional(list(object({
      name  = string
      value = string
      })), [
      # Cloud SQL "Exposed to local data loads": Fleet never issues
      # LOAD DATA LOCAL INFILE.
      { name = "local_infile", value = "off" },
      # Cloud SQL "Database names exposed": the Fleet user only needs its
      # own schema.
      { name = "skip_show_database", value = "on" },
      # Slow query log so the next pathological query is diagnosable from
      # Cloud Logging instead of a one-off container.
      { name = "slow_query_log", value = "on" },
      # Cloud SQL needs log_output=FILE for slow-query entries to reach Logs
      # Explorer; verified permitted (FILE,TABLE,NONE) on 8.0 and 8.4.
      { name = "log_output", value = "FILE" },
      { name = "long_query_time", value = "2" },
    ])
  })
  default = {
    name                = "fleet-mysql"
    database_name       = "fleet"
    database_user       = "fleet"
    collation           = "utf8mb4_unicode_ci"
    charset             = "utf8mb4"
    deletion_protection = true
    database_version    = "MYSQL_8_4"
    tier                = "db-custom-2-8192"
  }
}

variable "vpc_config" {
  description = "Configuration for the VPC network and subnets."
  type = object({
    network_name = string
    subnets = list(object({
      subnet_name           = string
      subnet_ip             = string
      subnet_region         = string
      subnet_private_access = bool
    }))
  })
  default = {
    network_name = "fleet-network"
    subnets = [
      {
        subnet_name           = "fleet-subnet"
        subnet_ip             = "10.10.10.0/24"
        subnet_region         = "us-central1"
        subnet_private_access = true
      }
    ]
  }
}

variable "fleet_config" {
  description = "Configuration for the Fleet application deployment."
  type = object({
    installers_bucket_name = string
    carves_bucket_name     = string
    image_tag              = string
    fleet_cpu              = string
    fleet_memory           = string
    debug_logging          = bool
    license_key            = optional(string)
    min_instance_count     = number
    max_instance_count     = number
    exec_migration         = bool
    use_h2c                = bool
    # Per-instance MySQL pool caps. Cloud Run can scale to
    # max_instance_count, and Fleet's default pool is 50 per instance, so
    # the default multiplies into a connection stampede against Cloud SQL
    # exactly when it is already struggling.
    mysql_max_open_conns = optional(number, 20)
    mysql_max_idle_conns = optional(number, 20)
    # Cloud SQL's server cert does not match the private IP, so "true"
    # (which verifies hostname) fails. skip-verify encrypts in transit
    # without server-name verification; traffic never leaves the VPC.
    mysql_tls_config = optional(string, "skip-verify")
    extra_env_vars   = optional(map(string))
    extra_secret_env_vars = optional(map(object({
      secret  = string
      version = string
    })))
  })
  default = {
    image_tag              = "fleetdm/fleet:v4.90.0"
    installers_bucket_name = "" # Bucket names must be globally unique
    carves_bucket_name     = "" # Bucket names must be globally unique
    fleet_cpu              = "1000m"
    fleet_memory           = "4096Mi"
    debug_logging          = false
    min_instance_count     = 1
    max_instance_count     = 5
    exec_migration         = true
    use_h2c                = false
    extra_env_vars         = {}
    extra_secret_env_vars  = {}
  }
}

variable "maxmind_license_key" {
  type        = string
  description = "Maxmind license key used to download GeoLite2-City for the custom Fleet image."
  sensitive   = true
}

variable "fleet_datadog_api_key" {
  type        = string
  description = "Datadog API key for the DDOT collector sidecar running alongside Fleet on Cloud Run. Distinct from the datadog-api-key secret used by the Pub/Sub→Datadog Dataflow jobs (which forward osquery results)."
  sensitive   = true
}
