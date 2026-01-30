# UniversalDrop (CipherLink)

UniversalDrop is an end-to-end encrypted drop service. FEATURE 1A provides a
baseline runnable repo with storage and token attachment points.

## Structure

- `/backend`: Go + chi API server
- `/app`: Flutter client scaffold
- `/docs/security`: security documentation (skeleton)

## Backend

### Prerequisites

- Go 1.22+

### Run

```bash
cd backend
go run ./cmd/server
```

Configuration (optional):

- `UD_ADDRESS` (default `:8080`)
- `UD_DATA_DIR` (default `data`)
- `UD_TOKEN_HMAC_SECRET_B64` (optional; base64 raw URL without padding or standard, >= 32 bytes). Tokens are stateless HMAC-signed; if unset, the server uses `<UD_DATA_DIR>/secrets/token_hmac.key` and creates it on first start; keep this file to preserve tokens across restarts.
- `UD_RATE_LIMIT_HEALTH_MAX` (default `60`)
- `UD_RATE_LIMIT_HEALTH_WINDOW` (default `1m`)
- `UD_RATE_LIMIT_V1_MAX` (default `30`)
- `UD_RATE_LIMIT_V1_WINDOW` (default `1m`)
- `UD_RATE_LIMIT_SESSION_CLAIM_MAX` (default `10`)
- `UD_RATE_LIMIT_SESSION_CLAIM_WINDOW` (default `1m`)
- `UD_CLAIM_TOKEN_TTL` (default `3m`, min `2m`, max `5m`)
- `UD_TRANSFER_TOKEN_TTL` (default `5m`, min `1m`, max `15m`)
- `UD_SWEEP_INTERVAL` (default `30s`)

### Verify

```bash
cd backend
go test ./...
```

## App

### Prerequisites

- Flutter SDK (stable)

### Build & Run

```bash
cd app
flutter pub get
flutter run
```

### Runtime Safety

- Background resume + foreground service is optional and defaults to off; if unavailable, transfers stay in-app.
- Experimental background transport is optional and defaults to off; it falls back to standard HTTP.

### Run

```bash
cd app && flutter pub get
flutter run -d android
flutter run -d ios
```

### Verify

```bash
cd app
flutter test
```

## Notes

- Use the app home screen "Ping Backend" button against `/healthz`.
- Receiver sessions are created via `POST /v1/session/create`.
- Senders claim via `POST /v1/session/claim` and poll `/v1/session/poll`.
- Receivers approve/reject via `POST /v1/session/approve`.
- Transfers use `/v1/transfer/init`, `/v1/transfer/chunk`, `/v1/transfer/finalize`,
  `/v1/transfer/manifest`, `/v1/transfer/download`, and `/v1/transfer/receipt`.
- `/v1` routes are rate-limited per IP and group.
- App crypto helpers live in `app/lib/crypto.dart` with tests under `app/test`.
- The app supports live “Send Text” using the same E2E transfer pipeline;
  content is deleted on receipt or TTL expiry.
- Packaging modes: Originals (default), ZIP, and Album. ZIP saves to Files by
  default; Album saves to Photos/Gallery by default, with fallbacks when
  permissions are denied.
- ZIP transfers can optionally be extracted locally; extraction is local-only.
- Optional Verified Scan Mode uploads a separate scan-copy encrypted to a server
  scan key; the receiver copy remains strict E2E and is never decrypted server-side.

## Security Guarantees

- Strict E2E by default: receiver copy is never decrypted server-side.
- Delete-on-receipt plus TTL sweeper for expired sessions/transfers/scan sessions.
- Optional scan-copy mode is explicit and isolated from receiver copy.
- Received media (image/video) defaults to Photos/Gallery, while other files
  default to Files. Permissions are requested only when needed; if denied, the
  app saves to its private storage and offers “Open in…” and “Save As…” actions.
- See `/docs/security` for the security documentation skeleton.