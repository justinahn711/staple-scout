"""Fixture-only contract tests for adapter refresh ingestion."""
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from staple_scout.adapters import AdapterRegistration, OfferEvidence
from staple_scout.main import create_app

NOW = datetime.now(timezone.utc).replace(microsecond=0)


class FakeAdapter:
    retailer = "wegmans"

    def __init__(self, evidence=(), error=None):
        self.evidence, self.error, self.calls = list(evidence), error, 0

    def fetch(self, context, product_ids, *, timeout):
        self.calls += 1
        if self.error:
            raise self.error
        return [x for x in self.evidence if x.retailer_product_id in product_ids]


def evidence(*, product="sku-1", price="4.00", quantity="16", available=True,
             observed_at=NOW, retrieved_at=NOW, channel="in_store",
             location_id="133", seller="Wegmans", form="bag",
             source_url="https://example.test/products/sku-1", valid_until=None):
    return OfferEvidence(source_record_id=f"record-{product}", retailer_product_id=product,
        product_name="Long Grain Rice", barcode=None,
        price=None if price is None else Decimal(price), currency="USD",
        quantity=None if quantity is None else Decimal(quantity),
        unit=None if quantity is None else "oz", quantity_kind="fixed", pack_count=1,
        form=form, channel=channel, available=available, seller=seller,
        location_id=location_id, observed_at=observed_at, retrieved_at=retrieved_at,
        source_url=source_url, valid_until=valid_until)


@pytest.fixture
def setup(tmp_path):
    fake = FakeAdapter()
    app = create_app(tmp_path / "ingestion.sqlite3", adapters={"fixture": AdapterRegistration(
        source_id="fixture", retailer="wegmans", adapter=fake,
        channels=frozenset({"in_store"}), sellers=frozenset({"Wegmans"}), validated=True)})
    with TestClient(app, base_url="http://localhost") as client:
        staple = client.post("/api/staples", json={"name": "Rice", "basis": "oz"}).json()
        store = client.get("/api/stores/wegmans").json()
        variant = client.post("/api/variants", json={"retailer":"wegmans", "retailer_product_id":"sku-1", "package_quantity":"16", "package_unit":"oz", "form":"bag"}).json()
        yield client, fake, staple["id"], store["preferred_context_id"], variant["id"]


def request(staple_id, context_id, key="key-1", product="sku-1", channel="in_store"):
    return {"source_id": "fixture", "context_id": context_id, "channel": channel,
            "requests": [{"staple_id": staple_id, "retailer_product_id": product}],
            "idempotency_key": key}


def test_refresh_accepts_evidence_and_returns_typed_result(setup):
    client, fake, staple_id, context_id, _ = setup
    fake.evidence = [evidence()]
    response = client.post("/api/refresh", json=request(staple_id, context_id))
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "succeeded"
    assert body["results"][0]["status"] == "accepted"
    assert body["results"][0]["evidence"]["retailer_product_id"] == "sku-1"


def test_retry_same_key_does_not_fetch_twice_and_conflict_is_409(setup):
    client, fake, staple_id, context_id, _ = setup
    fake.evidence = [evidence()]
    payload = request(staple_id, context_id)
    first, second = client.post("/api/refresh", json=payload), client.post("/api/refresh", json=payload)
    assert first.status_code == second.status_code == 200
    assert first.json()["id"] == second.json()["id"] and fake.calls == 1
    assert client.post("/api/refresh", json=request(staple_id, context_id, product="other")).status_code == 409


@pytest.mark.parametrize("source,channel,status", [("missing", "in_store", 404), ("fixture", "pickup", 422)])
def test_unknown_source_or_invalid_channel_is_rejected(setup, source, channel, status):
    client, _, staple_id, context_id, _ = setup
    payload = request(staple_id, context_id, channel=channel)
    payload["source_id"] = source
    assert client.post("/api/refresh", json=payload).status_code == status


def test_mismatched_response_context_fails_whole_run_without_observations(setup):
    client, fake, staple_id, context_id, _ = setup
    fake.evidence = [evidence(location_id="different-location")]
    response = client.post("/api/refresh", json=request(staple_id, context_id))
    assert response.status_code == 200
    assert response.json()["status"] == "failed"
    assert client.get("/api/observations").json() == []


