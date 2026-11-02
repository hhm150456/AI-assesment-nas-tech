import base64
import unittest
from unittest.mock import AsyncMock, patch

import httpx
from fastapi import FastAPI

import proxy
from proxy import configure_proxy_app


class ConversationTurnApiTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        app = FastAPI()
        configure_proxy_app(app)
        app.include_router(proxy.router)
        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
        )

    async def asyncTearDown(self) -> None:
        await self.client.aclose()

    async def test_normalizes_dify_start_output_without_status(self) -> None:
        outputs = {
            "session_id": "LqB6zhnmtf18Fn7fX7Hx",
            "lang_a": "English",
            "lang_b": "Arabic",
        }
        with (
            patch.object(proxy, "_dify_base_url", return_value="https://dify.test/v1"),
            patch.object(
                proxy, "_run_workflow", new=AsyncMock(return_value=outputs)
            ) as run,
        ):
            response = await self.client.post(
                "/api/conversation/start",
                headers={"X-Device-Id": "a" * 32},
                json={"lang_a": "Arabic", "lang_b": "Catalan"},
            )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(),
            {
                "status": "started",
                "session_id": "LqB6zhnmtf18Fn7fX7Hx",
                "lang_a": "English",
                "lang_b": "Arabic",
            },
        )
        self.assertEqual(
            run.await_args.kwargs["inputs"],
            {
                "action": "start",
                "session_id": "",
                "speaker": "A",
                "lang_a": "Arabic",
                "lang_b": "Catalan",
                "audio": None,
                "close_after": "no",
            },
        )

    async def test_reports_validation_stage_for_invalid_dify_session_id(self) -> None:
        with (
            patch.object(proxy, "_dify_base_url", return_value="https://dify.test/v1"),
            patch.object(
                proxy,
                "_run_workflow",
                new=AsyncMock(
                    return_value={
                        "session_id": "short",
                        "lang_a": "English",
                        "lang_b": "Arabic",
                    }
                ),
            ),
        ):
            response = await self.client.post(
                "/api/conversation/start",
                headers={"X-Device-Id": "a" * 32},
                json={"lang_a": "English", "lang_b": "Arabic"},
            )

        self.assertEqual(response.status_code, 502)
        self.assertEqual(response.json()["stage"], "validate_session_id")

    async def test_reports_dify_http_status_without_exposing_response_body(self) -> None:
        request = httpx.Request("POST", "https://dify.test/v1/workflows/run")
        upstream_response = httpx.Response(
            401,
            request=request,
            json={
                "code": "invalid_api_token",
                "message": "The API token is invalid.",
                "detail": "sensitive upstream response",
            },
        )
        error = httpx.HTTPStatusError(
            "Unauthorized",
            request=request,
            response=upstream_response,
        )
        with (
            patch.object(proxy, "_dify_base_url", return_value="https://dify.test/v1"),
            patch.object(proxy, "_run_workflow", new=AsyncMock(side_effect=error)),
        ):
            response = await self.client.post(
                "/api/conversation/start",
                headers={"X-Device-Id": "a" * 32},
                json={"lang_a": "English", "lang_b": "Arabic"},
            )

        self.assertEqual(response.status_code, 502)
        self.assertEqual(
            response.json(),
            {
                "status_code": 502,
                "error": "upstream_error",
                "message": "The translation service is temporarily unavailable. Please try again.",
                "status": "error",
                "stage": "run_dify_workflow",
                "failure": "upstream_http_error",
                "upstream_status": 401,
                "upstream_code": "invalid_api_token",
                "upstream_message": "The API token is invalid.",
            },
        )
        self.assertNotIn("sensitive upstream response", response.text)

    async def test_normalizes_dify_turn_output_for_flutter(self) -> None:
        audio_bytes = b"\x01\x02\x03"
        outputs = {
            "status": 200,
            "audio": [
                {
                    "extension": ".mp3",
                    "filename": "translation.mp3",
                    "mime_type": "audio/mpeg",
                    "transfer_method": "tool_file",
                    "type": "audio",
                    "url": (
                        "https://upload.dify.ai/files/tools/audio.mp3"
                        "?timestamp=123&nonce=abc&sign=signature"
                    ),
                }
            ],
            "translation": "这是一个英语录音。",
            "transcript": "This is a recording in English.",
            "speaker": "A",
            "source_lang": "English",
            "target_lang": "Chinese",
            "seq": 0,
        }
        with (
            patch.object(proxy, "_dify_base_url", return_value="https://dify.test/v1"),
            patch.object(proxy, "_api_key", return_value="conversation-secret"),
            patch.object(
                proxy, "_upload_to_dify", new=AsyncMock(return_value="upload-id")
            ),
            patch.object(
                proxy, "_run_workflow", new=AsyncMock(return_value=outputs)
            ) as run,
            patch.object(
                proxy,
                "_download_audio",
                new=AsyncMock(return_value=(audio_bytes, "audio/mpeg")),
            ) as download,
        ):
            response = await self.client.post(
                "/api/conversation/turn",
                headers={"X-Device-Id": "a" * 32},
                data={
                    "session_id": "session12345",
                    "speaker": "A",
                    "lang_a": "English",
                    "lang_b": "Arabic",
                },
                files={"audio": ("input.mp3", b"a" * 1024, "audio/mpeg")},
            )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(),
            {
                "status": "success",
                "translation": "这是一个英语录音。",
                "transcript": "This is a recording in English.",
                "speaker": "A",
                "source_lang": "English",
                "target_lang": "Chinese",
                "seq": 0,
                "audio_base64": base64.b64encode(audio_bytes).decode("ascii"),
                "audio_mime": "audio/mpeg",
            },
        )
        self.assertEqual(
            run.await_args.kwargs["inputs"],
            {
                "action": "turn",
                "session_id": "session12345",
                "speaker": "A",
                "lang_a": "English",
                "lang_b": "Arabic",
                "audio": {
                    "type": "audio",
                    "transfer_method": "local_file",
                    "upload_file_id": "upload-id",
                },
                "close_after": "no",
            },
        )
        self.assertEqual(download.await_args.args[0], outputs)

    async def test_normalizes_dify_summary_output_for_flutter(self) -> None:
        outputs = {
            "status_code": 200,
            "summary_a": (
                "Participant A stated that the recording is in English. "
                "Participant B confirmed this in Chinese. No further details "
                "or decisions were made during the conversation."
            ),
            "summary_b": (
                "参与者A表示录音是英语。参与者B用中文确认了这一点。"
                "对话中没有进一步的细节或决定。"
            ),
        }
        with (
            patch.object(proxy, "_dify_base_url", return_value="https://dify.test/v1"),
            patch.object(proxy, "_api_key", return_value="conversation-secret"),
            patch.object(
                proxy,
                "_upload_to_dify",
                new=AsyncMock(return_value="summary-upload-id"),
            ) as upload,
            patch.object(
                proxy, "_run_workflow", new=AsyncMock(return_value=outputs)
            ) as run,
        ):
            response = await self.client.post(
                "/api/conversation/summary",
                headers={"X-Device-Id": "a" * 32},
                data={
                    "action": "summary",
                    "session_id": "session12345",
                    "speaker": "A",
                    "lang_a": "English",
                    "lang_b": "Arabic",
                    "close_after": "no",
                },
                files={"audio": ("voice.mp3", b"a" * 1024, "audio/mpeg")},
            )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(),
            {
                "status": "success",
                "summary_a": outputs["summary_a"],
                "summary_b": outputs["summary_b"],
                "lang_a": "English",
                "lang_b": "Arabic",
                "closed": "no",
            },
        )
        self.assertEqual(
            upload.await_args.kwargs["file_name"],
            "voice.mp3",
        )
        self.assertEqual(
            run.await_args.kwargs["inputs"],
            {
                "action": "summary",
                "session_id": "session12345",
                "speaker": "A",
                "lang_a": "English",
                "lang_b": "Arabic",
                "audio": {
                    "type": "audio",
                    "transfer_method": "local_file",
                    "upload_file_id": "summary-upload-id",
                },
                "close_after": "no",
            },
        )
