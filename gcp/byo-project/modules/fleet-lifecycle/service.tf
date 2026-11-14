# -----------------------------------------------------------------------------
# The single owner of the Fleet Cloud Run service (replaces
# main's module.fleet-service.google_cloud_run_v2_service.main;
# moved in byo-project/cloud_run.tf). Same template as main rendered
# for Fleet, plus:
#   * scaling_mode declared explicitly: MANUAL/0 until the current migration
#     identity is migrated (`migrated` in main.tf), AUTOMATIC/min afterwards.
#     The module could not express scaling_mode.
#   * a revision-template attempt annotation (Job UID) so every migration
#     attempt deploys a fresh revision while still MANUAL/0 and the provider
#     waits for it to become Ready ("staged" restore).
#   * the restore marker annotation is NOT declared (left to the restore
#     PATCH; preserved by the provider's effective_annotations handling).
# -----------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "fleet" {
  provider = google-beta

  project             = var.project_id
  name                = var.service_name
  location            = var.region
  deletion_protection = false
  ingress             = var.ingress
  launch_stage        = "GA"

  # The restore marker is deliberately NOT declared: the provider sends
  # effective_annotations (refreshed server map + config), so an unmanaged key
  # survives provider updates, and declaring it would add a one-time diff
  # after every restore (observed with the real provider in the loopback
  # integration run).
  annotations = var.service_annotations

  scaling {
    scaling_mode          = local.serving ? "AUTOMATIC" : "MANUAL"
    manual_instance_count = local.serving ? null : 0
    min_instance_count    = local.serving ? var.min_instance_count : 0
  }

  # Declared exactly LATEST/100 without tags (as the module did implicitly).
  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  template {
    timeout               = var.request_timeout
    service_account       = var.service_account_email
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
    encryption_key        = var.encryption_key

    annotations = var.migration_enabled ? { (local.attempt_annotation_key) = local.attempt_value } : {}

    scaling {
      min_instance_count = 0 # Google suggests the service-level minimum
      max_instance_count = var.max_instance_count
    }

    vpc_access {
      network_interfaces {
        network    = var.vpc_network
        subnetwork = var.vpc_subnetwork
      }
      egress = "ALL_TRAFFIC"
    }

    containers {
      # Named only when sidecars exist: Cloud Run needs names to express
      # container dependencies. Fleet waits for the sidecars' startup probes.
      name       = length(var.sidecar_containers) > 0 ? "fleet" : null
      image      = var.image
      depends_on = length(var.sidecar_containers) > 0 ? [for c in var.sidecar_containers : c.container_name] : null

      ports {
        name           = var.use_h2c ? "h2c" : "http1"
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = true
        startup_cpu_boost = false
      }

      startup_probe {
        initial_delay_seconds = 30
        timeout_seconds       = 2
        period_seconds        = 60
        failure_threshold     = 3
        tcp_socket {
          port = 8080
        }
      }

      liveness_probe {
        initial_delay_seconds = 30
        timeout_seconds       = 2
        period_seconds        = 60
        failure_threshold     = 3
        http_get {
          path = "/healthz"
        }
      }

      dynamic "env" {
        for_each = merge(var.env, var.service_env)
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value.secret
              version = env.value.version
            }
          }
        }
      }
    }

    # Service-only sidecars (the migration job never runs them).
    dynamic "containers" {
      for_each = var.sidecar_containers
      content {
        name       = containers.value.container_name
        image      = containers.value.container_image
        command    = containers.value.container_command
        args       = containers.value.container_args
        depends_on = containers.value.depends_on_container

        # ports == null or container_port == 0: no ingress port (only one
        # container per service may own it).
        dynamic "ports" {
          for_each = try(containers.value.ports.container_port, 0) != 0 ? [containers.value.ports] : []
          content {
            name           = ports.value.name
            container_port = ports.value.container_port
          }
        }

        resources {
          limits            = containers.value.resources.limits == null ? null : { for k, v in containers.value.resources.limits : k => v if v != null }
          cpu_idle          = containers.value.resources.cpu_idle
          startup_cpu_boost = containers.value.resources.startup_cpu_boost
        }

        dynamic "startup_probe" {
          for_each = containers.value.startup_probe == null ? [] : [containers.value.startup_probe]
          content {
            failure_threshold     = startup_probe.value.failure_threshold
            initial_delay_seconds = startup_probe.value.initial_delay_seconds
            timeout_seconds       = startup_probe.value.timeout_seconds
            period_seconds        = startup_probe.value.period_seconds
            dynamic "tcp_socket" {
              for_each = startup_probe.value.tcp_socket == null ? [] : [startup_probe.value.tcp_socket]
              content {
                port = tcp_socket.value.port
              }
            }
          }
        }

        dynamic "env" {
          for_each = containers.value.env_vars
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = containers.value.env_secret_vars
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = env.value.secret
                version = env.value.version
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    # Migration-success gate (job.tf): no deploy, and therefore no restore,
    # unless this attempt's execution reports exactly EXECUTION_SUCCEEDED.
    precondition {
      condition     = !var.migration_enabled || local.migrated || local.migration_succeeded
      error_message = "Refusing to deploy or restore Fleet: the migration execution of this attempt has not succeeded (job terminal condition and latestCreatedExecution.completionStatus must be CONDITION_SUCCEEDED / EXECUTION_SUCCEEDED). Fleet stays stopped (MANUAL/0). Job status: ${jsonencode(local.job_view)}. A failed or cancelled execution is retried with a new job by the next `terraform apply`; a pending or running one: wait until it has finished, then apply again."
    }
  }

  # Ordering: secrets/IAM/CMEK via prerequisites; the migration job and its
  # execution read-back (job.tf).
  depends_on = [terraform_data.prerequisites, data.terracurl_request.job_execution]
}
