# Voice Translate

A Flutter Android/iOS client and a FastAPI service that proxies Dify requests and exposes authenticated Firestore bridge endpoints. Dify workflows handle transcription, translation, conversation, and speech generation; the conversation workflow calls the bridge routes on the same backend service to persist and retrieve conversation data.

## Project layout

```text
apps/mobile/       Flutter app (Android, iOS, Dart source, and tests)
services/proxy/    FastAPI proxy and its container/deployment files
README.md          Project setup, deployment, and manual test guide
```

Run Flutter commands from `apps/mobile`. Run or build the combined backend from `services/proxy`.

## Architecture

```text
apps/mobile/ --audio + JSON--> services/proxy/ --Dify Service API--> Dify workflows
                                      ^                                  |
                                      +------ /sessions + X-API-Key -----+
                                      |
                                      +---------------------------> Firestore
```

The app never calls the bridge or Dify directly. The proxy uses:

- `DIFY_API_BASE` — Dify API origin, for example `https://api.dify.ai`.
- `DIFY_KEY_TRANSLATE` — API key for the one-shot workflow app.
- `DIFY_KEY_CONVERSATION` — API key for the conversation workflow app.

`DIFY_KEY_TRANSLATE` and `DIFY_KEY_CONVERSATION` belong in the proxy host's secret environment variables. The imported Dify workflows separately need their `GROQ_API_KEY`, `OPENAI_KEY`, and `BRIDGE_KEY` secrets; `BRIDGE_URL` is the backend's public URL. Do not put keys in Flutter configuration, `.env` files, source control, or build arguments. `API_BASE_URL` is the backend's public URL and is not a secret. The Flutter app defaults to `https://ai-assesment-nas-tech-proxy.vercel.app`; change `apps/mobile/lib/core/config.dart` to update it, or pass `--dart-define=API_BASE_URL=<url>` to override it for a run or build.

The proxy and bridge routes are one service. Dify calls the service's `/sessions` endpoints with `X-API-Key` set to `BRIDGE_KEY`. The app does not need Firestore credentials or the bridge key.

The proxy uses the Dify Service API's `POST /v1/files/upload` and `POST /v1/workflows/run` endpoints with bearer authorization, `response_mode: blocking`, and an anonymous per-install `user` value. See the [Dify file upload API](https://docs.dify.ai/en/api-reference/files/upload-file.md) and [workflow run API](https://docs.dify.ai/en/api-reference/workflow-runs/run-workflow.md).

## Run the Flutter app

Install Flutter stable with Dart 3. Android builds also need Android Studio, an Android SDK with Command-line Tools, and a JDK supported by the Android Gradle Plugin (JDK 17 or newer). If Flutter does not find Android Studio's bundled JDK, point it to the JDK folder (adjust the path if Android Studio is installed elsewhere):

```powershell
flutter config --jdk-dir="C:\Program Files\Android\Android Studio\jbr"
flutter doctor --android-licenses
```

To run on a device, start an emulator or connect an Android phone with USB debugging enabled.

From the repository root, enter the Flutter app folder:

```powershell
Set-Location apps\mobile
flutter pub get
flutter run
```

Build a release APK:

```powershell
flutter build apk --release
```

The APK is written to `apps/mobile/build/app/outputs/flutter-apk/app-release.apk`. From `apps/mobile`, install it on a connected Android device with:

```powershell
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

Run `flutter test` and `flutter analyze` from `apps/mobile` before building. To test the web version in Chrome, run `flutter run -d chrome`. For a local proxy on Android Emulator, override the default with `flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080`. A physical phone needs a reachable address on the same network. Use HTTPS for deployed services. iOS builds require macOS and Xcode.

The anonymous device ID is generated once and stored locally using `shared_preferences`; it is not an authentication token. Conversation session IDs exist in memory only and are discarded when starting a new conversation or closing the app.

### Package choices

- `http` and `http_parser` for the shared JSON/multipart API client.
- `record` and `permission_handler` for microphone capture and permission/settings handling.
- `file_picker` for importing existing audio.
- `audioplayers` for playback directly from audio bytes.
- `shared_preferences` and `uuid` for a stable, random anonymous device ID.

State is kept in the feature screens with Flutter's built-in stateful widgets; a separate state-management package would add little for this two-screen client.

## Run the proxy locally

Use Python 3.12. From the repository root, enter the proxy folder. Set the Dify values in the current PowerShell session, then run:

```powershell
Set-Location services\proxy
$env:DIFY_API_BASE = "https://api.dify.ai"
$env:DIFY_KEY_TRANSLATE = "<translate-workflow-key>"
$env:DIFY_KEY_CONVERSATION = "<conversation-workflow-key>"
$env:BRIDGE_KEY = "<same-strong-secret-configured-in-Dify>"
$env:GOOGLE_APPLICATION_CREDENTIALS = "C:\secure\firestore-service-account.json"
$env:FIRESTORE_DATABASE_ID = "(default)"
$env:CORS_ALLOWED_ORIGINS = "http://localhost:3000"

