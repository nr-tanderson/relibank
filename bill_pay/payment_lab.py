import httpx


PAYMENT_TIMEOUT_SECONDS = 0.1


async def submit_lab_payment(gateway_url, timeout_seconds=None):
    timeout = PAYMENT_TIMEOUT_SECONDS if timeout_seconds is None else timeout_seconds
    async with httpx.AsyncClient(timeout=timeout, trust_env=False) as client:
        response = await client.post(
            f"{gateway_url}/authorize", json={"amount": 10, "currency": "USD"}
        )
        response.raise_for_status()
        return response.json()