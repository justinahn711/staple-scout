from datetime import datetime, timezone

from fastapi.testclient import TestClient

from staple_scout.database import Database
from staple_scout.main import create_app


def test_report_api_persists_cutoff_snapshot_across_reopen(tmp_path):
    path = tmp_path / "evidence.sqlite3"
    app = create_app(path)
    with TestClient(app, base_url="http://localhost") as client:
        staple = client.post("/api/staples", json={"name":"Rice", "basis":"oz"}).json()
        variant = client.post("/api/variants", json={"retailer":"wegmans", "retailer_product_id":"sku", "package_quantity":"16", "package_unit":"oz", "form":"bag"}).json()
        context = client.get("/api/stores/wegmans").json()["preferred_context_id"]
        assert client.put(f"/api/staples/{staple['id']}/matches/{variant['id']}", json={"status":"approved"}).status_code == 200
        observation = {"staple_id":staple["id"],"variant_id":variant["id"],"store_id":"wegmans","context_id":context,
            "product_name":"Rice","price":"4.00","quantity":"16","unit":"oz","pack_count":1,
            "channel":"in_store","observed_at":"2026-01-01T12:00:00Z","available":True}
        assert client.post("/api/observations", json=observation).status_code == 201
        request = {"as_of":"2026-01-02T00:00:00Z","stores":["wegmans"],"channel":"in_store"}
        created = client.post("/api/reports", json=request)
        assert created.status_code == 201
        report = created.json()
        assert report["comparisons"][0]["winner_id"] is not None
        report_id = report["id"]
    reopened = create_app(path)
    with TestClient(reopened, base_url="http://localhost") as client:
        fetched = client.get(f"/api/reports/{report_id}")
        assert fetched.status_code == 200
        assert fetched.json() == report


def test_report_cutoff_excludes_later_observation(tmp_path):
    path = tmp_path / "cutoff.sqlite3"
    app = create_app(path)
    with TestClient(app, base_url="http://localhost") as client:
        staple = client.post("/api/staples", json={"name":"Rice", "basis":"oz"}).json()
        variant = client.post("/api/variants", json={"retailer":"wegmans", "retailer_product_id":"sku", "package_quantity":"16", "package_unit":"oz", "form":"bag"}).json()
        context = client.get("/api/stores/wegmans").json()["preferred_context_id"]
        client.put(f"/api/staples/{staple['id']}/matches/{variant['id']}", json={"status":"approved"})
        base = {"staple_id":staple["id"],"variant_id":variant["id"],"store_id":"wegmans","context_id":context,"product_name":"Rice","quantity":"16","unit":"oz","pack_count":1,"channel":"in_store","available":True}
        for price, when in [("4.00", "2026-01-01T12:00:00Z"), ("2.00", "2026-01-03T12:00:00Z")]:
            assert client.post("/api/observations", json={**base,"price":price,"observed_at":when}).status_code == 201
        report = client.post("/api/reports", json={"as_of":"2026-01-02T00:00:00Z","stores":["wegmans"],"channel":"in_store"}).json()
        assert report["comparisons"][0]["offers"][0]["price"] == "4.00"
