import asyncio
import json
import unittest

import httpx

from bill_pay.payment_lab import submit_lab_payment


class PaymentContract(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.delay = 0.01
        self.status = 200
        self.server = await asyncio.start_server(self.respond, "127.0.0.1", 0)
        self.gateway_url = f"http://127.0.0.1:{self.server.sockets[0].getsockname()[1]}"

    async def asyncTearDown(self):
        self.server.close()
        await self.server.wait_closed()

    async def respond(self, reader, writer):
        try:
            await reader.readuntil(b"\r\n\r\n")
            await asyncio.sleep(self.delay)
            body = json.dumps({"status": "authorized", "synthetic": True}).encode()
            writer.write(
                f"HTTP/1.1 {self.status} Response\r\nContent-Length: {len(body)}\r\n"
                "Content-Type: application/json\r\nConnection: close\r\n\r\n".encode()
                + body
            )
            await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

    async def test_fast_gateway_succeeds(self):
        result = await submit_lab_payment(self.gateway_url)
        self.assertEqual(result["status"], "authorized")

    async def test_faulty_budget_times_out(self):
        self.delay = 0.3
        with self.assertRaises(httpx.ReadTimeout):
            await submit_lab_payment(self.gateway_url, timeout_seconds=0.1)

    async def test_sufficient_budget_succeeds(self):
        self.delay = 0.3
        result = await submit_lab_payment(self.gateway_url, timeout_seconds=1.0)
        self.assertTrue(result["synthetic"])

    async def test_unavailable_gateway_does_not_succeed(self):
        self.server.close()
        await self.server.wait_closed()
        with self.assertRaises(httpx.ConnectError):
            await submit_lab_payment(self.gateway_url, timeout_seconds=1.0)

    async def test_upstream_error_does_not_succeed(self):
        self.status = 503
        with self.assertRaises(httpx.HTTPStatusError):
            await submit_lab_payment(self.gateway_url, timeout_seconds=1.0)


class FixExercise(PaymentContract):
    async def test_slow_valid_gateway_succeeds_with_default_budget(self):
        self.delay = 0.3
        result = await submit_lab_payment(self.gateway_url)
        self.assertEqual(result["status"], "authorized")