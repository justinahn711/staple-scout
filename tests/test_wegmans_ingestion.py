"""Wegmans fixture integration through the normal typed ingestion API."""
import copy
import json
from pathlib import Path

import httpx
from fastapi.testclient import TestClient

from staple_scout.adapters import AdapterRegistration
from staple_scout.main import create_app
from staple_scout.wegmans import WegmansAdapter

RAW = json.loads((Path(__file__).parent / 'fixtures/wegmans-products.json').read_text())


def test_five_records_pending_then_only_eligible_shelf_wins_and_failures_preserve_history(tmp_path):
    state = {'products': copy.deepcopy(RAW), 'status': 200, 'calls': 0}
    def handler(request):
        state['calls'] += 1
        identity = request.url.path.rsplit('/', 1)[-1]
        return httpx.Response(state['status'], json=next(p for p in state['products'] if p['skuId'] == identity))
    source = AdapterRegistration('wegmans_fixture', 'wegmans', WegmansAdapter(transport=httpx.MockTransport(handler)),
                                 frozenset({'in_store'}), frozenset({'Wegmans'}), True)
    with TestClient(create_app(tmp_path / 'wegmans.sqlite3', adapters={source.source_id: source}), base_url='http://localhost') as client:
        context = client.get('/api/stores/wegmans').json()['preferred_context_id']
        requests = []
        for record, basis in zip(RAW, ['fl_oz', 'each', 'oz', 'oz', 'oz']):
            staple = client.post('/api/staples', json={'name': 'Fixture ' + record['productName'], 'basis': basis})
            assert staple.status_code == 201
            requests.append({'staple_id': staple.json()['id'], 'retailer_product_id': record['productId']})
        payload = {'source_id': source.source_id, 'context_id': context, 'channel': 'in_store',
                   'requests': requests, 'idempotency_key': 'initial'}
        first = client.post('/api/refresh', json=payload).json()
        assert first['status'] == 'succeeded' and len(first['results']) == 5
        assert next(r for r in first['results'] if r['retailer_product_id'] == '94427')['status'] == 'unavailable'
        assert len(client.get('/api/observations').json()) == 5
        assert all(row['winner_id'] is None for row in client.get('/api/comparisons').json())
        variants = []
        for request in requests:
            matches = client.get(f"/api/staples/{request['staple_id']}/matches").json()
            assert len(matches) == 1 and matches[0]['status'] == 'pending'
            variant = matches[0]['variant_id']
            variants.append(variant)
            response = client.put(f"/api/staples/{request['staple_id']}/matches/{variant}", json={'status': 'approved'})
            assert response.status_code == 200
        shelf = client.get('/api/comparisons').json()
        assert [row['winner_id'] is not None for row in shelf] == [False, True, False, False, False]
        reasons = [row['offers'][0]['exclusion_reasons'] for row in shelf]
        assert 'unavailable' in reasons[0]
        assert 'uncertain_quantity' in reasons[2] and 'conditional_price' in reasons[3]
        assert all(row['winner_id'] is None for row in client.get('/api/comparisons', params={'channel': 'pickup'}).json())
        snapshot = client.get('/api/observations').json()
        assert client.post('/api/refresh', json=payload).json()['id'] == first['id'] and state['calls'] == 5
        state['status'] = 403
        failed = client.post('/api/refresh', json={**payload, 'idempotency_key': 'access-failure'}).json()
        assert failed['status'] == 'failed' and failed['error'] == 'source_http_error'
        assert client.get('/api/observations').json() == snapshot
        assert client.get('/api/comparisons').json()[1]['winner_id'] == shelf[1]['winner_id']
        health = client.get('/api/source-status', params={'context_id': context, 'channel': 'in_store'}).json()[0]
        assert health['last_success']['id'] == first['id'] and health['last_failure']['id'] == failed['id']
        # A newer unknown price suppresses the old eligible offer without inventing one.
        state['status'] = 200
        state['products'][1]['price_inStore']['amount'] = None
        partial = client.post('/api/refresh', json={**payload, 'idempotency_key': 'unknown-price'}).json()
        assert partial['status'] == 'partial' and next(r for r in partial['results'] if r['retailer_product_id'] == '80133')['reason'] == 'source_price_unknown'
        assert client.get('/api/comparisons').json()[1]['winner_id'] is None
        # A new package creates a pending match; it never inherits approval.
        state['products'][1]['price_inStore']['amount'] = 1.69
        state['products'][1]['packSize'] = '18 ct.'
        changed = client.post('/api/refresh', json={**payload, 'idempotency_key': 'changed-package'}).json()
        assert changed['status'] == 'succeeded'
        matches = client.get(f"/api/staples/{requests[1]['staple_id']}/matches").json()
        assert len(matches) == 2 and sorted(row['status'] for row in matches) == ['approved', 'pending']
        assert client.get('/api/comparisons').json()[1]['winner_id'] is None


def test_default_registry_exposes_only_validated_channels_without_fetching(tmp_path, monkeypatch):
    def forbidden(*args, **kwargs):
        raise AssertionError('Creating the registry/app must not fetch')
    monkeypatch.setattr(WegmansAdapter, 'fetch', forbidden)
    from staple_scout.hmart import HMartAdapter
    monkeypatch.setattr(HMartAdapter, 'fetch', forbidden)
    with TestClient(create_app(tmp_path / 'empty.sqlite3'), base_url='http://localhost') as client:
        sources = {row['source_id']: row for row in client.get('/api/sources').json()}
        assert sources['wegmans_in_store']['validated'] is True
        assert sources['wegmans_in_store']['channels'] == ['in_store']
        assert sources['hmart_online']['channels'] == ['online']
        assert client.get('/api/observations').json() == []
