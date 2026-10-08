from datetime import datetime, timedelta, timezone
import json
import threading

import pytest

from staple_scout import scheduler
from staple_scout.database import Database


def setup_db(tmp_path):
    db = Database(tmp_path / "scheduler.sqlite3")
    with db.connect() as cx:
        cx.execute("INSERT INTO staples(name,basis,rules,needed) VALUES('Rice','oz','',1)")
    return db, tmp_path / "refresh.lock"


def config(source="fixture", context=1, channel="in_store"):
    return {"sources": [{"source_id": source, "context_id": context, "channel": channel,
        "requests": [{"staple_id": 1, "retailer_product_id": "sku"}]}]}


class Fake:
    validated = True
    channels = {"in_store"}
    timeout = 2


def test_same_day_claims_once_and_next_day_runs_again(tmp_path, monkeypatch):
    db, lock = setup_db(tmp_path); calls = []
    monkeypatch.setattr(scheduler, "run_adapter", lambda *args: calls.append(args) or {"id": len(calls), "status": "succeeded"})
    registry = {"fixture": Fake()}; day = datetime(2026, 10, 8, 12, tzinfo=timezone.utc)
    assert scheduler.run_schedule(db, registry, config(), lock_path=lock, now=lambda: day).status == "succeeded"
    assert scheduler.run_schedule(db, registry, config(), lock_path=lock, now=lambda: day + timedelta(hours=2)).error == "already_claimed"
    assert scheduler.run_schedule(db, registry, config(), lock_path=lock, now=lambda: day + timedelta(days=1)).status == "succeeded"
    assert len(calls) == 2


def test_flock_overlap_returns_busy(tmp_path, monkeypatch):
    db, lock = setup_db(tmp_path); entered = threading.Event(); release = threading.Event()
    def fake(*args):
        entered.set(); release.wait(2); return {"status": "succeeded"}
    monkeypatch.setattr(scheduler, "run_adapter", fake)
    result = []; day = datetime(2026, 10, 8, 12, tzinfo=timezone.utc)
    worker = threading.Thread(target=lambda: result.append(scheduler.run_schedule(db, {"fixture": Fake()}, config(), lock_path=lock, now=lambda: day)))
    worker.start(); assert entered.wait(1)
    busy = scheduler.run_schedule(db, {"fixture": Fake()}, config(), lock_path=lock, now=lambda: day)
    release.set(); worker.join(2)
    assert busy.status == "busy" and busy.error == "already_running" and result[0].status == "succeeded"


def test_retry_timeout_uses_backoff_and_then_succeeds(tmp_path, monkeypatch):
    db, lock = setup_db(tmp_path); attempts = []; sleeps = []
    def fake(*args):
        attempts.append(1)
        return {"status":"failed", "error":"source_timeout"} if len(attempts) < 3 else {"status":"succeeded", "id":3}
    monkeypatch.setattr(scheduler, "run_adapter", fake)
    out = scheduler.run_schedule(db, {"fixture": Fake()}, config(), lock_path=lock, now=lambda: datetime.now(timezone.utc), sleep=sleeps.append)
    assert out.status == "succeeded" and len(attempts) == 3 and sleeps == [.25, .5]


def test_retry_exhaustion_isolated_from_next_source(tmp_path, monkeypatch):
    db, lock = setup_db(tmp_path); calls = []
    class R(Fake): pass
    def fake(_db, source, *args):
        calls.append(source)
        return {"status":"failed", "error":"source_timeout"} if source is registry["bad"] else {"status":"succeeded", "id":9}
    registry = {"bad": R(), "good": R()}; monkeypatch.setattr(scheduler, "run_adapter", fake)
    cfg = {"sources": [config("bad")["sources"][0], config("good")["sources"][0]]}
    out = scheduler.run_schedule(db, registry, cfg, lock_path=lock, now=lambda: datetime.now(timezone.utc), sleep=lambda _: None)
    assert out.status == "partial" and len(calls) == 4


def test_naive_clock_and_invalid_config_are_rejected_before_claim(tmp_path):
    db, lock = setup_db(tmp_path)
    with pytest.raises(ValueError): scheduler.run_schedule(db, {"fixture": Fake()}, config(), lock_path=lock, now=lambda: datetime(2026,1,1))
    with pytest.raises(ValueError): scheduler.ScheduleConfig.model_validate({"sources": []})
    with pytest.raises(ValueError): scheduler.ScheduleConfig.model_validate({"sources": [{"source_id":"x","context_id":1,"channel":"in_store","requests":[]} ]})


def test_unvalidated_source_is_skipped_and_status_tracks_attempts(tmp_path):
    db, lock = setup_db(tmp_path); source = Fake(); source.validated = False
    out = scheduler.run_schedule(db, {"fixture": source}, config(), lock_path=lock, now=lambda: datetime.now(timezone.utc))
    assert out.status == "failed" and out.results[0]["status"] == "skipped"


def test_dry_run_validates_without_database_or_network(tmp_path, monkeypatch, capsys):
    path = tmp_path / "config.json"; path.write_text(json.dumps(config()))
    monkeypatch.setattr(scheduler, "default_sources", lambda: {})
    assert scheduler.main(["--db", str(tmp_path/"dry.sqlite3"), "--config", str(path), "--dry-run"]) == 0
    assert json.loads(capsys.readouterr().out)["status"] == "dry_run"
