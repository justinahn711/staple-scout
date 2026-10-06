"""SQLite persistence with atomic, versioned upgrades and immutable contexts."""

import sqlite3
from contextlib import contextmanager
from pathlib import Path

STORES = [
    ("wegmans", "Wegmans", "Chantilly #133", "in_store", "not_connected", "Location is user-reported. Prices require manual observation."),
    ("walmart", "Walmart", "Chantilly #5969 (tentative)", "in_store", "not_connected", "Confirm the store location before adding a price."),
    ("target", "Target", "Chantilly", "in_store", "not_connected", "Prices require manual observation."),
    ("hmart", "H Mart", "Centreville", "in_store", "not_connected", "Prices require manual observation."),
    ("lidl", "Lidl", "Unselected", "in_store", "not_connected", "Choose and record the local store before comparing prices."),
]
SCHEMA_VERSION = 1  # Version 0 is the original unversioned schema.

LEGACY_SCHEMA = (
    """CREATE TABLE stores (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, location TEXT NOT NULL,
        channel TEXT NOT NULL, source_status TEXT NOT NULL, note TEXT NOT NULL
    )""",
    """CREATE TABLE staples (
        id INTEGER PRIMARY KEY, name TEXT NOT NULL, basis TEXT NOT NULL,
        rules TEXT NOT NULL, needed INTEGER NOT NULL
    )""",
    """CREATE TABLE observations (
        id INTEGER PRIMARY KEY, staple_id INTEGER NOT NULL REFERENCES staples(id) ON DELETE CASCADE,
        store_id TEXT NOT NULL REFERENCES stores(id), product_name TEXT NOT NULL,
        price TEXT NOT NULL, quantity TEXT NOT NULL, unit TEXT NOT NULL, pack_count INTEGER NOT NULL,
        channel TEXT NOT NULL, observed_at TEXT NOT NULL, source_url TEXT,
        available INTEGER NOT NULL, approved INTEGER NOT NULL, conditions TEXT NOT NULL
    )""",
)


