"""Shared setup for the client tests. No Bluetooth stack and no card are needed."""
import importlib
import importlib.util
import os
import sys
import types

import pytest

CLIENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(CLIENT_DIR)
FIXTURES_DIR = os.path.join(REPO_ROOT, "app", "ReviveKit", "Tests", "CardProtocolTests", "Fixtures")
MAKE_FIXTURES = os.path.join(REPO_ROOT, "app", "ReviveKit", "scripts", "make_fixtures.py")

if CLIENT_DIR not in sys.path:
    sys.path.insert(0, CLIENT_DIR)


@pytest.fixture(scope="session")
def fixture_bytes():
    """Read a committed fixture file from app/ReviveKit/Tests/CardProtocolTests/Fixtures."""
    def read(name):
        with open(os.path.join(FIXTURES_DIR, name), "rb") as f:
            return f.read()
    return read


@pytest.fixture(scope="session")
def make_fixtures():
    """The fixture generator script, loaded as a module (importing it writes nothing)."""
    spec = importlib.util.spec_from_file_location("make_fixtures", MAKE_FIXTURES)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def dnote(monkeypatch):
    """Import dnote.py with a stub `bleak`, so the pure helpers can be tested anywhere.

    dnote.py exits at import time when bleak is missing; the tests below never touch BLE.
    """
    stub = types.ModuleType("bleak")
    stub.BleakScanner = type("BleakScanner", (), {})
    stub.BleakClient = type("BleakClient", (), {})
    monkeypatch.setitem(sys.modules, "bleak", stub)
    monkeypatch.delitem(sys.modules, "dnote", raising=False)
    module = importlib.import_module("dnote")
    yield module
    sys.modules.pop("dnote", None)
