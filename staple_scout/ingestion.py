"""Explicit, per-source ingestion transaction helpers."""
from datetime import datetime, timezone
from .adapters import AdapterContext, SourceAdapter
from decimal import Decimal

def run_adapter(database, adapter: SourceAdapter, context: AdapterContext, product_ids: list[str], *, context_id: int | None = None, staple_ids: list[int] | None = None, idempotency_key: str | None = None, allowed_sellers: set[str] | None = None):
    started = datetime.now(timezone.utc).isoformat()
    with database.connect() as db:
        db.execute('BEGIN IMMEDIATE')
        if context_id is None:
            found = db.execute("SELECT id FROM location_contexts WHERE store_id=? AND location_id=? AND channel=? ORDER BY id DESC LIMIT 1", (context.retailer, context.location_id, context.channel)).fetchone()
            if found is None: raise ValueError('context not found')
            context_id = found[0]
        if idempotency_key:
            prior = db.execute("SELECT id FROM refresh_runs WHERE retailer=? AND started_at=?", (context.retailer, idempotency_key)).fetchone()
            if prior: return prior[0]
        row = db.execute("INSERT INTO refresh_runs(retailer,context_id,started_at,status) VALUES(?,?,?,'running') RETURNING id", (context.retailer, context_id, idempotency_key or started)).fetchone()
        run_id = row[0]
    try:
        evidence = list(adapter.fetch(context, product_ids))
        with database.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            for item in evidence:
                if item.location_id != context.location_id or item.channel != context.channel or adapter.retailer != context.retailer:
                    raise ValueError('source response context does not match request')
                if allowed_sellers is not None and item.seller not in allowed_sellers:
                    db.execute("INSERT INTO refresh_results(run_id,retailer_product_id,status,error,seller,retrieved_at) VALUES(?,?,?,?,?,?)", (run_id,item.retailer_product_id,'rejected','seller not allowed',item.seller,item.retrieved_at.isoformat())); continue
                variant = db.execute("SELECT * FROM product_variants WHERE retailer=? AND retailer_product_id=? AND package_quantity=? AND package_unit=? AND pack_count=? AND form=?", (context.retailer,item.retailer_product_id,str(item.quantity),item.unit,item.pack_count,item.form)).fetchone()
                if variant is None:
                    db.execute("INSERT INTO refresh_results(run_id,retailer_product_id,status,error,retrieved_at) VALUES(?,?,?,?,?)", (run_id,item.retailer_product_id,'unresolved','Unknown product variant',item.retrieved_at.isoformat()))
                    continue
                db.execute("INSERT INTO staple_matches(staple_id,variant_id,status) SELECT id, ?, 'pending' FROM staples WHERE id NOT IN (SELECT staple_id FROM staple_matches WHERE variant_id=?)", (variant['id'], variant['id']))
                if item.quantity is None or item.unit is None:
                    db.execute("INSERT INTO refresh_results(run_id,retailer_product_id,status,error,retrieved_at) VALUES(?,?,?,?,?)", (run_id,item.retailer_product_id,'unresolved','Package quantity is unknown',item.retrieved_at.isoformat()))
                    continue
                context_row = db.execute("SELECT id FROM location_contexts WHERE id=? AND store_id=?", (context_id,context.retailer)).fetchone()
                if context_row is None: raise ValueError('configured response context not found')
                matches = staple_ids or [r[0] for r in db.execute("SELECT staple_id FROM staple_matches WHERE variant_id=?", (variant['id'],)).fetchall()]
                for staple_id in matches:
                    cur = db.execute("""INSERT INTO observations(staple_id,store_id,context_id,product_name,price,quantity,unit,pack_count,channel,observed_at,source_url,available,approved,conditions)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)""", (match[0],context.retailer,context_row[0],item.product_name,str(item.price),str(item.quantity),item.unit,item.pack_count,item.channel,item.observed_at.isoformat(),item.source_url,item.available,False,item.conditions))
                    db.execute("INSERT INTO observation_variants(observation_id,variant_id) VALUES(?,?)", (cur.lastrowid,variant['id']))
                    db.execute("INSERT INTO refresh_results(run_id,retailer_product_id,status,seller,retrieved_at,observation_id) VALUES(?,?,?,?,?,?)", (run_id,item.retailer_product_id,'accepted',item.seller,item.retrieved_at.isoformat(),cur.lastrowid))
            db.execute("UPDATE refresh_runs SET status='succeeded',finished_at=? WHERE id=?", (datetime.now(timezone.utc).isoformat(),run_id))
        return run_id
    except Exception as exc:
        with database.connect() as db:
            db.execute("UPDATE refresh_runs SET status='failed',finished_at=?,error=? WHERE id=?", (datetime.now(timezone.utc).isoformat(), 'adapter failure', run_id))
        raise
