"""Run locally: uv run uvicorn staple_scout.main:app --host 127.0.0.1."""

import os
import sqlite3
from pathlib import Path
from datetime import datetime, timezone
from decimal import Decimal
from uuid import uuid4
from urllib.parse import urlsplit

from fastapi import FastAPI, HTTPException, Query, Request, Response
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.trustedhost import TrustedHostMiddleware

from .comparison import compare
from .database import Database, STORES, STORE_SELECT, as_record
from .models import ObservationCreate, StapleCreate, StaplePatch, StorePatch, VariantCreate, MatchReview, Retailer, MatchStatus


def create_app(db_path: str | Path | None = None) -> FastAPI:
    database = Database(db_path or os.environ.get("STAPLE_SCOUT_DB", "data/staple-scout.sqlite3"))
    app = FastAPI(title="Staple Scout", version="0.1.0", description="Local, manually observed grocery comparisons. Automated sources are not connected. Approval confirms a product satisfies your staple rules; it does not verify its price.")
    app.state.database = database
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=["localhost", "127.0.0.1", "[::1]"])

    @app.middleware("http")
    async def local_json_writes(request: Request, call_next):
        if request.method in {"POST", "PUT", "PATCH", "DELETE"}:
            origin = request.headers.get("origin")
            if origin:
                try:
                    parsed = urlsplit(origin)
                    expected = urlsplit(str(request.base_url))
                    same = (parsed.scheme, parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80)) == (expected.scheme, expected.hostname, expected.port or (443 if expected.scheme == "https" else 80))
                    same = same and parsed.path in {"", "/"} and not parsed.query and not parsed.fragment and not parsed.username and not parsed.password
                except ValueError:
                    same = False
                if not same:
                    return JSONResponse({"detail": "Writes require the same origin"}, status_code=403)
            if request.headers.get("sec-fetch-site") == "cross-site":
                return JSONResponse({"detail": "Cross-site writes are not allowed"}, status_code=403)
            if request.method != "DELETE" and request.headers.get("content-type", "").split(";")[0].strip().lower() != "application/json":
                return JSONResponse({"detail": "Writes require application/json"}, status_code=415)
        return await call_next(request)

    @app.get("/api/health")
    def health():
        return {"status": "ok"}

    @app.get("/api/stores")
    def stores():
        with database.connect() as connection:
            return [as_record(row) for row in connection.execute(STORE_SELECT + " ORDER BY s.rowid")]

    def store_record(connection, store_id):
        row = connection.execute(STORE_SELECT + " WHERE s.id = ?", (store_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Store not found")
        return as_record(row)

    @app.get("/api/stores/{store_id}")
    def get_store(store_id: str):
        with database.connect() as connection:
            return store_record(connection, store_id)

    @app.get("/api/stores/{store_id}/contexts")
    def store_contexts(store_id: str):
        with database.connect() as connection:
            connection.execute("BEGIN")
            store = store_record(connection, store_id)
            return [as_record(row) for row in connection.execute("""
                SELECT *, location_status != 'unconfigured' AS location_configured,
                    id = ? AS is_current_context FROM location_contexts
                WHERE store_id = ? ORDER BY id
            """, (store["preferred_context_id"], store_id))]

    @app.patch("/api/stores/{store_id}", description="Select an immutable location context, or create/reuse one from context fields. Configuration does not verify any price source.")
    def update_store(store_id: str, body: StorePatch):
        with database.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            store = store_record(connection, store_id)
            context_id = store["preferred_context_id"]
            if body.context is not None:
                context = body.context
                identity = (store_id, context.location, context.location_id, context.channel, context.location_status)
                row = connection.execute("""SELECT id FROM location_contexts WHERE store_id = ?
                    AND location = ? AND location_id IS ? AND channel = ? AND location_status = ?""", identity).fetchone()
                if row is None:
                    context_id = connection.execute("""INSERT INTO location_contexts
                        (store_id, location, location_id, channel, location_status)
                        VALUES (?, ?, ?, ?, ?)""", identity).lastrowid
                else:
                    context_id = row["id"]
            elif body.context_id is not None:
                context_id = body.context_id
            context = connection.execute("SELECT * FROM location_contexts WHERE id = ? AND store_id = ?", (context_id, store_id)).fetchone()
            if context is None:
                raise HTTPException(422, "Context must exist and belong to this store")
            connection.execute("""UPDATE stores SET preferred_context_id = ?, location = ?, channel = ?, note = ?
                WHERE id = ?""", (context_id, context["location"], context["channel"],
                                  body.note if body.note is not None else store["note"], store_id))
            return store_record(connection, store_id)

    @app.get("/api/staples")
    def staples():
        with database.connect() as connection:
            return [as_record(row) for row in connection.execute("SELECT * FROM staples ORDER BY id")]

    @app.post("/api/staples", status_code=201)
    def create_staple(body: StapleCreate):
        with database.connect() as connection:
            cursor = connection.execute("INSERT INTO staples(name, basis, rules, needed, desired_quantity, desired_unit) VALUES (?, ?, ?, ?, ?, ?)", (body.name, body.basis, body.rules, body.needed, str(body.desired_quantity) if body.desired_quantity is not None else None, body.desired_unit))
            return as_record(connection.execute("SELECT * FROM staples WHERE id = ?", (cursor.lastrowid,)).fetchone())

    @app.patch("/api/staples/{staple_id}", description="Changing name, basis, or rules clears approval on existing observations; price history is retained. Needed-only and no-op changes preserve approval.")
    def update_staple(staple_id: int, body: StaplePatch):
        with database.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute("SELECT * FROM staples WHERE id = ?", (staple_id,)).fetchone()
            if existing is None:
                raise HTTPException(404, "Staple not found")
            changes = body.model_dump(exclude_unset=True)
            if "desired_quantity" in changes and changes["desired_quantity"] is not None:
                changes["desired_quantity"] = str(changes["desired_quantity"])
            if changes:
                if any(key in changes and changes[key] != existing[key] for key in ("name", "basis", "rules")):
                    connection.execute("UPDATE observations SET approved = 0 WHERE staple_id = ?", (staple_id,))
                    connection.execute("UPDATE staple_matches SET status = 'pending', approved_at = NULL WHERE staple_id = ?", (staple_id,))
                columns = ", ".join(f"{key} = ?" for key in changes)
                connection.execute(f"UPDATE staples SET {columns} WHERE id = ?", (*changes.values(), staple_id))
            return as_record(connection.execute("SELECT * FROM staples WHERE id = ?", (staple_id,)).fetchone())

    @app.delete("/api/staples/{staple_id}", status_code=204, description="Permanently delete this staple and all its price observations.")
    def delete_staple(staple_id: int):
        with database.connect() as connection:
            if connection.execute("DELETE FROM staples WHERE id = ?", (staple_id,)).rowcount == 0:
                raise HTTPException(404, "Staple not found")
        return Response(status_code=204)

    @app.post("/api/observations", status_code=201)
    def create_observation(body: ObservationCreate):
        values = body.model_dump()
        values["price"] = format(body.price, "f")
        values["quantity"] = format(body.quantity.normalize(), "f")
        values["observed_at"] = body.observed_at.isoformat(timespec="microseconds")
        with database.connect() as connection:
            # Resolve the implicit context and insert under one writer transaction.
            connection.execute("BEGIN IMMEDIATE")
            store = store_record(connection, body.store_id)
            values["context_id"] = body.context_id if body.context_id is not None else store["preferred_context_id"]
            if body.variant_id is not None:
                variant = connection.execute("SELECT * FROM product_variants WHERE id = ?", (body.variant_id,)).fetchone()
                if variant is None: raise HTTPException(422, "Unknown variant")
                if variant["retailer"] != body.store_id or Decimal(variant["package_quantity"]) != body.quantity or variant["package_unit"] != body.unit or variant["pack_count"] != body.pack_count:
                    raise HTTPException(422, "Observation package or retailer does not match variant")
            variant_id = values.pop("variant_id", None)
            if connection.execute("SELECT id FROM staples WHERE id = ?", (body.staple_id,)).fetchone() is None:
                raise HTTPException(404, "Staple not found")
            placeholders = ", ".join("?" for _ in values)
            try:
                cursor = connection.execute(f"INSERT INTO observations ({', '.join(values)}) VALUES ({placeholders})", tuple(values.values()))
            except sqlite3.IntegrityError:
                raise HTTPException(422, "Invalid observation reference") from None
            if variant_id is not None:
                connection.execute("INSERT INTO observation_variants(observation_id, variant_id) VALUES (?, ?)", (cursor.lastrowid, variant_id))
                connection.execute("INSERT INTO staple_matches(staple_id, variant_id, status) VALUES (?, ?, 'pending') ON CONFLICT DO NOTHING", (body.staple_id, variant_id))
            else:
                # Omitted identity means a new manual product, not a name match.
                # Clients reuse the returned variant_id for future observations.
                variant_id = connection.execute("""INSERT INTO product_variants
                    (retailer, manual_identity, package_quantity, package_unit, pack_count, form)
                    VALUES (?, ?, ?, ?, ?, ?)""", (body.store_id, "manual-" + uuid4().hex,
                    values["quantity"], body.unit, body.pack_count, body.product_name)).lastrowid
                connection.execute("INSERT INTO observation_variants VALUES (?, ?)", (cursor.lastrowid, variant_id))
                connection.execute("""INSERT INTO staple_matches(staple_id, variant_id, status, approved_at)
                    VALUES (?, ?, ?, ?)""", (body.staple_id, variant_id,
                    "approved" if body.approved else "pending",
                    datetime.now(timezone.utc).isoformat() if body.approved else None))
            row = as_record(connection.execute("SELECT * FROM observations WHERE id = ?", (cursor.lastrowid,)).fetchone())
            row["variant_id"] = variant_id
            row["match_status"] = connection.execute("SELECT status FROM staple_matches WHERE staple_id=? AND variant_id=?", (body.staple_id, variant_id)).fetchone()[0]
            return row

    @app.post("/api/variants", status_code=201)
    def create_variant(body: VariantCreate):
        values = body.model_dump()
        values["package_quantity"] = format(body.package_quantity.normalize(), "f")
        with database.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            identity = "retailer_product_id" if body.retailer_product_id is not None else "manual_identity"
            existing = connection.execute(f"SELECT * FROM product_variants WHERE retailer=? AND {identity}=? AND package_quantity=? AND package_unit=? AND pack_count=? AND form=?", (body.retailer, getattr(body, identity), values["package_quantity"], body.package_unit, body.pack_count, body.form)).fetchone()
            if existing is not None:
                return as_record(existing)
            keys = ", ".join(values); marks = ", ".join("?" for _ in values)
            try:
                row = connection.execute(f"INSERT INTO product_variants ({keys}) VALUES ({marks}) RETURNING *", tuple(values.values())).fetchone()
            except sqlite3.IntegrityError:
                raise HTTPException(409, "Variant identity already exists") from None
            return as_record(row)

    @app.get("/api/variants")
    def variants(retailer: Retailer | None = None):
        with database.connect() as connection:
            return [as_record(r) for r in connection.execute("SELECT * FROM product_variants WHERE (? IS NULL OR retailer = ?) ORDER BY id", (retailer, retailer))]

    @app.get("/api/staples/{staple_id}/matches")
    def matches(staple_id: int, status: MatchStatus | None = None):
        with database.connect() as connection:
            if connection.execute("SELECT 1 FROM staples WHERE id = ?", (staple_id,)).fetchone() is None: raise HTTPException(404, "Staple not found")
            return [as_record(r) for r in connection.execute("""SELECT m.*, v.retailer, v.retailer_product_id, v.manual_identity, v.barcode,
                v.package_quantity, v.package_unit, v.pack_count, v.form FROM staple_matches m JOIN product_variants v ON v.id=m.variant_id
                WHERE m.staple_id=? AND (? IS NULL OR m.status=?) ORDER BY m.id""", (staple_id, status, status))]

    @app.put("/api/staples/{staple_id}/matches/{variant_id}")
    def review_match(staple_id: int, variant_id: int, body: MatchReview):
        with database.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            if connection.execute("SELECT 1 FROM staples WHERE id=?", (staple_id,)).fetchone() is None: raise HTTPException(404, "Staple not found")
            if connection.execute("SELECT 1 FROM product_variants WHERE id=?", (variant_id,)).fetchone() is None: raise HTTPException(404, "Variant not found")
            connection.execute("""INSERT INTO staple_matches(staple_id,variant_id,status,approved_at) VALUES(?,?,?,?)
                ON CONFLICT(staple_id,variant_id) DO UPDATE SET status=excluded.status, approved_at=excluded.approved_at""", (staple_id, variant_id, body.status, datetime.now(timezone.utc).isoformat() if body.status == "approved" else None))
            return as_record(connection.execute("SELECT * FROM staple_matches WHERE staple_id=? AND variant_id=?", (staple_id, variant_id)).fetchone())

    @app.get("/api/observations", description="Original observation history, including previous location contexts and superseded prices.")
    def observation_history(staple_id: int | None = Query(default=None, gt=0),
                            store_id: str | None = None, context_id: int | None = Query(default=None, gt=0)):
        if store_id is not None and store_id not in {row[0] for row in STORES}:
            raise HTTPException(422, "Unknown store ID")
        with database.connect() as connection:
            return [as_record(row) for row in connection.execute("""
                SELECT o.*, ov.variant_id, COALESCE(sm.status, 'pending') AS match_status, v.retailer_product_id, v.manual_identity,
                    v.barcode, c.location AS store_location, c.location_id,
                    c.location_status, c.location_status != 'unconfigured' AS location_configured
                FROM observations o LEFT JOIN observation_variants ov ON ov.observation_id=o.id
                    LEFT JOIN staple_matches sm ON sm.staple_id=o.staple_id AND sm.variant_id=ov.variant_id
                    LEFT JOIN product_variants v ON v.id=ov.variant_id JOIN location_contexts c ON c.id = o.context_id
                WHERE (? IS NULL OR o.staple_id = ?) AND (? IS NULL OR o.store_id = ?)
                    AND (? IS NULL OR o.context_id = ?) ORDER BY o.id
            """, (staple_id, staple_id, store_id, store_id, context_id, context_id))]

    @app.get("/api/comparisons")
    def comparisons(needed_only: bool = False,
                    stores: str | None = Query(default=None, description="Comma-separated store IDs. Omit to include every store."),
                    channel: str = Query(default="in_store", description="Comparison channel: in_store (shelf) or pickup."),
                    include_previous_contexts: bool = Query(default=False, description="Show previous contexts as excluded offers; only preferred contexts can win.")):
        if channel not in {"in_store", "pickup"}:
            raise HTTPException(422, "Unknown comparison channel")
        selected = {item.strip() for item in stores.split(",")} if stores is not None else {row[0] for row in STORES}
        if not selected or not selected.issubset({row[0] for row in STORES}):
            raise HTTPException(422, "Unknown or empty store ID")
        with database.connect() as connection:
            # Hold a read transaction so staple and observation reads share a snapshot.
            connection.execute("BEGIN")
            staple_rows = connection.execute("SELECT * FROM staples WHERE (? = 0 OR needed = 1) ORDER BY id", (needed_only,)).fetchall()
            rows = connection.execute("""
                SELECT ranked.*, stores.name AS store_name, contexts.location AS store_location,
                    contexts.location_id, contexts.location_status,
                    contexts.location_status != 'unconfigured' AS location_configured,
                    ranked.context_id = stores.preferred_context_id AS is_current_context FROM (
                    SELECT observations.*, mv.variant_id, COALESCE(m.status, 'pending') AS match_status, ROW_NUMBER() OVER (
                        PARTITION BY observations.staple_id, mv.variant_id, observations.context_id, observations.channel
                        ORDER BY observations.observed_at DESC, observations.id DESC
                    ) AS rank FROM observations
                    LEFT JOIN observation_variants mv ON mv.observation_id = observations.id
                    LEFT JOIN staple_matches m ON m.staple_id = observations.staple_id AND m.variant_id = mv.variant_id
                ) ranked JOIN stores ON stores.id = ranked.store_id
                JOIN location_contexts contexts ON contexts.id = ranked.context_id
                WHERE ranked.rank = 1 AND (? OR ranked.context_id = stores.preferred_context_id)
                ORDER BY ranked.id
            """, (include_previous_contexts,)).fetchall()
        grouped = {}
        for row in rows:
            if row["store_id"] in selected:
                record = as_record(row)
                record.pop("rank")
                grouped.setdefault(row["staple_id"], []).append(record)
        return [compare(as_record(staple), grouped.get(staple["id"], []), channel=channel) for staple in staple_rows]

    assets = Path(__file__).parent
    if (assets / "static").is_dir():
        app.mount("/static", StaticFiles(directory=assets / "static"), name="static")

    @app.get("/", include_in_schema=False)
    def index():
        index_path = assets / "templates" / "index.html"
        return FileResponse(index_path) if index_path.is_file() else RedirectResponse("/docs")

    return app


app = create_app()
