from main import app, VERSION
from fastapi.testclient import TestClient

client = TestClient(app)


def test_root():
    assert client.get("/").json() == {"message": "Hello from IDP demo"}


def test_healthz():
    assert client.get("/healthz").json() == {"status": "ok"}


def test_version():
    assert client.get("/version").json() == {"version": VERSION}
