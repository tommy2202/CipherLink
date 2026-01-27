package transfer

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"

	"universaldrop/internal/storage"
)

var ErrInvalidInput = errors.New("invalid input")

type Engine struct {
	store storage.Storage
}

func New(store storage.Storage) *Engine {
	return &Engine{store: store}
}

func (e *Engine) CreateTransfer(ctx context.Context, manifest []byte, totalBytes int64) (string, error) {
	if len(manifest) == 0 || totalBytes < 0 {
		return "", ErrInvalidInput
	}
	transferID, err := randomID(18)
	if err != nil {
		return "", err
	}
	if err := e.CreateTransferWithID(ctx, transferID, manifest, totalBytes); err != nil {
		return "", err
	}
	return transferID, nil
}

func (e *Engine) CreateTransferWithID(ctx context.Context, transferID string, manifest []byte, totalBytes int64) error {
	if transferID == "" || len(manifest) == 0 || totalBytes < 0 {
		return ErrInvalidInput
	}
	if _, err := e.store.LoadManifest(ctx, transferID); err == nil {
		return storage.ErrConflict
	} else if err != nil && err != storage.ErrNotFound {
		return err
	}
	return e.store.SaveManifest(ctx, transferID, manifest)
}

func (e *Engine) AcceptChunk(ctx context.Context, transferID string, offset int64, data []byte) error {
	if transferID == "" || offset < 0 {
		return ErrInvalidInput
	}
	return e.store.WriteChunk(ctx, transferID, offset, data)
}

func (e *Engine) FinalizeTransfer(_ context.Context, transferID string) error {
	if transferID == "" {
		return ErrInvalidInput
	}
	return nil
}

func (e *Engine) GetManifest(ctx context.Context, transferID string) ([]byte, error) {
	if transferID == "" {
		return nil, ErrInvalidInput
	}
	return e.store.LoadManifest(ctx, transferID)
}

func (e *Engine) ReadRange(ctx context.Context, transferID string, offset int64, length int64) ([]byte, error) {
	if transferID == "" {
		return nil, ErrInvalidInput
	}
	return e.store.ReadRange(ctx, transferID, offset, length)
}

func (e *Engine) DeleteOnReceipt(ctx context.Context, transferID string) error {
	if transferID == "" {
		return ErrInvalidInput
	}
	return e.store.DeleteTransfer(ctx, transferID)
}

func randomID(size int) (string, error) {
	buf := make([]byte, size)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}
