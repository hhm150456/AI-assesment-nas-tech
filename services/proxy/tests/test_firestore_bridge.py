import os
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import httpx
from fastapi import FastAPI

import firestore_bridge


class FirestoreBridgeTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        app = FastAPI()
        app.include_router(firestore_bridge.router)
        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
        )

    async def asyncTearDown(self) -> None:
        await self.client.aclose()

    async def test_save_turn_uses_session_languages_when_dify_sends_empty_values(
        self,
    ) -> None:
        ref = object()
        session = {"langA": "English", "langB": "French"}
        transaction = object()
        with (
            patch.dict(os.environ, {"BRIDGE_KEY": "test-key"}),
            patch.object(
                firestore_bridge, "_get_session", return_value=(ref, session)
            ),
            patch.object(
                firestore_bridge,
                "_firestore",
                return_value=SimpleNamespace(transaction=Mock(return_value=transaction)),
            ),
            patch.object(
                firestore_bridge, "_add_turn_transaction", return_value=1
            ) as save_turn,
        ):
            response = await self.client.post(
                "/sessions/test-session/turns",
                headers={"X-API-Key": "test-key"},
                json={
                    "speaker": "A",
                    "source_lang": "",
                    "target_lang": "",
                    "source_text": "Hello",
                    "translated_text": "Bonjour",
                    "latency_ms": 0,
                },
            )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"seq": 1})
        saved_data = save_turn.call_args.args[2]
        self.assertEqual(saved_data["sourceLang"], "English")
        self.assertEqual(saved_data["targetLang"], "French")

    async def test_save_turn_uses_reverse_session_languages_for_speaker_b(self) -> None:
        ref = object()
        session = {"langA": "English", "langB": "French"}
        transaction = object()
        with (
            patch.dict(os.environ, {"BRIDGE_KEY": "test-key"}),
            patch.object(
                firestore_bridge, "_get_session", return_value=(ref, session)
            ),
            patch.object(
                firestore_bridge,
                "_firestore",
                return_value=SimpleNamespace(transaction=Mock(return_value=transaction)),
            ),
            patch.object(
                firestore_bridge, "_add_turn_transaction", return_value=2
            ) as save_turn,
        ):
            response = await self.client.post(
                "/sessions/test-session/turns",
                headers={"X-API-Key": "test-key"},
                json={
                    "speaker": "B",
                    "source_lang": "not-used",
                    "target_lang": "not-used",
                    "source_text": "Bonjour",
                    "translated_text": "Hello",
                },
            )

        self.assertEqual(response.status_code, 200)
        saved_data = save_turn.call_args.args[2]
        self.assertEqual(saved_data["sourceLang"], "French")
        self.assertEqual(saved_data["targetLang"], "English")

    async def test_save_summary_closes_session_when_requested(self) -> None:
        ref = Mock()
        with (
            patch.dict(os.environ, {"BRIDGE_KEY": "test-key"}),
            patch.object(
                firestore_bridge, "_get_session", return_value=(ref, {"status": "active"})
            ),
        ):
            response = await self.client.post(
                "/sessions/test-session/summary",
                headers={"X-API-Key": "test-key"},
                json={
                    "text_a": "Summary A",
                    "text_b": "Summary B",
                    "close_after": "yes",
                },
            )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"ok": True})
        updates = ref.update.call_args.args[0]
        self.assertEqual(updates["summary"]["textA"], "Summary A")
        self.assertEqual(updates["summary"]["textB"], "Summary B")
        self.assertEqual(updates["status"], "closed")
        self.assertIn("closedAt", updates)

    async def test_save_summary_does_not_close_by_default(self) -> None:
        ref = Mock()
        with (
            patch.dict(os.environ, {"BRIDGE_KEY": "test-key"}),
            patch.object(
                firestore_bridge, "_get_session", return_value=(ref, {"status": "active"})
            ),
        ):
            response = await self.client.post(
                "/sessions/test-session/summary",
                headers={"X-API-Key": "test-key"},
                json={"text_a": "Summary A", "text_b": "Summary B"},
            )

        self.assertEqual(response.status_code, 200)
        updates = ref.update.call_args.args[0]
        self.assertNotIn("status", updates)
        self.assertNotIn("closedAt", updates)
