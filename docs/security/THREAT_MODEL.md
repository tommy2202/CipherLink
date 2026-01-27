# Threat Model

## Scope

UniversalDrop V0 backend + Flutter app, including pairing, session approval,
transfer upload/download, and optional scan-copy flow.

## Assets

- A1: Receiver copy plaintext (E2E data).
- A2: Sender plaintext.
- A3: Receiver and sender public keys (integrity + authenticity).
- A4: Capability tokens (transfer tokens, claim tokens).
- A5: Scan-copy plaintext (server-only, optional).
- A6: Transfer manifests (encrypted).
- A7: Local device storage (receiver saved files).
- A8: Metadata (session IDs, transfer IDs, sizes).

## Trust Boundaries

- TB1: Client devices (sender/receiver).
- TB2: Backend server.
- TB3: Local filesystem storage on server.
- TB4: Optional scanner runtime (ClamAV).
- TB5: Network between clients and server.

## Threats and Mitigations

- T1: Server decrypts receiver copy (violates strict E2E).
  - M1: Receiver copy never decrypted server-side; server stores only ciphertext.
  - M2: Verified scan uses separate scan-copy only.

- T2: Token replay/forgery for transfer access.
  - M3: High-entropy capability tokens, short TTL.
  - M4: Token scope must match session/claim.
  - M5: Indistinguishable errors for invalid/missing tokens.

- T3: Unauthorized transfer access via ID probing.
  - M6: Indistinguishable errors for not-found/invalid.
  - M7: Rate limiting per IP and route group.

- T4: Scan-copy leaks to logs or persists.
  - M8: Logging allowlist, no payloads/labels/filenames.
  - M9: Scan-copy deleted after scan completion.
  - M10: TTL sweeper deletes expired scan sessions and chunks.

- T5: Session approval bypass.
  - M11: Receiver approval required; scan required flagged in session claim.
  - M12: Transfer auth requires SessionAuthContext resolution.

- T6: Data retention beyond receipt/TTL.
  - M13: Delete-on-receipt handler removes transfer artifacts.
  - M14: TTL sweeper removes expired sessions/transfers/scan sessions.

- T7: Malicious files causing unsafe extraction or path traversal.
  - M15: Zip Slip prevention on extraction (reject .., absolute paths).
  - M16: Extraction remains local-only; no server-side unpacking.

- T8: Scanner unavailable but treated as clean.
  - M17: Scanner unavailable => verdict "unavailable" (never auto-clean).

- T9: Metadata leakage in logs.
  - M18: Logging allowlist with hashed IDs only.

- T10: Integrity failure on chunk reordering/tamper.
  - M19: AEAD with chunk-index AAD binding.
  - M20: Receiver verifies before receipt.

## Residual Risks

- R1: Client device compromise (out of scope).
- R2: Side-channel metadata inference (size/timing).
