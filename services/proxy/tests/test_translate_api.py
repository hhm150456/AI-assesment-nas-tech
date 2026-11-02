import json
import unittest
from email.parser import BytesParser
from email.policy import default
from unittest.mock import AsyncMock, patch

import httpx
from fastapi import FastAPI

import proxy
import translate_api
from proxy import configure_proxy_app


class TranslateApiTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        app = FastAPI()
        configure_proxy_app(app)
        app.include_router(translate_api.router)
        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
        )

    async def asyncTearDown(self) -> None:
        await self.client.aclose()

    async def _send_translation(self) -> httpx.Response:
        return await self.client.post(
            "/api/translate",
            headers={"X-Device-Id": "a" * 32},
            data={"target_language": "French"},
            files={"audio": ("input.mp3", b"a" * 1024, "audio/mpeg")},
        )

    async def test_returns_metadata_and_audio_file_as_multipart(self) -> None:
        outputs = {
            "status_code": 200,
            "translation": "Bonjour",
            "transcript": "Hello there",
            "source_language": "English",
            "target_language": "French",
            "audio": [{"url": "https://dify.test/files/output.mp3"}],
        }
        with (
            patch.object(translate_api, "_dify_base_url", return_value="https://dify.test/v1"),
            patch.object(translate_api, "_api_key", return_value="server-secret"),
            patch.object(
                translate_api, "_upload_to_dify", new=AsyncMock(return_value="file-id")
            ) as upload,
            patch.object(
                translate_api, "_run_workflow", new=AsyncMock(return_value=outputs)
            ) as run,
            patch.object(
                translate_api,
                "_download_audio",
                new=AsyncMock(return_value=(b"\x01\x02\x03", "audio/mpeg")),
            ),
            self.assertLogs("translate_api", level="INFO") as logs,
        ):
            response = await self._send_translation()

        self.assertEqual(response.status_code, 200)
        self.assertIn("X-Request-ID", response.headers)
        self.assertTrue(response.headers["content-type"].startswith("multipart/mixed;"))
        message = BytesParser(policy=default).parsebytes(
            b"Content-Type: "
            + response.headers["content-type"].encode("ascii")
            + b"\r\nMIME-Version: 1.0\r\n\r\n"
            + response.content
        )
        metadata_part, audio_part = list(message.iter_parts())
        metadata = json.loads(metadata_part.get_payload(decode=True))
        self.assertEqual(metadata["status_code"], 200)
        self.assertEqual(metadata["translation"], "Bonjour")
        self.assertEqual(metadata["transcript"], "Hello there")
        self.assertEqual(metadata["source_language"], "English")
        self.assertEqual(metadata["target_language"], "French")
        self.assertEqual(audio_part.get_payload(decode=True), b"\x01\x02\x03")
        self.assertEqual(audio_part.get_content_type(), "audio/mpeg")
        run.assert_awaited_once()
        self.assertEqual(
            run.await_args.kwargs["inputs"]["target_language"],
            "French",
        )
        upload.assert_awaited_once()
        logged_text = "\n".join(logs.output)
        self.assertNotIn("Hello there", logged_text)
        self.assertNotIn("Bonjour", logged_text)
        self.assertNotIn("a" * 32, logged_text)
        self.assertNotIn("server-secret", logged_text)

    async def test_accepts_numeric_dify_status_without_status_code(self) -> None:
        outputs = {
            "status": 200,
            "translation": "Bonjour",
            "transcript": "Hello there",
            "source_language": "English",
            "target_language": "French",
            "audio": [{"url": "https://dify.test/files/output.mp3"}],
        }
        with (
            patch.object(translate_api, "_dify_base_url", return_value="https://dify.test/v1"),
            patch.object(translate_api, "_api_key", return_value="server-secret"),
            patch.object(
                translate_api, "_upload_to_dify", new=AsyncMock(return_value="file-id")
            ),
            patch.object(
                translate_api, "_run_workflow", new=AsyncMock(return_value=outputs)
            ),
            patch.object(
                translate_api,
                "_download_audio",
                new=AsyncMock(return_value=(b"\x01\x02\x03", "audio/mpeg")),
            ),
        ):
            response = await self._send_translation()

        self.assertEqual(response.status_code, 200)

    async def test_rejects_audio_urls_outside_trusted_dify_origins(self) -> None:
        with self.assertRaisesRegex(ValueError, "unsupported audio location"):
            await proxy._download_audio(
                {"audio": [{"url": "https://attacker.example/audio.mp3"}]},
                api_base="https://api.dify.ai/v1",
                api_key="server-secret",
            )

    async def test_downloads_signed_dify_tool_audio_without_api_key(self) -> None:
        class FakeResponse:
            content = b"\x01\x02\x03"
            headers = {"content-type": "audio/mpeg"}

            def raise_for_status(self) -> None:
                return None

        class FakeClient:
            def __init__(self) -> None:
                self.request: tuple[str, dict[str, str]] | None = None

            async def __aenter__(self) -> "FakeClient":
                return self

            async def __aexit__(self, *args: object) -> None:
                return None

            async def get(
                self, url: str, *, headers: dict[str, str], timeout: httpx.Timeout
            ) -> FakeResponse:
                self.request = (url, headers)
                return FakeResponse()

        client = FakeClient()
        signed_url = (
            "https://upload.dify.ai/files/tools/audio.mp3"
            "?timestamp=123&nonce=abc&sign=signature"
        )
        with patch.object(proxy.httpx, "AsyncClient", return_value=client):
            audio, mime = await proxy._download_audio(
                {"audio": [{"url": signed_url}]},
                api_base="https://api.dify.ai/v1",
                api_key="must-not-leak",
            )

        self.assertEqual(audio, b"\x01\x02\x03")
        self.assertEqual(mime, "audio/mpeg")
        self.assertIsNotNone(client.request)
        self.assertEqual(client.request[0], signed_url)
        self.assertEqual(client.request[1], {})

    async def test_returns_standard_json_error_on_workflow_failure(self) -> None:
        with (
            patch.object(translate_api, "_dify_base_url", return_value="https://dify.test/v1"),
            patch.object(translate_api, "_api_key", return_value="server-secret"),
            patch.object(
                translate_api, "_upload_to_dify", new=AsyncMock(return_value="file-id")
            ),
            patch.object(
                translate_api,
                "_run_workflow",
                new=AsyncMock(return_value={"status": "error", "message": "internal details"}),
            ),
        ):
            response = await self._send_translation()

        self.assertEqual(response.status_code, 502)
        self.assertEqual(
            set(response.json()),
            {"status_code", "error", "message"},
        )
        self.assertEqual(response.json()["status_code"], 502)
        self.assertEqual(response.json()["error"], "translation_failed")
        self.assertNotIn("internal details", response.text)

    async def test_returns_json_error_for_invalid_device_id(self) -> None:
        response = await self.client.post(
            "/api/translate",
            headers={"X-Device-Id": "invalid"},
            data={"target_language": "French"},
            files={"audio": ("input.mp3", b"a" * 1024, "audio/mpeg")},
        )

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["status_code"], 400)
        self.assertIsInstance(response.json()["error"], str)
        self.assertIsInstance(response.json()["message"], str)


if __name__ == "__main__":
    unittest.main()
