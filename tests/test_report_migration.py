import sqlite3
from unittest.mock import patch
import pytest
from staple_scout import database


def snapshot(path):
    with sqlite3.connect(path) as db:
        return tuple(db.iterdump()), db.execute('PRAGMA user_version').fetchone()[0]


def v5(path):
    with patch.object(database,'SCHEMA_VERSION',5), patch.object(database,'migrate_reports',lambda _:None):
        db=database.Database(path)
    with db.connect() as cx:
        cx.execute("INSERT INTO staples(name,basis,rules,needed) VALUES('Rice','oz','plain',1)")
    return db


def test_report_upgrade_preserves_data_and_snapshot_immutable(tmp_path):
    path=tmp_path/'upgrade.sqlite3'; v5(path)
    db=database.Database(path)
    with db.connect() as cx:
        assert cx.execute('PRAGMA user_version').fetchone()[0] == 6
        assert cx.execute('SELECT name FROM staples').fetchone()[0] == 'Rice'
        cx.execute("INSERT INTO reports VALUES('saved','{}','{}')")
    for sql in ["UPDATE reports SET payload_json='changed'", 'DELETE FROM reports']:
        with pytest.raises(sqlite3.IntegrityError), db.connect() as cx:
            cx.execute(sql)
    before=snapshot(path); database.Database(path)
    assert snapshot(path)==before


def test_report_upgrade_rollback_then_retry(tmp_path):
    path=tmp_path/'rollback.sqlite3'; v5(path); before=snapshot(path)
    original=database.migrate_reports
    def fail(cx):
        original(cx)
        raise RuntimeError('fixture failure')
    with patch.object(database,'migrate_reports',fail),pytest.raises(RuntimeError):
        database.Database(path)
    assert snapshot(path)==before
    database.Database(path)
    assert snapshot(path)[1] == 6
