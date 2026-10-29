import asyncio
import base64
import ipaddress
import logging
import os
import re
import time
from collections import deque
from pathlib import PurePosixPath
from typing import Any
from urllib.parse import urljoin, urlsplit

import httpx
from fastapi import APIRouter, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from starlette.middleware.cors import CORSMiddleware

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api")

MAX_REQUEST_BYTES = 20 * 1024 * 1024
MAX_AUDIO_BYTES = 20 * 1024 * 1024
MIN_AUDIO_BYTES = 1024
ALLOWED_EXTENSIONS = {
    "flac",
    "m4a",
    "mp3",
    "mp4",
    "mpeg",
    "mpga",
    "ogg",
    "wav",
    "webm",
}
ALLOWED_CONTENT_TYPES = {
    "application/ogg",
    "audio/flac",
    "audio/mp3",
    "audio/mp4",
    "audio/mpeg",
    "audio/mpga",
    "audio/ogg",
    "audio/wav",
    "audio/webm",
    "audio/x-flac",
    "audio/x-m4a",
    "audio/x-wav",
    "video/mp4",
}
CONTENT_TYPES_BY_EXTENSION = {
    "flac": {"audio/flac", "audio/x-flac"},
    "m4a": {"audio/mp4", "audio/x-m4a"},
    "mp3": {"audio/mp3", "audio/mpeg"},
    "mp4": {"audio/mp4", "video/mp4"},
    "mpeg": {"audio/mpeg", "audio/mp3"},
    "mpga": {"audio/mpga", "audio/mpeg", "audio/mp3"},
    "ogg": {"audio/ogg", "application/ogg"},
    "wav": {"audio/wav", "audio/x-wav"},
    "webm": {"audio/webm"},
}
SESSION_ID_PATTERN = re.compile(r"^[A-Za-z0-9]{10,40}$")
DEVICE_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{16,128}$")
RATE_LIMIT = 20
RATE_WINDOW_SECONDS = 60


class RateLimiter:
    def __init__(self) -> None:
        self._requests: dict[str, deque[float]] = {}
        self._lock = asyncio.Lock()

    async def allow(self, address: str) -> bool:
        now = time.monotonic()
        async with self._lock:
            requests = self._requests.setdefault(address, deque())
            while requests and now - requests[0] >= RATE_WINDOW_SECONDS:
                requests.popleft()
            if len(requests) >= RATE_LIMIT:
                return False
            requests.append(now)
            if len(self._requests) > 4096:
                expired = [
                    key
                    for key, values in self._requests.items()
                    if not values or now - values[-1] >= RATE_WINDOW_SECONDS
                ]
                for key in expired:
                    self._requests.pop(key, None)
            return True


rate_limiter = RateLimiter()


class ConversationStartRequest(BaseModel):
    lang_a: str = Field(min_length=1, max_length=80)
    lang_b: str = Field(min_length=1, max_length=80)


class ConversationSummaryRequest(BaseModel):
    session_id: str
    close_after: str


