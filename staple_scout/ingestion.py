"""Bounded, explicit refreshes with atomic evidence and durable run status."""
import hashlib
import json
from datetime import datetime, timezone
from itertools import islice

from .adapters import AdapterContext, OfferEvidence, ProductRequest


class RefreshConflict(ValueError):
    pass


def timestamp():
    return datetime.now(timezone.utc).isoformat(timespec='microseconds')


def get_run(connection, run_id):
    row = connection.execute('SELECT * FROM refresh_runs WHERE id=?', (run_id,)).fetchone()
    if row is None:
        return None
    run = dict(row)
    run.pop('fingerprint')
    run['results'] = []
    for result in connection.execute('SELECT * FROM refresh_results WHERE run_id=? ORDER BY id', (run_id,)):
        record = dict(result)
        record['evidence'] = json.loads(record.pop('evidence_json'))
        run['results'].append(record)
    return run


def run_adapter(database, registration, context_id, channel, requests, idempotency_key):
    """Commit one source independently. Failures retain previous observations unchanged.

    A key identifies a request, not a timestamp. Callers choose a new key for a new
    measurement and reuse the same key only to retrieve that request's outcome.
    """
    if not registration.validated:
        raise ValueError('Source has not passed its evidence verification gate')
    if channel not in registration.channels:
        raise ValueError('Source does not support this channel')
    requests = [ProductRequest.model_validate(r) for r in requests]
    if not 1 <= len(requests) <= 50 or not isinstance(idempotency_key, str) or not 1 <= len(idempotency_key.strip()) <= 100:
        raise ValueError('Refresh needs 1–50 explicit product requests and an idempotency key')
    targets = {}
    for request in requests:
        targets.setdefault(request.retailer_product_id, set()).add(request.staple_id)
    payload = {'context_id': context_id, 'channel': channel,
               'targets': sorted((product, sorted(staples)) for product, staples in targets.items())}
    fingerprint = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
    with database.connect() as db:
        db.execute('BEGIN IMMEDIATE')
        context_row = db.execute('SELECT * FROM location_contexts WHERE id=? AND store_id=?',
                                 (context_id, registration.retailer)).fetchone()
        if context_row is None or context_row['location_status'] == 'unconfigured':
            raise ValueError('Choose a configured context belonging to this source retailer')
        for staple_id in {sid for ids in targets.values() for sid in ids}:
            if db.execute('SELECT 1 FROM staples WHERE id=?', (staple_id,)).fetchone() is None:
                raise ValueError('Unknown staple')
        prior = db.execute('SELECT * FROM refresh_runs WHERE source_id=? AND idempotency_key=?',
                           (registration.source_id, idempotency_key)).fetchone()
        if prior:
            if prior['fingerprint'] != fingerprint:
                raise RefreshConflict('Idempotency key belongs to a different request')
            return get_run(db, prior['id'])
        context = AdapterContext(retailer=registration.retailer, context_id=context_id,
                                 location_id=context_row['location_id'], channel=channel)
        run_id = db.execute('''INSERT INTO refresh_runs
            (source_id,retailer,context_id,channel,idempotency_key,fingerprint,started_at,status)
            VALUES(?,?,?,?,?,?,?,'running')''', (registration.source_id, registration.retailer,
            context_id, channel, idempotency_key, fingerprint, timestamp())).lastrowid
    error = 'source_error'
    try:
        # HTTP adapters must pass this bounded timeout to their client. No writer
        # transaction stays open during network activity; no automatic retries.
        returned = registration.adapter.fetch(context, sorted(targets), timeout=registration.timeout)
        error = 'invalid_evidence'
        items = list(islice(iter(returned), 51))
        if len(items) > 50:
            raise ValueError('Source returned too many records')
        evidence = {}
        products = set()
        for raw in items:
            item = OfferEvidence.model_validate(raw.model_dump() if isinstance(raw, OfferEvidence) else raw)
            if (item.location_id != context.location_id or item.channel != channel
                    or item.seller not in registration.sellers or item.retailer_product_id not in targets):
                raise ValueError('Source evidence conflicts with the requested scope')
            if item.source_record_id in evidence:
                if evidence[item.source_record_id] != item:
                    raise ValueError('Conflicting source record identity')
                continue
            if item.retailer_product_id in products:
                raise ValueError('Source returned multiple offers for a requested product')
            products.add(item.retailer_product_id)
            evidence[item.source_record_id] = item
        error = 'storage_error'
        with database.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            resolved = 0
            for item in evidence.values():
                status, reason, variant_id = 'accepted', None, None
                if item.available is False:
                    status, reason = 'unavailable', 'source_unavailable'
                elif item.price is None:
                    status, reason = 'unresolved', 'source_price_unknown'
                elif item.quantity is None:
                    status, reason = 'unresolved', 'source_quantity_unknown'
                elif item.available is None:
                    status, reason = 'unresolved', 'source_availability_unknown'
                if item.quantity is not None:
                    quantity = format(item.quantity.normalize(), 'f')
                    identity = (registration.retailer, item.retailer_product_id, quantity,
                                item.unit, item.pack_count, item.form)
                    variant = db.execute('''SELECT * FROM product_variants WHERE retailer=?
                        AND retailer_product_id=? AND package_quantity=? AND package_unit=?
                        AND pack_count=? AND form=?''', identity).fetchone()
                    if variant:
                        # A barcode change is an identity conflict, never a silent rewrite.
                        if variant['barcode'] != item.barcode:
                            raise ValueError('Source changed the barcode of an immutable variant')
                        variant_id = variant['id']
                    else:
                        variant_id = db.execute('''INSERT INTO product_variants
                            (retailer,retailer_product_id,package_quantity,package_unit,pack_count,form,barcode)
                            VALUES(?,?,?,?,?,?,?)''', (*identity, item.barcode)).lastrowid
                    for staple_id in targets[item.retailer_product_id]:
                        db.execute('''INSERT INTO staple_matches(staple_id,variant_id,status)
                            VALUES(?,?,'pending') ON CONFLICT DO NOTHING''', (staple_id, variant_id))
                result_id = db.execute('''INSERT INTO refresh_results
                    (run_id,source_record_id,retailer_product_id,observed_at,retrieved_at,evidence_json,status,reason,variant_id)
                    VALUES(?,?,?,?,?,?,?,?,?)''', (run_id, item.source_record_id, item.retailer_product_id,
                    item.observed_at.isoformat(timespec='microseconds'), item.retrieved_at.isoformat(timespec='microseconds'),
                    item.model_dump_json(), status, reason, variant_id)).lastrowid
                # Unknown quantities/prices/stock remain evidence, never invented observations.
                # Explicit unavailability with a known package and price is also retained.
                if item.price is not None and item.quantity is not None and item.available is not None:
                    for staple_id in targets[item.retailer_product_id]:
                        obs_id = db.execute('''INSERT INTO observations
                            (staple_id,store_id,context_id,product_name,price,quantity,unit,pack_count,
                             channel,observed_at,source_url,available,approved,conditions,quantity_kind)
                            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0,?,?)''', (staple_id, registration.retailer,
                            context_id, item.product_name, format(item.price, 'f'), quantity, item.unit,
                            item.pack_count, channel, item.observed_at.isoformat(timespec='microseconds'),
                            item.source_url, item.available, item.conditions, item.quantity_kind)).lastrowid
                        db.execute('INSERT INTO observation_variants VALUES(?,?)', (obs_id, variant_id))
                        db.execute('INSERT INTO observation_imports VALUES(?,?)', (obs_id, result_id))
                if status in {'accepted', 'unavailable'}:
                    resolved += 1
            # Missing requested products are gaps, never an implicit out-of-stock claim.
            complete = len(products) == len(targets) and resolved == len(evidence)
            db.execute('UPDATE refresh_runs SET status=?,finished_at=? WHERE id=?',
                       ('succeeded' if complete else 'partial', timestamp(), run_id))
            return get_run(db, run_id)
    except Exception as exc:
        # Persist only classified error codes. Retailer exceptions may include tokens,
        # HTML, cookies or private URLs and must never enter the database/API/logs.
        if isinstance(exc, TimeoutError) or type(exc).__name__ in {'ReadTimeout', 'ConnectTimeout', 'TimeoutException', 'PoolTimeout', 'WriteTimeout'}:
            error = 'source_timeout'
        with database.connect() as db:
            db.execute('UPDATE refresh_runs SET status=\'failed\',finished_at=?,error=? WHERE id=?',
                       (timestamp(), error, run_id))
            return get_run(db, run_id)


