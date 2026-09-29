# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# main.tf
#
# Personalized Service Health (PSH) alerting for Google Cloud Managed Lustre.
#
# For every project in var.project_ids this configuration:
#   1. Enables the Service Health API (PSH needs up to 24h to start processing
#      events for a newly enabled project).
#   2. Creates an email notification channel.
#   3. Creates two Cloud Monitoring log-based alert policies on the
#      servicehealth.googleapis.com/activity log:
#        a. "[PSH] Managed Lustre incidents": any incident that lists
#           Google Cloud Managed Lustre, on creation and on every update.
#        b. "[PSH] Managed Lustre dependencies": new incidents (and state or
#           relevance changes) on Persistent Disk, Compute Engine or VPC whose
#           impacted locations include one of your Lustre regions.
#
# Apply it to every project that OWNS Managed Lustre instances, and ideally
# also to the projects that run your Lustre clients (GKE clusters / GPU VMs).
#
# IMPORTANT: Cloud Monitoring documentation variables such as
# ${resource.labels.event_id} must be written as $${...} in HCL so Terraform
# does not try to interpolate them.
#
# Product IDs come from
# https://cloud.google.com/service-health/docs/supported-products
# (use IDs, not display names, in filters).

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

# ----------------------------------------------------------------------------
# Inputs
# ----------------------------------------------------------------------------

variable "project_ids" {
  description = "Projects that own Managed Lustre instances and/or run Lustre clients."
  type        = set(string)
}

variable "lustre_regions" {
  description = "Regions where you run Managed Lustre, for example [\"us-east4\", \"asia-northeast1\"]. Use regions, not zones: the regex for a region also matches its zones (us-east4-a, ...)."
  type        = list(string)
}

variable "include_global_incidents" {
  description = "Also alert on dependency incidents whose impacted location is 'global'."
  type        = bool
  default     = true
}

variable "notification_email" {
  description = "Email address (for example an on-call alias) that receives the alerts. One email channel is created per project."
  type        = string
}

variable "extra_notification_channels" {
  description = "Optional: project_id => list of existing channel names (projects/PROJECT/notificationChannels/ID) such as PagerDuty, Slack, Pub/Sub or webhooks. Channels must live in the same project as the policy."
  type        = map(list(string))
  default     = {}
}

variable "dependency_product_ids" {
  description = "PSH product IDs of the Lustre dependencies to watch. Optional extras: Cloud Storage UwaYoXQ5bHYHG6EdiPB8 (import/export), Google Kubernetes Engine LCSbT57h59oR4W98NHuz (CSI driver clients), Cloud Key Management Service 67cSySTL7dwJZo9JWUGU (CMEK)."
  type        = map(string)
  default = {
    persistent_disk = "SzESm2Ux129pjDGKWD68"
    compute_engine  = "L3ggmi3Jy4xJmgodFA9K"
    vpc             = "BSGtCUnz6ZmyajsjgTKv"
  }
}

# ----------------------------------------------------------------------------
# Shared filter and notification content
# ----------------------------------------------------------------------------

