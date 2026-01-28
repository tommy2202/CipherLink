package transfer

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"time"

	"golang.org/x/crypto/chacha20poly1305"

	"universaldrop/internal/domain"
	"universaldrop/internal/scanner"
	"universaldrop/internal/storage"
)

var ErrInvalidInput = errors.New("invalid input")

type Engine struct {
	store storage.Storage
}

func New(store storage.Storage) *Engine {
	return &Engine{store: store}
}

func (e *Engine) CreateTransfer(ctx context.Context, manifest []byte, totalBytes int64, expiresAt time.Time) (string, error) {
	if len(manifest) == 0 || totalBytes < 0 {
		return "", ErrInvalidInput
	}
	transferID, err := randomID(18)
	if err != nil {
		return "", err
	}
	if err := e.CreateTransferWithID(ctx, transferID, manifest, totalBytes, expiresAt); err != nil {
		return "", err
	}
	return transferID, nil
}

func (e *Engine) CreateTransferWithID(ctx context.Context, transferID string, manifest []byte, totalBytes int64, expiresAt time.Time) error {
	if transferID == "" || len(manifest) == 0 || totalBytes < 0 {
		return ErrInvalidInput
	}
	if _, err := e.store.LoadManifest(ctx, transferID); err == nil {
		return storage.ErrConflict
	} else if err != nil && err != storage.ErrNotFound {
		return err
	}
	meta := domain.TransferMeta{
		Status:        domain.TransferStatusActive,
		BytesReceived: 0,
		TotalBytes:    totalBytes,
		CreatedAt:     time.Now().UTC(),
		ExpiresAt:     expiresAt.UTC(),
		ScanStatus:    domain.ScanStatusNotRequired,
	}
	if err := e.store.SaveTransferMeta(ctx, transferID, meta); err != nil {
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

func (e *Engine) InitScan(ctx context.Context, sessionID string, claimID string, transferID string, totalBytes int64, chunkSize int, expiresAt time.Time) (string, string, error) {
	if sessionID == "" || claimID == "" || transferID == "" || totalBytes < 0 {
		return "", "", ErrInvalidInput
	}
	scanID, err := randomID(18)
	if err != nil {
		return "", "", err
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return "", "", err
	}
	keyB64 := base64.RawURLEncoding.EncodeToString(key)
	scan := domain.ScanSession{
		ID:         scanID,
		SessionID:  sessionID,
		ClaimID:    claimID,
		TransferID: transferID,
		CreatedAt:  time.Now().UTC(),
		ExpiresAt:  expiresAt.UTC(),
		ScanKeyB64: keyB64,
		TotalBytes: totalBytes,
		ChunkSize:  chunkSize,
	}
	if err := e.store.CreateScanSession(ctx, scan); err != nil {
		return "", "", err
	}
	return scanID, keyB64, nil
}

func (e *Engine) StoreScanChunk(ctx context.Context, scanID string, chunkIndex int, data []byte) error {
	if scanID == "" || chunkIndex < 0 || len(data) == 0 {
		return ErrInvalidInput
	}
	return e.store.StoreScanChunk(ctx, scanID, chunkIndex, data)
}

func (e *Engine) FinalizeScan(ctx context.Context, scanID string, scan scanner.Scanner, maxBytes int64, maxDuration time.Duration) (domain.ScanStatus, error) {
	if scanID == "" {
		return domain.ScanStatusUnavailable, ErrInvalidInput
	}
	scanSession, err := e.store.GetScanSession(ctx, scanID)
	if err != nil {
		return domain.ScanStatusUnavailable, err
	}
	defer func() {
		_ = e.store.DeleteScanChunks(ctx, scanID)
		_ = e.store.DeleteScanSession(ctx, scanID)
	}()

	keyBytes, err := base64.RawURLEncoding.DecodeString(scanSession.ScanKeyB64)
	if err != nil || len(keyBytes) != 32 {
		return domain.ScanStatusUnavailable, ErrInvalidInput
	}
	if maxBytes > 0 && scanSession.TotalBytes > maxBytes {
		return domain.ScanStatusUnavailable, nil
	}

	chunkIndexes, err := e.store.ListScanChunks(ctx, scanID)
	if err != nil {
		return domain.ScanStatusUnavailable, err
	}

	plaintext := make([]byte, 0, scanSession.TotalBytes)
	aead, err := chacha20poly1305.New(keyBytes)
	if err != nil {
		return domain.ScanStatusUnavailable, err
	}
	for _, index := range chunkIndexes {
		encrypted, err := e.store.LoadScanChunk(ctx, scanID, index)
		if err != nil {
			return domain.ScanStatusUnavailable, err
		}
		nonce := scanNonce(index)
		decrypted, err := aead.Open(nil, nonce, encrypted, nil)
		if err != nil {
			return domain.ScanStatusFailed, nil
		}
		plaintext = append(plaintext, decrypted...)
		if maxBytes > 0 && int64(len(plaintext)) > maxBytes {
			return domain.ScanStatusUnavailable, nil
		}
	}

	if scan == nil {
		return domain.ScanStatusUnavailable, nil
	}
	scanCtx := ctx
	if maxDuration > 0 {
		var cancel context.CancelFunc
		scanCtx, cancel = context.WithTimeout(ctx, maxDuration)
		defer cancel()
	}
	result, err := scan.Scan(scanCtx, plaintext)
	if err != nil {
		if errors.Is(err, scanner.ErrUnavailable) {
			return domain.ScanStatusUnavailable, nil
		}
		return domain.ScanStatusFailed, nil
	}
	if result.Clean {
		return domain.ScanStatusClean, nil
	}
	return domain.ScanStatusFailed, nil
}

func scanNonce(chunkIndex int) []byte {
	nonce := make([]byte, chacha20poly1305.NonceSize)
	binary.BigEndian.PutUint64(nonce[4:], uint64(chunkIndex))
	return nonce
}

func randomID(size int) (string, error) {
	buf := make([]byte, size)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}
