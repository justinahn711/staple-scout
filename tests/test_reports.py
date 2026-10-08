from datetime import datetime, timezone, timedelta
import pytest

from staple_scout.reports import ReportRequest
from staple_scout.database import Database
from staple_scout.main import create_app
from fastapi.testclient import TestClient


def test_report_request_normalizes_aware_cutoff():
    request = ReportRequest(as_of="2026-01-02T07:00:00-05:00", stores=["wegmans"], channel="in_store")
    assert request.as_of == datetime(2026, 1, 2, 12, tzinfo=timezone.utc)


@pytest.mark.parametrize("as_of", ["2026-01-02T12:00:00", "2099-01-02T12:00:00Z"])
def test_report_request_rejects_naive_or_future_cutoff(as_of):
    with pytest.raises(ValueError):
        ReportRequest(as_of=as_of, stores=["wegmans"])


def test_report_request_rejects_duplicate_stores_and_extra_fields():
    with pytest.raises(ValueError):
        ReportRequest(as_of="2026-01-02T12:00:00Z", stores=["wegmans", "wegmans"])
    with pytest.raises(ValueError):
        ReportRequest(as_of="2026-01-02T12:00:00Z", stores=["wegmans"], unexpected=True)


def _fixture(tmp_path):
    path = tmp_path / "reports.sqlite3"
    app = create_app(path)
    client = TestClient(app, base_url="http://localhost")
    staple = client.post("/api/staples", json={"name":"Rice", "basis":"oz"}).json()
    variant = client.post("/api/variants", json={"retailer":"wegmans", "retailer_product_id":"sku", "package_quantity":"16", "package_unit":"oz", "form":"bag"}).json()
    context = client.get("/api/stores/wegmans").json()["preferred_context_id"]
    client.put(f"/api/staples/{staple['id']}/matches/{variant['id']}", json={"status":"approved"})
    return path, client, staple["id"], variant["id"], context


def _observation(client, staple, context, *, price="4.00", available=True, when="2026-01-01T12:00:00Z"):
    response = client.post("/api/observations", json={"variant_id":1, "staple_id":staple, "store_id":"wegmans", "context_id":context,
        "product_name":"Rice", "price":price, "quantity":"16", "unit":"oz", "pack_count":1,
        "channel":"in_store", "observed_at":when, "available":available})
    assert response.status_code == 201, response.text
    return response.json()


def test_generate_get_report_uses_latest_cutoff_observation_and_is_immutable(tmp_path):
    path, client, staple, variant, context = _fixture(tmp_path)
    _observation(client, staple, context, price="4.00", when="2026-01-01T12:00:00Z")
    _observation(client, staple, context, price="5.00", available=False, when="2026-01-02T12:00:00Z")
    database = Database(path)
    request = {"as_of":"2026-01-03T00:00:00Z", "stores":["wegmans"], "channel":"in_store"}
    first = __import__("staple_scout.reports", fromlist=["generate_report"]).generate_report(database, request)
    assert first["comparisons"][0]["winner_id"] is None
    client.patch(f"/api/staples/{staple}", json={"name":"Changed"})
    second = __import__("staple_scout.reports", fromlist=["get_report"]).get_report(database, first["id"])
    assert second == first


def test_report_reuses_equivalent_sorted_store_filter(tmp_path):
    path, client, staple, variant, context = _fixture(tmp_path)
    _observation(client, staple, context)
    database = Database(path)
    from staple_scout.reports import generate_report
    one = generate_report(database, {"as_of":"2026-01-02T00:00:00Z", "stores":["wegmans", "walmart"]})
    two = generate_report(database, {"as_of":"2026-01-02T00:00:00Z", "stores":["walmart", "wegmans"]})
    assert one["id"] == two["id"]


def test_report_excludes_observation_after_cutoff(tmp_path):
    path, client, staple, variant, context = _fixture(tmp_path)
    _observation(client, staple, context, price="4.00", when="2026-01-01T12:00:00Z")
    _observation(client, staple, context, price="2.00", when="2026-01-03T12:00:00Z")
    from staple_scout.reports import generate_report
    report = generate_report(Database(path), {"as_of":"2026-01-02T00:00:00Z", "stores":["wegmans"]})
    assert report["comparisons"][0]["offers"][0]["price"] == "4.00"


