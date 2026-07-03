variable "project_id" {
  type        = string
  description = "GCP project ID (dedicated project, not the fraud-detector one)"
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "service_name" {
  type    = string
  default = "quake-pipeline"
}

variable "image" {
  type        = string
  description = "Cloud Run container image URI. Placeholder on first apply; CI passes the built image on later applies."
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "github_repo" {
  type        = string
  description = "GitHub repo allowed to assume the CI service account, as \"owner/repo\""
}

variable "bq_dataset" {
  type    = string
  default = "quakes"
}
