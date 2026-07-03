# Quake Pipeline

Event-driven Terraform project. Second GCP/IaC project for the CV, deliberately
a different pattern from the [Credit Card Fraud Detection](https://github.com)
project's Cloud Run request/response API: here everything is async,
streaming, and provisioned end-to-end from Terraform on a dedicated GCP
project.

## Architecture

```
Cloud Scheduler (every 5 min, OIDC)
  → Cloud Run  POST /ingest   — fetch USGS all_hour.geojson, publish 1 msg/quake
  → Pub/Sub topic "quakes" → push subscription (OIDC)
  → Cloud Run  POST /consume  — validate, z-score magnitude, insert BigQuery
  → BigQuery dataset "quakes"
       events          (raw, time-partitioned)
       events_latest   (view, deduped by id/updated)
       anomalies       (view, events_latest WHERE is_anomaly)
```

One Cloud Run service, two endpoints — no need for two deployable units at
this scale. Anomaly score is a z-score of magnitude against the trailing
30-day mean/std (computed via BigQuery, cached 1h in-process); falls back to
a constant prior until 30 days of data exist.

Data source: [USGS Earthquake GeoJSON feed](https://earthquake.usgs.gov/earthquakes/feed/v1.0/geojson.php),
public, no API key.

## Repo layout

```
app/            Flask service (main.py), Dockerfile, requirements
terraform/      All infra: Cloud Run, Pub/Sub, BigQuery, Scheduler, WIF
tests/          Self-check for scoring/parsing logic (no GCP creds needed)
BACKEND-SETUP.md  One-time manual bootstrap (new project, state bucket, first apply)
.github/workflows/deploy.yml  plan on PR, build+apply on push to main
```

## Setup

See [BACKEND-SETUP.md](BACKEND-SETUP.md) for the one-time bootstrap (new GCP
project, state bucket, first local `terraform apply`, WIF wiring). After
that, CI handles plan/apply on every PR/push, keyless.

## Example queries

```sql
-- Recent anomalies
SELECT id, place, mag, z_score, TIMESTAMP_SECONDS(CAST(time AS INT64)) AS occurred_at
FROM `quakes.anomalies`
ORDER BY time DESC
LIMIT 20;

-- Quake volume by day
SELECT DATE(time) AS day, COUNT(*) AS quakes, AVG(mag) AS avg_mag
FROM `quakes.events_latest`
GROUP BY day
ORDER BY day DESC;
```

## Out of scope (YAGNI)

Dataflow/Beam, multi-env workspaces, dashboards, dead-letter topic (add if
push delivery failures start piling up), model retraining.
