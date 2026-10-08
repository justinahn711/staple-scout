"""Explicit, per-source ingestion transaction helpers."""
from datetime import datetime, timezone
from .adapters import AdapterContext, SourceAdapter

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
                db.execute("INSERT INTO refresh_results(run_id,retailer_product_id,status) VALUES(?,?,?)", (run_id,item.retailer_product_id,'accepted'))
            db.execute("UPDATE refresh_runs SET status='succeeded',finished_at=? WHERE id=?", (datetime.now(timezone.utc).isoformat(),run_id))
        return run_id
    except Exception as exc:
        with database.connect() as db:
            db.execute("UPDATE refresh_runs SET status='failed',finished_at=?,error=? WHERE id=?", (datetime.now(timezone.utc).isoformat(), str(exc)[:500], run_id))
        raise
