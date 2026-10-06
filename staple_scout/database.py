"""SQLite persistence; observations are append-only until a staple is deleted."""

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


class Database:
    def __init__(self, path: str | Path):
        self.path = str(path)
        if self.path == ":memory:":
            raise ValueError("Use a temporary file for an isolated database; :memory: cannot persist across request connections")
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as connection:
            connection.executescript("""
                CREATE TABLE IF NOT EXISTS stores (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, location TEXT NOT NULL,
                    channel TEXT NOT NULL, source_status TEXT NOT NULL, note TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS staples (
                    id INTEGER PRIMARY KEY, name TEXT NOT NULL, basis TEXT NOT NULL,
                    rules TEXT NOT NULL, needed INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS observations (
                    id INTEGER PRIMARY KEY, staple_id INTEGER NOT NULL REFERENCES staples(id) ON DELETE CASCADE,
                    store_id TEXT NOT NULL REFERENCES stores(id), product_name TEXT NOT NULL,
                    price TEXT NOT NULL, quantity TEXT NOT NULL, unit TEXT NOT NULL, pack_count INTEGER NOT NULL,
                    channel TEXT NOT NULL, observed_at TEXT NOT NULL, source_url TEXT,
                    available INTEGER NOT NULL, approved INTEGER NOT NULL, conditions TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS observation_latest
                ON observations(staple_id, store_id, product_name, channel, observed_at DESC, id DESC);
            """)
            connection.executemany("INSERT OR IGNORE INTO stores VALUES (?, ?, ?, ?, ?, ?)", STORES)

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
    for key in ("needed", "approved", "available"):
        if key in result:
            result[key] = bool(result[key])
    return result
