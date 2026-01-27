package memory

import (
	"context"
	"sync"
	"time"

	"universaldrop/internal/domain"
	"universaldrop/internal/storage"
)

type Store struct {
	mu             sync.Mutex
	tokens         map[string]domain.PairingToken
	pairings       map[string]domain.Pairing
	drops          map[string]domain.Drop
	receiverCopies map[string][]byte
	scanCopies     map[string][]byte
}

func New() *Store {
	return &Store{
		tokens:         map[string]domain.PairingToken{},
		pairings:       map[string]domain.Pairing{},
		drops:          map[string]domain.Drop{},
		receiverCopies: map[string][]byte{},
		scanCopies:     map[string][]byte{},
	}
}

func (s *Store) CreatePairingToken(_ context.Context, token domain.PairingToken) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.tokens[token.Token]; exists {
		return storage.ErrConflict
	}
	s.tokens[token.Token] = token
	return nil
}

func (s *Store) RedeemPairingToken(_ context.Context, token string, pairing domain.Pairing, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	stored, ok := s.tokens[token]
	if !ok {
		return storage.ErrNotFound
	}
	if !stored.ExpiresAt.After(now) {
		delete(s.tokens, token)
		return storage.ErrNotFound
	}
	delete(s.tokens, token)
	s.pairings[pairing.ID] = pairing
	return nil
}

func (s *Store) GetPairing(_ context.Context, id string) (domain.Pairing, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	pairing, ok := s.pairings[id]
	if !ok {
		return domain.Pairing{}, storage.ErrNotFound
	}
	return pairing, nil
}

func (s *Store) CreateDrop(_ context.Context, drop domain.Drop) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.drops[drop.ID]; exists {
		return storage.ErrConflict
	}
	s.drops[drop.ID] = drop
	return nil
}

func (s *Store) GetDrop(_ context.Context, id string) (domain.Drop, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	drop, ok := s.drops[id]
	if !ok {
		return domain.Drop{}, storage.ErrNotFound
	}
	return drop, nil
}

func (s *Store) UpdateDrop(_ context.Context, drop domain.Drop) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.drops[drop.ID]; !exists {
		return storage.ErrNotFound
	}
	s.drops[drop.ID] = drop
	return nil
}

func (s *Store) DeleteDrop(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.drops[id]; !exists {
		return storage.ErrNotFound
	}
	delete(s.drops, id)
	delete(s.receiverCopies, id)
	delete(s.scanCopies, id)
	return nil
}

func (s *Store) StoreReceiverCopy(_ context.Context, dropID string, data []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	drop, ok := s.drops[dropID]
	if !ok {
		return storage.ErrNotFound
	}
	if drop.ReceiverCopyPath != "" {
		return storage.ErrConflict
	}
	drop.ReceiverCopyPath = "memory"
	s.drops[dropID] = drop
	s.receiverCopies[dropID] = append([]byte(nil), data...)
	return nil
}

func (s *Store) LoadReceiverCopy(_ context.Context, dropID string) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.drops[dropID]; !ok {
		return nil, storage.ErrNotFound
	}
	data, ok := s.receiverCopies[dropID]
	if !ok {
		return nil, storage.ErrNotFound
	}
	return append([]byte(nil), data...), nil
}

func (s *Store) DeleteReceiverCopy(_ context.Context, dropID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	drop, ok := s.drops[dropID]
	if !ok || drop.ReceiverCopyPath == "" {
		return storage.ErrNotFound
	}
	delete(s.receiverCopies, dropID)
	drop.ReceiverCopyPath = ""
	s.drops[dropID] = drop
	return nil
}

func (s *Store) StoreScanCopy(_ context.Context, dropID string, data []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	drop, ok := s.drops[dropID]
	if !ok {
		return storage.ErrNotFound
	}
	if drop.ScanCopyPath != "" {
		return storage.ErrConflict
	}
	drop.ScanCopyPath = "memory"
	s.drops[dropID] = drop
	s.scanCopies[dropID] = append([]byte(nil), data...)
	return nil
}

func (s *Store) LoadScanCopy(_ context.Context, dropID string) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.drops[dropID]; !ok {
		return nil, storage.ErrNotFound
	}
	data, ok := s.scanCopies[dropID]
	if !ok {
		return nil, storage.ErrNotFound
	}
	return append([]byte(nil), data...), nil
}

func (s *Store) DeleteScanCopy(_ context.Context, dropID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	drop, ok := s.drops[dropID]
	if !ok || drop.ScanCopyPath == "" {
		return storage.ErrNotFound
	}
	delete(s.scanCopies, dropID)
	drop.ScanCopyPath = ""
	s.drops[dropID] = drop
	return nil
}

func (s *Store) PurgeExpired(_ context.Context, now time.Time) (storage.PurgeReport, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	report := storage.PurgeReport{}
	for token, pairing := range s.tokens {
		if !pairing.ExpiresAt.After(now) {
			delete(s.tokens, token)
			report.Tokens++
		}
	}
	for id, drop := range s.drops {
		if !drop.ExpiresAt.After(now) {
			delete(s.drops, id)
			if _, ok := s.receiverCopies[id]; ok {
				report.ReceiverCopies++
			}
			if _, ok := s.scanCopies[id]; ok {
				report.ScanCopies++
			}
			delete(s.receiverCopies, id)
			delete(s.scanCopies, id)
			report.Drops++
		}
	}
	return report, nil
}
