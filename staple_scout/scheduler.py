"""Explicit daily runner. Importing this module never fetches or installs a job."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import sqlite3
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Callable
from uuid import uuid4

from pydantic import Field, model_validator

from .adapters import ProductRequest, TextID
from .database import Database
from .ingestion import run_adapter
from .models import Channel, StrictModel
from .registry import default_sources


class ScheduledSource(StrictModel):
    source_id: TextID
    context_id: int = Field(gt=0, strict=True)
    channel: Channel
    requests: list[ProductRequest] = Field(min_length=1, max_length=50)


class ScheduleConfig(StrictModel):
    sources: list[ScheduledSource] = Field(min_length=1, max_length=5)

    @model_validator(mode='after')
    def bounded_unique_sources(self):
        if sum(len(source.requests) for source in self.sources) > 50:
            raise ValueError('At most fifty explicit product requests per daily run')
        identities = [(s.source_id, s.context_id, s.channel) for s in self.sources]
        if len(set(identities)) != len(identities):
            raise ValueError('Combine duplicate source/context/channel entries')
        return self


@dataclass
class RefreshSummary:
    status: str
    results: list[dict]
    error: str | None = None


class DailyClaim:
    """Retained flock inode; process exit releases it without unsafe stale deletion."""
    def __init__(self, path: str | Path):
        self.path, self._file = Path(path), None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._file = self.path.open('a+')
        try:
            fcntl.flock(self._file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self._file.close()
            self._file = None
            raise RuntimeError('refresh already running') from None
        return self

    def __exit__(self, *_):
        if self._file:
            fcntl.flock(self._file.fileno(), fcntl.LOCK_UN)
            self._file.close()
            self._file = None


def utc_now(clock):
    stamp = clock()
    if stamp.tzinfo is None or stamp.utcoffset() is None:
        raise ValueError('Runner clock requires an aware timestamp')
    return stamp.astimezone(timezone.utc)


def run_schedule(database, registry, config, *, lock_path=None,
                 now: Callable[[], datetime] | None = None,
                 sleep: Callable[[float], None] = time.sleep) -> RefreshSummary:
    """One claimed UTC day, at most three transient attempts per source.

    Manual invocation and launchd share the same daily cache. Changing config
    after a claimed day does not trigger extra fetches. A crashed claim remains
    visible and claimed for that day; tomorrow can run after flock releases.
    """
    config = ScheduleConfig.model_validate(config)
    clock = now or (lambda: datetime.now(timezone.utc))
    stamp = utc_now(clock)
    day = stamp.date().isoformat()
    claim_id = uuid4().hex
    lock_path = lock_path or str(Path(database.path).resolve()) + '.refresh.lock'
    try:
        claim = DailyClaim(lock_path)
        claim.__enter__()
    except RuntimeError:
        return RefreshSummary('busy', [], 'already_running')
    try:
        with database.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            try:
                db.execute('''INSERT INTO scheduler_runs(day,started_at,status,claim_id)
                    VALUES(?,?,'running',?)''', (day, stamp.isoformat(), claim_id))
            except sqlite3.IntegrityError:
                row = db.execute('SELECT status FROM scheduler_runs WHERE day=?', (day,)).fetchone()
                if row is None:
                    raise
                return RefreshSummary(row['status'] if isinstance(row, sqlite3.Row) else row[0], [], 'already_claimed')
        results = []
        for entry in config.sources:
            source = registry.get(entry.source_id)
            if source is None or not source.validated:
                results.append({'source_id': entry.source_id, 'status': 'skipped', 'error': 'source_not_validated'})
                continue
            # Include canonical requests in the short key. The durable day claim
            # remains the primary cache, including changed configs or failed days.
            digest = hashlib.sha256(entry.model_dump_json().encode()).hexdigest()[:24]
            outcome = None
            for attempt in range(3):
                key = f'scheduled:{day}:{digest}:{attempt}'
                try:
                    outcome = run_adapter(database, source, entry.context_id, entry.channel, entry.requests, key)
                except ValueError:
                    outcome = {'status': 'failed', 'error': 'invalid_configuration'}
                except Exception:
                    outcome = {'status': 'failed', 'error': 'runner_error'}
                if (outcome['status'] != 'failed' or outcome.get('error') not in
                        {'source_timeout', 'source_network_error', 'source_http_retryable'} or attempt == 2):
                    break
                sleep(.25 * 2 ** attempt)
            results.append({'source_id': entry.source_id, 'context_id': entry.context_id,
                            'channel': entry.channel, 'run_id': outcome.get('id'),
                            'status': outcome['status'], 'error': outcome.get('error')})
        statuses = [result['status'] for result in results]
        if all(status == 'succeeded' for status in statuses):
            final = 'succeeded'
        elif all(status in {'failed', 'skipped'} for status in statuses):
            final = 'failed'
        else:
            final = 'partial'
        with database.connect() as db:
            db.execute('''UPDATE scheduler_runs SET finished_at=?,status=?,error=?
                WHERE day=? AND claim_id=?''', (utc_now(clock).isoformat(), final,
                None if final == 'succeeded' else 'one_or_more_sources_incomplete', day, claim_id))
        return RefreshSummary(final, results)
    finally:
        claim.__exit__(None, None, None)


def source_status(database, source_id, *, context_id=None, channel=None):
    """Last attempt/success/failure separately; partial-with-no-evidence isn't success."""
    with database.connect() as db:
        rows = db.execute('''SELECT run.id,run.context_id,run.channel,run.started_at,run.finished_at,
            run.status,run.error,EXISTS(SELECT 1 FROM refresh_results result WHERE result.run_id=run.id
                AND result.status IN ('accepted','unavailable')) AS has_evidence
            FROM refresh_runs run WHERE run.source_id=? AND (? IS NULL OR run.context_id=?)
                AND (? IS NULL OR run.channel=?) ORDER BY run.id DESC''',
            (source_id, context_id, context_id, channel, channel)).fetchall()
    def record(row):
        if row is None:
            return None
        value = dict(row)
        value.pop('has_evidence')
        return value
    return {'source_id': source_id,
            'last_attempt': record(rows[0]) if rows else None,
            'last_success': record(next((row for row in rows if row['status'] in {'succeeded','partial'} and row['has_evidence']), None)),
            'last_failure': record(next((row for row in rows if row['status'] == 'failed'), None))}