python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m uvicorn main:app --reload --host 0.0.0.0 --port 8080
```

Keep credentials and key values outside source control. For local Firestore access, create a service account with Firestore access, download its JSON key to a protected location, and set `GOOGLE_APPLICATION_CREDENTIALS` to that file. Hosted platforms should use their managed Google identity if available, or inject the JSON securely as `FIREBASE_CREDENTIALS_JSON`; never commit the credential or place it in a client build. `BRIDGE_KEY` must match the value configured in Dify. For mobile-only use, omit `CORS_ALLOWED_ORIGINS`; browser access is denied unless an explicit origin is configured. The health endpoint is `GET /health`.

### Proxy routes

| Method | Path | Request |
|---|---|---|
| POST | `/api/translate` | Multipart `audio`, `target_language` |
| POST | `/api/conversation/start` | JSON `lang_a`, `lang_b` |
| POST | `/api/conversation/turn` | Multipart `session_id`, `speaker`, `audio` |
| POST | `/api/conversation/summary` | JSON `session_id`, `close_after` |

Every client request must include `X-Device-Id`. A successful `POST /api/translate` returns HTTP 200 as `multipart/mixed`: a JSON `metadata` part with numeric `status_code` and string `translation`, `transcript`, `source_language`, and `target_language` fields, followed by the translated audio as the `audio` file part. Translation failures return JSON with numeric `status_code` and string `error` and `message` fields; the HTTP status matches `status_code`. The Flutter client parses the multipart response and passes the raw audio bytes to the existing playback flow. For conversation turns, the proxy accepts Dify's numeric 2xx `status` and audio file array, downloads the file, and returns `audio_base64` and `audio_mime` for Flutter to decode and play. For conversation summaries, it accepts a numeric 2xx `status_code` and the two summary strings, then returns the client contract with session language labels and close state.

Translation diagnostics log a random request ID, processing stage, elapsed time, and audio size/type only. They do not log device IDs, credentials, audio, transcript, or translation text. Translation responses use `Cache-Control: no-store`.

#### Dify workflow contract

The Dify exports are in [`workflows/`](./workflows/). The proxy calls one app for translation and one for conversation. The following are the inputs and outputs the proxy requires; configure the Dify Start and End nodes to match these names and types.

| Workflow | Inputs | Required successful outputs |
|---|---|---|
| Translate | `audio` (Dify audio file object), `target_language` | Numeric 2xx TTS status in `status_code` or `status`, `translation`, `transcript`, `source_language`, `target_language`, `audio` (non-empty file array; first item must have a URL on the configured Dify API origin or a signed `https://upload.dify.ai/files/tools/` URL) |
| Conversation `action: "start"` | `action: "start"`, empty `session_id`, `speaker: "A"`, lowercase `lang_a` and `lang_b`, `audio: null`, `close_after: "no"` | `session_id`, `lang_a`, `lang_b`; the proxy normalizes Dify's status-less start End node to `status: "started"` |
| Conversation `action: "turn"` | `session_id`, `speaker` (`A` or `B`), `audio` (Dify audio file object) | `status` as a 2xx number (for example `200`) or `"success"`, `seq` (string or number, including `0`), `translation`, `transcript`, `speaker`, `source_lang`, `target_lang`, `audio` (as above) |
| Conversation `action: "summary"` | `session_id`, `close_after` (`"yes"` or `"no"`), `lang_a`, `lang_b` | Numeric 2xx `status_code` (for example `200`), `summary_a`, `summary_b`, and `closed` matching the requested close state. |

For translation workflow-level failures, the proxy converts Dify failures to a generic, user-safe JSON error response; Dify does not need to return an error message. The proxy uploads source audio to Dify, runs the workflow with the requested target language, and fetches generated audio from the configured Dify origin before returning it as a file part. The conversation endpoint continues returning generated audio as `audio_base64` and `audio_mime`.

Conversation state is persisted by the bridge in Firestore; Dify should pass the same `session_id` through each turn and summary request. Starting a new conversation creates a distinct session. The client does not expose a `reset` action, and starting a new session does not close the previous one. Summarization can close a session by sending `close_after: "yes"`.

