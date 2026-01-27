package storage

import (
	"context"
	"errors"
	"time"

	"universaldrop/internal/domain"
)

var ErrNotFound = errors.New("not found")
var ErrConflict = errors.New("conflict")

type PurgeReport struct {
	Tokens         int
	Drops          int
	ReceiverCopies int
	ScanCopies     int
}

type Storage interface {
	CreatePairingToken(ctx context.Context, token domain.PairingToken) error
	RedeemPairingToken(ctx context.Context, token string, pairing domain.Pairing, now time.Time) error
	GetPairing(ctx context.Context, id string) (domain.Pairing, error)

	CreateDrop(ctx context.Context, drop domain.Drop) error
	GetDrop(ctx context.Context, id string) (domain.Drop, error)
	UpdateDrop(ctx context.Context, drop domain.Drop) error
	DeleteDrop(ctx context.Context, id string) error

	StoreReceiverCopy(ctx context.Context, dropID string, data []byte) error
	LoadReceiverCopy(ctx context.Context, dropID string) ([]byte, error)
	DeleteReceiverCopy(ctx context.Context, dropID string) error

	StoreScanCopy(ctx context.Context, dropID string, data []byte) error
	LoadScanCopy(ctx context.Context, dropID string) ([]byte, error)
	DeleteScanCopy(ctx context.Context, dropID string) error

	PurgeExpired(ctx context.Context, now time.Time) (PurgeReport, error)
}
