"""Saved local reports with cutoff-scoped evidence and frozen generation rules.

The first request freezes current requirements, approvals and preferred contexts.
A cutoff selects observations; it does not reconstruct historical user settings.
Repeating the normalized request returns that same immutable snapshot.
"""
import hashlib
import json
from datetime import datetime, timezone
from decimal import Decimal

from pydantic import Field, field_validator

from .comparison import compare
from .database import as_record, STORE_SELECT
from .models import Retailer, StrictModel
from typing import Literal


class ReportRequest(StrictModel):
    as_of: datetime
    stores: list[Retailer] = Field(min_length=1, max_length=5)
    channel: Literal['in_store', 'pickup'] = 'in_store'
    needed_only: bool = True

    @field_validator('as_of')
    @classmethod
    def aware_cutoff(cls, value):
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError('Report cutoff must include a timezone')
        value = value.astimezone(timezone.utc)
        if value > datetime.now(timezone.utc):
            raise ValueError('Report cutoff cannot be in the future')
        return value

    @field_validator('stores')
    @classmethod
    def unique_stores(cls, value):
        if len(set(value)) != len(value):
            raise ValueError('Report stores must be unique')
        return sorted(value)


def _time(value):
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError('Stored evidence time must include a timezone')
    return parsed.astimezone(timezone.utc)


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))


def _source_evidence(db, cutoff):
    latest = {}
    results = {}
    for record in db.execute('''SELECT r.*,run.source_id,run.context_id,run.channel,
        run.finished_at FROM refresh_results r JOIN refresh_runs run ON run.id=r.run_id
        WHERE run.status IN ('succeeded','partial') ORDER BY r.id'''):
        row = dict(record)
        # An old source timestamp discovered after the cutoff wasn't known then.
        if not row['finished_at'] or any(_time(row[key]) > cutoff
                for key in ('observed_at', 'retrieved_at', 'finished_at')):
            continue
        results[row['id']] = row
        key = (row['source_id'], row['context_id'], row['channel'], row['retailer_product_id'])
        prior = latest.get(key)
        if prior is None or (_time(row['observed_at']), row['id']) > (_time(prior['observed_at']), prior['id']):
            latest[key] = row
    imports = {row['observation_id']: row['result_id']
               for row in db.execute('SELECT * FROM observation_imports')}
    return results, latest, imports


def _observations(db, request):
    results, latest, imports = _source_evidence(db, request.as_of)
    rows = []
    for original in db.execute('''SELECT o.*, ov.variant_id,
        COALESCE(sm.status,'pending') AS match_status, v.retailer_product_id,
        v.manual_identity,v.barcode,v.form,c.location AS store_location,c.location_id,
        c.location_status,c.location_status != 'unconfigured' AS location_configured,
        s.name AS store_name,s.preferred_context_id
        FROM observations o JOIN observation_variants ov ON ov.observation_id=o.id
        JOIN product_variants v ON v.id=ov.variant_id
        LEFT JOIN staple_matches sm ON sm.staple_id=o.staple_id AND sm.variant_id=ov.variant_id
        JOIN location_contexts c ON c.id=o.context_id JOIN stores s ON s.id=o.store_id
        ORDER BY o.id'''):
        row = as_record(original)
        if row['store_id'] not in request.stores or _time(row['observed_at']) > request.as_of:
            continue
        row['is_current_context'] = row['context_id'] == row['preferred_context_id']
        if row['id'] in imports:
            source = results.get(imports[row['id']])
            if source is None:
                continue
            evidence = json.loads(source['evidence_json'])
            row.update({key: evidence.get(key) for key in
                ('source_record_id', 'retrieved_at', 'seller', 'valid_from', 'valid_until')})
            row['source_id'] = source['source_id']
            current = latest[(source['source_id'],row['context_id'],row['channel'],source['retailer_product_id'])]
            if current['status'] != 'accepted':
                row['source_exclusion'] = current['reason']
            elif current['variant_id'] != row['variant_id']:
                row['source_exclusion'] = 'source_product_changed'
        rows.append(row)
    return rows


def _latest(rows):
    partitions = {}
    for row in rows:
        key = (row['staple_id'],row['variant_id'],row['context_id'],row['channel'])
        prior = partitions.get(key)
        if prior is None or (_time(row['observed_at']),row['id']) > (_time(prior['observed_at']),prior['id']):
            partitions[key] = row
    return sorted(partitions.values(), key=lambda row: row['id'])


