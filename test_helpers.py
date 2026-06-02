"""Shared test fixtures loaded from conf/test_fixtures.json."""
import json
from pathlib import Path

_FIXTURES_DIR = Path(__file__).parent / "conf"

def load_fixtures():
    """Load test fixtures from conf/test_fixtures.json.
    Falls back to conf/test_fixtures.json.example if real file missing."""
    real = _FIXTURES_DIR / "test_fixtures.json"
    example = _FIXTURES_DIR / "test_fixtures.json.example"
    path = real if real.exists() else example
    with open(path) as f:
        return json.load(f)

# Lazy-loaded module-level accessors
_data = None

def _get():
    global _data
    if _data is None:
        _data = load_fixtures()
    return _data

def get_boards():
    return _get()["boards"]

def get_servers():
    return _get()["servers"]

def get_paths():
    return _get()["paths"]

def get_ssh():
    return _get()["ssh"]

def get_pdu():
    return _get()["pdu"]
