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
- `/v1` routes are rate-limited per IP and group.
- See `/docs/security` for the security documentation skeleton.