def _configured(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        logger.error("Required server configuration is missing: %s", name)
        raise HTTPException(
            status_code=502,
            detail="The translation service is temporarily unavailable.",
        )
    return value


def _dify_base_url() -> str:
    configured = _configured("DIFY_API_BASE").rstrip("/")
    parsed = urlsplit(configured)
    if parsed.scheme not in {"https", "http"} or not parsed.netloc:
        logger.error("DIFY_API_BASE must be an absolute HTTP(S) URL.")
        raise HTTPException(
            status_code=502,
            detail="The translation service is temporarily unavailable.",
        )
    return configured if parsed.path.rstrip("/").endswith("/v1") else f"{configured}/v1"


def _device_id(request: Request) -> str:
    device_id = request.headers.get("x-device-id", "")
    if not DEVICE_ID_PATTERN.fullmatch(device_id):
        raise HTTPException(status_code=400, detail="A valid device id is required.")
    return device_id


def _session_id(value: str) -> str:
    if not SESSION_ID_PATTERN.fullmatch(value):
        raise HTTPException(status_code=400, detail="Invalid conversation session id.")
    return value


def _client_address(scope: dict[str, Any]) -> str:
    headers = dict(scope.get("headers", []))
    forwarded = headers.get(b"x-forwarded-for", b"").decode("latin-1")
    if forwarded:
        candidate = forwarded.split(",")[-1].strip()
        try:
            return str(ipaddress.ip_address(candidate))
        except ValueError:
            pass
    client = scope.get("client")
    return str(client[0]) if client else "unknown"


class ApiGuardMiddleware:
    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope["type"] != "http" or not scope.get("path", "").startswith("/api/"):
            await self.app(scope, receive, send)
            return

        if not await rate_limiter.allow(_client_address(scope)):
            response = JSONResponse(
                status_code=429,
                content={"status": "error", "message": "Too many requests. Please wait and try again."},
            )
            await response(scope, receive, send)
            return

        headers = dict(scope.get("headers", []))
        content_length = headers.get(b"content-length")
        if content_length:
            try:
                if int(content_length) > MAX_REQUEST_BYTES:
                    raise ValueError
            except ValueError:
                response = JSONResponse(
                    status_code=413,
                    content={"status": "error", "message": "The audio upload is too large."},
                )
                await response(scope, receive, send)
                return

        messages = []
        size = 0
        while True:
            message = await receive()
            if message["type"] != "http.request":
                if message["type"] == "http.disconnect":
                    return
                messages.append(message)
                continue
            size += len(message.get("body", b""))
            if size > MAX_REQUEST_BYTES:
                response = JSONResponse(
                    status_code=413,
                    content={"status": "error", "message": "The audio upload is too large."},
                )
                await response(scope, receive, send)
                return
            messages.append(message)
            if not message.get("more_body", False):
                break

        index = 0

        async def replay_receive() -> dict[str, Any]:
            nonlocal index
            if index < len(messages):
                message = messages[index]
                index += 1
                return message
            return {"type": "http.request", "body": b"", "more_body": False}

        await self.app(scope, replay_receive, send)


def _allowed_origins() -> list[str]:
    raw_origins = os.getenv("CORS_ALLOWED_ORIGINS", "")
    origins = [origin.strip() for origin in raw_origins.split(",") if origin.strip()]
    for origin in origins:
        parsed = urlsplit(origin)
        if (
            origin == "*"
            or parsed.scheme not in {"http", "https"}
            or not parsed.netloc
            or parsed.path
            or parsed.query
            or parsed.fragment
        ):
            raise RuntimeError("CORS_ALLOWED_ORIGINS must contain explicit HTTP(S) origins only.")
    return origins


def _api_key(workflow: str) -> str:
    return _configured(
        "DIFY_KEY_TRANSLATE" if workflow == "translate" else "DIFY_KEY_CONVERSATION"
    )


async def _upload_to_dify(
    client: httpx.AsyncClient,
    *,
    file_name: str,
    content_type: str,
    content: bytes,
    device_id: str,
    api_base: str,
    api_key: str,
) -> str:
    response = await client.post(
        f"{api_base}/files/upload",
        headers={"Authorization": f"Bearer {api_key}"},
        data={"user": device_id},
        files={"file": (file_name, content, content_type)},
        timeout=httpx.Timeout(60.0),
    )
    response.raise_for_status()
    result = response.json()
    file_id = result.get("id") if isinstance(result, dict) else None
    if not isinstance(file_id, str) or not file_id:
        raise ValueError("Dify returned an invalid file response.")
    return file_id


async def _run_workflow(
    *,
    workflow: str,
    inputs: dict[str, Any],
    device_id: str,
    api_base: str,
) -> dict[str, Any]:
    api_key = _api_key(workflow)
    async with httpx.AsyncClient() as client:
        response = await client.post(
            f"{api_base}/workflows/run",
            headers={"Authorization": f"Bearer {api_key}"},
            json={"inputs": inputs, "response_mode": "blocking", "user": device_id},
            timeout=httpx.Timeout(180.0),
        )
        response.raise_for_status()
        payload = response.json()
    data = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(data, dict):
        raise ValueError("The workflow did not succeed.")
    if data.get("status") != "succeeded":
        return {
            "status": "error",
            "message": "The translation service failed. Please try again.",
        }
    outputs = data.get("outputs")
    if not isinstance(outputs, dict):
        raise ValueError("The workflow response is invalid.")
    return outputs


async def _download_audio(outputs: dict[str, Any], *, api_base: str, api_key: str) -> tuple[str, str]:
    files = outputs.get("audio")
    if not isinstance(files, list) or not files or not isinstance(files[0], dict):
        raise ValueError("The workflow did not return translated audio.")
    file_url = files[0].get("url")
    if not isinstance(file_url, str) or not file_url.strip():
        raise ValueError("The workflow did not return a playable audio file.")

    resolved_url = urljoin(f"{api_base}/", file_url)
    base = urlsplit(api_base)
    target = urlsplit(resolved_url)
    if (
        target.scheme != base.scheme
        or target.netloc.lower() != base.netloc.lower()
        or target.username
        or target.password
    ):
        raise ValueError("The workflow returned an unsupported audio location.")

    async with httpx.AsyncClient() as client:
        response = await client.get(
            resolved_url,
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=httpx.Timeout(60.0),
        )
        response.raise_for_status()
    mime = response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
    if not mime.startswith("audio/"):
        mime = "audio/mpeg"
    if not response.content:
        raise ValueError("The workflow returned an empty audio file.")
    return base64.b64encode(response.content).decode("ascii"), mime


async def _read_and_validate_audio(file: UploadFile) -> tuple[bytes, str, str]:
    file_name = PurePosixPath((file.filename or "").replace("\\", "/")).name
    extension = file_name.rsplit(".", 1)[-1].lower() if "." in file_name else ""
    if extension not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail="Choose a supported audio file.")

    content_type = (file.content_type or "").lower().split(";", 1)[0].strip()
    if (
        content_type not in ALLOWED_CONTENT_TYPES
        or content_type not in CONTENT_TYPES_BY_EXTENSION.get(extension, set())
    ):
        raise HTTPException(status_code=400, detail="Choose a supported audio file.")

    content = await file.read(MAX_AUDIO_BYTES + 1)
    if len(content) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="The audio file must be 20 MB or smaller.")
    if len(content) < MIN_AUDIO_BYTES:
        raise HTTPException(status_code=400, detail="The audio file is empty or too short.")
    return content, file_name, content_type


