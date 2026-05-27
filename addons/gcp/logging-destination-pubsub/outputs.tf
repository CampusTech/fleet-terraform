output "fleet_extra_environment_variables" {
  description = "Environment variables to set on the Fleet server so it publishes logs to the topics created by this module."
  value = merge(
    {
      FLEET_PUBSUB_PROJECT = var.project_id
    },
    var.enable_results_topic ? {
      FLEET_OSQUERY_RESULT_LOG_PLUGIN = "pubsub"
      FLEET_PUBSUB_RESULT_TOPIC       = google_pubsub_topic.fleet["results"].name
    } : {},
    var.enable_status_topic ? {
      FLEET_OSQUERY_STATUS_LOG_PLUGIN = "pubsub"
      FLEET_PUBSUB_STATUS_TOPIC       = google_pubsub_topic.fleet["status"].name
    } : {},
    var.enable_audit_topic ? {
      FLEET_ACTIVITY_AUDIT_LOG_PLUGIN = "pubsub"
      FLEET_ACTIVITY_ENABLE_AUDIT_LOG = "true"
      FLEET_PUBSUB_AUDIT_TOPIC        = google_pubsub_topic.fleet["audit"].name
    } : {},
    var.add_attributes ? {
      FLEET_PUBSUB_ADD_ATTRIBUTES = "true"
    } : {},
  )
}

output "publisher_service_account_email" {
  description = "Email of the service account Fleet should run as (or impersonate) to publish to these topics. Bind this to the Fleet workload (Cloud Run service account, GKE Workload Identity, etc.). Null when `create_publisher_service_account` is false."
  value       = try(google_service_account.publisher[0].email, null)
}

output "topic_ids" {
  description = "Map of fully qualified Pub/Sub topic IDs (projects/PROJECT/topics/NAME), keyed by log stream (results, status, audit). Subscribe downstream consumers to these."
  value       = { for k, t in google_pubsub_topic.fleet : k => t.id }
}

output "topic_names" {
  description = "Map of Pub/Sub topic short names, keyed by log stream (results, status, audit)."
  value       = { for k, t in google_pubsub_topic.fleet : k => t.name }
}
