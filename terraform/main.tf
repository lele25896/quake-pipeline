terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Bucket created manually in bootstrap (BACKEND-SETUP.md) — chicken-egg,
  # backend config can't reference a Terraform-managed resource.
  backend "gcs" {
    bucket = "quake-pipeline-quake-pipeline-90565-tfstate"
    prefix = "quake-pipeline"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {}

locals {
  apis = [
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "pubsub.googleapis.com",
    "bigquery.googleapis.com",
    "cloudscheduler.googleapis.com",
    "iamcredentials.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = each.value
  disable_on_destroy = false
}

# --- Artifact Registry ---------------------------------------------------

resource "google_artifact_registry_repository" "repo" {
  repository_id = var.service_name
  format        = "DOCKER"
  location      = var.region
  depends_on    = [google_project_service.apis]
}

# --- Pub/Sub ---------------------------------------------------------------

resource "google_pubsub_topic" "quakes" {
  name       = "quakes"
  depends_on = [google_project_service.apis]
}

# Pub/Sub's own service agent needs to mint OIDC tokens as the push SA.
resource "google_service_account_iam_member" "pubsub_push_token_creator" {
  service_account_id = google_service_account.pubsub_push.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_subscription" "consumer" {
  name  = "quake-consumer"
  topic = google_pubsub_topic.quakes.id

  ack_deadline_seconds = 30

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.quake.uri}/consume"
    oidc_token {
      service_account_email = google_service_account.pubsub_push.email
    }
  }
}

# --- Service accounts --------------------------------------------------

resource "google_service_account" "runtime" {
  account_id   = "quake-runtime"
  display_name = "Quake pipeline runtime (Cloud Run)"
}

resource "google_service_account" "scheduler" {
  account_id   = "quake-scheduler"
  display_name = "Invokes /ingest via Cloud Scheduler"
}

resource "google_service_account" "pubsub_push" {
  account_id   = "quake-pubsub-push"
  display_name = "Invokes /consume via Pub/Sub push"
}

resource "google_service_account" "github_ci" {
  account_id   = "github-ci"
  display_name = "GitHub Actions CI (WIF, keyless)"
}

resource "google_pubsub_topic_iam_member" "runtime_publisher" {
  topic  = google_pubsub_topic.quakes.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_bigquery_dataset_iam_member" "runtime_editor" {
  dataset_id = google_bigquery_dataset.quakes.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "runtime_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_cloud_run_v2_service_iam_member" "scheduler_invoker" {
  name     = google_cloud_run_v2_service.quake.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_cloud_run_v2_service_iam_member" "pubsub_push_invoker" {
  name     = google_cloud_run_v2_service.quake.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.pubsub_push.email}"
}

# CI project-level roles. Bucket IAM for state is granted manually in
# bootstrap (BACKEND-SETUP.md) since the bucket itself isn't Terraform-managed.
resource "google_project_iam_member" "github_ci_roles" {
  for_each = toset([
    "roles/run.admin",
    "roles/artifactregistry.admin",
    "roles/pubsub.admin",
    "roles/bigquery.admin",
    "roles/cloudscheduler.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.github_ci.email}"
}

# --- Workload Identity Federation (keyless CI) --------------------------

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }
  attribute_condition = "assertion.repository == \"${var.github_repo}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_ci_wif" {
  service_account_id = google_service_account.github_ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

# --- Cloud Run ---------------------------------------------------------

resource "google_cloud_run_v2_service" "quake" {
  name     = var.service_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.runtime.email
    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }
    containers {
      image = var.image
      env {
        name  = "GCP_PROJECT"
        value = var.project_id
      }
      env {
        name  = "PUBSUB_TOPIC"
        value = google_pubsub_topic.quakes.name
      }
      env {
        name  = "BQ_DATASET"
        value = google_bigquery_dataset.quakes.dataset_id
      }
    }
  }

  depends_on = [google_project_service.apis]

  lifecycle {
    ignore_changes = [template[0].containers[0].image]
  }
}

# --- BigQuery ------------------------------------------------------------

resource "google_bigquery_dataset" "quakes" {
  dataset_id = var.bq_dataset
  location   = var.region
  depends_on = [google_project_service.apis]
}

resource "google_bigquery_table" "events" {
  dataset_id = google_bigquery_dataset.quakes.dataset_id
  table_id   = "events"

  time_partitioning {
    type  = "DAY"
    field = "time"
  }

  schema = jsonencode([
    { name = "id", type = "STRING", mode = "REQUIRED" },
    { name = "mag", type = "FLOAT64", mode = "NULLABLE" },
    { name = "place", type = "STRING", mode = "NULLABLE" },
    { name = "time", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "updated", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "longitude", type = "FLOAT64", mode = "NULLABLE" },
    { name = "latitude", type = "FLOAT64", mode = "NULLABLE" },
    { name = "depth_km", type = "FLOAT64", mode = "NULLABLE" },
    { name = "url", type = "STRING", mode = "NULLABLE" },
    { name = "tsunami", type = "BOOL", mode = "NULLABLE" },
    { name = "sig", type = "INT64", mode = "NULLABLE" },
    { name = "z_score", type = "FLOAT64", mode = "NULLABLE" },
    { name = "is_anomaly", type = "BOOL", mode = "NULLABLE" },
  ])
}

resource "google_bigquery_table" "events_latest" {
  dataset_id = google_bigquery_dataset.quakes.dataset_id
  table_id   = "events_latest"

  view {
    use_legacy_sql = false
    query          = <<-SQL
      SELECT * EXCEPT(rn) FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated DESC) AS rn
        FROM `${var.project_id}.${var.bq_dataset}.events`
      )
      WHERE rn = 1
    SQL
  }
}

resource "google_bigquery_table" "anomalies" {
  dataset_id = google_bigquery_dataset.quakes.dataset_id
  table_id   = "anomalies"

  view {
    use_legacy_sql = false
    query          = <<-SQL
      SELECT * FROM `${var.project_id}.${var.bq_dataset}.events_latest`
      WHERE is_anomaly
    SQL
  }
}

# --- Cloud Scheduler -----------------------------------------------------

resource "google_cloud_scheduler_job" "ingest" {
  name      = "quake-ingest-trigger"
  schedule  = "*/5 * * * *"
  time_zone = "UTC"

  http_target {
    uri         = "${google_cloud_run_v2_service.quake.uri}/ingest"
    http_method = "POST"
    oidc_token {
      service_account_email = google_service_account.scheduler.email
      audience              = google_cloud_run_v2_service.quake.uri
    }
  }

  depends_on = [google_project_service.apis]
}
