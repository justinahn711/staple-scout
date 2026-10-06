"""Keep module-level application initialization away from real user data."""

import os
from pathlib import Path
from tempfile import TemporaryDirectory

_module_database = TemporaryDirectory(prefix="staple-scout-tests-")
os.environ["STAPLE_SCOUT_DB"] = str(Path(_module_database.name) / "module.sqlite3")
