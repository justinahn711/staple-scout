"""Atomic v3 upgrades retain money, review and immutable provenance."""
import sqlite3
from unittest.mock import patch

import pytest
from staple_scout import database


def version_three(path):
    with patch.object(database, 'migrate_reports', lambda _: None), patch.object(database, 'migrate_source_ingestion', lambda _: None), patch.object(database, 'SCHEMA_VERSION', 3), patch.object(database, 'migrate_daily_refresh', lambda _: None):
        db = database.Database(path)
    with db.connect() as connection:
        connection.execute("INSERT INTO staples(name,basis,rules,needed,desired_quantity,desired_unit) VALUES('Rice','oz','plain',1,'32','oz')")
        connection.execute("INSERT INTO product_variants(retailer,retailer_product_id,barcode,package_quantity,package_unit,pack_count,form) VALUES('wegmans','rice','0001','16','oz',1,'bag')")
        connection.execute("INSERT INTO staple_matches(staple_id,variant_id,status,approved_at) VALUES(1,1,'approved','2026-10-07T10:00:00+00:00')")
        context_id = connection.execute("SELECT preferred_context_id FROM stores WHERE id='wegmans'").fetchone()[0]
        connection.execute("""INSERT INTO observations(staple_id,store_id,context_id,product_name,price,quantity,unit,pack_count,channel,observed_at,source_url,available,approved,conditions,quantity_kind)
            VALUES(1,'wegmans',?,'Rice','4.99','16','oz',1,'in_store','2026-10-07T12:00:00+00:00',NULL,1,1,'','fixed')""", (context_id,))
        connection.execute('INSERT INTO observation_variants VALUES(1,1)')
    return db


def dump(path):
    with sqlite3.connect(path) as connection:
        return tuple(connection.iterdump()), connection.execute('PRAGMA user_version').fetchone()[0]


def test_v3_upgrade_preserves_rows_reviews_and_is_idempotent(tmp_path):
    path = tmp_path / 'v3.sqlite3'
    db = version_three(path)
    with db.connect() as connection:
        original = {table: [dict(row) for row in connection.execute(f'SELECT * FROM {table}')] for table in ('staples','observations','product_variants','staple_matches','location_contexts')}
    upgraded = database.Database(path)
    with upgraded.connect() as connection:
        assert connection.execute('PRAGMA user_version').fetchone()[0] == database.SCHEMA_VERSION
        assert connection.execute('PRAGMA foreign_key_check').fetchall() == []
        assert connection.execute('SELECT count(*) FROM refresh_runs').fetchone()[0] == 0
        for table, rows in original.items():
            assert [dict(row) for row in connection.execute(f'SELECT * FROM {table}')] == rows
    before = dump(path)
    database.Database(path)
    assert dump(path) == before


def test_v3_upgrade_rolls_back_partial_ddl_and_retries(tmp_path):
    path = tmp_path / 'v3.sqlite3'
    version_three(path)
    before = dump(path)
    original = database.migrate_source_ingestion
    def fail(connection):
        original(connection)
        raise RuntimeError('simulated migration failure')
    with patch.object(database, 'migrate_source_ingestion', fail), pytest.raises(RuntimeError):
        database.Database(path)
    assert dump(path) == before
    database.Database(path)
    assert dump(path)[1] == database.SCHEMA_VERSION
