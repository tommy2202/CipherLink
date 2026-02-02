package localfs

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"universaldrop/internal/domain"
)

func TestSweepExpiredRemovesSessionsAndTransfers(t *testing.T) {
	dir := t.TempDir()
	store, err := New(dir)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}

	now := time.Now().UTC()
	session := domain.Session{
		ID:        "sess1",
		CreatedAt: now.Add(-2 * time.Hour),
		ExpiresAt: now.Add(-time.Hour),
		Claims: []domain.SessionClaim{
			{
				ID:         "claim1",
				TransferID: "trans1",
			},
		},
	}
	if err := store.CreateSession(context.Background(), session); err != nil {
		t.Fatalf("create session: %v", err)
	}

	meta := domain.TransferMeta{
		Status:        domain.TransferStatusActive,
		BytesReceived: 0,
		TotalBytes:    0,
		CreatedAt:     now.Add(-2 * time.Hour),
		ExpiresAt:     now.Add(-time.Hour),
		ScanStatus:    domain.ScanStatusNotRequired,
	}
	if err := store.SaveTransferMeta(context.Background(), "trans1", meta); err != nil {
		t.Fatalf("save transfer meta: %v", err)
	}
	if err := store.SaveManifest(context.Background(), "trans1", []byte("manifest")); err != nil {
		t.Fatalf("save manifest: %v", err)
	}
	if err := store.WriteChunk(context.Background(), "trans1", 0, []byte("data")); err != nil {
		t.Fatalf("write chunk: %v", err)
	}

	result, err := store.SweepExpired(context.Background(), now)
	if err != nil {
		t.Fatalf("sweep expired: %v", err)
	}
	if result.Total() == 0 {
		t.Fatalf("expected sweep to delete entries")
	}

	if _, err := os.Stat(filepath.Join(dir, "sessions", "sess1.json")); !os.IsNotExist(err) {
		t.Fatalf("expected session file removed")
	}
	if _, err := os.Stat(filepath.Join(dir, "transfers", "trans1")); !os.IsNotExist(err) {
		t.Fatalf("expected transfer directory removed")
	}
}
