#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="${ROOT_DIR}/backend"
BASE_URL="${BASE_URL:-http://localhost:8080}"
BASE_URL="${BASE_URL%/}"

cd "$BACKEND_DIR"
go test ./...

go run ./cmd/server > "${ROOT_DIR}/.smoke_server.log" 2>&1 &
SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

health_url="${BASE_URL}/healthz"
session_url="${BASE_URL}/v1/session/create"

for _ in {1..40}; do
  if curl -fsS "$health_url" >/dev/null; then
    break
  fi
  sleep 0.25
done

curl -fsS "$health_url" >/dev/null

receiver_key="$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d '\n')"
curl -fsS -X POST "$session_url" \
  -H 'Content-Type: application/json' \
  -d "{\"receiver_pubkey_b64\":\"${receiver_key}\"}"
