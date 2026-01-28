# Security Test Plan

## Scope

Validates MUST requirements from SECURITY_REQUIREMENTS_SPEC.md.

## Backend Tests

- TP-1 (R-MUST-4): Indistinguishable errors for invalid vs missing token.
- TP-2 (R-MUST-5): Transfer init blocked without approval.
- TP-3 (R-MUST-6): Receipt deletes transfer artifacts.
- TP-4 (R-MUST-7): TTL sweeper deletes expired sessions/transfers/scan sessions.
- TP-5 (R-MUST-8): Scanner unavailable => status "unavailable".
- TP-6 (R-MUST-9): Scan-copy deleted after scan finalize.
- TP-7 (R-MUST-3): Transfer token scope enforced.
- TP-12 (R-MUST-15): Transfer/day quota blocks extra transfers (indistinguishable).
- TP-13 (R-MUST-16): Throttle delay sanity for upload/download.
- TP-14 (R-MUST-14): TURN relay quota blocks extra relay issuance.
- TP-15 (R-MUST-17): Download token single-use/short TTL.
- TP-16 (R-MUST-4/R-MUST-15): Protected endpoints keep indistinguishable errors on quota exceed.

## App Tests

- TP-8 (R-MUST-12): AEAD tamper/reorder fails (chunk_index AAD).
- TP-9 (R-MUST-11): Zip Slip rejection for "../" paths.
- TP-10 (R-MUST-11/R-SHOULD-4): Extraction leaves ZIP intact on failure.
- TP-11 (R-MUST-10): No secrets logged in UI flows (manual review).

## Manual Verification

- MV-1: Inspect server logs to confirm allowlist + hashed IDs only.
- MV-2: Confirm receipt only after decrypted payload displayed/saved.
