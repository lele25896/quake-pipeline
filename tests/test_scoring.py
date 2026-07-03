"""Runnable self-check for the pure logic in app/main.py: GeoJSON -> row
parsing and z-score anomaly math. No GCP credentials needed (clients are
lazy)."""
import os
import sys

os.environ.setdefault("GCP_PROJECT", "test-project")
os.environ.setdefault("PUBSUB_TOPIC", "test-topic")
os.environ.setdefault("BQ_DATASET", "test_dataset")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))
from main import feature_to_row, zscore  # noqa: E402

SAMPLE_FEATURE = {
    "id": "us7000abcd",
    "properties": {
        "mag": 4.5,
        "place": "10km NE of Somewhere",
        "time": 1700000000000,
        "updated": 1700000100000,
        "url": "https://earthquake.usgs.gov/x",
        "tsunami": 0,
        "sig": 312,
    },
    "geometry": {"coordinates": [-122.1, 37.5, 10.2]},
}


def test_feature_to_row():
    row = feature_to_row(SAMPLE_FEATURE)
    assert row["id"] == "us7000abcd"
    assert row["mag"] == 4.5
    assert row["time"] == 1700000000.0
    assert row["longitude"] == -122.1
    assert row["latitude"] == 37.5
    assert row["depth_km"] == 10.2
    assert row["tsunami"] is False


def test_zscore_normal():
    assert zscore(2.0, mean=2.0, std=1.0) == 0.0
    assert zscore(5.0, mean=2.0, std=1.0) == 3.0


def test_zscore_missing_inputs():
    assert zscore(None, mean=2.0, std=1.0) is None
    assert zscore(5.0, mean=2.0, std=0) is None


if __name__ == "__main__":
    test_feature_to_row()
    test_zscore_normal()
    test_zscore_missing_inputs()
    print("ok")
