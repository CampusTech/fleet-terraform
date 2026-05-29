# -------------------------------------
# Datadog DDOT Sidecar (Cloud Run)
# -------------------------------------
# Runs the Datadog Agent in DDOT mode (DD_OTELCOLLECTOR_ENABLED=true) as a
# sidecar in both fleet-api and fleet-api-bulk. The agent exposes an OTLP
# gRPC receiver on localhost:4317; Fleet's built-in OTel exporters (traces,
# metrics, logs) post to it; the agent forwards to Datadog us5.
#
# Why DDOT and not serverless-init or otelcol-contrib:
#   - serverless-init's OTLP logs pipeline is broken (datadog-agent#34097,
#     closed without fix in Feb 2026) — fatal for our use case.
#   - otelcol-contrib would work but loses Datadog-specific features like
#     Database Monitoring span correlation, Live Processes, Cloud Network
#     Monitoring, and Universal Service Monitoring.
#   - DDOT's Linux/EKS-Fargate install paths confirm the agent variant runs
#     fine outside K8s when given the right env vars; the smoke test on
#     Cloud Run (revision fleet-api-00022-bvl, 2026-05-29) confirmed all
#     three signal types land in DD us5.
#
# Why a sidecar and not Datadog's direct OTLP intake:
#   - Datadog's direct intake is HTTP-only; Fleet's exporters are hard-coded
#     gRPC (otlptracegrpc / otlpmetricgrpc / otlploggrpc — see
#     cmd/fleet/serve.go).
#   - The metrics intake requires delta temporality; Fleet emits cumulative
#     and has no config knob to switch.
#   - Patching Fleet to change either would fork the upstream image and
#     break the geolite2 + tag-bump upgrade path.

resource "google_secret_manager_secret" "fleet_datadog_api_key" {
  project   = module.project_factory.project_id
  secret_id = "fleet-datadog-api-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "fleet_datadog_api_key" {
  secret      = google_secret_manager_secret.fleet_datadog_api_key.name
  secret_data = var.fleet_datadog_api_key
}

locals {
  datadog_site    = "us5.datadoghq.com"
  datadog_service = "fleet"
  datadog_env     = "prod"
  # source: lets us filter all DDOT-routed signals in DD UI by `source:fleet-otel`,
  # distinguishing them from the Pub/Sub→Dataflow→DD pipeline that ships osquery
  # results under a different source.
  datadog_source         = "fleet-otel"
  datadog_deployment_tag = "cloudrun-ddot"
  # Image version surfaces as service.version (OTel) and DD_VERSION (DD agent),
  # so split versions remain attributable per release.
  fleet_image_version = replace(local.fleet_upstream_image, "/.*:/", "")

  # Env vars set on the Fleet container so its built-in OTel SDK exporters
  # target the sidecar. logging.otel_logs_enabled requires
  # logging.tracing_enabled (see cmd/fleet/serve.go validation).
  # OTEL_EXPORTER_OTLP_INSECURE is required: the SDK defaults to TLS, but
  # we're talking plaintext to localhost.
  fleet_otel_env_vars = {
    FLEET_LOGGING_TRACING_ENABLED   = "true"
    FLEET_LOGGING_OTEL_LOGS_ENABLED = "true"
    OTEL_EXPORTER_OTLP_ENDPOINT     = "http://localhost:4317"
    OTEL_EXPORTER_OTLP_PROTOCOL     = "grpc"
    OTEL_EXPORTER_OTLP_INSECURE     = "true"
    OTEL_SERVICE_NAME               = local.datadog_service
    OTEL_RESOURCE_ATTRIBUTES = join(",", [
      "deployment.environment=${local.datadog_env}",
      "service.version=${local.fleet_image_version}",
      "source=${local.datadog_source}",
      "deployment.id=${local.datadog_deployment_tag}",
    ])
  }

  datadog_sidecar = {
    container_name  = "datadog-agent"
    container_image = "gcr.io/datadoghq/agent:latest-full"
    # container_port = 0 is the sentinel our vendored cloud-run-v2 module
    # honors to mean "this container has no exposed port" — skips emitting a
    # ports block entirely. Required because Cloud Run rejects services
    # where more than one container has a ports block, and only the Fleet
    # container is the ingress (8080/http1). The sidecar listens on
    # localhost:4317 internally, which Cloud Run doesn't need to know about.
    ports = {
      name           = ""
      container_port = 0
    }
    resources = {
      limits = {
        cpu    = "1"
        memory = "512Mi"
      }
    }
    env_vars = {
      DD_SITE                  = local.datadog_site
      DD_SERVICE               = local.datadog_service
      DD_ENV                   = local.datadog_env
      DD_VERSION               = local.fleet_image_version
      DD_OTELCOLLECTOR_ENABLED = "true"
      DD_LOGS_ENABLED          = "true"
      # Cloud Run instances are ephemeral; hard-code the hostname so DD groups
      # signals under one logical host instead of generating per-instance UIDs.
      DD_HOSTNAME = "fleet-api-cloudrun"
      DD_TAGS     = "source:${local.datadog_source},deployment:${local.datadog_deployment_tag}"
    }
    env_secret_vars = {
      DD_API_KEY = {
        secret  = google_secret_manager_secret.fleet_datadog_api_key.secret_id
        version = "latest"
      }
    }
    # Cloud Run requires a startup_probe on any container that another
    # container depends_on (the Fleet container does). TCP on the OTLP gRPC
    # port: once the receiver is listening, the agent's collector pipeline
    # is fully configured and ready to accept Fleet's spans.
    startup_probe = {
      failure_threshold     = 30
      period_seconds        = 5
      initial_delay_seconds = 5
      timeout_seconds       = 2
      tcp_socket = {
        port = 4317
      }
    }
  }
}
