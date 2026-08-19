resource "random_id" "suffix" {
  byte_length = 5
}


module "private-service-access" {
  source  = "terraform-google-modules/sql-db/google//modules/private_service_access"
  version = "~> 25.0"

  project_id      = var.project_id
  vpc_network     = module.vpc.network_name
  deletion_policy = "ABANDON"
}

module "mysql" {
  source  = "terraform-google-modules/sql-db/google//modules/mysql"
  version = "~> 25.0"

  name                              = var.database_config.name
  project_id                        = var.project_id
  deletion_protection               = var.database_config.deletion_protection
  deletion_protection_enabled       = var.database_config.deletion_protection_enabled
  database_version                  = var.database_config.database_version
  tier                              = var.database_config.tier
  database_flags                    = var.database_config.database_flags
  encryption_key_name               = var.database_config.encryption_key_name
  password_validation_policy_config = var.database_config.password_validation_policy_config
  region                            = var.region
  random_instance_name              = true

  # Query Insights: without it, diagnosing a saturated instance means
  # shelling into a throwaway container to read performance_schema.
  insights_config = var.database_config.query_insights_enabled ? {
    query_plans_per_minute  = 5
    query_string_length     = 1024
    record_application_tags = false
    record_client_address   = false
  } : null
  enable_default_user = true
  enable_default_db   = true
  user_name           = var.database_config.database_user
  db_name             = var.database_config.database_name
  db_collation        = var.database_config.collation
  db_charset          = var.database_config.charset

  ip_configuration = {
    ipv4_enabled = false
    # We never set authorized networks, we need all connections via the
    # public IP to be mediated by Cloud SQL.
    authorized_networks = []
    ssl_mode            = var.database_config.ssl_mode
    private_network     = module.vpc.network_self_link
  }

  module_depends_on = [module.private-service-access.peering_completed]
}