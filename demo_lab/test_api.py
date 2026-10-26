import os
import unittest
from unittest.mock import AsyncMock, patch

import httpx

from bill_pay.payment_lab_api import app


class PaymentAPI(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.environment = patch.dict(os.environ, {
            "LAB_GENERATION": "test-generation",
            "IMAGE_COMMIT": "test-commit",
            "PAYMENT_GATEWAY_URL": "http://internal-gateway:8080",
        })
        self.environment.start()
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")

    async def asyncTearDown(self):
        await self.client.aclose()
        self.environment.stop()

    async def test_timeout_is_recorded_and_returns_504(self):
        with patch("bill_pay.payment_lab_api.submit_lab_payment", new=AsyncMock(side_effect=httpx.ReadTimeout("slow gateway"))), patch("bill_pay.payment_lab_api.newrelic.agent.notice_error") as notice:
            response = await self.client.post("/lab/payments")
        self.assertEqual(response.status_code, 504)
        notice.assert_called_once()

    async def test_connection_failure_is_recorded_and_returns_503(self):
        with patch("bill_pay.payment_lab_api.submit_lab_payment", new=AsyncMock(side_effect=httpx.ConnectError("gateway down"))), patch("bill_pay.payment_lab_api.newrelic.agent.notice_error") as notice:
            response = await self.client.post("/lab/payments")
        self.assertEqual(response.status_code, 503)
        notice.assert_called_once()

    async def test_success_is_synthetic(self):
        with patch("bill_pay.payment_lab_api.submit_lab_payment", new=AsyncMock(return_value={"status": "authorized", "synthetic": True})):
            response = await self.client.post("/lab/payments")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["synthetic"])