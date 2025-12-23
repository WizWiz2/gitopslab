import os
from typing import List

import joblib
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="IDP Demo Hello API")

VERSION = os.getenv("VERSION", "dev")
MODEL_PATH = os.getenv("MODEL_PATH", "model/model.joblib")
MODEL_SHA = os.getenv("MODEL_SHA", "dev")


class PredictRequest(BaseModel):
    features: List[float]


def load_model():
    try:
        bundle = joblib.load(MODEL_PATH)
        model = bundle.get("model")
        target_names = bundle.get("target_names") or ["class_0", "class_1", "class_2"]
        if model is None:
            raise ValueError("model not found in bundle")
        return model, target_names
    except FileNotFoundError:
        return None, None
    except Exception as exc:
        # fallback to no-model mode
        print(f"[warn] failed to load model {MODEL_PATH}: {exc}")
        return None, None


MODEL, TARGET_NAMES = load_model()


@app.get("/")
def read_root():
    return {"message": "Hello from IDP demo"}


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/version")
def version():
    return {"version": VERSION, "model_sha": MODEL_SHA}


@app.post("/predict")
def predict(req: PredictRequest):
    if MODEL is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
    if len(req.features) != 4:
        raise HTTPException(status_code=400, detail="features must contain 4 values")
    preds = MODEL.predict([req.features])
    idx = int(preds[0])
    label = TARGET_NAMES[idx] if TARGET_NAMES and idx < len(TARGET_NAMES) else str(idx)
    return {"class_id": idx, "class_name": label}
