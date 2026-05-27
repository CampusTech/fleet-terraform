terraform {
  required_version = "~> 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.35.0"
    }
  }
}

locals {
  topics = {
    results = {
      enabled = var.enable_results_topic
      name    = var.results_topic_name
    }
    status = {
      enabled = var.enable_status_topic
      name    = var.status_topic_name
    }
    audit = {
      enabled = var.enable_audit_topic
      name    = var.audit_topic_name
    }
  }

  enabled_topics = { for k, v in local.topics : k => v if v.enabled }
}

resource "google_pubsub_topic" "fleet" {
  for_each = local.enabled_topics

  project                    = var.project_id
  name                       = each.value.name
  labels                     = var.labels
  message_retention_duration = var.message_retention_duration
}

resource "google_service_account" "publisher" {
  project      = var.project_id
  account_id   = var.publisher_service_account_id
  display_name = "Fleet log publisher"
  description  = "Service account Fleet uses to publish osquery and audit logs to Pub/Sub"
}

resource "google_pubsub_topic_iam_member" "publisher" {
  for_each = google_pubsub_topic.fleet

  project = each.value.project
  topic   = each.value.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.publisher.email}"
}
