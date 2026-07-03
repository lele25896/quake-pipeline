# Backend setup (one-time, manual)

Chicken-egg: Terraform needs a state bucket and a CI identity before CI can
run Terraform. Do this once, by hand, with your own `gcloud` auth.

## 1. New GCP project

```
gcloud projects create quake-pipeline-<random-suffix> --name="Quake Pipeline"
gcloud config set project quake-pipeline-<random-suffix>
gcloud billing projects link quake-pipeline-<random-suffix> --billing-account=<BILLING_ACCOUNT_ID>
```

Enable the APIs Terraform itself needs to bootstrap (the rest are enabled by
`google_project_service` in `main.tf`):

```
gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com iam.googleapis.com
```

## 2. State bucket

```
gsutil mb -l europe-west1 gs://quake-pipeline-<PROJECT_ID>-tfstate
gsutil versioning set on gs://quake-pipeline-<PROJECT_ID>-tfstate
```

Edit `terraform/main.tf` `backend "gcs" { bucket = "..." }` to that bucket
name. Fill in `terraform/terraform.tfvars`: `project_id`, `github_repo`
("owner/repo").

## 3. First apply (local, your own credentials)

```
gcloud auth application-default login
cd terraform
terraform init
terraform apply
```

This creates everything, including the `github-ci` service account and the
Workload Identity Federation pool/provider. `image` defaults to a public
placeholder so this apply doesn't need a built image yet.

## 4. Grant CI access to the state bucket

The bucket isn't Terraform-managed (can't reference it from its own
backend), so grant it manually:

```
gsutil iam ch serviceAccount:github-ci@<PROJECT_ID>.iam.gserviceaccount.com:objectAdmin \
  gs://quake-pipeline-<PROJECT_ID>-tfstate
```

## 5. GitHub Actions secrets/vars

In the repo settings, add as repo variables (not secrets — WIF is keyless):

- `GCP_PROJECT_ID`
- `GCP_WORKLOAD_IDENTITY_PROVIDER` — from `terraform output workload_identity_provider`
- `GCP_CI_SERVICE_ACCOUNT` — from `terraform output github_ci_service_account`

From here on, push to `main` runs `terraform apply` through CI, keyless.
