# Security Requirements Spec

All items use RFC 2119 language.

## Mappings

- T1: Server decrypts receiver copy
- T2: Token replay/forgery
- T3: ID probing
- T4: Scan-copy leaks/persistence
- T5: Approval bypass
- T6: Retention beyond receipt/TTL
- T7: Unsafe extraction
- T8: Scanner unavailable misinterpreted
- T9: Metadata leakage
- T10: Integrity failure

## MUST Requirements

- R-MUST-1 (T1): Server MUST never decrypt receiver copy.
- R-MUST-2 (T1): Scan-copy MUST be separate from receiver copy.
- R-MUST-3 (T2): Transfer tokens MUST be scoped to session_id + claim_id.
- R-MUST-4 (T3): Invalid/missing tokens or IDs MUST return indistinguishable errors.
- R-MUST-5 (T5): Receiver approval MUST be required before transfer init.
- R-MUST-6 (T6): Transfers MUST be deleted on receipt.
- R-MUST-7 (T6): TTL sweeper MUST delete expired sessions/transfers/scan sessions.
- R-MUST-8 (T8): Scanner unavailable MUST yield verdict "unavailable".
- R-MUST-9 (T4): Scan-copy MUST be deleted after scan finalize.
- R-MUST-10 (T9): Logs MUST use allowlist and MUST NOT include secrets.
- R-MUST-11 (T7): ZIP extraction MUST prevent path traversal (Zip Slip).
- R-MUST-12 (T10): AEAD MUST bind session_id, transfer_id, chunk_index, direction.

## SHOULD Requirements

- R-SHOULD-1 (T3): Rate limiting SHOULD be enabled per IP and route group.
- R-SHOULD-2 (T4): Scan limits SHOULD cap bytes and time.
- R-SHOULD-3 (T6): Scan session chunks SHOULD be deleted on TTL sweep.
- R-SHOULD-4 (T7): Extraction UI SHOULD keep original ZIP on failure.

## MAY Requirements

- R-MAY-1: Optional scan integration (ClamAV) MAY be enabled when available.