def _workflow_message(outputs: dict[str, Any], expected_status: str) -> str | None:
    if outputs.get("status") == "error":
        message = outputs.get("message")
        if isinstance(message, str) and message.strip():
            return message.strip()[:500]
        return "The translation service could not process this request. Please try again."
    if outputs.get("status") != expected_status:
        raise ValueError("The workflow returned an invalid status.")
    return None


def _output_text(outputs: dict[str, Any], key: str) -> str:
    value = outputs.get(key)
    if not isinstance(value, str):
        raise ValueError("The workflow returned an invalid response.")
    return value


def _proxy_error(message: str, status_code: int) -> JSONResponse:
    return JSONResponse(status_code=status_code, content={"status": "error", "message": message})


@router.post("/translate")
async def translate(
    request: Request,
    audio: UploadFile = File(...),
    target_language: str = Form(...),
) -> JSONResponse:
    device_id = _device_id(request)
    if not target_language.strip() or len(target_language) > 80:
        raise HTTPException(status_code=400, detail="Choose a target language.")
    content, file_name, content_type = await _read_and_validate_audio(audio)
    api_base = _dify_base_url()
    api_key = _api_key("translate")
    try:
        async with httpx.AsyncClient() as client:
            file_id = await _upload_to_dify(
                client,
                file_name=file_name,
                content_type=content_type,
                content=content,
                device_id=device_id,
                api_base=api_base,
                api_key=api_key,
            )
            outputs = await _run_workflow(
                workflow="translate",
                inputs={
                    "audio": {
                        "type": "audio",
                        "transfer_method": "local_file",
                        "upload_file_id": file_id,
                    },
                    "target_language": target_language.strip(),
                },
                device_id=device_id,
                api_base=api_base,
            )
            message = _workflow_message(outputs, "success")
            if message:
                return JSONResponse(content={"status": "error", "message": message})
            audio_base64, audio_mime = await _download_audio(
                outputs, api_base=api_base, api_key=api_key
            )
        return JSONResponse(
            content={
                "status": "success",
                "translation": _output_text(outputs, "translation"),
                "transcript": _output_text(outputs, "transcript"),
                "source_language": _output_text(outputs, "source_language"),
                "target_language": _output_text(outputs, "target_language"),
                "audio_base64": audio_base64,
                "audio_mime": audio_mime,
            }
        )
    except HTTPException:
        raise
    except (httpx.HTTPError, ValueError, KeyError, TypeError):
        logger.warning("Dify translation request failed.")
        return _proxy_error("The translation service is temporarily unavailable. Please try again.", 502)


@router.post("/conversation/start")
async def start_conversation(
    body: ConversationStartRequest,
    request: Request,
) -> JSONResponse:
    device_id = _device_id(request)
    if body.lang_a == body.lang_b:
        raise HTTPException(status_code=400, detail="Choose two different languages.")
    api_base = _dify_base_url()
    try:
        outputs = await _run_workflow(
            workflow="conversation",
            inputs={"action": "start", "lang_a": body.lang_a, "lang_b": body.lang_b},
            device_id=device_id,
            api_base=api_base,
        )
        message = _workflow_message(outputs, "started")
        if message:
            return JSONResponse(content={"status": "error", "message": message})
        session_id = outputs.get("session_id")
        if not isinstance(session_id, str) or not SESSION_ID_PATTERN.fullmatch(session_id):
            raise ValueError("The workflow returned an invalid conversation id.")
        return JSONResponse(
            content={
                "status": "started",
                "session_id": session_id,
                "lang_a": _output_text(outputs, "lang_a"),
                "lang_b": _output_text(outputs, "lang_b"),
            }
        )
    except HTTPException:
        raise
    except (httpx.HTTPError, ValueError, KeyError, TypeError):
        logger.warning("Dify conversation start request failed.")
        return _proxy_error("The translation service is temporarily unavailable. Please try again.", 502)


