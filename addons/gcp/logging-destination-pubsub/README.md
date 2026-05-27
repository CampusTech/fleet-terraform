# Logging Destination: Google Cloud Pub/Sub

This addon provisions Google Cloud Pub/Sub topics for Fleet's three log streams and a service account with `roles/pubsub.publisher` on each topic.

Fleet's [`pubsub` log plugin](https://fleetdm.com/guides/log-destinations) publishes each log stream to its own topic; downstream consumers (BigQuery, a log forwarder, etc.) attach as subscriptions.

## Log streams

| Log stream | Default topic name | Fleet env var | Toggle |
| ---------- | ------------------ | ------------- | ------ |
| Osquery scheduled query results | `fleet-osquery-results` | `FLEET_PUBSUB_RESULT_TOPIC` | `enable_results_topic` |
| Osquery status | `fleet-osquery-status` | `FLEET_PUBSUB_STATUS_TOPIC` | `enable_status_topic` |
| Fleet activity audit | `fleet-audit` | `FLEET_PUBSUB_AUDIT_TOPIC` | `enable_audit_topic` |

Each topic can be disabled independently. When a topic is disabled, the corresponding Fleet env vars are omitted from `fleet_extra_environment_variables`, so the log stream falls back to whatever Fleet's default plugin is configured to be.

## Usage

```hcl
module "fleet_pubsub_logging" {
  source     = "github.com/fleetdm/fleet-terraform//addons/gcp/logging-destination-pubsub?ref=main"
  project_id = "my-fleet-project"

  labels = {
    app = "fleet"
  }
}

# Wire the publisher SA into Fleet's workload (Cloud Run example).
resource "google_cloud_run_v2_service_iam_member" "fleet_uses_publisher_sa" {
  # ...impersonation or direct binding, depending on your deploy pattern.
}

# Pass the env vars to Fleet.
output "fleet_env" {
  value = module.fleet_pubsub_logging.fleet_extra_environment_variables
}
```

The module emits:

- `publisher_service_account_email` — bind this to your Fleet workload (Cloud Run service account, GKE Workload Identity, etc.) so Fleet can publish.
- `topic_ids` / `topic_names` — for wiring downstream subscribers.
- `fleet_extra_environment_variables` — drop-in env map for Fleet, including the plugin selectors and topic names.

If Fleet already runs as an existing service account and you'd rather grant publisher to that SA directly instead of using the module's auto-created SA, pass it via `additional_publisher_members`:

```hcl
module "fleet_pubsub_logging" {
  source     = "github.com/fleetdm/fleet-terraform//addons/gcp/logging-destination-pubsub?ref=main"
  project_id = "my-fleet-project"

  additional_publisher_members = [
    "serviceAccount:${module.fleet.fleet_service_account_email}",
  ]
}
```

## Permissions

The principal running Terraform needs, on `var.project_id`:

- `roles/pubsub.admin` (or finer-grained: create topics and set topic IAM)
- `roles/iam.serviceAccountAdmin` (to create the publisher SA)

`pubsub.googleapis.com` and `iam.googleapis.com` must be enabled on the project.

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
