import json
import logging
import time
from uuid import uuid4

import httpx
from fastapi import APIRouter, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse, Response

from proxy import (
    MAX_AUDIO_BYTES,
    _api_key,
    _device_id,
    _dify_base_url,
    _download_audio,
    _output_text,
    _read_and_validate_audio,
    _run_workflow,
    _upload_to_dify,
)

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api")

_ERROR_MESSAGE = "The translation service is temporarily unavailable. Please try again."
_AUDIO_EXTENSIONS = {
    "audio/flac": "flac",
    "audio/mp4": "m4a",
    "audio/mpeg": "mp3",
    "audio/ogg": "ogg",
    "audio/wav": "wav",
    "audio/webm": "webm",
}


def _error_response(
    status_code: int, error: str, message: str, *, request_id: str
) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content={"status_code": status_code, "error": error, "message": message},
        headers={"Cache-Control": "no-store", "X-Request-ID": request_id},
    )


def _file_response(
    metadata: dict[str, object],
    audio: bytes,
    audio_mime: str,
    *,
    request_id: str,
) -> Response:
    boundary = f"voice-translate-{uuid4().hex}"
    extension = _AUDIO_EXTENSIONS.get(audio_mime, "mp3")
    metadata_bytes = json.dumps(
        metadata, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    body = b"".join(
        [
            (
                f"--{boundary}\r\n"
                "Content-Type: application/json; charset=utf-8\r\n"
                'Content-Disposition: form-data; name="metadata"\r\n\r\n'
            ).encode("ascii"),
            metadata_bytes,
            (
                f"\r\n--{boundary}\r\n"
                f"Content-Type: {audio_mime}\r\n"
                f'Content-Disposition: attachment; name="audio"; filename="translation.{extension}"\r\n\r\n'
            ).encode("ascii"),
            audio,
            f"\r\n--{boundary}--\r\n".encode("ascii"),
        ]
    )
    return Response(
        content=body,
        status_code=200,
        media_type=f'multipart/mixed; boundary="{boundary}"',
        headers={
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "X-Request-ID": request_id,
        },
    )


@router.post("/translate")
async def translate(
    request: Request,
    audio: UploadFile = File(...),
    target_language: str = Form(...),
) -> Response:
    request_id = uuid4().hex
    started_at = time.monotonic()
    stage = "validating request"
    try:
        device_id = _device_id(request)
        language = target_language.strip()
        if not language or len(language) > 80:
            raise HTTPException(status_code=400, detail="Choose a target language.")
        content, file_name, content_type = await _read_and_validate_audio(audio)
        logger.info(
            "Translation request accepted "
            "request_id=%s audio_bytes=%d audio_type=%s",
            request_id,
            len(content),
            content_type,
        )

        api_base = _dify_base_url()
        key = _api_key("translate")
        stage = "uploading audio"
        async with httpx.AsyncClient() as client:
            file_id = await _upload_to_dify(
                client,
                file_name=file_name,
                content_type=content_type,
                content=content,
                device_id=device_id,
                api_base=api_base,
                api_key=key,
            )
        stage = "running workflow"
        outputs = await _run_workflow(
            workflow="translate",
            inputs={
                "audio": {
                    "type": "audio",
                    "transfer_method": "local_file",
                    "upload_file_id": file_id,
                },
                "target_language": language,
            },
            device_id=device_id,
            api_base=api_base,
        )
        workflow_status = outputs.get("status_code")
        if workflow_status is None:
            workflow_status = outputs.get("status")
        status_code_success = (
            isinstance(workflow_status, int)
            and not isinstance(workflow_status, bool)
            and 200 <= workflow_status < 300
        )
        legacy_success = (
            workflow_status is None and outputs.get("status") == "success"
        )
        if outputs.get("status") == "error" or not (
            status_code_success or legacy_success
        ):
            log_status = (
                workflow_status
                if workflow_status is not None
                else outputs.get("status")
            )
            logger.warning(
                "Translation workflow failed "
                "request_id=%s stage=%s workflow_status=%s",
                request_id,
                stage,
                log_status,
            )
            return _error_response(
                502,
                "translation_failed",
                _ERROR_MESSAGE,
                request_id=request_id,
            )

        stage = "validating workflow output"
        metadata: dict[str, object] = {
            "status_code": 200,
            "translation": _output_text(outputs, "translation"),
            "transcript": _output_text(outputs, "transcript"),
            "source_language": _output_text(outputs, "source_language"),
            "target_language": _output_text(outputs, "target_language"),
        }
        stage = "downloading translated audio"
        translated_audio, audio_mime = await _download_audio(
            outputs, api_base=api_base, api_key=key
        )
        if len(translated_audio) > MAX_AUDIO_BYTES:
            logger.warning(
                "Translation audio rejected request_id=%s reason=audio_too_large audio_bytes=%d",
                request_id,
                len(translated_audio),
            )
            return _error_response(
                502,
                "translation_failed",
                "The translation service returned an audio file that is too large.",
                request_id=request_id,
            )
        result = _file_response(
            metadata,
            translated_audio,
            audio_mime,
            request_id=request_id,
        )
        logger.info(
            "Translation request completed "
            "request_id=%s status_code=200 audio_bytes=%d duration_ms=%d",
            request_id,
            len(translated_audio),
            int((time.monotonic() - started_at) * 1000),
        )
        return result
    except HTTPException as error:
        code = {
            400: "invalid_request",
            413: "audio_too_large",
            429: "rate_limited",
        }.get(error.status_code, "translation_service_unavailable")
        logger.info(
            "Translation request rejected request_id=%s status_code=%d error=%s",
            request_id,
            error.status_code,
            code,
        )
        message = (
            error.detail
            if isinstance(error.detail, str)
            else "The request could not be processed."
        )
        return _error_response(
            error.status_code,
            code,
            message,
            request_id=request_id,
        )
    except (httpx.HTTPError, ValueError, KeyError, TypeError) as error:
        logger.warning(
            "Translation request failed "
            "request_id=%s stage=%s error_type=%s upstream_status=%s duration_ms=%d",
            request_id,
            stage,
            type(error).__name__,
            getattr(getattr(error, "response", None), "status_code", None),
            int((time.monotonic() - started_at) * 1000),
        )
        return _error_response(
            502,
            "translation_failed",
            _ERROR_MESSAGE,
            request_id=request_id,
        )
