output "cloud_run_url" {
  value = google_cloud_run_v2_service.quake.uri
}

output "pubsub_topic" {
  value = google_pubsub_topic.quakes.id
}

output "bq_dataset" {
  value = google_bigquery_dataset.quakes.dataset_id
}

output "artifact_registry_repo" {
  value = google_artifact_registry_repository.repo.name
}

output "github_ci_service_account" {
  value = google_service_account.github_ci.email
}

output "workload_identity_provider" {
  value = google_iam_workload_identity_pool_provider.github.name
}
