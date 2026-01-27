package storage

import (
	"context"
	"errors"
	"time"

	"universaldrop/internal/domain"
)

var ErrNotFound = errors.New("not found")
var ErrInvalidRange = errors.New("invalid range")
var ErrConflict = errors.New("conflict")

type Storage interface {
	SaveManifest(ctx context.Context, transferID string, manifest []byte) error
	LoadManifest(ctx context.Context, transferID string) ([]byte, error)
	SaveTransferMeta(ctx context.Context, transferID string, meta domain.TransferMeta) error
	GetTransferMeta(ctx context.Context, transferID string) (domain.TransferMeta, error)
	DeleteTransferMeta(ctx context.Context, transferID string) error
	WriteChunk(ctx context.Context, transferID string, offset int64, data []byte) error
	ReadRange(ctx context.Context, transferID string, offset int64, length int64) ([]byte, error)
	DeleteTransfer(ctx context.Context, transferID string) error
	SweepExpired(ctx context.Context, now time.Time) (int, error)

	CreateSession(ctx context.Context, session domain.Session) error
	GetSession(ctx context.Context, sessionID string) (domain.Session, error)
	UpdateSession(ctx context.Context, session domain.Session) error
	DeleteSession(ctx context.Context, sessionID string) error

	SaveSessionAuthContext(ctx context.Context, auth domain.SessionAuthContext) error
	GetSessionAuthContext(ctx context.Context, sessionID string, claimID string) (domain.SessionAuthContext, error)

	CreateScanSession(ctx context.Context, scan domain.ScanSession) error
	GetScanSession(ctx context.Context, scanID string) (domain.ScanSession, error)
	DeleteScanSession(ctx context.Context, scanID string) error
	StoreScanChunk(ctx context.Context, scanID string, chunkIndex int, data []byte) error
	ListScanChunks(ctx context.Context, scanID string) ([]int, error)
	LoadScanChunk(ctx context.Context, scanID string, chunkIndex int) ([]byte, error)
	DeleteScanChunks(ctx context.Context, scanID string) error
}
