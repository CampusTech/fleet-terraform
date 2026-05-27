variable "project_id" {
  type        = string
  description = "GCP project ID where the Pub/Sub topics and publisher service account will be created."
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to created Pub/Sub topics."
  default     = {}
}

variable "message_retention_duration" {
  type        = string
  description = "How long Pub/Sub retains unacknowledged messages on each topic. Must be between 10m and 31d, suffixed with 's'."
  default     = "604800s" # 7 days
}

variable "publisher_service_account_id" {
  type        = string
  description = "Account ID (the part before @PROJECT.iam.gserviceaccount.com) for the service account Fleet uses to publish logs."
  default     = "fleet-log-publisher"
}

variable "additional_publisher_members" {
  type        = list(string)
  description = "Extra IAM members (fully qualified, e.g. \"serviceAccount:foo@bar.iam.gserviceaccount.com\") to grant roles/pubsub.publisher on each enabled topic, in addition to the module's own publisher service account. Use this when Fleet runs as an existing service account that should publish directly without impersonation."
  default     = []
}

variable "enable_results_topic" {
  type        = bool
  description = "Create a topic for osquery scheduled query result logs and wire FLEET_OSQUERY_RESULT_LOG_PLUGIN to pubsub."
  default     = true
}

variable "results_topic_name" {
  type        = string
  description = "Name of the topic that receives osquery scheduled query result logs."
  default     = "fleet-osquery-results"
}

variable "enable_status_topic" {
  type        = bool
  description = "Create a topic for osquery status logs and wire FLEET_OSQUERY_STATUS_LOG_PLUGIN to pubsub."
  default     = true
}

variable "status_topic_name" {
  type        = string
  description = "Name of the topic that receives osquery status logs."
  default     = "fleet-osquery-status"
}

variable "enable_audit_topic" {
  type        = bool
  description = "Create a topic for Fleet activity audit logs and wire FLEET_ACTIVITY_AUDIT_LOG_PLUGIN to pubsub."
  default     = true
}

variable "audit_topic_name" {
  type        = string
  description = "Name of the topic that receives Fleet activity audit logs."
  default     = "fleet-audit"
}

variable "add_attributes" {
  type        = bool
  description = "If true, sets FLEET_PUBSUB_ADD_ATTRIBUTES=true so Fleet adds osquery host attributes (hostname, etc.) to published messages."
  default     = false
}