def test_unknown_price_or_quantity_is_unresolved_and_mixed_batch_is_partial(setup):
    client, fake, staple_id, context_id, _ = setup
    fake.evidence = [evidence(product="sku-1", price=None), evidence(product="sku-2", quantity=None)]
    payload = request(staple_id, context_id)
    payload["requests"].append({"staple_id": staple_id, "retailer_product_id": "sku-2"})
    response = client.post("/api/refresh", json=payload)
    assert response.status_code == 200
    assert response.json()["status"] == "partial"
    assert all(x["status"] == "unresolved" for x in response.json()["results"])


def test_adapter_failure_is_safe_and_does_not_expose_exception(setup):
    client, fake, staple_id, context_id, _ = setup
    fake.error = RuntimeError("secret-token=do-not-leak")
    response = client.post("/api/refresh", json=request(staple_id, context_id))
    assert response.status_code in {200, 502, 503}
    assert "secret-token" not in response.text


@pytest.mark.parametrize("kwargs", [
    {"observed_at": datetime.now(timezone.utc) + timedelta(days=1)},
    {"observed_at": datetime.now().replace(tzinfo=None)},
    {"source_url": "https://example.test/p?token=secret"},
])
def test_evidence_rejects_unsafe_timestamps_and_urls(kwargs):
    with pytest.raises(ValueError):
        evidence(**kwargs)


def test_refresh_runs_are_listable_and_default_registry_is_empty(tmp_path):
    app = create_app(tmp_path / "empty.sqlite3")
    with TestClient(app, base_url="http://localhost") as client:
        assert client.get("/api/refresh-runs").status_code == 200
        assert client.get("/api/refresh-runs").json() == []


def test_unvalidated_registration_never_fetches(setup, tmp_path):
    client, fake, staple_id, context_id, _ = setup
    # A separate app makes the policy explicit and keeps the fixture isolated.
    blocked = FakeAdapter([evidence()])
    app = create_app(tmp_path / "blocked.sqlite3", adapters={"blocked": AdapterRegistration(
        source_id="blocked", retailer="wegmans", adapter=blocked,
        channels=frozenset({"in_store"}), sellers=frozenset({"Wegmans"}), validated=False)})
    with TestClient(app, base_url="http://localhost") as c:
        payload = request(staple_id, context_id)
        payload["source_id"] = "blocked"
        assert c.post("/api/refresh", json=payload).status_code in {403, 404, 422}
    assert blocked.calls == 0


def test_expired_evidence_is_unavailable_and_does_not_win(setup):
    client, fake, staple_id, context_id, variant_id = setup
    fake.evidence = [evidence(valid_until=NOW - timedelta(seconds=1), available=True)]
    response = client.post("/api/refresh", json=request(staple_id, context_id))
    assert response.status_code == 200
    assert response.json()["status"] == "succeeded"
    assert response.json()["results"][0]["status"] == "accepted"
    assert client.put(f"/api/staples/{staple_id}/matches/{variant_id}", json={"status":"approved"}).status_code == 200
    comparison = client.get("/api/comparisons").json()[0]
    assert comparison["winner_id"] is None
    offer = next(x for x in comparison["offers"] if x["variant_id"] == variant_id)
    assert "offer_expired" in offer["exclusion_reasons"]


def test_failed_refresh_leaves_prior_success_and_does_not_leak_error(setup):
    client, fake, staple_id, context_id, _ = setup
    fake.evidence = [evidence()]
    prior = client.post("/api/refresh", json=request(staple_id, context_id, key="good")).json()
    fake.error = RuntimeError("credential=secret")
    failed = client.post("/api/refresh", json=request(staple_id, context_id, key="bad"))
    assert "credential=secret" not in failed.text
    runs = client.get("/api/refresh-runs").json()
    assert any(r["id"] == prior["id"] and r["status"] == "succeeded" for r in runs)


