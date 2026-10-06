from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import sqlite3

from fastapi.testclient import TestClient
import pytest

from staple_scout import database
from staple_scout.main import create_app


@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(tmp_path / "contexts.sqlite3"), base_url="http://localhost") as client:
        yield client


def add_staple(client):
    response = client.post("/api/staples", json={"name": "Oats", "basis": "oz"})
    assert response.status_code == 201
    return response.json()["id"]


def add_observation(client, staple_id, **fields):
    response = client.post("/api/observations", json={
        "staple_id": staple_id, "store_id": "wegmans", "product_name": "Oats",
        "price": "4.00", "quantity": "16", "unit": "oz", "channel": "in_store",
        "observed_at": (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat(),
        "approved": True, **fields,
    })
    assert response.status_code == 201, response.text
    return response.json()


def select_other(client, store="wegmans"):
    response = client.patch(f"/api/stores/{store}", json={
        "context": {"location": "Another local store", "location_id": "local-2"}
    })
    assert response.status_code == 200, response.text
    return response.json()


def test_switch_and_back_switch_keep_history_and_context_identity(client):
    original_store = client.get("/api/stores/wegmans").json()
    item = add_staple(client)
    original = add_observation(client, item)
    assert original["context_id"] == original_store["preferred_context_id"]
    other = select_other(client)
    assert other["preferred_context_id"] != original["context_id"]
    assert client.get("/api/comparisons").json()[0]["offers"] == []
    old_offer = client.get("/api/comparisons?include_previous_contexts=true").json()[0]["offers"][0]
    assert old_offer["store_location"] == original_store["location"]
    assert old_offer["exclusion_reasons"] == ["location_not_current"]
    latest = add_observation(client, item, price="10")
    assert latest["context_id"] == other["preferred_context_id"]
    assert client.get("/api/comparisons").json()[0]["winner_id"] == latest["id"]
    # Same original product/package is independently ranked in each context.
    all_contexts = client.get("/api/comparisons?include_previous_contexts=true").json()[0]
    assert {o["id"] for o in all_contexts["offers"]} == {original["id"], latest["id"]}
    assert all_contexts["winner_id"] == latest["id"]
    assert select_other(client)["preferred_context_id"] == other["preferred_context_id"]
    back = client.patch("/api/stores/wegmans", json={"context_id": original["context_id"]})
    assert back.status_code == 200
    assert back.json()["location"] == original_store["location"]
    assert client.get("/api/comparisons").json()[0]["winner_id"] == original["id"]
    contexts = client.get("/api/stores/wegmans/contexts").json()
    assert len(contexts) == 2
    assert [c["id"] for c in contexts if c["is_current_context"]] == [original["context_id"]]
    history = client.get(f"/api/observations?store_id=wegmans&context_id={original['context_id']}&staple_id={item}").json()
    assert len(history) == 1 and history[0]["store_location"] == original_store["location"]
    assert history[0]["price"] == "4.00" and history[0]["approved"]


def test_stale_client_context_never_moves_observation_to_new_preference(client):
    context_id = client.get("/api/stores/wegmans").json()["preferred_context_id"]
    item = add_staple(client)
    select_other(client)
    delayed = add_observation(client, item, context_id=context_id)
    assert delayed["context_id"] == context_id
    result = client.get("/api/comparisons?include_previous_contexts=true").json()[0]
    assert result["winner_id"] is None
    assert result["offers"][0]["exclusion_reasons"] == ["location_not_current"]
    assert client.get("/api/comparisons").json()[0]["offers"] == []


def test_unconfigured_history_never_becomes_configured_price(client):
    item = add_staple(client)
    old = add_observation(client, item, store_id="lidl")
    other = select_other(client, "lidl")
    assert other["location_configured"] is True
    assert other["source_status"] == "not_connected"
    result = client.get("/api/comparisons?include_previous_contexts=true").json()[0]
    assert result["winner_id"] is None
    assert result["offers"][0]["store_location"] == "Unselected"
    assert result["offers"][0]["exclusion_reasons"] == ["location_not_current", "location_not_configured"]
    assert client.patch("/api/stores/lidl", json={"context_id": old["context_id"]}).status_code == 200
    assert client.get("/api/comparisons").json()[0]["offers"][0]["exclusion_reasons"] == ["location_not_configured"]


@pytest.mark.parametrize("change_rules", [False, True])
def test_switch_back_does_not_revive_stale_or_invalidated_approvals(client, change_rules):
    item = add_staple(client)
    fields = {} if change_rules else {"observed_at": (datetime.now(timezone.utc) - timedelta(hours=49)).isoformat()}
    old = add_observation(client, item, **fields)
    select_other(client)
    if change_rules:
        assert client.patch(f"/api/staples/{item}", json={"rules": "Organic only"}).status_code == 200
    assert client.patch("/api/stores/wegmans", json={"context_id": old["context_id"]}).status_code == 200
    result = client.get("/api/comparisons").json()[0]
    assert result["winner_id"] is None
    assert result["offers"][0]["exclusion_reasons"] == ["not_approved" if change_rules else "stale"]
    assert result["offers"][0]["price"] == old["price"]


@pytest.mark.parametrize("body", [
    {"context": {"location": "  "}}, {"context": {"location": "A", "location_id": ""}},
    {"context": {"location": "A", "location_id": "   "}},
    {"context": {"location": "A", "location_id": "a/b"}},
    {"context": {"location": "A", "location_id": "a b"}},
    {"context": {"location": "A", "location_id": 123}},
    {"context": {"location": "A", "location_id": "x" * 101}},
    {"context": {"location": "A", "channel": "shipping"}},
    {"context": {"location": "A", "location_status": "verified"}},
    {"context": {"location": "A", "location_status": "unconfigured"}},
    {"context": {"location": "Unselected"}},
    {"context": {"location": "Unselected", "location_status": "unconfigured", "location_id": "1"}},
    {"context": None}, {"context_id": None}, {"context_id": 0}, {"context_id": True},
    {"context_id": "1"}, {"context_id": 9999}, {"note": None},
    {"context_id": 1, "context": {"location": "A"}},
    {"source_status": "verified"}, {"name": "Another retailer"},
])
def test_invalid_configuration_is_rejected_without_mutation(client, body):
    before = client.get("/api/stores/wegmans").json()
    contexts = client.get("/api/stores/wegmans/contexts").json()
    assert client.patch("/api/stores/wegmans", json=body).status_code == 422
    assert client.get("/api/stores/wegmans").json() == before
    assert client.get("/api/stores/wegmans/contexts").json() == contexts


def test_store_ownership_unknown_ids_and_write_protection(client):
    foreign_id = client.get("/api/stores/walmart").json()["preferred_context_id"]
    assert client.patch("/api/stores/wegmans", json={"context_id": foreign_id}).status_code == 422
    item = add_staple(client)
    for context_id in (None, foreign_id, 9999, 0, True, "1"):
        response = client.post("/api/observations", json={
            "staple_id": item, "store_id": "wegmans", "context_id": context_id,
            "product_name": "Oats", "price": "4", "quantity": "16", "unit": "oz",
            "channel": "in_store", "observed_at": "2020-01-01T00:00:00Z",
        })
        assert response.status_code == 422
    assert client.get("/api/observations").json() == []
    for url in ("/api/stores/unknown", "/api/stores/unknown/contexts"):
        assert client.get(url).status_code == 404
    assert client.patch("/api/stores/unknown", json={}).status_code == 404
    assert client.get("/api/observations?store_id=unknown").status_code == 422
    assert client.get("/api/observations?context_id=0").status_code == 422
    assert client.patch("/api/stores/wegmans", json={}, headers={"origin": "https://evil.example"}).status_code == 403
    assert client.patch("/api/stores/wegmans", content="{}").status_code == 415


def test_configuration_defaults_provenance_and_notes_do_not_verify_prices(client):
    stores = {s["id"]: s for s in client.get("/api/stores").json()}
    assert stores["walmart"]["location_status"] == "tentative"
    assert stores["walmart"]["location_id"] == "5969"
    assert stores["wegmans"]["location_status"] == "user_reported"
    assert stores["wegmans"]["location_id"] == "133"
    assert stores["lidl"]["location_id"] is None and not stores["lidl"]["location_configured"]
    before = stores["wegmans"]
    for body in ({}, {"note": "User configuration; no connected price source"}):
        result = client.patch("/api/stores/wegmans", json=body).json()
        assert result["preferred_context_id"] == before["preferred_context_id"]
        assert result["source_status"] == "not_connected"
    # Channel is a preference; manually reported evidence retains its own channel.
    result = client.patch("/api/stores/wegmans", json={"context": {
        "location": " New store ", "location_id": " T-12 ", "channel": "pickup"}}).json()
    assert result["location"] == "New store" and result["location_id"] == "T-12"
    item = add_staple(client)
    shelf = add_observation(client, item)
    pickup = add_observation(client, item, channel="pickup")
    comparison = client.get("/api/comparisons").json()[0]
    assert comparison["winner_id"] == shelf["id"]
    assert next(o for o in comparison["offers"] if o["id"] == pickup["id"])["exclusion_reasons"] == ["not_in_store"]


# Deliberately independent original-schema fixture: do not derive it from the
# migration's schema constants, so changed migration code cannot mask data loss.
@pytest.fixture
def legacy_path(tmp_path):
    path = tmp_path / "legacy.sqlite3"
    with sqlite3.connect(path) as connection:
        connection.executescript("""
            CREATE TABLE stores (id TEXT PRIMARY KEY, name TEXT NOT NULL, location TEXT NOT NULL,
                channel TEXT NOT NULL, source_status TEXT NOT NULL, note TEXT NOT NULL);
            CREATE TABLE staples (id INTEGER PRIMARY KEY, name TEXT NOT NULL, basis TEXT NOT NULL,
                rules TEXT NOT NULL, needed INTEGER NOT NULL);
            CREATE TABLE observations (id INTEGER PRIMARY KEY,
                staple_id INTEGER NOT NULL REFERENCES staples(id) ON DELETE CASCADE,
                store_id TEXT NOT NULL REFERENCES stores(id), product_name TEXT NOT NULL,
                price TEXT NOT NULL, quantity TEXT NOT NULL, unit TEXT NOT NULL, pack_count INTEGER NOT NULL,
                channel TEXT NOT NULL, observed_at TEXT NOT NULL, source_url TEXT,
                available INTEGER NOT NULL, approved INTEGER NOT NULL, conditions TEXT NOT NULL);
            CREATE INDEX observation_latest ON observations
                (staple_id, store_id, product_name, channel, observed_at DESC, id DESC);
            INSERT INTO stores VALUES ('wegmans', 'Wegmans', 'Chantilly #133', 'in_store', 'not_connected', 'User-reported');
            INSERT INTO stores VALUES ('walmart', 'Walmart', 'Chantilly #5969 (tentative)', 'in_store', 'not_connected', 'Tentative');
            INSERT INTO stores VALUES ('lidl', 'Lidl', 'Unselected', 'in_store', 'not_connected', 'Unselected');
            INSERT INTO staples VALUES (7, 'Oats', 'oz', 'Plain', 1);
        """)
        now = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
        connection.executemany("INSERT INTO observations VALUES (?, 7, ?, 'Oats', ?, '16', 'oz', 2, ?, ?, ?, ?, ?, ?)", [
            (11, "wegmans", "5.00", "in_store", now, "https://example.com/oats", 1, 1, ""),
            (12, "wegmans", "2.00", "pickup", now, None, 1, 0, "Membership"),
            (13, "lidl", "1.00", "in_store", now, None, 1, 1, ""),
            (14, "walmart", "3.00", "online", now, None, 0, 1, ""),
        ])
    return path


def snapshot(path):
    with sqlite3.connect(path) as connection:
        return tuple(connection.iterdump()), connection.execute("PRAGMA user_version").fetchone()[0]


def test_original_database_migrates_preserving_data_and_reopens_idempotently(legacy_path):
    with sqlite3.connect(legacy_path) as connection:
        columns = [r[1] for r in connection.execute("PRAGMA table_info(observations)")]
        originals = connection.execute("SELECT * FROM observations ORDER BY id").fetchall()
    db = database.Database(legacy_path)
    with db.connect() as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0] == database.SCHEMA_VERSION
        assert [tuple(r) for r in connection.execute(f"SELECT {', '.join(columns)} FROM observations ORDER BY id")] == originals
        assert connection.execute("PRAGMA foreign_key_check").fetchall() == []
        assert connection.execute("SELECT count(*) FROM location_contexts").fetchone()[0] == 3
        assert connection.execute("SELECT count(*) FROM observations WHERE context_id IS NULL").fetchone()[0] == 0
    migrated = snapshot(legacy_path)
    database.Database(legacy_path)
    assert snapshot(legacy_path) == migrated
    with TestClient(create_app(legacy_path), base_url="http://localhost") as client:
        result = client.get("/api/comparisons").json()[0]
        assert result["winner_id"] == 11
        assert next(o for o in result["offers"] if o["id"] == 13)["exclusion_reasons"] == ["location_not_configured"]
        assert next(o for o in result["offers"] if o["id"] == 14)["channel"] == "online"
        select_other(client)
        assert client.get("/api/observations?store_id=wegmans").json()[0]["store_location"] == "Chantilly #133"


