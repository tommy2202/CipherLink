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

### Run

```bash
cd app
flutter pub get
flutter run -d chrome
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
- See `/docs/security` for the security documentation skeleton.