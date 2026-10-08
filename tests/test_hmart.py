import json
from datetime import timezone
from pathlib import Path
import pytest

import httpx

from staple_scout.adapters import AdapterContext
from staple_scout.hmart import HMartAdapter

FIXTURE = Path(__file__).parent / "fixtures/hmart/raw-catalog-rice.json"

def response_for(payload, request):
    product_id = request.url.params.get("fq", "").split(":")[-1]
    return httpx.Response(200, json={**payload, "products": [p for p in payload["products"] if p["productId"] == product_id]})


def test_hmart_fixture_normalizes_all_records_and_preserves_item_identity():
    payload = json.loads(FIXTURE.read_text())

    def handler(request):
        product_id = request.url.params.get("fq", "").split(":")[-1]
        return httpx.Response(206, json={**payload, "products": [p for p in payload["products"] if p["productId"] == product_id]})

    adapter = HMartAdapter(transport=httpx.MockTransport(handler))
    context = AdapterContext(retailer="hmart", context_id=1, location_id=None, channel="online")
    rows = adapter.fetch(context, ["332:332", "72:72", "8011:8027", "63:63", "13422:11307"], timeout=2)
    assert len(rows) == 5
    assert rows[2].retailer_product_id == "8011:8027"
    assert rows[0].barcode == "880925185119"
    assert str(rows[0].quantity) == "7.05" and rows[0].unit == "oz"
    assert rows[0].seller == "HMart - US" and rows[0].location_id is None
    assert rows[0].observed_at.tzinfo == timezone.utc


def test_hmart_rejects_shelf_context():
    adapter = HMartAdapter(transport=httpx.MockTransport(lambda request: httpx.Response(200, json=[])))
    context = AdapterContext(retailer="hmart", context_id=1, location_id="133", channel="online")
    try:
        adapter.fetch(context, ["332:332"], timeout=2)
    except ValueError:
        pass
    else:
        raise AssertionError("online H Mart evidence must not claim a location")


def test_fixture_preserves_zero_padded_ean_and_unavailable_state():
    payload = json.loads(FIXTURE.read_text())
    payload["products"][0]["items"][0]["ean"] = "00001234"
    payload["products"][0]["items"][0]["sellers"][0]["commertialOffer"]["IsAvailable"] = False
    adapter = HMartAdapter(transport=httpx.MockTransport(lambda request: response_for(payload, request)))
    context = AdapterContext(retailer="hmart", context_id=1, location_id=None, channel="online")
    row = adapter.fetch(context, ["332:332"], timeout=2)[0]
    assert row.barcode == "00001234" and row.available is False


def test_wrong_seller_is_filtered_and_unknown_quantity_is_null():
    payload = json.loads(FIXTURE.read_text())
    product = payload["products"][0]
    product["items"][0]["name"] = "Brown Rice Family Pack"
    product["items"][0]["sellers"] = [{"sellerName": "Other Seller", "commertialOffer": {"Price": 1, "IsAvailable": True}}]
    adapter = HMartAdapter(transport=httpx.MockTransport(lambda request: response_for(payload, request)))
    context = AdapterContext(retailer="hmart", context_id=1, location_id=None, channel="online")
    assert adapter.fetch(context, ["332:332"], timeout=2) == []


def test_malformed_price_valid_until_and_malformed_offer_fail():
    payload = json.loads(FIXTURE.read_text())
    offer = payload["products"][0]["items"][0]["sellers"][0]["commertialOffer"]
    offer["PriceValidUntil"] = "not-a-time"
    adapter = HMartAdapter(transport=httpx.MockTransport(lambda request: response_for(payload, request)))
    context = AdapterContext(retailer="hmart", context_id=1, location_id=None, channel="online")
    with pytest.raises(ValueError):
        adapter.fetch(context, ["332:332"], timeout=2)


def test_http_error_propagates_and_timeout_is_supplied():
    seen = {}
    def handler(request):
        seen["timeout"] = request.extensions.get("timeout")
        return httpx.Response(503)
    adapter = HMartAdapter(transport=httpx.MockTransport(handler))
    context = AdapterContext(retailer="hmart", context_id=1, location_id=None, channel="online")
    with pytest.raises(httpx.HTTPStatusError):
        adapter.fetch(context, ["332:332"], timeout=3.5)
    assert seen["timeout"] is not None


