# Verifier Mode

This document describes the "Verifier Mode" audit checks used to validate
security invariants in UniversalDrop.

## Goals

- Confirm strict E2E behavior is preserved.
- Confirm optional scan-copy does not access receiver copy.
- Confirm deletion and TTL behaviors.
- Confirm logs are privacy-safe.

## Checks

1) Strict E2E Default
   - Verify server code never decrypts receiver copy.
   - Verify transfer endpoints treat payload as opaque bytes.

2) Scan-Copy Isolation
   - Confirm scan-copy uses a dedicated scan key.
   - Confirm scan-copy is deleted after scan finalize.
   - If scanner unavailable, verify status "unavailable".

3) Receiver Approval Required
   - Confirm transfer init is blocked until approval.

4) Indistinguishable Errors
   - Compare invalid token vs missing resource responses.

5) Deletion + TTL
   - Verify delete-on-receipt path.
   - Verify TTL sweeper deletes expired sessions/transfers/scan sessions.

6) Logging Allowlist
   - Confirm logs use allowlisted keys only, with hashed IDs.
   - Ensure no filenames/labels/tokens/keys are logged.

7) Local-Only Extraction
   - Zip extraction is local-only and Zip Slip is prevented.
