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

def test_explicit_pending_match_cannot_be_bypassed_by_observation_approval(client):
    sid=staple(client); vid=variant(client)['id']; observation(client,sid,vid)
    client.put(f'/api/staples/{sid}/matches/{vid}',json={'status':'pending'})
    row=client.post('/api/observations',json={'staple_id':sid,'variant_id':vid,'store_id':'wegmans','product_name':'Rice','price':'3','quantity':'16','unit':'oz','channel':'in_store','approved':True,'observed_at':datetime.now(timezone.utc).isoformat()})
    assert row.status_code==201
    assert client.get('/api/comparisons').json()[0]['winner_id'] is None

def test_approved_match_applies_to_refreshed_unapproved_observation(client):
    sid=staple(client); vid=variant(client)['id']; observation(client,sid,vid)
    client.put(f'/api/staples/{sid}/matches/{vid}',json={'status':'approved'})
    row=observation(client,sid,vid,'2')
    assert client.get('/api/comparisons').json()[0]['winner_id']==row['id']

def test_renamed_listing_same_variant_supersedes_old_offer(client):
    sid=staple(client); vid=variant(client)['id']; observation(client,sid,vid,'9')
    client.put(f'/api/staples/{sid}/matches/{vid}',json={'status':'approved'})
    row=client.post('/api/observations',json={'staple_id':sid,'variant_id':vid,'store_id':'wegmans','product_name':'Completely new listing title','price':'14','quantity':'16','unit':'oz','channel':'in_store','observed_at':datetime.now(timezone.utc).isoformat()}).json()
    assert [x['id'] for x in client.get('/api/comparisons').json()[0]['offers']]==[row['id']]

def test_same_manual_name_does_not_merge_distinct_explicit_identities(client):
    a=variant(client,retailer_product_id=None,manual_identity='manual-a')
    b=variant(client,retailer_product_id=None,manual_identity='manual-b')
    assert a['id'] != b['id']
    assert variant(client,retailer_product_id=None,manual_identity='manual-a')['id']==a['id']

def test_invalid_retailer_and_decimal_json_rejected(client):
    assert client.post('/api/variants',json={'retailer':'unknown-shop','retailer_product_id':'x','package_quantity':'1','package_unit':'oz','form':'bag'}).status_code==422
    assert client.post('/api/variants',json={'retailer':'wegmans','retailer_product_id':'x','package_quantity':1,'package_unit':'oz','form':'bag'}).status_code==422

def test_package_version_requires_new_review_and_keeps_history(client):
    sid=staple(client); old=variant(client); observation(client,sid,old['id'])
    client.put(f'/api/staples/{sid}/matches/{old["id"]}',json={'status':'approved'})
    new=variant(client,package_quantity='32'); assert new['id'] != old['id']
    assert client.get(f'/api/staples/{sid}/matches').json()[0]['status']=='approved'
    assert client.get('/api/observations').json()

def test_rule_invalidation_cannot_revive_with_observation_flag(client):
    sid=staple(client); vid=variant(client)['id']; observation(client,sid,vid)
    client.put(f'/api/staples/{sid}/matches/{vid}',json={'status':'approved'})
    client.patch(f'/api/staples/{sid}',json={'rules':'organic'})
    observation(client,sid,vid)
    assert client.get('/api/comparisons').json()[0]['winner_id'] is None


def test_manual_entries_without_identity_never_infer_same_product(client):
    sid = staple(client)
    body = dict(staple_id=sid, store_id="wegmans", product_name="Same title",
                price="4", quantity="16", unit="oz", channel="in_store",
                observed_at=datetime.now(timezone.utc).isoformat())
    first = client.post('/api/observations', json={**body, "approved": True}).json()
    second = client.post('/api/observations', json=body).json()
    assert first['variant_id'] != second['variant_id']
    assert second['match_status'] == 'pending'
    assert client.get('/api/comparisons').json()[0]['winner_id'] == first['id']


def test_rule_change_cannot_be_undone_by_approved_flag(client):
    sid = staple(client)
    vid = variant(client)['id']
    observation(client, sid, vid)
    client.put(f'/api/staples/{sid}/matches/{vid}', json={'status': 'approved'})
    client.patch(f'/api/staples/{sid}', json={'rules': 'Organic only'})
    response = client.post('/api/observations', json=dict(staple_id=sid, variant_id=vid,
        store_id='wegmans', product_name='Rice', price='1', quantity='16', unit='oz',
        channel='in_store', approved=True, observed_at=datetime.now(timezone.utc).isoformat()))
    assert response.status_code == 201
    assert response.json()['match_status'] == 'pending'
    assert client.get('/api/comparisons').json()[0]['winner_id'] is None


def test_versioned_package_stays_pending_and_old_history_is_immutable(client):
    sid = staple(client)
    old = variant(client)
    old_price = observation(client, sid, old['id'])
    client.put(f'/api/staples/{sid}/matches/{old["id"]}', json={'status': 'approved'})
    new = variant(client, package_quantity='32')
    response = client.post('/api/observations', json=dict(staple_id=sid, variant_id=new['id'],
        store_id='wegmans', product_name='Rice', price='1', quantity='32', unit='oz',
        channel='in_store', approved=True, observed_at=datetime.now(timezone.utc).isoformat()))
    assert response.status_code == 201 and response.json()['match_status'] == 'pending'
    result = client.get('/api/comparisons').json()[0]
    assert result['winner_id'] == old_price['id']
    assert not next(o for o in result['offers'] if o['variant_id'] == new['id'])['eligible']
    assert len(client.get('/api/observations').json()) == 2


def test_barcode_string_and_decimal_identity_canonicalization(client):
    first = variant(client, barcode='00012345', package_quantity='16.000')
    assert first['barcode'] == '00012345'
    assert variant(client, barcode='00012345', package_quantity='16')['id'] == first['id']
    sid = staple(client)
    assert observation(client, sid, first['id'])['variant_id'] == first['id']


def test_retailer_mismatch_is_rejected_without_saving(client):
    sid = staple(client)
    vid = variant(client, retailer='target')['id']
    response = client.post('/api/observations', json=dict(staple_id=sid, variant_id=vid,
        store_id='wegmans', product_name='Rice', price='1', quantity='16', unit='oz',
        channel='in_store', observed_at=datetime.now(timezone.utc).isoformat()))
    assert response.status_code == 422
    assert client.get('/api/observations').json() == []


def test_invalid_review_filters_are_rejected(client):
    sid = staple(client)
    assert client.get('/api/variants?retailer=other').status_code == 422
    assert client.get(f'/api/staples/{sid}/matches?status=maybe').status_code == 422