locals {
  lustre_product_id = "6NIyMyXGmDuhgEOGEy2z" # Google Cloud Managed Lustre

  base_filter = join(" AND ", [
    "resource.type=\"servicehealth.googleapis.com/Event\"",
    "jsonPayload.@type=\"type.googleapis.com/google.cloud.servicehealth.logging.v1.EventLog\"",
    "jsonPayload.category=\"INCIDENT\"",
    "jsonPayload.relevance!=\"NOT_IMPACTED\"",
  ])

  location_regex = join("|", concat(
    var.lustre_regions,
    var.include_global_incidents ? ["global"] : [],
  ))

  lustre_filter = join(" AND ", [
    local.base_filter,
    "jsonPayload.impactedProductIds=~\"${local.lustre_product_id}\"",
  ])

  dependency_filter = join(" AND ", [
    local.base_filter,
    "jsonPayload.impactedProductIds=~\"${join("|", values(var.dependency_product_ids))}\"",
    # Whole-token match: "us-east4" matches us-east4 and us-east4-a but
    # "europe-west1" does not match europe-west10.
    "jsonPayload.impactedLocations=~\"(^|[^a-z0-9-])(${local.location_regex})(-[a-z])?([^a-z0-9-]|$)\"",
    "(labels.\"servicehealth.googleapis.com/new_event\"=true OR labels.\"servicehealth.googleapis.com/updated_fields\"=~\"'state'|'relevance'\")",
  ])

  label_extractors = {
    title             = "EXTRACT(jsonPayload.title)"
    description       = "EXTRACT(jsonPayload.description)"
    relevance         = "EXTRACT(jsonPayload.relevance)"
    state             = "EXTRACT(jsonPayload.state)"
    detailedState     = "EXTRACT(jsonPayload.detailedState)"
    impactedProducts  = "EXTRACT(jsonPayload.impactedProducts)"
    impactedLocations = "EXTRACT(jsonPayload.impactedLocations)"
    startTime         = "EXTRACT(jsonPayload.startTime)"
  }

  # "$${" renders a literal "${" so that Cloud Monitoring, not Terraform,
  # substitutes these variables when the notification is sent.
  dashboard_link = "[Open in Service Health dashboard](https://console.cloud.google.com/servicehealth/incidentDetails/projects%2F$${resource.labels.resource_container}%2Flocations%2F$${resource.labels.location}%2Fevents%2F$${resource.labels.event_id}?project=$${resource.labels.resource_container})\n\n*Test alert? The link above shows \"incident not found\". That's expected: test events aren't real Service Health incidents. Real incidents open normally. All incidents: [Service Health](https://console.cloud.google.com/servicehealth/incidents?project=$${resource.labels.resource_container}).*"

  incident_details = join("\n\n", [
    "**Title:** $${log.extracted_label.title}",
    "**Relevance to this project:** $${log.extracted_label.relevance}",
    "**State:** $${log.extracted_label.state} / $${log.extracted_label.detailedState}",
    "**Impacted products:** $${log.extracted_label.impactedProducts}",
    "**Impacted locations:** $${log.extracted_label.impactedLocations}",
    "**Start time:** $${log.extracted_label.startTime}",
    "**Latest update:** $${log.extracted_label.description}",
  ])

  lustre_doc = join("\n\n", [
    "## Google Cloud Managed Lustre incident",
    local.dashboard_link,
    local.incident_details,
  ])

  dependency_doc = join("\n\n", [
    "## Incident on a product that Managed Lustre depends on",
    "Managed Lustre runs on Persistent Disk, Compute Engine and VPC networking. An incident on one of these products in a region where you run Managed Lustre instances **may** affect Lustre performance or availability, even if no Lustre incident has been posted yet. Check your Lustre client metrics and the linked event.",
    local.dashboard_link,
    local.incident_details,
  ])
}

# ----------------------------------------------------------------------------
# Resources
# ----------------------------------------------------------------------------

resource "google_project_service" "servicehealth" {
  for_each           = var.project_ids
  project            = each.value
  service            = "servicehealth.googleapis.com"
  disable_on_destroy = false
}

resource "google_monitoring_notification_channel" "email" {
  for_each     = var.project_ids
  project      = each.value
  display_name = "Managed Lustre service health - ${var.notification_email}"
  type         = "email"
  labels = {
    email_address = var.notification_email
  }
}

resource "google_monitoring_alert_policy" "lustre" {
  for_each     = var.project_ids
  project      = each.value
  display_name = "[PSH] Managed Lustre incidents (new + all updates)"
  combiner     = "OR"
  enabled      = true
  severity     = "ERROR"

  conditions {
    display_name = "Service Health event for Google Cloud Managed Lustre"
    condition_matched_log {
      filter           = local.lustre_filter
      label_extractors = local.label_extractors
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "1800s"
  }

  documentation {
    content   = local.lustre_doc
    mime_type = "text/markdown"
  }

  notification_channels = concat(
    [google_monitoring_notification_channel.email[each.key].name],
    lookup(var.extra_notification_channels, each.key, []),
  )

  user_labels = {
    source = "personalized-service-health"
    scope  = "managed-lustre"
  }

  depends_on = [google_project_service.servicehealth]
}

resource "google_monitoring_alert_policy" "lustre_dependencies" {
  for_each     = var.project_ids
  project      = each.value
  display_name = "[PSH] Managed Lustre dependencies (PD / Compute Engine / VPC) in Lustre regions"
  combiner     = "OR"
  enabled      = true
  severity     = "WARNING"

  conditions {
    display_name = "New incident, or state/relevance change, on a Lustre dependency in a Lustre region"
    condition_matched_log {
      filter           = local.dependency_filter
      label_extractors = local.label_extractors
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "1800s"
  }

  documentation {
    content   = local.dependency_doc
    mime_type = "text/markdown"
  }

  notification_channels = concat(
    [google_monitoring_notification_channel.email[each.key].name],
    lookup(var.extra_notification_channels, each.key, []),
  )

  user_labels = {
    source = "personalized-service-health"
    scope  = "managed-lustre-dependencies"
  }

  depends_on = [google_project_service.servicehealth]
}