For translation, verify the published workflow accepts `audio` and `target_language` and exposes a numeric 2xx status in `status_code` or `status`, `translation`, `transcript`, `source_language`, `target_language`, and an `audio` file output. Dify cloud signed audio URLs on `upload.dify.ai` are supported; the proxy only fetches URLs from the configured API origin or signed URLs under `https://upload.dify.ai/files/tools/`, and never forwards the Dify API key to the signed-file host. The proxy provides the failure envelope itself, so translation failure End nodes do not need to return a message. The checked-in conversation export makes action-specific Start inputs optional, fixes the summary turns URL, and passes `close_after` to the bridge when saving the summary; the bridge saves the summaries and closes the session in the same update. The start End node intentionally has no status, so the proxy validates its session ID and language pair before returning `status: "started"`. Import and publish the updated workflow package for these changes to take effect. The conversation turn End node still needs verification that its `seq` is the sequence returned by `save_turn`.

The exports configure Groq Whisper `whisper-large-v3`, OpenAI `gpt-4o-mini` for translation and summary, and OpenAI `gpt-4o-mini-tts` with voice `alloy` and MP3 output. They use Dify environment secrets `GROQ_API_KEY`, `OPENAI_KEY`, and, for conversation, `BRIDGE_KEY`; configure `BRIDGE_URL` to the deployed backend URL. These model names describe the checked-in exports, not necessarily a separately published Dify version.

## Deploy the backend to Render

