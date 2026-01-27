# UniversalDrop (CipherLink)

UniversalDrop is an end-to-end encrypted drop service with receiver approval and
short-lived pairing tokens. The backend stores encrypted payloads as opaque data
and never decrypts receiver copies.

## Structure

- `/backend`: Go + chi API server
- `/app`: Flutter client scaffold

## Backend

### Prerequisites

- Go 1.21+

### Run

```bash
cd backend
go run ./cmd/server
```

Configuration (optional):

- `UD_ADDRESS` (default `:8080`)
- `UD_DATA_DIR` (default `data`)
- `UD_PAIRING_TOKEN_TTL` (default `5m`)
- `UD_DROP_TTL` (default `1h`)
- `UD_MAX_DROP_TTL` (default `24h`)
- `UD_SWEEP_INTERVAL` (default `30s`)
- `UD_MAX_COPY_BYTES` (default `10485760`)
- `UD_RATE_LIMIT_CREATE` (default `5`)
- `UD_RATE_LIMIT_REDEEM` (default `10`)
- `UD_RATE_LIMIT_WINDOW` (default `1m`)

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

## Security Notes

- The server never decrypts receiver copies (strict E2E default).
- Receiver approval is required before receiver copies can be uploaded or read.
- Pairing tokens are single-use, high-entropy, and short-lived with rate limits.
- Errors are intentionally indistinguishable for probing on token/ID endpoints.
- Logging is allowlisted to avoid secrets, tokens, labels, or filenames.
- Receiver copies are deleted immediately upon receipt; a TTL sweeper purges
  expired tokens and drops.
- Verified Scan Mode scans only the scan-copy; the receiver copy is never used.