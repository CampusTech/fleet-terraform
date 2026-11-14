// Fork-only: service sidecars + service-only env never reach the migration job.
mock_provider "google-beta" {}
mock_provider "terracurl" {}
mock_provider "time" {}

variables {
  project_id            = "fictional-proj"
  region                = "us-central1"
  image                 = "fleetdm/fleet:v4.93.0"
  service_account_email = "fleet-run-sa@fictional-proj.iam.gserviceaccount.com"
  vpc_network           = "fleet-network"
  vpc_subnetwork        = "fleet-subnet"
  cpu                   = "1000m"
  memory                = "4096Mi"
  min_instance_count    = 1
  max_instance_count    = 5
  database_identity     = { sql_connection_name = "fictional-proj:us-central1:fleet-mysql-0a1b2c3d", database_name = "fleet" }
  env                   = { FLEET_MYSQL_DATABASE = "fleet" }
  service_env           = { OTEL_EXPORTER_OTLP_ENDPOINT = "http://localhost:4317" }
  sidecar_containers = [{
    container_name  = "datadog-agent"
    container_image = "gcr.io/datadoghq/agent:latest-full"
    ports           = { name = "", container_port = 0 }
    resources       = { limits = { cpu = "1", memory = "512Mi" } }
    env_secret_vars = { DD_API_KEY = { secret = "fleet-datadog-api-key", version = "latest" } }
    startup_probe   = { failure_threshold = 30, period_seconds = 5, tcp_socket = { port = 4317 } }
  }]
}

run "sidecar_on_service_not_job" {
  command = plan

  assert {
    condition = (
      length(google_cloud_run_v2_service.fleet.template[0].containers) == 2 &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].name == "fleet" &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].depends_on == tolist(["datadog-agent"]) &&
      length(google_cloud_run_v2_service.fleet.template[0].containers[1].ports) == 0 &&
      contains([for e in google_cloud_run_v2_service.fleet.template[0].containers[0].env : e.name], "OTEL_EXPORTER_OTLP_ENDPOINT")
    )
    error_message = "Service must run Fleet (depending on the port-less sidecar) with the service-only env."
  }

  assert {
    condition = (
      length(google_cloud_run_v2_job.migration[0].template[0].template[0].containers) == 1 &&
      !contains([for e in google_cloud_run_v2_job.migration[0].template[0].template[0].containers[0].env : e.name], "OTEL_EXPORTER_OTLP_ENDPOINT")
    )
    error_message = "Migration job must not get sidecars or service-only env."
  }
}
