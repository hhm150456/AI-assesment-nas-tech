import base64
import hmac
import ipaddress
import json
import os
import socket
import threading
from typing import Literal, Optional
from urllib.parse import urlparse

import firebase_admin
import httpx
from fastapi import APIRouter, Header, HTTPException, Query
from firebase_admin import credentials, firestore
from pydantic import BaseModel, Field

router = APIRouter()

_database = None
_database_lock = threading.Lock()


def _load_credentials():
    raw = os.environ.get("FIREBASE_CREDENTIALS_JSON", "").strip()
    if raw:
        if not raw.startswith("{"):
            raw = base64.b64decode(raw).decode("utf-8")
        info = json.loads(raw)
        info["private_key"] = info["private_key"].replace("\\n", "\n")
        return credentials.Certificate(info)

    path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", "").strip()
    if path:
        return credentials.Certificate(path)
    return None


def _firestore():
    global _database
    if _database is None:
        with _database_lock:
            if _database is None:
                try:
                    app = firebase_admin.get_app()
                except ValueError:
                    app = firebase_admin.initialize_app(_load_credentials())
                _database = firestore.client(
                    app=app,
                    database_id=os.environ.get("FIRESTORE_DATABASE_ID", "(default)"),
                )
    return _database


def _auth(key: Optional[str]) -> None:
    bridge_key = os.environ.get("BRIDGE_KEY", "").strip()
    if not bridge_key:
        raise HTTPException(503, "bridge_unavailable")
    if not key or not hmac.compare_digest(key, bridge_key):
        raise HTTPException(401, "unauthorized")


def _get_session(sid: str, must_be_active: bool = True):
    ref = _firestore().collection("sessions").document(sid)
    doc = ref.get()
    if not doc.exists:
        raise HTTPException(404, "session_not_found")
    data = doc.to_dict()
    if must_be_active and data.get("status") != "active":
        raise HTTPException(409, "session_closed")
    return ref, data


class NewSession(BaseModel):
    lang_a: str = Field(min_length=2, max_length=64)
    lang_b: str = Field(min_length=2, max_length=64)


class Turn(BaseModel):
    speaker: Literal["A", "B"]
    source_lang: str = Field(min_length=2, max_length=64)
    target_lang: str = Field(min_length=2, max_length=64)
    source_text: str = Field(min_length=1, max_length=20000)
    translated_text: str = Field(min_length=1, max_length=20000)
    latency_ms: Optional[int] = None


class Summary(BaseModel):
    text_a: str = Field(max_length=20000)
    text_b: str = Field(max_length=20000)


@router.post("/sessions")
def new_session(body: NewSession, x_api_key: str = Header(None)):
    _auth(x_api_key)
    ref = _firestore().collection("sessions").document()
    ref.set({
        "status": "active",
        "langA": body.lang_a,
        "langB": body.lang_b,
        "turnCount": 0,
        "createdAt": firestore.SERVER_TIMESTAMP,
    })
    return {"session_id": ref.id, "lang_a": body.lang_a, "lang_b": body.lang_b}


@router.get("/sessions/{sid}")
def read_session(sid: str, x_api_key: str = Header(None)):
    _auth(x_api_key)
    _, data = _get_session(sid)
    return {
        "session_id": sid,
        "lang_a": data["langA"],
        "lang_b": data["langB"],
        "turn_count": data["turnCount"],
    }


@router.get("/sessions/{sid}/turns")
def list_turns(
    sid: str,
    limit: int = Query(10, ge=1, le=500),
    x_api_key: str = Header(None),
):
    _auth(x_api_key)
    ref, _ = _get_session(sid, must_be_active=False)
    query = (
        ref.collection("turns")
        .order_by("seq", direction=firestore.Query.DESCENDING)
        .limit(limit)
    )
    items = [turn.to_dict() for turn in query.stream()][::-1]
    lines = [
        f'[{turn["speaker"]} | {turn["sourceLang"]}] {turn["sourceText"]}  =>  '
        f'[{turn["targetLang"]}] {turn["translatedText"]}'
        for turn in items
    ]
    return {"count": len(items), "history_text": "\n".join(lines)}