def test_approval_survives_same_variant_refresh(setup):
    client, fake, staple_id, context_id, variant_id = setup
    fake.evidence = [evidence()]
    client.post("/api/refresh", json=request(staple_id, context_id, key="first"))
    review = client.put(f"/api/staples/{staple_id}/matches/{variant_id}", json={"status":"approved"})
    assert review.status_code == 200
    client.post("/api/refresh", json=request(staple_id, context_id, key="second"))
    matches = client.get(f"/api/staples/{staple_id}/matches").json()
    assert any(m["variant_id"] == variant_id and m["status"] == "approved" for m in matches)


def test_unavailable_refresh_blocks_old_approved_winner(setup):
    client, fake, staple_id, context_id, variant_id = setup
    fake.evidence = [evidence(available=True)]
    client.post("/api/refresh", json=request(staple_id, context_id, key="available"))
    client.put(f"/api/staples/{staple_id}/matches/{variant_id}", json={"status":"approved"})
    fake.evidence = [evidence(available=False)]
    response = client.post("/api/refresh", json=request(staple_id, context_id, key="unavailable"))
    assert response.status_code == 200
    assert response.json()["results"][0]["status"] == "unavailable"
    assert client.get("/api/comparisons").json()[0]["winner_id"] is None


def test_package_change_creates_pending_variant_and_suppresses_old_source_winner(setup):
    client, fake, staple_id, context_id, old_variant = setup
    fake.evidence = [evidence(quantity="16")]
    client.post("/api/refresh", json=request(staple_id, context_id, key="old"))
    client.put(f"/api/staples/{staple_id}/matches/{old_variant}", json={"status":"approved"})
    fake.evidence = [evidence(quantity="32")]
    changed = client.post("/api/refresh", json=request(staple_id, context_id, key="new"))
    assert changed.json()["results"][0]["status"] == "accepted"
    new_variant = changed.json()["results"][0]["variant_id"]
    assert new_variant != old_variant
    matches = {m["variant_id"]: m["status"] for m in client.get(f"/api/staples/{staple_id}/matches").json()}
    assert matches[old_variant] == "approved" and matches[new_variant] == "pending"
    assert client.get("/api/comparisons").json()[0]["winner_id"] is None


def test_new_key_same_price_adds_observation_and_preserves_provenance(setup):
    client, fake, staple_id, context_id, _ = setup
    first_time = NOW - timedelta(minutes=10)
    fake.evidence = [evidence(observed_at=first_time, retrieved_at=first_time)]
    assert client.post("/api/refresh", json=request(staple_id, context_id, key="one")).status_code == 200
    later = NOW - timedelta(minutes=1)
    fake.evidence = [evidence(observed_at=later, retrieved_at=later)]
    assert client.post("/api/refresh", json=request(staple_id, context_id, key="two")).status_code == 200
    observations = client.get("/api/observations").json()
    assert len(observations) == 2
    assert {o["observed_at"] for o in observations} == {first_time.isoformat(timespec="microseconds"), later.isoformat(timespec="microseconds")}


def test_timeout_is_classified_and_does_not_change_prices(setup):
    client, fake, staple_id, context_id, _ = setup
    fake.evidence = [evidence()]
    client.post("/api/refresh", json=request(staple_id, context_id, key="good"))
    before = client.get("/api/observations").json()
    fake.error = TimeoutError("private timeout details")
    failed = client.post("/api/refresh", json=request(staple_id, context_id, key="timeout")).json()
    assert failed["status"] == "failed" and failed["error"] == "source_timeout"
    assert client.get("/api/observations").json() == before


def test_one_retailer_failure_does_not_erase_another_retailers_results(tmp_path):
    first, second = FakeAdapter([evidence()]), FakeAdapter(error=RuntimeError("private"))
    second.retailer = "walmart"
    app = create_app(tmp_path / "two-retailers.sqlite3", adapters={
        "first": AdapterRegistration("first", "wegmans", first, frozenset({"in_store"}), frozenset({"Wegmans"}), True),
        "second": AdapterRegistration("second", "walmart", second, frozenset({"in_store"}), frozenset({"Walmart"}), True),
    })
    with TestClient(app, base_url="http://localhost") as client:
        staple = client.post("/api/staples", json={"name":"Rice", "basis":"oz"}).json()["id"]
        wegmans = client.get("/api/stores/wegmans").json()["preferred_context_id"]
        walmart = client.get("/api/stores/walmart").json()["preferred_context_id"]
        first_payload = request(staple, wegmans, key="first")
        first_payload["source_id"] = "first"
        first_run = client.post("/api/refresh", json=first_payload)
        payload = request(staple, walmart, key="second")
        payload["source_id"] = "second"
        second_run = client.post("/api/refresh", json=payload)
        assert first_run.json()["status"] == "succeeded"
        assert second_run.json()["status"] == "failed"
        assert len(client.get("/api/observations?store_id=wegmans").json()) == 1


