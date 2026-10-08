"""Replay whitelisted public product responses; never contact a retailer."""
import copy
import json
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

import httpx
import pytest

from staple_scout.adapters import AdapterContext
from staple_scout.wegmans import WegmansAdapter

RAW = json.loads((Path(__file__).parent / 'fixtures/wegmans-products.json').read_text())
CTX = AdapterContext(retailer='wegmans', context_id=1, location_id='133', channel='in_store')
IDS = [row['skuId'] for row in RAW]


def adapter(data=None, *, status=200, headers=None, calls=None):
    data = RAW if data is None else data
    def handler(request):
        if calls is not None:
            calls.append(request)
        identity = request.url.path.rsplit('/', 1)[-1]
        row = next((row for row in data if row['skuId'] == identity), data[0])
        return httpx.Response(status, json=row, headers=headers or {})
    return WegmansAdapter(transport=httpx.MockTransport(handler))


def test_five_captured_records_preserve_actual_amounts_packages_and_availability():
    calls = []
    rows = adapter(calls=calls).fetch(CTX, IDS, timeout=2)
    assert [(r.retailer_product_id, r.price, r.quantity, r.unit, r.quantity_kind, r.available) for r in rows] == [
        ('94427', Decimal('3.39'), Decimal('128'), 'fl_oz', 'fixed', False),
        ('80133', Decimal('1.69'), Decimal('12'), 'each', 'fixed', True),
        ('57084', Decimal('11'), Decimal('4.8'), 'lb', 'estimated', True),
        ('47264', Decimal('3.49'), Decimal('5'), 'lb', 'fixed', True),
        ('92685', Decimal('.19'), Decimal('.38'), 'lb', 'estimated', True),
    ]
    assert [str(call.url) for call in calls] == [f'https://www.wegmans.com/api/products/133/{pid}' for pid in IDS]
    assert all(call.extensions['timeout']['read'] == 2 for call in calls)
    assert all(r.source_record_id == f'133-{r.retailer_product_id}-Instore' and r.location_id == '133' and r.channel == 'in_store' for r in rows)
    assert rows[0].barcode == '00077890944271' and rows[4].barcode == RAW[4]['upc'][0]
    assert '2.29/lb.' in rows[2].conditions and '.49/lb.' in rows[4].conditions
    assert rows[1].conditions == ''


def test_loyalty_remains_conditional_and_never_replaces_regular_price():
    chicken = adapter().fetch(CTX, ['57084'], timeout=2)[0]
    assert chicken.price == Decimal('11')
    assert '9.56' in chicken.conditions and '2026-10-18' in chicken.conditions
    assert 'triggerQuantity' in chicken.conditions and 'unverified' in chicken.conditions
    # A conditional loyalty expiry is not the regular price's expiry.
    assert chicken.valid_until is None
    rice = adapter().fetch(CTX, ['47264'], timeout=2)[0]
    assert rice.price == Decimal('3.49') and '7582181' in rice.conditions and 'details may be missing' in rice.conditions


@pytest.mark.parametrize('location,channel', [('5969', 'in_store'), ('133', 'pickup'), ('133', 'online'), (None, 'in_store')])
def test_context_guard(location, channel):
    context = AdapterContext(retailer='wegmans', context_id=1, location_id=location, channel=channel)
    calls = []
    with pytest.raises(ValueError):
        adapter(calls=calls).fetch(context, [IDS[0]], timeout=2)
    assert calls == []


@pytest.mark.parametrize('bad', [['x'], ['1/2'], ['１'], [True], [1], [], ['1'] * 51])
def test_product_ids_are_bounded_explicit_ascii_strings(bad):
    with pytest.raises(ValueError):
        adapter().fetch(CTX, bad, timeout=2)


@pytest.mark.parametrize('timeout', [0, -1, 31, True, float('inf')])
def test_timeout_is_bounded(timeout):
    with pytest.raises(ValueError):
        adapter().fetch(CTX, [IDS[0]], timeout=timeout)


@pytest.mark.parametrize('key,value', [('storeNumber', '999'), ('storeNumber', None), ('skuId', 'other'), ('productID', None), ('productId', '999'), ('objectId', '999-94427')])
def test_missing_or_conflicting_identity_fails(key, value):
    data = copy.deepcopy(RAW)
    data[0][key] = value
    with pytest.raises(ValueError):
        adapter(data).fetch(CTX, [IDS[0]], timeout=2)


def test_delivery_or_wrong_store_price_is_never_reclassified():
    data = copy.deepcopy(RAW)
    data[0]['price_inStore']['channelKey'] = '133-Delivery'
    with pytest.raises(ValueError):
        adapter(data).fetch(CTX, [IDS[0]], timeout=2)


@pytest.mark.parametrize('key', ['isAvailable', 'isSoldAtStore'])
def test_one_missing_stock_flag_is_unknown_even_when_other_true(key):
    data = copy.deepcopy(RAW)
    data[1].pop(key)
    assert adapter(data).fetch(CTX, ['80133'], timeout=2)[0].available is None


def test_false_stock_dominates_missing_and_buyable_flags():
    data = copy.deepcopy(RAW)
    data[0].pop('isSoldAtStore')
    assert data[0]['isBuyable'] is True
    assert adapter(data).fetch(CTX, [IDS[0]], timeout=2)[0].available is False