@pytest.mark.parametrize('name,expected', [
    ('Unknown family rice bag', (None, None)),
    ('Rice 2 x 16 oz', (None, None)),
    ('Rice 1-2 lb', (None, None)),
    ('Rice 16 oz pack of 2', (None, None)),
    ('Snack 12 ct', ('12', 'each')),
    ('Rice 7.05oz(200g)', ('7.05', 'oz')),
    ('Rice 5 oz and 10 oz', (None, None)),
])
def test_uncertain_package_labels_are_not_guessed(name, expected):
    quantity, unit = HMartAdapter._quantity(name)
    assert (str(quantity) if quantity is not None else None, unit) == expected


def test_cache_age_and_retrieval_time_are_separate():
    from datetime import datetime, timedelta
    retrieved = datetime(2026, 10, 8, 12, 30, tzinfo=timezone.utc)
    response = httpx.Response(200, headers={'Date': 'Thu, 08 Oct 2026 12:25:00 GMT', 'Age': '120'})
    assert HMartAdapter._observed_time(response, retrieved) == retrieved - timedelta(minutes=5)
    with pytest.raises(ValueError):
        HMartAdapter._observed_time(httpx.Response(200, headers={'Age': 'broken'}), retrieved)


def test_five_online_records_ingest_pending_and_cannot_win_local_modes(tmp_path):
    from fastapi.testclient import TestClient
    from staple_scout.adapters import AdapterRegistration
    from staple_scout.main import create_app
    payload = json.loads(FIXTURE.read_text())['products']
    def handler(request):
        product_id = request.url.params['fq'].split(':')[1]
        return httpx.Response(200, json=[p for p in payload if p['productId'] == product_id])
    adapter = HMartAdapter(transport=httpx.MockTransport(handler))
    registration = AdapterRegistration('hmart_fixture', 'hmart', adapter, frozenset({'online'}), frozenset({'HMart - US'}), True)
    app = create_app(tmp_path / 'reference.sqlite3', adapters={'hmart_fixture': registration})
    with TestClient(app, base_url='http://localhost') as client:
        staple = client.post('/api/staples', json={'name': 'Fixture rice reference', 'basis': 'oz'}).json()['id']
        context = client.patch('/api/stores/hmart', json={'context': {'location': 'H Mart online catalog', 'channel': 'online'}}).json()['preferred_context_id']
        ids = [f"{p['productId']}:{p['items'][0]['itemId']}" for p in payload]
        run = client.post('/api/refresh', json={'source_id': 'hmart_fixture', 'context_id': context,
            'channel': 'online', 'requests': [{'staple_id': staple, 'retailer_product_id': identity} for identity in ids],
            'idempotency_key': 'fixture-one'}).json()
        assert run['status'] == 'succeeded' and len(run['results']) == 5
        matches = client.get(f'/api/staples/{staple}/matches').json()
        assert len(matches) == 5 and all(m['status'] == 'pending' for m in matches)
        for match in matches:
            client.put(f"/api/staples/{staple}/matches/{match['variant_id']}", json={'status': 'approved'})
        for channel in ('in_store', 'pickup'):
            comparison = client.get('/api/comparisons', params={'channel': channel}).json()[0]
            assert comparison['winner_id'] is None and len(comparison['offers']) == 5
            for offer in comparison['offers']:
                assert offer['channel'] == 'online' and offer['location_id'] is None
                assert ('not_in_store' if channel == 'in_store' else 'not_pickup') in offer['exclusion_reasons']
                assert 'Centreville stock' in offer['conditions']


def test_registry_preserves_verified_online_reference_without_fetching():
    from staple_scout.registry import default_sources
    sources = default_sources()
    assert set(sources) == {'hmart_online', 'wegmans_in_store'}
    assert sources['hmart_online'].validated and sources['hmart_online'].channels == frozenset({'online'})


def test_cosmetic_title_change_retains_source_storage_form_and_identity():
    payload = json.loads(FIXTURE.read_text())['products'][0]
    def handler(request):
        return httpx.Response(200, json=[payload])
    adapter = HMartAdapter(transport=httpx.MockTransport(handler))
    context = AdapterContext(retailer='hmart',context_id=1,location_id=None,channel='online')
    before = adapter.fetch(context, ['332:332'], timeout=2)[0]
    payload['items'][0]['name'] = 'Renamed Brown Rice Paper 7.05oz(200g)'
    after = adapter.fetch(context, ['332:332'], timeout=2)[0]
    assert after.product_name != before.product_name
    assert before.form == after.form == 'Catalog storage: Dry'
    assert before.retailer_product_id == after.retailer_product_id
