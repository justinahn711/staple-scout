from datetime import datetime, timezone
import pytest
from fastapi.testclient import TestClient
from staple_scout.main import create_app

@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(tmp_path/'m.sqlite3'), base_url='http://localhost') as c: yield c

def staple(c):
    return c.post('/api/staples', json={'name':'Rice','basis':'oz'}).json()['id']

def variant(c, **kw):
    body={'retailer':'wegmans','retailer_product_id':'sku-1','package_quantity':'16','package_unit':'oz','pack_count':1,'form':'bag', **kw}
    r=c.post('/api/variants',json=body); assert r.status_code==201, r.text; return r.json()

def observation(c, sid, vid, price='4'):
    return c.post('/api/observations',json={'staple_id':sid,'variant_id':vid,'store_id':'wegmans','product_name':'Renamed rice','price':price,'quantity':'16','unit':'oz','channel':'in_store','observed_at':datetime.now(timezone.utc).isoformat()}).json()

def test_match_approval_flows_to_refresh_and_rejection_excludes(client):
    sid=staple(client); vid=variant(client)['id']; observation(client,sid,vid)
    assert client.get(f'/api/comparisons').json()[0]['winner_id'] is None
    client.put(f'/api/staples/{sid}/matches/{vid}',json={'status':'approved'})
    assert client.get('/api/comparisons').json()[0]['winner_id'] is not None
    observation(client,sid,vid,'3'); client.put(f'/api/staples/{sid}/matches/{vid}',json={'status':'rejected'})
    assert client.get('/api/comparisons').json()[0]['winner_id'] is None

def test_exact_import_idempotent_rename_and_package_version(client):
    a=variant(client); b=variant(client, form='new listing'); assert a['id'] != b['id']
    again=variant(client); assert again['id']==a['id']

def test_rule_change_invalidates_review(client):
    sid=staple(client); vid=variant(client)['id']; observation(client,sid,vid)
    client.put(f'/api/staples/{sid}/matches/{vid}',json={'status':'approved'})
    client.patch(f'/api/staples/{sid}',json={'rules':'brown rice'})
    assert client.get(f'/api/staples/{sid}/matches').json()[0]['status']=='pending'

def test_variant_package_mismatch_rejected(client):
    sid=staple(client); vid=variant(client)['id']
    r=client.post('/api/observations',json={'staple_id':sid,'variant_id':vid,'store_id':'wegmans','product_name':'Rice','price':'4','quantity':'32','unit':'oz','channel':'in_store','observed_at':datetime.now(timezone.utc).isoformat()})
    assert r.status_code == 422
