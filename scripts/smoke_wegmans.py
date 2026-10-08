"""Explicit five-product live gate; only a newly created temporary database."""
import argparse
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', help='Allow five public Wegmans product requests')
    args = parser.parse_args()
    if not args.live:
        parser.error('Live requests require --live; no request was made')
    with TemporaryDirectory(prefix='staple-scout-wegmans-smoke-') as temporary:
        database = Path(temporary) / 'smoke.sqlite3'
        # main constructs a module-level app; isolate that initialization too.
        os.environ['STAPLE_SCOUT_DB'] = str(database)
        from fastapi.testclient import TestClient
        from staple_scout.main import create_app
        products = [('94427', 'Milk', 'fl_oz'), ('80133', 'Eggs', 'each'),
                    ('57084', 'Chicken', 'oz'), ('47264', 'Rice', 'oz'), ('92685', 'Bananas', 'oz')]
        with TestClient(create_app(database), base_url='http://localhost') as client:
            context = client.get('/api/stores/wegmans').json()['preferred_context_id']
            requests = []
            for identity, name, basis in products:
                response = client.post('/api/staples', json={'name': f'Live validation only: {name}', 'basis': basis})
                response.raise_for_status()
                requests.append({'staple_id': response.json()['id'], 'retailer_product_id': identity})
            response = client.post('/api/refresh', json={'source_id': 'wegmans_in_store', 'context_id': context,
                'channel': 'in_store', 'requests': requests, 'idempotency_key': 'five-product-live-gate'})
            response.raise_for_status()
            run = response.json()
            assert run['status'] == 'succeeded', run['error']
            observations = client.get('/api/observations').json()
            assert len(run['results']) == len(observations) == 5
            assert {r['evidence']['retailer_product_id'] for r in run['results']} == {p[0] for p in products}
            for request in requests:
                matches = client.get(f"/api/staples/{request['staple_id']}/matches").json()
                assert len(matches) == 1 and matches[0]['status'] == 'pending'
            assert all(c['winner_id'] is None for c in client.get('/api/comparisons').json())
            assert all(o['source_id'] == 'wegmans_in_store' and o['location_id'] == '133' and o['channel'] == 'in_store' and not o['approved'] for o in observations)
            print(json.dumps({'validation': 'five real in-store observations; all matches pending; disposable database removed on exit',
                'source_id': 'wegmans_in_store', 'store_number': '133', 'status': run['status'],
                'records': [{'status': r['status'], 'evidence': r['evidence']} for r in run['results']]}, indent=2))


if __name__ == '__main__':
    main()
