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

The Dify keys belong in your hosting provider's secret environment variables. Do not put keys in Flutter configuration, `.env` files, source control, or build arguments. `API_BASE_URL` is the backend's public URL and is not a secret.

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
flutter run --dart-define=API_BASE_URL=https://your-service.onrender.com
```

Build a release APK:

```powershell
flutter build apk --release --dart-define=API_BASE_URL=https://your-service.onrender.com
```

The APK is written to `apps/mobile/build/app/outputs/flutter-apk/app-release.apk`. From `apps/mobile`, install it on a connected Android device with:

```powershell
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

Run `flutter test` and `flutter analyze` from `apps/mobile` before building. For a local proxy on Android Emulator, use `http://10.0.2.2:8080` as the API base URL. A physical phone needs a reachable address on the same network. Use HTTPS for deployed services. iOS builds require macOS and Xcode.

The anonymous device ID is generated once and stored locally using `shared_preferences`; it is not an authentication token. Conversation session IDs exist in memory only and are discarded when starting a new conversation or closing the app.

### Package choices

- `http` and `http_parser` for the shared JSON/multipart API client.
- `record` and `permission_handler` for microphone capture and permission/settings handling.
- `file_picker` for importing existing audio.
- `audioplayers` and `path_provider` for playback from temporary files.
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

Every client request must include `X-Device-Id`. Workflow outcomes use HTTP 200 and a `status` of `success`, `started`, or `error`. Proxy input, rate-limit, size, and transport failures use non-2xx responses with `{ "status": "error", "message": "..." }`. Dify error details and file URLs are not returned for transport failures; translated audio is downloaded by the proxy and returned as base64.

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

The public backend URL is also the bridge base URL. Configure the Dify conversation workflow's HTTP Request nodes to call that URL with header `X-API-Key: <BRIDGE_KEY>`. The workflow should:

- On `action=start`, `POST /sessions` with JSON `{"lang_a":"...","lang_b":"..."}` and return the resulting `session_id`, `lang_a`, and `lang_b` to the proxy as `status: "started"`.
- On `action=turn`, retrieve context from `GET /sessions/{session_id}/turns`, run the translation, then `POST /sessions/{session_id}/turns` with `speaker`, `source_lang`, `target_lang`, `source_text`, and `translated_text`. Return `status: "success"`, the bridge's `seq`, `translation`, `transcript`, `speaker`, `source_lang`, `target_lang`, and the generated `audio` file list to the proxy.
- On `action=summary`, retrieve the session turns, generate both summaries, and `POST /sessions/{session_id}/summary` with `text_a` and `text_b`. If `close_after` is `"yes"`, also call `POST /sessions/{session_id}/close`. Return `status: "success"`, `summary_a`, `summary_b`, `lang_a`, `lang_b`, and `closed` to the proxy.

These workflow edits happen in Dify and are not represented by source files in this repository. Verify that the workflow does not also perform a second write to Firestore for the same session or turn.

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
flutter run --dart-define=API_BASE_URL=https://<your-service>.onrender.com
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

The single ordered list of 57 supported display names is in [`apps/mobile/lib/core/languages.dart`](./apps/mobile/lib/core/languages.dart) and is used by the searchable pickers. Supported extensions are MP3, MP4, MPEG, MPGA, M4A, WAV, WEBM, OGG, and FLAC. Files must be at least 1 KiB and no larger than 20 MiB; microphone recordings are limited to two minutes.

## Known issues

- Dify workflows must be published and return the documented output names, including an `audio` array whose first item has a URL on the configured Dify API origin.
- The in-memory rate limiter is process-local and resets on restart. Use a shared limiter when running multiple backend instances. Render free instances may restart or sleep while idle.
- A timed-out conversation request may have completed upstream even though the client did not receive its response. The app prevents concurrent duplicate taps and preserves the same recording for retry, but the specified API has no idempotency key, so retrying an ambiguous timeout could create a second turn.
- Audio decoder support varies by device and source format. If the device cannot decode a selected file, convert it to a supported format and retry.
- The app keeps a selected audio clip in memory while it is in use. Temporary playback files are deleted when their playback widgets are removed.

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
- [ ] For web, verify an allowed origin works and an unlisted origin is rejected by CORS.
