from datetime import datetime, timezone

from fastapi.testclient import TestClient

from staple_scout.database import Database
from staple_scout.main import create_app


def test_report_api_persists_cutoff_snapshot_across_reopen(tmp_path):
    path = tmp_path / "evidence.sqlite3"
    app = create_app(path)
    with TestClient(app, base_url="http://localhost") as client:
        staple = client.post("/api/staples", json={"name":"Rice", "basis":"oz"}).json()
        variant = client.post("/api/variants", json={"retailer":"wegmans", "retailer_product_id":"sku", "package_quantity":"16", "package_unit":"oz", "form":"bag"}).json()
        context = client.get("/api/stores/wegmans").json()["preferred_context_id"]
        assert client.put(f"/api/staples/{staple['id']}/matches/{variant['id']}", json={"status":"approved"}).status_code == 200
        observation = {"staple_id":staple["id"],"variant_id":variant["id"],"store_id":"wegmans","context_id":context,
            "product_name":"Rice","price":"4.00","quantity":"16","unit":"oz","pack_count":1,
            "channel":"in_store","observed_at":"2026-01-01T12:00:00Z","available":True}
        assert client.post("/api/observations", json=observation).status_code == 201
        request = {"as_of":"2026-01-02T00:00:00Z","stores":["wegmans"],"channel":"in_store"}
        created = client.post("/api/reports", json=request)
        assert created.status_code == 201
        report = created.json()
        assert report["comparisons"][0]["winner_id"] is not None
        report_id = report["id"]
    reopened = create_app(path)
    with TestClient(reopened, base_url="http://localhost") as client:
        fetched = client.get(f"/api/reports/{report_id}")
        assert fetched.status_code == 200
        assert fetched.json() == report


def test_report_cutoff_excludes_later_observation(tmp_path):
    path = tmp_path / "cutoff.sqlite3"
    app = create_app(path)
    with TestClient(app, base_url="http://localhost") as client:
        staple = client.post("/api/staples", json={"name":"Rice", "basis":"oz"}).json()
        variant = client.post("/api/variants", json={"retailer":"wegmans", "retailer_product_id":"sku", "package_quantity":"16", "package_unit":"oz", "form":"bag"}).json()
        context = client.get("/api/stores/wegmans").json()["preferred_context_id"]
        client.put(f"/api/staples/{staple['id']}/matches/{variant['id']}", json={"status":"approved"})
        base = {"staple_id":staple["id"],"variant_id":variant["id"],"store_id":"wegmans","context_id":context,"product_name":"Rice","quantity":"16","unit":"oz","pack_count":1,"channel":"in_store","available":True}
        for price, when in [("4.00", "2026-01-01T12:00:00Z"), ("2.00", "2026-01-03T12:00:00Z")]:
            assert client.post("/api/observations", json={**base,"price":price,"observed_at":when}).status_code == 201
        report = client.post("/api/reports", json={"as_of":"2026-01-02T00:00:00Z","stores":["wegmans"],"channel":"in_store"}).json()
        assert report["comparisons"][0]["offers"][0]["price"] == "4.00"


def test_source_evidence_unknown_after_cutoff_does_not_leak_backwards(tmp_path):
    from test_ingestion import FakeAdapter, evidence, request
    from staple_scout.adapters import AdapterRegistration
    path=tmp_path/'source-history.sqlite3'
    fake=FakeAdapter()
    source=AdapterRegistration(source_id='fixture',retailer='wegmans',adapter=fake,
        channels=frozenset({'in_store'}),sellers=frozenset({'Wegmans'}),validated=True)
    client=TestClient(create_app(path,adapters={'fixture':source}),base_url='http://localhost')
    staple=client.post('/api/staples',json={'name':'Rice','basis':'oz'}).json()['id']
    context=client.get('/api/stores/wegmans').json()['preferred_context_id']
    first_time=datetime(2026,1,1,12,tzinfo=timezone.utc)
    fake.evidence=[evidence(observed_at=first_time,retrieved_at=first_time)]
    first=client.post('/api/refresh',json=request(staple,context,'one')).json()
    assert first['status']=='succeeded'
    variant=first['results'][0]['variant_id']
    assert client.put(f'/api/staples/{staple}/matches/{variant}',json={'status':'approved'}).status_code==200
    later=datetime(2026,1,2,12,tzinfo=timezone.utc)
    fake.evidence=[evidence(price=None,observed_at=later,retrieved_at=later)]
    second=client.post('/api/refresh',json=request(staple,context,'two')).json()
    assert second['status']=='partial'
    db=Database(path)
    with db.connect() as cx:
        for run,when in [(first,first_time),(second,later)]:
            cx.execute('UPDATE refresh_runs SET started_at=?,finished_at=? WHERE id=?',
                (when.isoformat(),when.isoformat(),run['id']))
    early=client.post('/api/reports',json={'as_of':'2026-01-02T00:00:00Z','stores':['wegmans']})
    assert early.status_code==201,early.text
    assert early.json()['comparisons'][0]['winner_id'] is not None
    assert early.json()['source_health'][0]['last_attempt']['id']==first['id']
    after=client.post('/api/reports',json={'as_of':'2026-01-03T00:00:00Z','stores':['wegmans']}).json()
    assert after['comparisons'][0]['winner_id'] is None
    assert 'source_price_unknown' in after['comparisons'][0]['offers'][0]['exclusion_reasons']
    assert after['source_health'][0]['last_success']['id']==first['id']
    # Imported observation discovered after cutoff is not retrospectively available.
    with db.connect() as cx:
        cx.execute('UPDATE refresh_runs SET finished_at=? WHERE id=?',(later.isoformat(),first['id']))
    absent=client.post('/api/reports',json={'as_of':'2026-01-02T01:00:00Z','stores':['wegmans']}).json()
    assert absent['comparisons'][0]['offers']==[]
    assert client.get('/api/reports/'+early.json()['id']).json()==early.json()