@pytest.mark.parametrize('key,value', [('isAvailable', 'true'), ('isSoldAtStore', 1), ('isSoldByWeight', 'false'), ('upc', [123]), ('upc', ['0001', 123]), ('soldByVendor', 'Marketplace')])
def test_malformed_flags_barcodes_and_vendor_fail(key, value):
    data = copy.deepcopy(RAW)
    data[0][key] = value
    with pytest.raises(ValueError):
        adapter(data).fetch(CTX, [IDS[0]], timeout=2)


@pytest.mark.parametrize('label', ['2 x 16 oz', '1-2 lb', '16 oz pack of 2', '5 lb / 2 kg', 'family size', '0 lb'])
def test_ambiguous_package_size_is_not_guessed_from_title(label):
    data = copy.deepcopy(RAW)
    data[0]['packSize'] = label
    row = adapter(data).fetch(CTX, [IDS[0]], timeout=2)[0]
    assert row.quantity is None and row.unit is None


@pytest.mark.parametrize('key', ['price_inStore', 'packSize', 'isSoldByWeight', 'upc'])
def test_missing_evidence_stays_unknown(key):
    data = copy.deepcopy(RAW)
    data[0].pop(key)
    data[0]['price_delivery'] = {'amount': '.01', 'channelKey': '133-Delivery'}
    row = adapter(data).fetch(CTX, [IDS[0]], timeout=2)[0]
    if key == 'price_inStore':
        assert row.price is None
    elif key == 'upc':
        assert row.barcode is None
    else:
        assert row.quantity is None


@pytest.mark.parametrize('approx', [None, 0])
def test_variable_purchase_without_positive_weight_stays_unresolved(approx):
    data = copy.deepcopy(RAW)
    data[2]['onlineApproxUnitWeight'] = approx
    row = adapter(data).fetch(CTX, ['57084'], timeout=2)[0]
    assert row.quantity_kind == 'variable' and row.quantity is None


def test_cosmetic_rename_preserves_package_form_and_source_identity():
    data = copy.deepcopy(RAW)
    before = adapter(data).fetch(CTX, ['80133'], timeout=2)[0]
    data[1]['productName'] = 'Renamed Large Eggs'
    after = adapter(data).fetch(CTX, ['80133'], timeout=2)[0]
    assert before.product_name != after.product_name
    assert (before.quantity, before.unit, before.form, before.retailer_product_id) == (after.quantity, after.unit, after.form, after.retailer_product_id)


def test_date_and_age_choose_older_bound_without_retiming_cached_payload():
    retrieved = datetime(2026, 10, 8, 13, 30, tzinfo=timezone.utc)
    response = httpx.Response(200, headers={'Date': 'Thu, 08 Oct 2026 13:20:00 GMT', 'Age': '120'})
    assert WegmansAdapter._observed(response, retrieved) == retrieved - timedelta(minutes=10)
    response = httpx.Response(200, headers={'Date': 'Thu, 08 Oct 2026 13:29:00 GMT', 'Age': '120'})
    assert WegmansAdapter._observed(response, retrieved) == retrieved - timedelta(minutes=2)


@pytest.mark.parametrize('headers', [{'age': 'broken'}, {'date': 'Thu, 08 Oct 2026 13:00:00'}, {'date': 'Thu, 08 Oct 2026 13:31:00 GMT'}])
def test_bad_cache_metadata_fails(headers):
    with pytest.raises(ValueError):
        WegmansAdapter._observed(httpx.Response(200, headers=headers), datetime(2026, 10, 8, 13, 30, tzinfo=timezone.utc))


def test_http_error_propagates_without_browser_fallback():
    with pytest.raises(httpx.HTTPStatusError):
        adapter(status=403).fetch(CTX, [IDS[0]], timeout=2)


@pytest.mark.parametrize('fixture_name', ['milk', 'eggs', 'chicken', 'rice', 'bananas', 'store', 'portal', 'request-failures'])
def test_historical_research_cannot_be_used_as_store_price_evidence(fixture_name):
    historical = json.loads((Path(__file__).parent / f'fixtures/wegmans/{fixture_name}.json').read_text())
    projection = historical.get('json_ld_product_projection', historical)
    if 'sku' in projection:
        canonical = next(row for row in RAW if row['skuId'] == projection['sku'])
        assert historical['json_ld_has_offers'] is False
        assert 'offers' not in historical['json_ld_original_keys']
        # The oddly named JSON-LD gtin13 values are 14-digit source text, unchanged.
        assert projection['gtin13'] == canonical['upc'][0]
        assert isinstance(projection['gtin13'], str) and len(projection['gtin13']) == 14
        assert 'price_inStore' not in projection and 'isAvailable' not in projection
    # Sanitized HTML projections/diagnostics are deliberately incompatible with
    # the observed JSON contract, even when a product and In Store label exist.
    transport = httpx.MockTransport(lambda request: httpx.Response(200, json=projection))
    with pytest.raises(ValueError):
        WegmansAdapter(transport=transport).fetch(CTX, [projection.get('sku', '94427')], timeout=2)
