"""Explicit, per-source ingestion transaction helpers."""
from datetime import datetime, timezone
from .adapters import AdapterContext, SourceAdapter
from decimal import Decimal

def run_adapter(database, adapter: SourceAdapter, context: AdapterContext, product_ids: list[str]):
    started = datetime.now(timezone.utc).isoformat()
    with database.connect() as db:
        db.execute('BEGIN IMMEDIATE')
        row = db.execute("INSERT INTO refresh_runs(retailer,context_id,started_at,status) VALUES(?,?,?,'running') RETURNING id", (context.retailer, context.location_id, started)).fetchone()
        run_id = row[0]
    try:
        evidence = list(adapter.fetch(context, product_ids))
        with database.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            for item in evidence:
                if item.location_id != context.location_id or item.channel != context.channel:
                    raise ValueError('source response context does not match request')
                variant = db.execute("SELECT * FROM product_variants WHERE retailer=? AND retailer_product_id=? ORDER BY id DESC LIMIT 1", (context.retailer,item.retailer_product_id)).fetchone()
                if variant is None:
                    db.execute("INSERT INTO refresh_results(run_id,retailer_product_id,status,error) VALUES(?,?,?,?)", (run_id,item.retailer_product_id,'unresolved','Unknown product variant'))
                    continue
                db.execute("INSERT INTO staple_matches(staple_id,variant_id,status) SELECT id, ?, 'pending' FROM staples WHERE id NOT IN (SELECT staple_id FROM staple_matches WHERE variant_id=?)", (variant['id'], variant['id']))
                if item.quantity is None or item.unit is None:
                    db.execute("INSERT INTO refresh_results(run_id,retailer_product_id,status,error) VALUES(?,?,?,?)", (run_id,item.retailer_product_id,'unresolved','Package quantity is unknown'))
                    continue
                context_row = db.execute("SELECT id FROM location_contexts WHERE store_id=? AND location_id=? AND channel=? ORDER BY id DESC LIMIT 1", (context.retailer,context.location_id,context.channel)).fetchone()
                if context_row is None: raise ValueError('configured response context not found')
                for match in db.execute("SELECT staple_id FROM staple_matches WHERE variant_id=?", (variant['id'],)).fetchall():
                    cur = db.execute("""INSERT INTO observations(staple_id,store_id,context_id,product_name,price,quantity,unit,pack_count,channel,observed_at,source_url,available,approved,conditions)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)""", (match[0],context.retailer,context_row[0],item.product_name,str(item.price),str(item.quantity),item.unit,item.pack_count,item.channel,item.observed_at.isoformat(),item.source_url,item.available,False,item.conditions))
                    db.execute("INSERT INTO observation_variants(observation_id,variant_id) VALUES(?,?)", (cur.lastrowid,variant['id']))
                    db.execute("INSERT INTO refresh_results(run_id,retailer_product_id,status,observation_id) VALUES(?,?,?,?)", (run_id,item.retailer_product_id,'accepted',cur.lastrowid))
            db.execute("UPDATE refresh_runs SET status='succeeded',finished_at=? WHERE id=?", (datetime.now(timezone.utc).isoformat(),run_id))
        return run_id
    except Exception as exc:
        with database.connect() as db:
            db.execute("UPDATE refresh_runs SET status='failed',finished_at=?,error=? WHERE id=?", (datetime.now(timezone.utc).isoformat(), str(exc)[:500], run_id))
        raise
