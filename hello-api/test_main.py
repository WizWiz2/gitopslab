from main import app, VERSION
from fastapi.testclient import TestClient

client = TestClient(app)


def test_root():
    assert client.get("/").json() == {"message": "Hello from IDP demo"}


def test_healthz():
    assert client.get("/healthz").json() == {"status": "ok"}


def test_version():
    body = client.get("/version").json()
    assert body["version"] == VERSION
    assert "model_sha" in body


def test_predict_setosa():
    resp = client.post("/predict", json={"features": [5.1, 3.5, 1.4, 0.2]})
    assert resp.status_code == 200
    body = resp.json()
    assert body["class_id"] == 0
    assert body["class_name"].lower().startswith("setosa")
