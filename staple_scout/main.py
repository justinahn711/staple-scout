"""Run locally: uv run uvicorn staple_scout.main:app --host 127.0.0.1."""

import os
import sqlite3
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import FastAPI, HTTPException, Query, Request, Response
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.trustedhost import TrustedHostMiddleware

from .comparison import compare
from .database import Database, STORES, as_record
from .models import ObservationCreate, StapleCreate, StaplePatch


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
            return [dict(row) for row in connection.execute("SELECT * FROM stores ORDER BY rowid")]

    @app.get("/api/staples")
    def staples():
        with database.connect() as connection:
            return [as_record(row) for row in connection.execute("SELECT * FROM staples ORDER BY id")]

    @app.post("/api/staples", status_code=201)
    def create_staple(body: StapleCreate):
        with database.connect() as connection:
            cursor = connection.execute("INSERT INTO staples(name, basis, rules, needed) VALUES (?, ?, ?, ?)", (body.name, body.basis, body.rules, body.needed))
            return as_record(connection.execute("SELECT * FROM staples WHERE id = ?", (cursor.lastrowid,)).fetchone())

    @app.patch("/api/staples/{staple_id}", description="Changing name, basis, or rules clears approval on existing observations; price history is retained. Needed-only and no-op changes preserve approval.")
    def update_staple(staple_id: int, body: StaplePatch):
        with database.connect() as connection:
            existing = connection.execute("SELECT * FROM staples WHERE id = ?", (staple_id,)).fetchone()
            if existing is None:
                raise HTTPException(404, "Staple not found")
            changes = body.model_dump(exclude_unset=True)
            if changes:
                if any(key in changes and changes[key] != existing[key] for key in ("name", "basis", "rules")):
                    connection.execute("UPDATE observations SET approved = 0 WHERE staple_id = ?", (staple_id,))
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
            if connection.execute("SELECT id FROM staples WHERE id = ?", (body.staple_id,)).fetchone() is None:
                raise HTTPException(404, "Staple not found")
            placeholders = ", ".join("?" for _ in values)
            try:
                cursor = connection.execute(f"INSERT INTO observations ({', '.join(values)}) VALUES ({placeholders})", tuple(values.values()))
            except sqlite3.IntegrityError:
                raise HTTPException(422, "Invalid observation reference") from None
            return as_record(connection.execute("SELECT * FROM observations WHERE id = ?", (cursor.lastrowid,)).fetchone())

    @app.get("/api/comparisons")
    def comparisons(needed_only: bool = False, stores: str | None = Query(default=None, description="Comma-separated store IDs. Omit to include every store.")):
        selected = {item.strip() for item in stores.split(",")} if stores is not None else {row[0] for row in STORES}
        if not selected or not selected.issubset({row[0] for row in STORES}):
            raise HTTPException(422, "Unknown or empty store ID")
        with database.connect() as connection:
            # Hold a read transaction so staple and observation reads share a snapshot.
            connection.execute("BEGIN")
            staple_rows = connection.execute("SELECT * FROM staples WHERE (? = 0 OR needed = 1) ORDER BY id", (needed_only,)).fetchall()
            rows = connection.execute("""
                SELECT ranked.*, stores.name AS store_name, stores.location AS store_location FROM (
                    SELECT observations.*, ROW_NUMBER() OVER (
                        PARTITION BY staple_id, store_id, product_name, channel, quantity, unit, pack_count
                        ORDER BY observed_at DESC, id DESC
                    ) AS rank FROM observations
                ) ranked JOIN stores ON stores.id = ranked.store_id
                WHERE ranked.rank = 1 ORDER BY ranked.id
            """).fetchall()
        grouped = {}
        for row in rows:
            if row["store_id"] in selected:
                record = as_record(row)
                record.pop("rank")
                grouped.setdefault(row["staple_id"], []).append(record)
        return [compare(as_record(staple), grouped.get(staple["id"], [])) for staple in staple_rows]

    assets = Path(__file__).parent
    if (assets / "static").is_dir():
        app.mount("/static", StaticFiles(directory=assets / "static"), name="static")

    @app.get("/", include_in_schema=False)
    def index():
        index_path = assets / "templates" / "index.html"
        return FileResponse(index_path) if index_path.is_file() else RedirectResponse("/docs")

    return app


app = create_app()
