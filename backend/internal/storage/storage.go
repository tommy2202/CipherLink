package storage

import (
	"context"
	"errors"
	"time"
)

var ErrNotFound = errors.New("not found")
var ErrInvalidRange = errors.New("invalid range")

type Storage interface {
	SaveManifest(ctx context.Context, transferID string, manifest []byte) error
	LoadManifest(ctx context.Context, transferID string) ([]byte, error)
	WriteChunk(ctx context.Context, transferID string, offset int64, data []byte) error
	ReadRange(ctx context.Context, transferID string, offset int64, length int64) ([]byte, error)
	DeleteTransfer(ctx context.Context, transferID string) error
	SweepExpired(ctx context.Context, now time.Time) (int, error)
}
