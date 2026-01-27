# Verifier Report

Date: 2026-01-27

## Step 1 — Structure Check

Root folder structure (depth 2):

- /app
  - /lib
  - /test
- /backend
  - /cmd
  - /internal
  - go.mod
  - go.sum
- /docs
  - /security
- /README.md

Result:
- Exactly one /backend and one /app: PASS
- No extra top-level project folders: PASS

## Step 2 — No-Duplication Check

Searched for duplicates:

- Auth/token validation helpers: single helper `authorizeTransfer` (backend/internal/api/handlers.go)
- Indistinguishable error responder: single `writeIndistinguishable` (backend/internal/api/security.go)
- Rate limiting middleware: single `rateLimit` (backend/internal/api/server.go)
- Crypto module: single client crypto helper (app/lib/crypto.dart)
- Storage backend: single LocalFS implementation with storage interface (backend/internal/storage/localfs)

Result: PASS (no duplicates found)

## Step 3 — Security Invariants Check

1) Strict E2E default intact:
   - Server does not derive X25519 session_key; receiver copy not decrypted server-side.
   - Verified scan uses scan-copy only.
2) Receiver approval gate:
   - Transfer endpoints require SessionAuthContext (created on approve).
3) Pairing/claim token protections:
   - Claim token high entropy, single-use, TTL enforced, rate limited.
4) Indistinguishable errors:
   - Invalid/missing session/token/transfer return same status/body.
5) Logging allowlist:
   - Allowlist enforced; hashed IDs only, no secrets.
6) Delete-on-receipt + TTL sweeper:
   - Receipt deletes transfer artifacts; sweeper cleans expired sessions/transfers/scan sessions.
7) Verified Scan Mode:
   - Scan-copy only; unavailable scanner yields "unavailable".
8) Range download support:
   - /v1/transfer/download supports Range.

Result: PASS

## Step 4 — Secret Leak Search

Search patterns: claim_token, transfer_token, Authorization, privateKey, seed, pubkey.

Findings:
- Occurrences are in request/response structs and tests, not logs.
- Logging uses allowlist with hashed IDs only.

Result: PASS (no log leaks)

## Step 5 — Test Coverage Check

Backend tests (go test ./...):
- Single-use claim token: TestClaimTokenSingleUse
- Delete-on-receipt: TestReceiptDeletesTransferArtifacts
- Manifest auth (indistinguishable): TestManifestDownloadReturnsIdenticalBytes / TestWrongTokenVsMissingTransferIndistinguishable
- Indistinguishable errors: TestIndistinguishableErrors

App tests:
- Crypto roundtrip/tamper: app/test/crypto_test.dart

Result: PASS

## Issues Found

None.

## Fixes Applied

No changes required beyond this report.

## Invariant Checklist

- [x] Strict E2E default (server never decrypts receiver copy)
- [x] Receiver approval gate enforced
- [x] Claim token protections (entropy, TTL, single-use, rate limiting)
- [x] Indistinguishable errors for invalid/missing IDs/tokens
- [x] Logging allowlist (no secrets)
- [x] Delete-on-receipt + TTL sweeper
- [x] Verified scan uses scan-copy only; unavailable => "unavailable"
- [x] Range download supported