def migrate_location_contexts(connection):
    connection.execute("""CREATE TABLE location_contexts (
        id INTEGER PRIMARY KEY, store_id TEXT NOT NULL REFERENCES stores(id),
        location TEXT NOT NULL CHECK(length(trim(location)) > 0),
        location_id TEXT, channel TEXT NOT NULL CHECK(channel IN ('in_store', 'pickup', 'online')),
        location_status TEXT NOT NULL CHECK(location_status IN ('user_reported', 'tentative', 'unconfigured')),
        UNIQUE(id, store_id)
    )""")
    connection.execute("""CREATE UNIQUE INDEX location_context_identity ON location_contexts
        (store_id, location, coalesce(location_id, ''), channel, location_status)""")
    connection.execute("ALTER TABLE stores ADD COLUMN preferred_context_id INTEGER REFERENCES location_contexts(id)")
    for store in connection.execute("SELECT * FROM stores").fetchall():
        status = "unconfigured" if store["location"].strip().lower() == "unselected" else "user_reported"
        if "tentative" in store["location"].lower():
            status = "tentative"
        # Only retain known seeded IDs when the exact original label is present.
        location_id = {("wegmans", "Chantilly #133"): "133",
                       ("walmart", "Chantilly #5969 (tentative)"): "5969"}.get((store["id"], store["location"]))
        cursor = connection.execute("""INSERT INTO location_contexts
            (store_id, location, location_id, channel, location_status) VALUES (?, ?, ?, ?, ?)""",
            (store["id"], store["location"], location_id, store["channel"], status))
        connection.execute("UPDATE stores SET preferred_context_id = ? WHERE id = ?", (cursor.lastrowid, store["id"]))
    connection.execute("""CREATE TABLE observations_v1 (
        id INTEGER PRIMARY KEY, staple_id INTEGER NOT NULL REFERENCES staples(id) ON DELETE CASCADE,
        store_id TEXT NOT NULL REFERENCES stores(id), context_id INTEGER NOT NULL,
        product_name TEXT NOT NULL, price TEXT NOT NULL, quantity TEXT NOT NULL,
        unit TEXT NOT NULL, pack_count INTEGER NOT NULL, channel TEXT NOT NULL,
        observed_at TEXT NOT NULL, source_url TEXT, available INTEGER NOT NULL,
        approved INTEGER NOT NULL, conditions TEXT NOT NULL,
        FOREIGN KEY(context_id, store_id) REFERENCES location_contexts(id, store_id)
    )""")
    connection.execute("""INSERT INTO observations_v1
        SELECT o.id, o.staple_id, o.store_id, s.preferred_context_id, o.product_name,
               o.price, o.quantity, o.unit, o.pack_count, o.channel, o.observed_at,
               o.source_url, o.available, o.approved, o.conditions
        FROM observations o LEFT JOIN stores s ON s.id = o.store_id""")
    connection.execute("DROP TABLE observations")
    connection.execute("ALTER TABLE observations_v1 RENAME TO observations")
    connection.execute("""CREATE INDEX observation_latest ON observations
        (staple_id, context_id, product_name, channel, observed_at DESC, id DESC)""")
    for action in ("UPDATE", "DELETE"):
        connection.execute(f"""CREATE TRIGGER context_no_{action.lower()} BEFORE {action} ON location_contexts
            BEGIN SELECT RAISE(ABORT, 'Location contexts are immutable'); END""")
    connection.execute("""CREATE TRIGGER observation_context_immutable
        BEFORE UPDATE OF context_id, store_id ON observations
        WHEN NEW.context_id != OLD.context_id OR NEW.store_id != OLD.store_id
        BEGIN SELECT RAISE(ABORT, 'Observation context is immutable'); END""")
    for action in ("INSERT", "UPDATE"):
        connection.execute(f"""CREATE TRIGGER preferred_context_{action.lower()} BEFORE {action} ON stores
            WHEN NOT EXISTS (SELECT 1 FROM location_contexts c
                WHERE c.id = NEW.preferred_context_id AND c.store_id = NEW.id)
            BEGIN SELECT RAISE(ABORT, 'Preferred context must belong to this store'); END""")


class Database:
    def __init__(self, path: str | Path):
        self.path = str(path)
        if self.path == ":memory:":
            raise ValueError("Use a temporary file for an isolated database; :memory: cannot persist across request connections")
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as connection:
            # Explicit BEGIN is essential: sqlite3 otherwise autocommits DDL before
            # the first DML statement. Never use executescript inside this migration.
            connection.execute("BEGIN IMMEDIATE")
            version = connection.execute("PRAGMA user_version").fetchone()[0]
            if version > SCHEMA_VERSION:
                raise RuntimeError(f"Unsupported database schema version {version}")
            if version == 0:
                tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
                if not tables:
                    for statement in LEGACY_SCHEMA:
                        connection.execute(statement)
                    connection.executemany("INSERT INTO stores VALUES (?, ?, ?, ?, ?, ?)", STORES)
                elif not {"stores", "staples", "observations"}.issubset(tables):
                    raise RuntimeError("Incomplete original database schema")
                migrate_location_contexts(connection)
                if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
                    raise RuntimeError("Database migration failed foreign key validation")
                connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")

    @contextmanager
    def connect(self):
        connection = sqlite3.connect(self.path, timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        try:
            with connection:
                yield connection
        finally:
            connection.close()


def as_record(row):
    result = dict(row)
    for key in ("needed", "approved", "available", "location_configured", "is_current_context"):
        if key in result:
            result[key] = bool(result[key])
    return result


STORE_SELECT = """SELECT s.id, s.name, c.location, c.channel, s.source_status, s.note,
    s.preferred_context_id, c.location_id, c.location_status,
    c.location_status != 'unconfigured' AS location_configured
    FROM stores s JOIN location_contexts c ON c.id = s.preferred_context_id"""
