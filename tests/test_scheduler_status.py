from datetime import datetime, timezone
from pathlib import Path
import json

import httpx
from fastapi.testclient import TestClient

from staple_scout.adapters import AdapterRegistration, OfferEvidence
from staple_scout.hmart import HMartAdapter
from staple_scout.main import create_app
from staple_scout.scheduler import run_schedule


class Source:
    def __init__(self): self.error = None
    def fetch(self, context, products, *, timeout):
        if self.error: raise self.error
        stamp=datetime.now(timezone.utc)
        return [OfferEvidence(source_record_id='sku',retailer_product_id='sku',product_name='Fixture rice',
            price='4.99',quantity='16',unit='oz',form='bag',channel='in_store',available=True,
            seller='Wegmans',location_id='133',observed_at=stamp,retrieved_at=stamp,source_url='https://example.test/rice')]


def test_source_status_failure_cannot_replace_success_or_freshen_price(tmp_path):
    source=Source()
    registration=AdapterRegistration('fixture','wegmans',source,frozenset({'in_store'}),frozenset({'Wegmans'}),True)
    app=create_app(tmp_path/'status.sqlite3',adapters={'fixture':registration})
    with TestClient(app,base_url='http://localhost') as c:
        staple=c.post('/api/staples',json={'name':'Fixture rice','basis':'oz'}).json()['id']
        context=c.get('/api/stores/wegmans').json()['preferred_context_id']
        entry={'source_id':'fixture','context_id':context,'channel':'in_store','requests':[{'staple_id':staple,'retailer_product_id':'sku'}]}
        initial=c.post('/api/refresh',json={**entry,'idempotency_key':'initial'}).json()
        assert initial['status']=='succeeded'
        variant=initial['results'][0]['variant_id']
        c.put(f'/api/staples/{staple}/matches/{variant}',json={'status':'approved'})
        before=c.get('/api/observations').json()
        winner=c.get('/api/comparisons').json()[0]['winner_id']
        source.error=TimeoutError('private-cookie-do-not-log')
        summary=run_schedule(app.state.database,app.state.adapters,{'sources':[entry]},sleep=lambda _:None)
        assert summary.status=='failed'
        states=c.get('/api/source-status',params={'context_id':context,'channel':'in_store'}).json()
        state=states[0]
        assert state['last_success']['id']==initial['id']
        assert state['last_attempt']['id']==state['last_failure']['id']!=initial['id']
        assert state['last_failure']['error']=='source_timeout'
        assert c.get('/api/observations').json()==before
        assert c.get('/api/comparisons').json()[0]['winner_id']==winner
        assert 'private-cookie' not in json.dumps(states)
        assert c.get('/api/source-status',params={'channel':'unknown'}).status_code==422


def test_http_retryable_source_uses_new_attempt_records_and_bounded_backoff(tmp_path):
    products=json.loads((Path(__file__).parent/'fixtures/hmart/raw-catalog-rice.json').read_text())['products']
    calls=[]
    def handler(request):
        calls.append(request)
        if len(calls)<3: return httpx.Response(503)
        return httpx.Response(200,json=[products[0]])
    adapter=HMartAdapter(transport=httpx.MockTransport(handler))
    registration=AdapterRegistration('hmart_fixture','hmart',adapter,frozenset({'online'}),frozenset({'HMart - US'}),True)
    app=create_app(tmp_path/'http-retry.sqlite3',adapters={'hmart_fixture':registration})
    with TestClient(app,base_url='http://localhost') as c:
        staple=c.post('/api/staples',json={'name':'Rice reference','basis':'oz'}).json()['id']
        context=c.patch('/api/stores/hmart',json={'context':{'location':'Online reference','channel':'online'}}).json()['preferred_context_id']
        pauses=[]
        entry={'source_id':'hmart_fixture','context_id':context,'channel':'online','requests':[{'staple_id':staple,'retailer_product_id':'332:332'}]}
        summary=run_schedule(app.state.database,app.state.adapters,{'sources':[entry]},sleep=pauses.append)
        assert summary.status=='succeeded'
        assert len(calls)==3 and pauses==[.25,.5]
        runs=c.get('/api/refresh-runs').json()
        assert [r['status'] for r in runs]==['succeeded','failed','failed']
        assert runs[1]['error']==runs[2]['error']=='source_http_retryable'
        assert len({r['idempotency_key'] for r in runs})==3
        assert len(c.get('/api/observations').json())==1