@firestore.transactional
def _add_turn_transaction(transaction, ref, data):
    snapshot = ref.get(transaction=transaction)
    session = snapshot.to_dict() or {}
    if session.get("status") != "active":
        raise HTTPException(409, "session_closed")
    sequence = session.get("turnCount", 0) + 1
    transaction.update(ref, {"turnCount": sequence})
    transaction.set(
        ref.collection("turns").document(f"{sequence:04d}"),
        {**data, "seq": sequence, "createdAt": firestore.SERVER_TIMESTAMP},
    )
    return sequence


@router.post("/sessions/{sid}/turns")
def add_turn(sid: str, turn: Turn, x_api_key: str = Header(None)):
    _auth(x_api_key)
    ref, _ = _get_session(sid)
    sequence = _add_turn_transaction(
        _firestore().transaction(),
        ref,
        {
            "speaker": turn.speaker,
            "sourceLang": turn.source_lang,
            "targetLang": turn.target_lang,
            "sourceText": turn.source_text,
            "translatedText": turn.translated_text,
            "latencyMs": turn.latency_ms,
        },
    )
    return {"seq": sequence}


@router.post("/sessions/{sid}/summary")
def save_summary(sid: str, summary: Summary, x_api_key: str = Header(None)):
    _auth(x_api_key)
    ref, _ = _get_session(sid, must_be_active=False)
    ref.update(
        {
            "summary": {
                "textA": summary.text_a,
                "textB": summary.text_b,
                "createdAt": firestore.SERVER_TIMESTAMP,
            }
        }
    )
    return {"ok": True}


@router.post("/sessions/{sid}/close")
def close_session(sid: str, x_api_key: str = Header(None)):
    _auth(x_api_key)
    ref, _ = _get_session(sid, must_be_active=False)
    ref.update({"status": "closed", "closedAt": firestore.SERVER_TIMESTAMP})
    return {"ok": True}


MAX_BYTES = 20 * 1024 * 1024


class TranscribeRequest(BaseModel):
    audio_url: str = Field(max_length=2048)
    extension: str = Field("mp3", max_length=8)


def _is_public_host(host: str) -> bool:
    try:
        for info in socket.getaddrinfo(host, None):
            address = ipaddress.ip_address(info[4][0])
            if (
                address.is_private
                or address.is_loopback
                or address.is_link_local
                or address.is_reserved
                or address.is_multicast
            ):
                return False
        return True
    except (OSError, ValueError):
        return False


@router.post("/transcribe")
def transcribe(body: TranscribeRequest, x_api_key: str = Header(None)):
    _auth(x_api_key)
    from openai import OpenAI, OpenAIError

    audio_url = urlparse(body.audio_url)
    if (
        audio_url.scheme != "https"
        or not audio_url.hostname
        or not _is_public_host(audio_url.hostname)
    ):
        raise HTTPException(400, "invalid_audio_url")
    try:
        response = httpx.get(body.audio_url, timeout=30, follow_redirects=False)
        response.raise_for_status()
    except httpx.HTTPError as error:
        raise HTTPException(400, "audio_download_failed") from error
    if not response.content:
        raise HTTPException(400, "empty_audio")
    if len(response.content) > MAX_BYTES:
        raise HTTPException(413, "file_too_large")

    extension = (body.extension or "mp3").lstrip(".").lower()
    try:
        result = OpenAI().audio.transcriptions.create(
            model="gpt-4o-transcribe",
            file=(f"audio.{extension}", response.content),
        )
    except OpenAIError as error:
        raise HTTPException(502, "transcription_failed") from error
    return {"transcript": (result.text or "").strip()}