def test_current_context_switch_excludes_old_context_winner(tmp_path):
    path, client, staple, variant, old_context = _fixture(tmp_path)
    _observation(client, staple, old_context)
    changed = client.patch("/api/stores/wegmans", json={"context":{"location":"Second location","location_id":"999","channel":"in_store","location_status":"user_reported"}}).json()
    report = __import__("staple_scout.reports", fromlist=["generate_report"]).generate_report(Database(path), {"as_of":"2026-01-02T00:00:00Z", "stores":["wegmans"]})
    group = report["comparisons"][0]
    assert group["winner_id"] is None
    assert any("location_not_current" in offer["exclusion_reasons"] for offer in group["offers"])


def test_price_drop_requires_same_variant_and_channel_and_skips_conditional_prior(tmp_path):
    path, client, staple, variant, context = _fixture(tmp_path)
    _observation(client, staple, context, price="6.00", when="2026-01-01T12:00:00Z")
    _observation(client, staple, context, price="4.00", when="2026-01-02T12:00:00Z")
    report = __import__("staple_scout.reports", fromlist=["generate_report"]).generate_report(Database(path), {"as_of":"2026-01-03T00:00:00Z", "stores":["wegmans"]})
    assert report["price_drops"] and report["price_drops"][0]["previous_price"] == "6.00"

    # A different channel is a separate history and cannot produce a drop.
    pickup = client.post("/api/observations", json={"variant_id":variant,"staple_id":staple,"store_id":"wegmans","context_id":context,"product_name":"Rice","price":"3.00","quantity":"16","unit":"oz","pack_count":1,"channel":"pickup","observed_at":"2026-01-02T12:00:00Z"})
    assert pickup.status_code == 201
    pickup_report = __import__("staple_scout.reports", fromlist=["generate_report"]).generate_report(Database(path), {"as_of":"2026-01-03T00:00:00Z", "stores":["wegmans"], "channel":"pickup"})
    assert pickup_report["price_drops"] == []


@pytest.mark.parametrize('prior_available,prior_conditions', [(False,''),(True,'member price')])
def test_unavailable_or_conditional_previous_price_is_not_a_drop(tmp_path,prior_available,prior_conditions):
    path,client,staple,variant,context=_fixture(tmp_path)
    previous=_observation(client,staple,context,price='9',available=prior_available)
    with Database(path).connect() as db:
        db.execute('UPDATE observations SET conditions=? WHERE id=?',(prior_conditions,previous['id']))
    current=_observation(client,staple,context,price='4',when='2026-01-02T12:00:00Z')
    response=client.post('/api/reports',json={'as_of':'2026-01-03T00:00:00Z','stores':['wegmans']})
    assert response.status_code == 201,response.text
    assert response.json()['comparisons'][0]['winner_id'] == current['id']
    assert response.json()['price_drops'] == []


def test_new_package_variant_is_not_a_price_drop_and_outlay_is_separate(tmp_path):
    path,client,staple,variant,context=_fixture(tmp_path)
    client.patch(f'/api/staples/{staple}',json={'desired_quantity':'20','desired_unit':'oz'})
    _observation(client,staple,context,price='6')
    smaller=client.post('/api/variants',json={'retailer':'wegmans','retailer_product_id':'sku',
        'package_quantity':'8','package_unit':'oz','form':'bag'}).json()
    client.put(f"/api/staples/{staple}/matches/{smaller['id']}",json={'status':'approved'})
    response=client.post('/api/observations',json={'variant_id':smaller['id'],'staple_id':staple,
        'store_id':'wegmans','context_id':context,'product_name':'Rice smaller','price':'4',
        'quantity':'8','unit':'oz','channel':'in_store','observed_at':'2026-01-02T12:00:00Z'})
    assert response.status_code == 201,response.text
    report=client.post('/api/reports',json={'as_of':'2026-01-03T00:00:00Z','stores':['wegmans']}).json()
    assert report['price_drops'] == []
    big=next(o for o in report['comparisons'][0]['offers'] if o['variant_id']==variant)
    assert big['packages_needed'] == 2 and big['purchase_cost'] == '12'
    assert big['excess_quantity'] == '12'


def test_empty_report_and_missing_retrieval_and_wrong_channel(tmp_path):
    client=TestClient(create_app(tmp_path/'empty.sqlite3'),base_url='http://localhost')
    response=client.post('/api/reports',json={'as_of':'2026-01-03T00:00:00Z','stores':['wegmans']})
    assert response.status_code == 201 and response.json()['comparisons']==[]
    report=response.json()
    assert client.get('/api/reports/'+report['id']).json() == report
    assert client.get('/reports/'+report['id']).status_code == 200
    assert client.get('/api/reports/missing').status_code == 404
    assert client.post('/api/reports',json={'as_of':report['as_of'],'stores':['wegmans'],'channel':'online'}).status_code == 422
