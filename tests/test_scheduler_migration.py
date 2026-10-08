import sqlite3
from unittest.mock import patch

import pytest
from staple_scout import database


def snapshot(path):
    with sqlite3.connect(path) as connection:
        return tuple(connection.iterdump()), connection.execute('PRAGMA user_version').fetchone()[0]


def make_v4(path):
    with patch.object(database, 'migrate_reports', lambda _: None), patch.object(database, 'SCHEMA_VERSION', 4), patch.object(database, 'migrate_daily_refresh', lambda _: None):
        db = database.Database(path)
    with db.connect() as connection:
        connection.execute("INSERT INTO refresh_runs(source_id,retailer,context_id,channel,idempotency_key,fingerprint,started_at,status,error) VALUES('fixture','wegmans',1,'in_store','before','fingerprint','2026-10-07T00:00:00+00:00','failed','source_timeout')")
    return db


def test_daily_schema_preserves_existing_run_and_upgrades_once(tmp_path):
    path=tmp_path/'v4.sqlite3'
    db=make_v4(path)
    with db.connect() as connection:
        original=dict(connection.execute('SELECT * FROM refresh_runs').fetchone())
    upgraded=database.Database(path)
    with upgraded.connect() as connection:
        assert dict(connection.execute('SELECT * FROM refresh_runs').fetchone()) == original
        assert connection.execute('SELECT * FROM scheduler_runs').fetchall() == []
        assert connection.execute('PRAGMA user_version').fetchone()[0] == database.SCHEMA_VERSION
        assert connection.execute('PRAGMA foreign_key_check').fetchall() == []
    before=snapshot(path)
    database.Database(path)
    assert snapshot(path) == before


def test_failed_daily_upgrade_rolls_back_and_retries(tmp_path):
    path=tmp_path/'v4.sqlite3'
    make_v4(path)
    before=snapshot(path)
    original=database.migrate_daily_refresh
    def fail(connection):
        original(connection)
        raise RuntimeError('simulated failure')
    with patch.object(database,'migrate_daily_refresh',fail), pytest.raises(RuntimeError):
        database.Database(path)
    assert snapshot(path) == before
    database.Database(path)
    assert snapshot(path)[1] == database.SCHEMA_VERSION
