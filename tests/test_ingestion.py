from datetime import datetime, timezone
from decimal import Decimal
from staple_scout.adapters import AdapterContext, OfferEvidence
from staple_scout.ingestion import run_adapter
import pytest
from fastapi.testclient import TestClient
from staple_scout.main import create_app

@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(tmp_path/'ingest.sqlite3'), base_url='http://localhost') as c: yield c

class Fake:
    retailer='wegmans'
    def __init__(self, items): self.items=items
    def fetch(self, context, product_ids): return self.items

def test_ingestion_materializes_known_offer_and_leaves_match_pending(client):
    sid=client.post('/api/staples',json={'name':'Rice','basis':'oz'}).json()['id']
    vid=client.post('/api/variants',json={'retailer':'wegmans','retailer_product_id':'sku','package_quantity':'16','package_unit':'oz','form':'bag'}).json()['id']
    ctx=client.get('/api/stores/wegmans').json(); c=AdapterContext('wegmans',ctx['location_id'],'in_store')
    item=OfferEvidence('sku','Rice','0001',Decimal('4'),Decimal('16'),'oz',1,'bag','in_store',True,'Wegmans',ctx['location_id'],datetime.now(timezone.utc),datetime.now(timezone.utc))
    run_adapter(client.app.state.database,Fake([item]),c,['sku'])
    assert client.get(f'/api/staples/{sid}/matches').json()[0]['status']=='pending'
    assert client.get('/api/observations').json()[0]['variant_id']==vid

def test_unknown_quantity_is_unresolved(client):
    ctx=client.get('/api/stores/wegmans').json(); c=AdapterContext('wegmans',ctx['location_id'],'in_store')
    item=OfferEvidence('missing','Rice',None,Decimal('4'),None,None,1,'bag','in_store',True,None,ctx['location_id'],datetime.now(timezone.utc),datetime.now(timezone.utc))
    run=run_adapter(client.app.state.database,Fake([item]),c,['missing'])
    with client.app.state.database.connect() as db: assert db.execute('SELECT status FROM refresh_results WHERE run_id=?',(run,)).fetchone()[0]=='unresolved'