The root [`render.yaml`](./render.yaml) is a Render Blueprint for the combined Docker backend. It builds from `services/proxy/Dockerfile`, configures `/health` as the health check, and defaults to Render's free web-service plan. Free services are intended for testing and hobby projects, not production. They spin down after 15 minutes without inbound traffic and typically take about a minute to wake; they also have monthly instance-hour, outbound-bandwidth, and build-minute limits. Firestore and Dify usage may have separate charges. See [Render's free-instance limits](https://render.com/docs/free) before deploying.

1. Create a Firestore Native mode database in your Google Cloud project if needed. Create a service account with the `roles/datastore.user` role and download its JSON key to a protected location. Do not add the key to the repository.
2. Push this repository to GitHub and, in Render, choose **New > Blueprint** and connect the repository. Render will read `render.yaml` from the repository root and create the service.
3. During setup, enter the secret environment variables in Render:
   - `DIFY_KEY_TRANSLATE` and `DIFY_KEY_CONVERSATION`: Dify workflow app API keys.
   - `BRIDGE_KEY`: a long, random secret; copy this same value into Dify's protected workflow configuration.
   - `FIREBASE_CREDENTIALS_JSON`: the service-account JSON, base64-encoded as shown below. This is a server secret, not a Flutter value.
4. Wait for the Render deploy to succeed and copy the service URL, for example `https://voice-translate-backend.onrender.com`.
5. In the Dify conversation workflow, set the bridge URL to that service URL and send `X-API-Key: <BRIDGE_KEY>`. Publish the workflow after configuring its bridge calls as described below.
6. Launch Flutter with `API_BASE_URL` set to the Render service URL.

To base64-encode the service-account JSON in PowerShell (copy the output directly into Render's `FIREBASE_CREDENTIALS_JSON` secret field):

```powershell
[Convert]::ToBase64String(
  [System.IO.File]::ReadAllBytes("C:\secure\firestore-service-account.json")
)
```

Generate a bridge secret in PowerShell and keep it out of source control:

```powershell
$keyBytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($keyBytes)
$BRIDGE_KEY = [Convert]::ToBase64String($keyBytes)
$rng.Dispose()
Write-Output $BRIDGE_KEY
```

Render's Blueprint marks credentials and API keys as unsynced values, so enter them in Render's environment settings rather than in `render.yaml`. The `FIRESTORE_DATABASE_ID` defaults to `(default)`; change it in Render if using a named database. Configure `CORS_ALLOWED_ORIGINS` only if a browser client needs access.

The public backend URL is also the bridge base URL. Configure the Dify conversation workflow's HTTP Request nodes to call that URL with header `X-API-Key: <BRIDGE_KEY>`. The bridge routes are:

| Method | Path | Behavior |
|---|---|---|
| POST | `/sessions` | Creates an active session from `lang_a` and `lang_b`; returns `session_id`, `lang_a`, and `lang_b`. |
| GET | `/sessions/{session_id}` | Returns session languages and turn count for an active session. |
| GET | `/sessions/{session_id}/turns?limit=N` | Returns recent turns as `history_text`; default limit is 10, maximum is 500. |
| POST | `/sessions/{session_id}/turns` | Saves a turn and transactionally assigns its sequence. Requires `speaker`, `source_text`, and `translated_text`; optional `source_lang`, `target_lang`, and `latency_ms`. The API derives the language pair from the session and speaker so blank Dify language variables cannot invalidate a turn. |
| POST | `/sessions/{session_id}/summary` | Saves `text_a` and `text_b`; optional `close_after: "yes"` also closes the session in the same Firestore update. |
| POST | `/sessions/{session_id}/close` | Marks the session closed. |
| POST | `/transcribe` | Optional authenticated transcription endpoint accepting `audio_url` and `extension`; downloads the audio and transcribes it with OpenAI `gpt-4o-transcribe`. |

For the proxy contract above, the conversation workflow should create the bridge session on `action: "start"` and return the bridge's session ID. On `action: "turn"`, it should reject unknown/closed sessions, load prior history if the translation prompt uses it, synthesize the translated audio, and only after TTS succeeds save exactly one turn through the bridge; return the saved sequence and generated Dify audio file list along with the required outputs. On `action: "summary"`, it should read the turns, generate both language summaries, save them through the bridge, and close the session only when `close_after` is `"yes"`. The bridge stores turns under `sessions/{id}/turns/{sequence}` and stores the summary on the session document. Field names in Firestore use camelCase (for example `langA`, `turnCount`, `sourceLang`, and `translatedText`).

In the `save_turn` HTTP Request node, configure the JSON body as separate key/value entries for `speaker`, `source_lang`, `target_lang`, `source_text`, and `translated_text`. Do not paste unquoted Dify variable expressions into a raw JSON body; use each expression as the value for its corresponding key so Dify serializes strings and escapes transcript text. Map `source_text` to the current transcript (`parse_transcript.text`), not `history_text`, which contains earlier turns. In `validate_turn`, map `lang_a` from `parse_session.lang_a`, not `parse_session.error`. The API also derives the persisted language pair from the session and speaker if Dify sends empty language values. The checked-in `workflows/ai translation conversation-actual.ifpkg` export contains these corrections; import it into Dify and publish the workflow for them to take effect. Verify that the workflow does not also perform a second write to Firestore for the same session or turn.

If you prefer to create the service manually instead of using **New > Blueprint**, choose **New > Web Service**, connect the repository, select **Docker** as the runtime, set **Dockerfile Path** to `services/proxy/Dockerfile`, and set the **Docker Context Directory** to `services/proxy`. Add the same environment variables/secrets above, set the health-check path to `/health`, and deploy. Do not set a separate start command; the Dockerfile already starts Uvicorn and listens on Render's `PORT`.

### Test the deployed system

First check Render's health endpoint at `https://<your-service>.onrender.com/health`; it should return `{"status":"ok"}`. This checks that the web service started, not that Firestore credentials work. To verify Firestore access, create a test session from PowerShell using the same bridge key configured in Render and Dify:

```powershell
$BACKEND_URL = "https://<your-service>.onrender.com"
$BRIDGE_KEY = "<your-bridge-key>"
$session = Invoke-RestMethod `
  -Uri "$BACKEND_URL/sessions" `
  -Method Post `
  -Headers @{ "X-API-Key" = $BRIDGE_KEY } `
  -ContentType "application/json" `
  -Body (@{ lang_a = "English"; lang_b = "French" } | ConvertTo-Json)
$session
```

The response should contain a `session_id`. Confirm that document exists in the Firestore `sessions` collection. A request without the correct `X-API-Key` should return HTTP 401.

You do **not** need to deploy the Flutter mobile app to Render. It is an Android/iOS client; run it on an Android emulator or a connected device, pointing it at the Render backend:

```powershell
Set-Location apps\mobile
flutter pub get
flutter test
flutter analyze
flutter run
```

In the app, test a one-shot translation, start a conversation, record/send turns from both participants, and finish with a summary. Verify that the session and `turns` subcollection appear in Firestore and that the summary/closed state updates. Also check Render logs and Dify workflow logs if a request fails. An installed Android APK or iOS app uses the same backend URL; only publish/store-distribute it if you want other people to install it. For local Flutter-only widget tests, the live Render/Dify/Firestore services are not contacted.

## Security model and limits

- Dify keys are read only from server environment variables and sent only from the proxy to Dify.
- The proxy validates audio extensions and matching audio content types, rejects empty/under-1 KiB files, and caps each request body and audio file at 20 MiB.
- Recordings stop at two minutes. These input limits are also checked in Flutter before upload.
- The API applies an in-memory limit of 20 requests per IP per minute. It uses the rightmost `X-Forwarded-For` address; deploy behind a trusted reverse proxy that sets this header. The counter resets on instance restart and is process-local, so use a shared limiter if scaling to multiple backend instances.
- CORS is disabled unless `CORS_ALLOWED_ORIGINS` is set to an explicit comma-separated allowlist. Wildcard origins are rejected. CORS is a browser control, not authentication.
- Session IDs are validated against `^[A-Za-z0-9]{10,40}$`. Upstream transport errors are replaced with generic client messages and logs omit keys, audio, and upstream error bodies.
- This proxy cannot authenticate individual app users. A public endpoint can still be abused from non-browser clients, and an anonymous device ID is not a credential. The per-IP limit is only a mitigation; production deployments that need stronger abuse prevention should add user authentication and a shared rate limiter.
- Audio downloads are accepted only from the configured Dify API origin to avoid turning the proxy into an arbitrary URL fetcher. If a Dify deployment returns generated audio on another host, explicitly add a trusted audio-host allowlist before using that deployment.

## Languages and audio limits

The app's searchable language pickers use the 57 display names in [`apps/mobile/lib/core/languages.dart`](./apps/mobile/lib/core/languages.dart). The proxy accepts MP3, MP4, MPEG, MPGA, M4A, WAV, WEBM, OGG, and FLAC audio, with matching content types. Files must be at least 1 KiB and no larger than 20 MiB; microphone recordings are limited to two minutes. These are client/proxy input constraints, not a guarantee that every configured transcription or translation model supports every language pair. The workflow dropdowns in Dify must be kept in sync with the app list.

The proxy's `/transcribe` bridge endpoint separately uses OpenAI `gpt-4o-transcribe`; the checked-in Dify workflows instead transcribe through Groq Whisper `whisper-large-v3`.

## Errors and workflow behavior

The proxy returns `{ "status": "error", "message": "..." }` for both workflow-level failures (normally HTTP 200) and proxy/validation failures (non-2xx). It does not expose a stable `error_code` field and does not pass Dify error codes through to the app. The bridge returns HTTP 401 for a missing/incorrect key, HTTP 404 for an unknown session, and HTTP 409 for a closed session; the proxy may report a failed upstream workflow with a generic message instead. Workflow-specific errors such as silent audio, unintelligible speech, unsupported target language, or translation length must be implemented in Dify and are not normalized by the proxy.

## Known issues

- The checked-in Dify exports currently mismatch the proxy contract as described above; correct and publish them before expecting successful mobile requests. Successful audio must be an `audio` array whose first item has a URL on the configured Dify API origin.
- The in-memory rate limiter is process-local and resets on restart. Use a shared limiter when running multiple backend instances. Render free instances may restart or sleep while idle.
- A timed-out conversation request may have completed upstream even though the client did not receive its response. The app prevents concurrent duplicate taps and preserves the same recording for retry, but the specified API has no idempotency key, so retrying an ambiguous timeout could create a second turn.
- Audio decoder support varies by device and source format. If the device cannot decode a selected file, convert it to a supported format and retry.
- The app keeps selected audio clips in memory while they are in use and passes the bytes directly to the audio player.

## Manual test checklist

- [ ] Translate a clear recording and verify translated audio plays; inspect transcript, translation, and detected source language.
- [ ] Upload each supported format and verify normal playback and translation.
- [ ] Try different target languages and conversation pairs, including non-Latin scripts.
- [ ] Record silence/near-silence and confirm a useful error plus retry/reset behavior.
- [ ] Upload a wrong extension or mismatched content type and confirm it is rejected before Dify.
- [ ] Upload a file larger than 20 MiB and confirm the client and proxy reject it.
- [ ] Deny microphone permission; confirm the upload option remains usable and a settings shortcut is offered when permission is permanently denied.
- [ ] Disable networking and confirm a friendly offline/timeout message with retry.
- [ ] Exceed the per-IP request limit and confirm HTTP 429 with a retry message.
- [ ] Use a closed or unknown conversation session; confirm the error stays on the pending turn and offers a new conversation.
- [ ] End and summarize; confirm both language summaries display and recording controls lock.
- [ ] Start a new conversation and confirm its new session has no previous turn history.
- [ ] Confirm Dify can create a session and save turns/summary through the backend `/sessions` routes, and that calls without a valid `X-API-Key` are rejected.
- [ ] After correcting and publishing the Dify workflows, check they return every required output name in the workflow contract table above and that generated audio uses the configured Dify API origin.
- [ ] For web, verify an allowed origin works and an unlisted origin is rejected by CORS.