def _health(db, stores, channel, cutoff, sources):
    records = []
    for store in stores:
        for source in sources:
            if source['retailer'] != store['id']:
                continue
            runs = []
            for row in db.execute('''SELECT run.id,run.context_id,run.channel,run.started_at,
                run.finished_at,run.status,run.error FROM refresh_runs run
                WHERE run.source_id=? AND run.context_id=? AND run.channel=? ORDER BY run.id DESC''',
                (source['source_id'],store['preferred_context_id'],channel)):
                # A later completion must not leak a future result/status backwards.
                if _time(row['started_at']) > cutoff:
                    continue
                item = dict(row)
                if not item['finished_at'] or _time(item['finished_at']) > cutoff:
                    item.update(status='running', finished_at=None, error=None)
                runs.append(item)
            success = None
            for run in runs:
                if run['status'] in {'succeeded','partial'}:
                    if any(r['status'] in {'accepted','unavailable'} and _time(r['observed_at']) <= cutoff
                           and _time(r['retrieved_at']) <= cutoff for r in db.execute(
                           'SELECT status,observed_at,retrieved_at FROM refresh_results WHERE run_id=?', (run['id'],))):
                        success = run
                        break
            records.append({'store_id':store['id'], **source,
                'relevant':source['validated'] and channel in source['channels'],
                'last_attempt':runs[0] if runs else None, 'last_success':success,
                'last_failure':next((run for run in runs if run['status']=='failed'),None)})
    return records


def _price_drops(comparisons, history):
    drops = []
    for group in comparisons:
        for current in group['offers']:
            if not current['eligible']:
                continue
            prior_rows = [row for row in history if
                all(row.get(key) == current.get(key) for key in
                    ('staple_id','variant_id','context_id','channel','source_id'))
                and _time(row['observed_at']) < _time(current['observed_at'])]
            if not prior_rows:
                continue
            # Compare the immediately previous observation, never cherry-pick a high price.
            prior = max(prior_rows,key=lambda row: (_time(row['observed_at']),row['id']))
            if (not prior['available'] or prior['conditions'].strip()
                    or prior.get('quantity_kind','fixed') != 'fixed'):
                continue
            # Offer terms must have applied at the previous observation too.
            if prior.get('valid_from') and _time(prior['observed_at']) < _time(prior['valid_from']):
                continue
            if prior.get('valid_until') and _time(prior['observed_at']) >= _time(prior['valid_until']):
                continue
            difference = Decimal(prior['price']) - Decimal(current['price'])
            if difference > 0:
                drops.append({'staple_id':group['staple']['id'], 'variant_id':current['variant_id'],
                    'context_id':current['context_id'],'store_id':current['store_id'],
                    'channel':current['channel'],'product_name':current['product_name'],
                    'previous_observation_id':prior['id'],'observation_id':current['id'],
                    'previous_observed_at':prior['observed_at'],'observed_at':current['observed_at'],
                    'previous_price':prior['price'],'price':current['price'],
                    'package_price_drop':format(difference,'f')})
    return drops


def generate_report(database, request, *, sources=()):
    request = ReportRequest.model_validate(request)
    normalized = request.model_dump(mode='json')
    key = _canonical({'report_schema':1, **normalized})
    report_id = hashlib.sha256(key.encode()).hexdigest()
    with database.connect() as db:
        db.execute('BEGIN IMMEDIATE')
        prior = db.execute('SELECT payload_json FROM reports WHERE id=?',(report_id,)).fetchone()
        if prior:
            return json.loads(prior[0])
        stores = [as_record(row) for row in db.execute(STORE_SELECT+' ORDER BY s.id') if row['id'] in request.stores]
        staples = [as_record(row) for row in db.execute(
            'SELECT * FROM staples WHERE (?=0 OR needed=1) ORDER BY id',(request.needed_only,))]
        history = _observations(db,request)
        latest = _latest(history)
        comparisons = [compare(staple,[row for row in latest if row['staple_id']==staple['id']],
            now=request.as_of,channel=request.channel) for staple in staples]
        shopping = []
        for store in stores:
            choices = []
            for group in comparisons:
                winner = next((offer for offer in group['offers'] if offer['id']==group['winner_id']),None)
                if winner and winner['store_id']==store['id']:
                    choices.append({'staple':group['staple'],'offer':winner,
                        'purchase_cost_winner_id':group['purchase_cost_winner_id']})
            shopping.append({'store':store,'choices':choices})
        payload = {'id':report_id,'report_schema':1,'format':'local_web','request':normalized,
            'as_of':normalized['as_of'],'channel':request.channel,
            'generated_at':datetime.now(timezone.utc).isoformat(),
            'settings_policy':'Requirements, approvals, planned stores and preferred locations are frozen at first generation. Cutoff selects recorded evidence, not historical user settings. Repeating these inputs returns this saved report.',
            'stores':stores,'comparisons':comparisons,'shopping':shopping,
            'coverage_gaps':[group['staple']['id'] for group in comparisons if group['winner_id'] is None],
            'price_drops':_price_drops(comparisons,history),
            'source_health':_health(db,stores,request.channel,request.as_of,sources)}
        encoded = _canonical(payload)
        db.execute('INSERT INTO reports(id,request_json,payload_json) VALUES(?,?,?)',(report_id,key,encoded))
        return json.loads(encoded)


def get_report(database, report_id):
    with database.connect() as db:
        row = db.execute('SELECT payload_json FROM reports WHERE id=?',(report_id,)).fetchone()
    return None if row is None else json.loads(row[0])
