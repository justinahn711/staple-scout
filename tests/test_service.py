from datetime import datetime, timedelta, timezone
from decimal import Decimal
import sqlite3

from fastapi.testclient import TestClient
import pytest

from staple_scout.comparison import compare, unit_price
from staple_scout.main import create_app


@pytest.fixture
def database_path(tmp_path):
    return tmp_path / "test.sqlite3"


@pytest.fixture
def client(database_path):
    with TestClient(create_app(database_path), base_url="http://localhost") as client:
        yield client


def staple(client, **overrides):
    response = client.post("/api/staples", json={"name": "Plain oats", "basis": "oz", "rules": "Unflavored", **overrides})
    assert response.status_code == 201, response.text
    return response.json()


def observation(client, staple_id, **overrides):
    body = {"staple_id": staple_id, "store_id": "wegmans", "product_name": "Oats", "price": "6.00", "quantity": "12", "unit": "oz", "pack_count": 2, "channel": "in_store", "observed_at": (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat(), "available": True, "approved": True, **overrides}
    # These fixtures explicitly reuse a product identity for refresh scenarios.
    key = (staple_id, body["store_id"], body["product_name"], Decimal(body["quantity"]),
           body["unit"], body.get("pack_count", 1))
    identities = getattr(client, "test_variant_ids", {})
    if key in identities:
        body.setdefault("variant_id", identities[key])
    response = client.post("/api/observations", json=body)
    assert response.status_code == 201, response.text
    identities[key] = response.json()["variant_id"]
    client.test_variant_ids = identities
    return response.json()


def test_empty_start_and_source_honesty(client):
    assert client.get("/api/health").json() == {"status": "ok"}
    assert client.get("/api/staples").json() == []
    assert client.get("/api/comparisons").json() == []
    stores = client.get("/api/stores").json()
    assert {row["id"] for row in stores} == {"wegmans", "walmart", "target", "hmart", "lidl"}
    assert all(row["source_status"] == "not_connected" for row in stores)
    assert client.get("/", follow_redirects=False).headers["location"] == "/docs"


@pytest.mark.parametrize("unit,quantity,basis,expected", [
    ("oz", "12", "oz", Decimal("0.25")),
    ("lb", "0.75", "oz", Decimal("0.25")),
    ("g", "100", "oz", Decimal("0.85048569375")),
    ("kg", "0.1", "oz", Decimal("0.85048569375")),
    ("ml", "100", "fl_oz", Decimal("0.887205886875")),
    ("l", "0.1", "fl_oz", Decimal("0.887205886875")),
    ("fl_oz", "12", "fl_oz", Decimal("0.25")),
    ("each", "12", "each", Decimal("0.25")),
])
def test_unit_conversion_and_multipacks(unit, quantity, basis, expected):
    value = unit_price({"unit": unit, "quantity": quantity, "price": "6", "pack_count": 2}, basis)
    assert abs(value - expected) < Decimal("1e-40")


@pytest.mark.parametrize("unit,basis", [("oz", "fl_oz"), ("each", "oz"), ("ml", "each"), ("kg", "fl_oz")])
def test_dimensions_never_mix(unit, basis):
    assert unit_price({"unit": unit, "quantity": "12", "price": "6", "pack_count": 1}, basis) is None


def test_each_eligibility_condition_and_winner(client):
    item = staple(client)
    winner = observation(client, item["id"])
    excluded = [
        ({"approved": False}, "not_approved"),
        ({"available": False}, "unavailable"),
        ({"channel": "online"}, "not_in_store"),
        ({"channel": "pickup"}, "not_in_store"),
        ({"conditions": "Loyalty card required"}, "conditional_price"),
        ({"observed_at": (datetime.now(timezone.utc) - timedelta(hours=49)).isoformat()}, "stale"),
        ({"unit": "fl_oz"}, "incompatible_dimension"),
    ]
    for index, (fields, reason) in enumerate(excluded):
        observation(client, item["id"], product_name=f"Alternative {index}", price="0.01", **fields)
    result = client.get("/api/comparisons").json()[0]
    assert result["winner_id"] == winner["id"]
    assert Decimal(result["offers"][0]["unit_price"]) == Decimal("0.25")
    for offer, (_, reason) in zip(result["offers"][1:], excluded):
        assert not offer["eligible"]
        assert offer["exclusion_reasons"] == [reason]
    assert result["offers"][-1]["unit_price"] is None


def test_comparison_channel_is_explicit_and_never_mixes_shelf_pickup_or_online(client):
    item = staple(client)
    shelf = observation(client, item["id"], product_name="Shelf", price="8")
    pickup = observation(client, item["id"], product_name="Pickup", price="1", channel="pickup")
    online = observation(client, item["id"], product_name="Online", price="0.10", channel="online")
    shelf_result = client.get("/api/comparisons?channel=in_store").json()[0]
    assert shelf_result["winner_id"] == shelf["id"]
    assert next(o for o in shelf_result["offers"] if o["id"] == pickup["id"])["exclusion_reasons"] == ["not_in_store"]
    pickup_result = client.get("/api/comparisons?channel=pickup").json()[0]
    assert pickup_result["winner_id"] == pickup["id"]
    assert next(o for o in pickup_result["offers"] if o["id"] == shelf["id"])["exclusion_reasons"] == ["not_pickup"]
    assert next(o for o in pickup_result["offers"] if o["id"] == online["id"])["exclusion_reasons"] == ["not_pickup"]
    assert client.get("/api/comparisons?channel=online").status_code == 422


def test_comparison_reports_channel_gap_and_rejects_internal_unknown_channel():
    item = {"basis": "each"}
    empty = compare(item, [], channel="pickup")
    assert empty["channel"] == "pickup" and empty["winner_id"] is None
    assert empty["gap"] == "no_observations"
    row = {"id": 1, "price": "1", "quantity": "1", "pack_count": 1, "unit": "each", "approved": False,
           "available": True, "conditions": "", "channel": "pickup", "observed_at": datetime.now(timezone.utc).isoformat()}
    assert compare(item, [row], channel="pickup")["gap"] == "no_eligible_offers"
    with pytest.raises(ValueError):
        compare(item, [], channel="online")


def test_freshness_boundary_and_recomputed_age():
    now = datetime.now(timezone.utc)
    row = {"id": 1, "price": "1", "quantity": "1", "pack_count": 1, "unit": "each", "approved": True, "available": True, "conditions": "", "channel": "in_store", "observed_at": (now - timedelta(hours=48) + timedelta(microseconds=1)).isoformat()}
    item = {"basis": "each"}
    assert compare(item, [row], now)["winner_id"] == 1
    assert compare(item, [row], now + timedelta(microseconds=1))["offers"][0]["exclusion_reasons"] == ["stale"]
    row["observed_at"] = (now + timedelta(seconds=1)).isoformat()
    assert compare(item, [row], now)["offers"][0]["exclusion_reasons"] == ["future_observation"]


def test_latest_observation_not_cheapest_or_latest_insert_and_history_persists(client, database_path):
    item = staple(client)
    now = datetime.now(timezone.utc)
    older = observation(client, item["id"], price="1", observed_at=(now - timedelta(hours=2)).isoformat())
    latest = observation(client, item["id"], price="10", observed_at=(now - timedelta(hours=1)).isoformat())
    observation(client, item["id"], price="0.01", observed_at=(now - timedelta(hours=3)).isoformat())
    result = client.get("/api/comparisons").json()[0]
    assert [offer["id"] for offer in result["offers"]] == [latest["id"]]
    assert result["winner_id"] == latest["id"]
    with TestClient(create_app(database_path), base_url="http://localhost") as restarted:
        assert restarted.get("/api/comparisons").json() == [result]
    with sqlite3.connect(database_path) as db:
        assert db.execute("SELECT count(*) FROM observations").fetchone()[0] == 3
        assert db.execute("SELECT price FROM observations WHERE id = ?", (older["id"],)).fetchone()[0] == "1"
    # Equal observation times use insertion ID, and unavailability replaces the old offer.
    newest = observation(client, item["id"], available=False, observed_at=latest["observed_at"])
    result = client.get("/api/comparisons").json()[0]
    assert [offer["id"] for offer in result["offers"]] == [newest["id"]]
    assert result["winner_id"] is None


def test_offset_dates_order_by_actual_time_and_channels_stay_separate(client):
    item = staple(client)
    now = datetime.now(timezone.utc) - timedelta(minutes=10)
    observation(client, item["id"], observed_at=(now - timedelta(hours=1)).astimezone(timezone(timedelta(hours=12))).isoformat())
    latest = observation(client, item["id"], observed_at=now.astimezone(timezone(timedelta(hours=-8))).isoformat())
    online = observation(client, item["id"], channel="online", observed_at=now.isoformat())
    result = client.get("/api/comparisons").json()[0]
    assert {row["id"] for row in result["offers"]} == {latest["id"], online["id"]}
    assert result["winner_id"] == latest["id"]


def test_filters_crud_and_deliberate_cascade(client, database_path):
    first, second = staple(client), staple(client, name="Milk", basis="fl_oz", needed=False)
    observation(client, first["id"])
    assert len(client.get("/api/comparisons?needed_only=true").json()) == 1
    assert client.get("/api/comparisons?stores=walmart").json()[0]["offers"] == []
    assert client.get("/api/comparisons?stores=costco").status_code == 422
    assert client.get("/api/comparisons?stores=").status_code == 422
    assert client.patch(f"/api/staples/{first['id']}", json={"basis": "each", "needed": False}).status_code == 200
    assert client.get("/api/comparisons").json()[0]["offers"][0]["exclusion_reasons"] == ["incompatible_dimension", "not_approved"]
    assert client.patch(f"/api/staples/{first['id']}", json={"name": None}).status_code == 422
    assert client.delete(f"/api/staples/{first['id']}").status_code == 204
    assert client.delete(f"/api/staples/{first['id']}").status_code == 404
    assert client.get("/api/staples").json() == [second]
    with sqlite3.connect(database_path) as db:
        assert db.execute("SELECT count(*) FROM observations").fetchone()[0] == 0


@pytest.mark.parametrize("field,value", [
    ("price", "NaN"), ("price", "Infinity"), ("price", "-0.01"),
    ("price", "1000000.01"), ("price", "1.1234567"), ("price", 2.5),
    ("quantity", "0"), ("quantity", "-1"), ("quantity", "Infinity"),
    ("quantity", "1000001"), ("pack_count", 0), ("pack_count", 1.5),
    ("pack_count", True), ("pack_count", 10001), ("unit", "cup"),
    ("store_id", "costco"), ("approved", "true"), ("available", "false"),
    ("product_name", "   "), ("source_url", "javascript:alert(1)"),
    ("source_url", "https://user:password@example.com"),
    ("observed_at", "2020-01-01T00:00:00"),
    ("observed_at", 0), ("observed_at", "0"),
    ("observed_at", "2999-01-01T00:00:00Z"),
])
def test_invalid_observations_do_not_persist(client, database_path, field, value):
    item = staple(client)
    body = {"staple_id": item["id"], "store_id": "wegmans", "product_name": "Oats", "price": "6", "quantity": "12", "unit": "oz", "channel": "in_store", "observed_at": "2020-01-01T00:00:00Z", field: value}
    response = client.post("/api/observations", json=body)
    assert response.status_code == 422, response.text
    with sqlite3.connect(database_path) as db:
        assert db.execute("SELECT count(*) FROM observations").fetchone()[0] == 0


def test_defaults_conservative_and_missing_references(client):
    item = staple(client)
    body = {"staple_id": item["id"], "store_id": "wegmans", "product_name": "Oats", "price": "6", "quantity": "12", "unit": "oz", "channel": "in_store", "observed_at": "2020-01-01T00:00:00Z"}
    saved = client.post("/api/observations", json=body).json()
    assert saved["pack_count"] == 1 and saved["approved"] is False and saved["available"] is True
    body["staple_id"] = 999
    assert client.post("/api/observations", json=body).status_code == 404
    assert client.patch("/api/staples/999", json={"name": "Missing"}).status_code == 404


def test_local_json_write_protection(client):
    body = {"name": "Oats", "basis": "oz"}
    for origin in ["https://evil.example", "null", "http://localhost.evil.example", "http://localhost:9000", "http://localhost@evil.example"]:
        assert client.post("/api/staples", json=body, headers={"origin": origin}).status_code == 403
    assert client.post("/api/staples", json=body, headers={"sec-fetch-site": "cross-site"}).status_code == 403
    assert client.post("/api/staples", content='{"name":"Oats","basis":"oz"}', headers={"content-type": "text/plain"}).status_code == 415
    assert client.post("/api/staples", json=body, headers={"origin": "http://localhost:80"}).status_code == 201
    assert client.post("/api/staples", json=body, headers={"host": "evil.example"}).status_code == 400
    assert client.get("/api/staples").headers.get("access-control-allow-origin") is None


def test_whitespace_only_conditions_are_unconditional(client):
    item = staple(client)
    row = observation(client, item["id"], conditions=" \n ")
    assert client.get("/api/comparisons").json()[0]["winner_id"] == row["id"]


@pytest.mark.parametrize("change", [{"name": "Steel-cut oats"}, {"rules": "Organic only"}, {"basis": "each"}])
def test_changed_identity_or_rules_clear_approval_but_keep_price_history(client, database_path, change):
    item = staple(client)
    row = observation(client, item["id"])
    assert client.patch(f"/api/staples/{item['id']}", json=change).status_code == 200
    result = client.get("/api/comparisons").json()[0]
    assert result["winner_id"] is None
    assert result["offers"][0]["approved"] is False
    with sqlite3.connect(database_path) as db:
        assert db.execute("SELECT id, price FROM observations").fetchall() == [(row["id"], "6.00")]


def test_no_op_and_needed_changes_preserve_approval(client):
    item = staple(client)
    row = observation(client, item["id"])
    for change in [{"needed": False}, {"name": item["name"], "basis": item["basis"], "rules": item["rules"]}, {}]:
        assert client.patch(f"/api/staples/{item['id']}", json=change).status_code == 200
        assert client.get("/api/comparisons").json()[0]["winner_id"] == row["id"]


def test_unconfigured_store_visible_but_cannot_win(client):
    item = staple(client)
    observation(client, item["id"], store_id="lidl")
    result = client.get("/api/comparisons").json()[0]
    assert result["winner_id"] is None
    assert result["offers"][0]["store_location"] == "Unselected"
    assert result["offers"][0]["exclusion_reasons"] == ["location_not_configured"]


def test_distinct_packages_stay_visible_and_equivalent_decimal_spellings_replace(client):
    item = staple(client)
    twelve = observation(client, item["id"], quantity="12.00", pack_count=1)
    sixteen = observation(client, item["id"], quantity="16", pack_count=1)
    multipack = observation(client, item["id"], quantity="12", pack_count=2)
    updated = observation(client, item["id"], quantity="12.0", pack_count=1, observed_at=(datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat())
    result = client.get("/api/comparisons").json()[0]
    assert {row["id"] for row in result["offers"]} == {sixteen["id"], multipack["id"], updated["id"]}
    assert twelve["id"] not in {row["id"] for row in result["offers"]}
    assert updated["quantity"] == "12"


def test_winner_compares_unit_price_not_package_price_and_ties_are_stable(client):
    item = staple(client)
    observation(client, item["id"], store_id="wegmans", price="6", quantity="12", pack_count=2)
    best = observation(client, item["id"], store_id="target", price="8", quantity="16", pack_count=4)
    observation(client, item["id"], store_id="walmart", price="8", quantity="16", pack_count=4)
    result = client.get("/api/comparisons").json()[0]
    assert result["winner_id"] == best["id"]
    assert Decimal(next(row for row in result["offers"] if row["id"] == best["id"])["unit_price"]) == Decimal("0.125")


def test_api_explorer_describes_decimal_inputs_as_strings(client):
    schema = client.get("/openapi.json").json()["components"]["schemas"]["ObservationCreate"]["properties"]
    assert schema["price"]["type"] == schema["quantity"]["type"] == "string"