@router.post("/conversation/turn")
async def conversation_turn(
    request: Request,
    session_id: str = Form(...),
    speaker: str = Form(...),
    audio: UploadFile = File(...),
) -> JSONResponse:
    device_id = _device_id(request)
    session_id = _session_id(session_id)
    if speaker not in {"A", "B"}:
        raise HTTPException(status_code=400, detail="Choose participant A or B.")
    content, file_name, content_type = await _read_and_validate_audio(audio)
    api_base = _dify_base_url()
    api_key = _api_key("conversation")
    try:
        async with httpx.AsyncClient() as client:
            file_id = await _upload_to_dify(
                client,
                file_name=file_name,
                content_type=content_type,
                content=content,
                device_id=device_id,
                api_base=api_base,
                api_key=api_key,
            )
            outputs = await _run_workflow(
                workflow="conversation",
                inputs={
                    "action": "turn",
                    "session_id": session_id,
                    "speaker": speaker,
                    "audio": {
                        "type": "audio",
                        "transfer_method": "local_file",
                        "upload_file_id": file_id,
                    },
                },
                device_id=device_id,
                api_base=api_base,
            )
            message = _workflow_message(outputs, "success")
            if message:
                return JSONResponse(content={"status": "error", "message": message})
            audio_base64, audio_mime = await _download_audio(
                outputs, api_base=api_base, api_key=api_key
            )
            sequence = outputs.get("seq")
            if not isinstance(sequence, (int, float, str)) or isinstance(sequence, bool):
                raise ValueError("The workflow returned an invalid sequence number.")
        return JSONResponse(
            content={
                "status": "success",
                "translation": _output_text(outputs, "translation"),
                "transcript": _output_text(outputs, "transcript"),
                "speaker": _output_text(outputs, "speaker"),
                "source_lang": _output_text(outputs, "source_lang"),
                "target_lang": _output_text(outputs, "target_lang"),
                "seq": sequence,
                "audio_base64": audio_base64,
                "audio_mime": audio_mime,
            }
        )
    except HTTPException:
        raise
    except (httpx.HTTPError, ValueError, KeyError, TypeError):
        logger.warning("Dify conversation turn request failed.")
        return _proxy_error("The translation service is temporarily unavailable. Please try again.", 502)


@router.post("/conversation/summary")
async def conversation_summary(
    body: ConversationSummaryRequest,
    request: Request,
) -> JSONResponse:
    device_id = _device_id(request)
    session_id = _session_id(body.session_id)
    if body.close_after not in {"yes", "no"}:
        raise HTTPException(status_code=400, detail="close_after must be yes or no.")
    api_base = _dify_base_url()
    try:
        outputs = await _run_workflow(
            workflow="conversation",
            inputs={
                "action": "summary",
                "session_id": session_id,
                "close_after": body.close_after,
            },
            device_id=device_id,
            api_base=api_base,
        )
        message = _workflow_message(outputs, "success")
        if message:
            return JSONResponse(content={"status": "error", "message": message})
        closed = _output_text(outputs, "closed")
        if closed not in {"yes", "no"}:
            raise ValueError("The workflow returned an invalid closed status.")
        return JSONResponse(
            content={
                "status": "success",
                "summary_a": _output_text(outputs, "summary_a"),
                "summary_b": _output_text(outputs, "summary_b"),
                "lang_a": _output_text(outputs, "lang_a"),
                "lang_b": _output_text(outputs, "lang_b"),
                "closed": closed,
            }
        )
    except HTTPException:
        raise
    except (httpx.HTTPError, ValueError, KeyError, TypeError):
        logger.warning("Dify conversation summary request failed.")
        return _proxy_error("The translation service is temporarily unavailable. Please try again.", 502)


def configure_proxy_app(app: FastAPI) -> None:
    app.add_middleware(ApiGuardMiddleware)
    origins = _allowed_origins()
    if origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=origins,
            allow_methods=["GET", "POST", "OPTIONS"],
            allow_headers=["Content-Type", "X-Device-Id"],
        )

    @app.exception_handler(HTTPException)
    async def http_error_handler(request: Request, exc: HTTPException) -> JSONResponse:
        message = exc.detail if isinstance(exc.detail, str) else "The request is invalid."
        return JSONResponse(
            status_code=exc.status_code,
            content={"status": "error", "message": message},
            headers=exc.headers,
        )

    @app.exception_handler(RequestValidationError)
    async def validation_error_handler(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        return _proxy_error("The request is invalid or incomplete.", 400)
