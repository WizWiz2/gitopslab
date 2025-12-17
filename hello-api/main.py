from fastapi import FastAPI
import os

app = FastAPI(title="IDP Demo Hello API")

VERSION = os.getenv("VERSION", "dev")


@app.get("/")
def read_root():
    return {"message": "Hello from IDP demo"}


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/version")
def version():
    return {"version": VERSION}