def enrich_observations(connection, observations):
    """Attach original provenance and the newest source product state.

    A changed/unknown package cannot leave an older approved package winning.
    A failed fetch has no results, so it never changes source product state.
    """
    latest = {}
    for row in connection.execute('''SELECT r.*, run.source_id,run.context_id,run.channel
        FROM refresh_results r JOIN refresh_runs run ON run.id=r.run_id
        ORDER BY r.observed_at,r.id'''):
        latest[(row['source_id'], row['context_id'], row['channel'], row['retailer_product_id'])] = row
    imports = {row['observation_id']: row for row in connection.execute('''SELECT i.observation_id,
        r.*,run.source_id FROM observation_imports i JOIN refresh_results r ON r.id=i.result_id
        JOIN refresh_runs run ON run.id=r.run_id''')}
    enriched = []
    for original in observations:
        row = dict(original)
        source = imports.get(row['id'])
        if source:
            evidence = json.loads(source['evidence_json'])
            for key in ('source_record_id', 'retrieved_at', 'seller', 'valid_from', 'valid_until'):
                row[key] = evidence.get(key)
            row['source_id'] = source['source_id']
            current = latest[(source['source_id'], row['context_id'], row['channel'], source['retailer_product_id'])]
            if current['status'] != 'accepted':
                row['source_exclusion'] = current['reason']
            elif current['variant_id'] != row['variant_id']:
                row['source_exclusion'] = 'source_product_changed'
        enriched.append(row)
    return enriched
