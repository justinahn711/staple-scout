from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from staple_scout.main import create_app


@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(tmp_path / "test.sqlite3"), base_url="http://localhost") as value:
        yield value


def make_staple(client, **extra):
    body = {"name": "Rice", "basis": "oz", "rules": "", **extra}
    response = client.post("/api/staples", json=body)
    assert response.status_code == 201, response.text
    return response.json()


def add_offer(client, staple_id, *, price="3", quantity="10", unit="oz", pack_count=1,
              channel="in_store", approved=True, available=True, conditions="", product_name="Rice", observed_at=None):
    body = {"staple_id": staple_id, "store_id": "wegmans", "product_name": product_name,
            "price": price, "quantity": quantity, "unit": unit, "pack_count": pack_count,
            "channel": channel, "observed_at": observed_at or datetime.now(timezone.utc).isoformat(),
            "approved": approved, "available": available, "conditions": conditions}
    response = client.post("/api/observations", json=body)
    assert response.status_code == 201, response.text
    return response.json()


def test_exact_partial_bulk_multipack_and_count_outlay(client):
    item = make_staple(client, desired_quantity="30", desired_unit="oz")
    exact = add_offer(client, item["id"], product_name="exact", quantity="10", price="3")
    partial = add_offer(client, item["id"], product_name="partial", quantity="16", price="2")
    bulk = add_offer(client, item["id"], product_name="bulk", quantity="100", price="8")
    result = client.get("/api/comparisons").json()[0]
    assert result["unit_price_winner_id"] == bulk["id"]
    assert result["purchase_cost_winner_id"] == partial["id"]
    by_id = {row["id"]: row for row in result["offers"]}
    assert by_id[exact["id"]]["packages_needed"] == 3
    assert by_id[exact["id"]]["purchase_cost"] == "9"
    assert by_id[exact["id"]]["excess_quantity"] == "0"
    assert by_id[partial["id"]]["packages_needed"] == 2
    assert by_id[partial["id"]]["purchase_cost"] == "4"
    assert by_id[partial["id"]]["excess_quantity"] == "2"
    assert by_id[bulk["id"]]["packages_needed"] == 1
    assert by_id[bulk["id"]]["excess_quantity"] == "70"
    multi = add_offer(client, item["id"], product_name="multipack", quantity="10", pack_count=2, price="5")
    assert {row["id"]: row for row in client.get("/api/comparisons").json()[0]["offers"]}[multi["id"]]["packages_needed"] == 2


def test_units_count_no_quantity_and_validation(client):
    item = make_staple(client, desired_quantity="3", desired_unit="each", basis="each")
    row = add_offer(client, item["id"], quantity="2", unit="each", price="4")
    offer = next(x for x in client.get("/api/comparisons").json()[0]["offers"] if x["id"] == row["id"])
    assert offer["purchase_cost"] == "8" and offer["excess_quantity"] == "1"
    no_quantity = make_staple(client, basis="oz")
    bare = add_offer(client, no_quantity["id"], quantity="10", unit="oz")
    bare_offer = client.get("/api/comparisons").json()[1]["offers"][0]
    assert bare_offer["id"] == bare["id"] and "purchase_cost" not in bare_offer
    assert client.post("/api/staples", json={"name":"bad","basis":"oz","rules":"","desired_quantity":3,"desired_unit":"g"}).status_code == 422
    assert client.post("/api/staples", json={"name":"bad","basis":"oz","rules":"","desired_quantity":"3"}).status_code == 422
    assert client.post("/api/staples", json={"name":"bad","basis":"oz","rules":"","desired_quantity":"3","desired_unit":"each"}).status_code == 422


def test_quantity_patch_pair_basis_and_reviews(client):
    item = make_staple(client, desired_quantity="2", desired_unit="oz")
    assert client.patch(f"/api/staples/{item['id']}", json={"desired_quantity":"3"}).status_code == 422
    assert client.patch(f"/api/staples/{item['id']}", json={"desired_quantity":None,"desired_unit":None}).status_code == 200
    assert client.patch(f"/api/staples/{item['id']}", json={"desired_quantity":"3","desired_unit":"oz"}).status_code == 200
    assert client.patch(f"/api/staples/{item['id']}", json={"basis":"each"}).status_code == 422


def test_ineligible_offers_do_not_provide_outlay_winners(client):
    item = make_staple(client, desired_quantity="30", desired_unit="oz")
    good = add_offer(client, item["id"], product_name="good")
    for i, fields in enumerate(({"available":False}, {"approved":False}, {"conditions":"member"}, {"observed_at":(datetime.now(timezone.utc)-timedelta(hours=49)).isoformat()})):
        add_offer(client, item["id"], product_name=f"bad{i}", price="0.01", **fields)
    result = client.get("/api/comparisons").json()[0]
    assert result["unit_price_winner_id"] == good["id"]
    assert result["purchase_cost_winner_id"] == good["id"]
    assert client.get("/api/comparisons?channel=pickup").json()[0]["purchase_cost_winner_id"] is None