@pytest.mark.parametrize('change', [
    {'seller': 'Marketplace'}, {'channel': 'pickup'}, {'location_id': 'wrong'},
])
def test_mixed_good_and_out_of_scope_evidence_is_atomic(setup, change):
    client, fake, staple_id, context_id, _ = setup
    good = evidence()
    bad = evidence(product='sku-2', **change)
    fake.evidence = [good, bad]
    payload = request(staple_id, context_id)
    payload['requests'].append({'staple_id': staple_id, 'retailer_product_id': 'sku-2'})
    run = client.post('/api/refresh', json=payload).json()
    assert run['status'] == 'failed' and run['error'] == 'invalid_evidence'
    assert run['results'] == []
    assert client.get('/api/observations').json() == []
    assert client.get(f'/api/staples/{staple_id}/matches').json() == []


@pytest.mark.parametrize('fields,reason', [
    ({'price': None}, 'source_price_unknown'),
    ({'quantity': None}, 'source_quantity_unknown'),
    ({'available': None}, 'source_availability_unknown'),
    ({'price': None, 'quantity': None, 'available': False}, 'source_unavailable'),
])
def test_unresolved_or_unavailable_new_source_state_blocks_old_winner(setup, fields, reason):
    client, fake, staple_id, context_id, variant = setup
    fake.evidence = [evidence()]
    client.post('/api/refresh', json=request(staple_id, context_id))
    client.put(f'/api/staples/{staple_id}/matches/{variant}', json={'status': 'approved'})
    assert client.get('/api/comparisons').json()[0]['winner_id'] is not None
    before = client.get('/api/observations').json()
    fake.evidence = [evidence(**fields)]
    run = client.post('/api/refresh', json=request(staple_id, context_id, key='unknown')).json()
    assert run['status'] == ('succeeded' if fields.get('available') is False else 'partial')
    assert len(client.get('/api/observations').json()) == len(before)
    comparison = client.get('/api/comparisons').json()[0]
    assert comparison['winner_id'] is None
    assert reason in comparison['offers'][0]['exclusion_reasons']
    assert comparison['offers'][0]['observed_at'] == before[0]['observed_at']


def test_duplicate_delivery_is_collapsed_and_unrelated_staple_not_matched(setup):
    client, fake, staple_id, context_id, _ = setup
    other = client.post('/api/staples', json={'name': 'Rice noodles', 'basis': 'oz'}).json()['id']
    fake.evidence = [evidence(), evidence()]
    run = client.post('/api/refresh', json=request(staple_id, context_id)).json()
    assert run['status'] == 'succeeded' and len(run['results']) == 1
    assert len(client.get('/api/observations').json()) == 1
    assert client.get(f'/api/staples/{other}/matches').json() == []


def test_exact_context_survives_preference_change(setup):
    client, fake, staple_id, context_id, _ = setup
    new_store = client.patch('/api/stores/wegmans', json={'context': {
        'location': 'Other shop', 'location_id': '999', 'channel': 'in_store'}}).json()
    assert new_store['preferred_context_id'] != context_id
    fake.evidence = [evidence()]
    run = client.post('/api/refresh', json=request(staple_id, context_id)).json()
    assert run['status'] == 'succeeded' and run['context_id'] == context_id
    obs = client.get('/api/observations').json()[0]
    assert obs['context_id'] == context_id and obs['location_id'] == '133'


@pytest.mark.parametrize('field,value', [('price', 4.25), ('price', True), ('quantity', 16.0), ('price', 'NaN'), ('quantity', '0')])
def test_binary_float_nonfinite_or_zero_evidence_cannot_enter_contract(field, value):
    data = evidence().model_dump()
    data[field] = value
    with pytest.raises(ValueError):
        OfferEvidence.model_validate(data)