def test_failed_migration_rolls_back_ddl_data_and_version_then_can_retry(legacy_path, monkeypatch):
    before = snapshot(legacy_path)
    migrate = database.migrate_location_contexts

    def fail_after_rebuild(connection):
        migrate(connection)
        raise RuntimeError("Injected failure after table rebuild")

    with monkeypatch.context() as patch:
        patch.setattr(database, "migrate_location_contexts", fail_after_rebuild)
        with pytest.raises(RuntimeError, match="Injected failure"):
            database.Database(legacy_path)
    assert snapshot(legacy_path) == before
    database.Database(legacy_path)
    assert snapshot(legacy_path)[1] == database.SCHEMA_VERSION


@pytest.mark.parametrize("column,value", [("store_id", "missing-store"), ("staple_id", 999)])
def test_invalid_legacy_reference_rolls_back_instead_of_losing_rows(legacy_path, column, value):
    with sqlite3.connect(legacy_path) as connection:
        connection.execute(f"UPDATE observations SET {column} = ? WHERE id = 11", (value,))
    before = snapshot(legacy_path)
    with pytest.raises(sqlite3.IntegrityError):
        database.Database(legacy_path)
    assert snapshot(legacy_path) == before


def test_concurrent_initializers_apply_migration_once(legacy_path):
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda _: database.Database(legacy_path), range(4)))
    with sqlite3.connect(legacy_path) as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0] == database.SCHEMA_VERSION
        assert connection.execute("SELECT count(*) FROM observations").fetchone()[0] == 4
        assert connection.execute("SELECT count(*) FROM location_contexts").fetchone()[0] == 3
        assert connection.execute("PRAGMA foreign_key_check").fetchall() == []


def test_future_schema_version_refused_without_changes(legacy_path):
    with sqlite3.connect(legacy_path) as connection:
        connection.execute("PRAGMA user_version = 999")
    before = snapshot(legacy_path)
    with pytest.raises(RuntimeError, match="Unsupported database schema"):
        database.Database(legacy_path)
    assert snapshot(legacy_path) == before


def test_database_enforces_immutable_context_and_store_ownership(legacy_path):
    db = database.Database(legacy_path)
    for statement in (
        "UPDATE location_contexts SET location = 'Changed' WHERE id = 1",
        "DELETE FROM location_contexts WHERE id = 1",
        "UPDATE observations SET context_id = 2 WHERE id = 11",
        "UPDATE stores SET preferred_context_id = 2 WHERE id = 'wegmans'",
        "UPDATE stores SET preferred_context_id = NULL WHERE id = 'wegmans'",
        "INSERT INTO observations SELECT 99, staple_id, store_id, 2, product_name, price, quantity, unit, pack_count, channel, observed_at, source_url, available, approved, conditions FROM observations WHERE id = 11",
    ):
        with pytest.raises(sqlite3.IntegrityError), db.connect() as connection:
            connection.execute(statement)
