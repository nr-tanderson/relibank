import asyncio
import time

from fastapi import FastAPI
from pydantic import BaseModel, Field


app = FastAPI(title="Internal synthetic gateway - never charges money")
slow_until = 0.0


class FailureWindow(BaseModel):
    seconds: int = Field(default=600, ge=0, le=900)


@app.get("/healthz")
async def health():
    return {"status": "ok"}


@app.post("/failure-window")
async def failure_window(window: FailureWindow):
    global slow_until
    slow_until = time.monotonic() + window.seconds
    return {"duration_seconds": window.seconds, "synthetic": True}


@app.post("/authorize")
async def authorize():
    await asyncio.sleep(0.3 if time.monotonic() < slow_until else 0.01)
    return {"status": "authorized", "synthetic": True, "amount": 10, "currency": "USD"}