def main(argv=None):
    parser = argparse.ArgumentParser(description='Explicit daily grocery refresh; never installs or activates launchd')
    parser.add_argument('--db', required=True, help='Explicit SQLite path')
    parser.add_argument('--config', help='JSON with explicit sources/context/channel/product requests')
    parser.add_argument('--status', action='store_true', help='Show source attempt/success/failure without fetching')
    parser.add_argument('--dry-run', action='store_true', help='Validate configuration without fetching or claiming a day')
    args = parser.parse_args(argv)
    if not args.status and not args.config:
        parser.error('--config is required for a refresh or dry run')
    registry = default_sources()
    database = Database(args.db)
    if args.status:
        print(json.dumps([source_status(database, source_id) for source_id in registry]))
        return 0
    try:
        config = ScheduleConfig.model_validate_json(Path(args.config).read_text())
    except Exception:
        print(json.dumps({'status': 'failed', 'error': 'invalid_configuration'}))
        return 2
    if args.dry_run:
        print(json.dumps({'status': 'dry_run', 'sources': len(config.sources),
                          'requests': sum(len(source.requests) for source in config.sources)}))
        return 0
    outcome = run_schedule(database, registry, config)
    # Never print product evidence, response bodies, config payloads or exceptions.
    print(json.dumps(asdict(outcome)))
    return 0 if outcome.status == 'succeeded' or outcome.error == 'already_claimed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
