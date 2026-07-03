"""Quake pipeline service: /ingest publishes USGS quakes to Pub/Sub, /consume
scores + writes them to BigQuery. One Flask app, two endpoints — no need for
two Cloud Run services at this scale.
"""
import base64
import functools
import json
import os
import time

import requests
from flask import Flask, request, jsonify
from google.cloud import bigquery, pubsub_v1

app = Flask(__name__)

PROJECT_ID = os.environ["GCP_PROJECT"]
TOPIC_ID = os.environ["PUBSUB_TOPIC"]
BQ_DATASET = os.environ["BQ_DATASET"]
BQ_TABLE = os.environ.get("BQ_TABLE", "events")
USGS_FEED_URL = os.environ.get(
    "USGS_FEED_URL",
    "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_hour.geojson",
)
ANOMALY_Z_THRESHOLD = float(os.environ.get("ANOMALY_Z_THRESHOLD", "3.0"))
BASELINE_TTL_SECONDS = int(os.environ.get("BASELINE_TTL_SECONDS", "3600"))
# ponytail: fallback baseline is a rough global magnitude prior for the all_hour
# feed (mostly M1-M3 chatter), used only until 30 days of real data exist.
FALLBACK_MEAN, FALLBACK_STD = 1.5, 1.0

# ponytail: lazy clients so importing this module (e.g. in tests) doesn't
# require live GCP credentials.
@functools.lru_cache(maxsize=1)
def get_publisher():
    return pubsub_v1.PublisherClient()


@functools.lru_cache(maxsize=1)
def get_bq_client():
    return bigquery.Client()


_baseline_cache = {"mean": None, "std": None, "fetched_at": 0.0}


def fetch_quakes(feed_url=USGS_FEED_URL):
    resp = requests.get(feed_url, timeout=10)
    resp.raise_for_status()
    return resp.json()["features"]


def feature_to_row(feature):
    props = feature["properties"]
    coords = feature["geometry"]["coordinates"]
    return {
        "id": feature["id"],
        "mag": props.get("mag"),
        "place": props.get("place"),
        # USGS gives epoch ms; BigQuery streaming inserts want epoch seconds.
        "time": props["time"] / 1000,
        "updated": props["updated"] / 1000,
        "longitude": coords[0],
        "latitude": coords[1],
        "depth_km": coords[2],
        "url": props.get("url"),
        "tsunami": bool(props.get("tsunami")),
        "sig": props.get("sig"),
    }


def get_baseline():
    """Trailing 30-day mean/std of magnitude, cached with a TTL. Falls back
    to a constant prior when the table has no data yet (cold start)."""
    now = time.time()
    if _baseline_cache["mean"] is not None and now - _baseline_cache["fetched_at"] < BASELINE_TTL_SECONDS:
        return _baseline_cache["mean"], _baseline_cache["std"]

    query = f"""
        SELECT AVG(mag) AS mean_mag, STDDEV(mag) AS std_mag
        FROM `{PROJECT_ID}.{BQ_DATASET}.{BQ_TABLE}`
        WHERE time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
          AND mag IS NOT NULL
    """
    row = next(iter(get_bq_client().query(query).result()), None)
    mean = row.mean_mag if row and row.mean_mag is not None else FALLBACK_MEAN
    std = row.std_mag if row and row.std_mag else FALLBACK_STD

    _baseline_cache.update(mean=mean, std=std, fetched_at=now)
    return mean, std


def zscore(mag, mean, std):
    if mag is None or not std:
        return None
    return (mag - mean) / std


@app.get("/")
def health():
    return "ok"


@app.post("/ingest")
def ingest():
    features = fetch_quakes()
    publisher = get_publisher()
    topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)
    for feature in features:
        publisher.publish(topic_path, json.dumps(feature).encode("utf-8"))
    return jsonify(published=len(features))


@app.post("/consume")
def consume():
    envelope = request.get_json()
    if not envelope or "message" not in envelope:
        return "bad request: no Pub/Sub message", 400

    feature = json.loads(base64.b64decode(envelope["message"]["data"]))
    row = feature_to_row(feature)
    mean, std = get_baseline()
    row["z_score"] = zscore(row["mag"], mean, std)
    row["is_anomaly"] = row["z_score"] is not None and abs(row["z_score"]) >= ANOMALY_Z_THRESHOLD

    table_ref = f"{PROJECT_ID}.{BQ_DATASET}.{BQ_TABLE}"
    errors = get_bq_client().insert_rows_json(table_ref, [row])
    if errors:
        return jsonify(errors=errors), 500
    return jsonify(inserted=row["id"])


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
