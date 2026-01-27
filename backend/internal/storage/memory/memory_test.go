package memory

import (
	"context"
	"testing"
	"time"

	"universaldrop/internal/domain"
	"universaldrop/internal/storage"
)

func TestPurgeExpiredRemovesDropsAndCopies(t *testing.T) {
	store := New()
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	drop := domain.Drop{
		ID:        "drop-1",
		PairingID: "pairing-1",
		CreatedAt: now.Add(-2 * time.Hour),
		ExpiresAt: now.Add(-time.Minute),
		Status:    domain.DropStatusPendingApproval,
		ScanMode:  domain.ScanModeVerified,
		ScanStatus: domain.ScanStatusPending,
	}
	if err := store.CreateDrop(context.Background(), drop); err != nil {
		t.Fatalf("create drop: %v", err)
	}
	if err := store.StoreReceiverCopy(context.Background(), drop.ID, []byte("receiver")); err != nil {
		t.Fatalf("store receiver copy: %v", err)
	}
	if err := store.StoreScanCopy(context.Background(), drop.ID, []byte("scan")); err != nil {
		t.Fatalf("store scan copy: %v", err)
	}

	report, err := store.PurgeExpired(context.Background(), now)
	if err != nil {
		t.Fatalf("purge expired: %v", err)
	}
	if report.Drops != 1 || report.ReceiverCopies != 1 || report.ScanCopies != 1 {
		t.Fatalf("unexpected purge report: %+v", report)
	}

	if _, err := store.GetDrop(context.Background(), drop.ID); err != storage.ErrNotFound {
		t.Fatalf("expected drop deleted")
	}
	if _, err := store.LoadReceiverCopy(context.Background(), drop.ID); err != storage.ErrNotFound {
		t.Fatalf("expected receiver copy deleted")
	}
	if _, err := store.LoadScanCopy(context.Background(), drop.ID); err != storage.ErrNotFound {
		t.Fatalf("expected scan copy deleted")
	}
}
