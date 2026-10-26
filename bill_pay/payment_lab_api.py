import os

import httpx
import newrelic.agent
from fastapi import FastAPI, HTTPException

from bill_pay.payment_lab import submit_lab_payment


app = FastAPI(title="ReliBank synthetic payment lab")


@app.get("/healthz")
async def health():
    return {"status": "ok", "synthetic": True}


@app.post("/lab/payments")
async def payment():
    newrelic.agent.add_custom_attribute("lab.synthetic", True)
    newrelic.agent.add_custom_attribute("lab.generation", os.environ["LAB_GENERATION"])
    newrelic.agent.add_custom_attribute("deployment.commit", os.environ["IMAGE_COMMIT"])
    try:
        return await submit_lab_payment(os.environ["PAYMENT_GATEWAY_URL"])
    except httpx.TimeoutException:
        newrelic.agent.notice_error()
        raise HTTPException(status_code=504, detail="Synthetic payment gateway timed out")
    except httpx.RequestError:
        newrelic.agent.notice_error()
        raise HTTPException(status_code=503, detail="Synthetic payment gateway unavailable")
    except httpx.HTTPStatusError:
        newrelic.agent.notice_error()
        raise HTTPException(status_code=502, detail="Synthetic payment gateway rejected request")