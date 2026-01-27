package localfs

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"

	"universaldrop/internal/domain"
	"universaldrop/internal/storage"
)

type Store struct {
	mu        sync.Mutex
	root      string
	stateFile string
	dropsDir  string
	tokens    map[string]domain.PairingToken
	pairings  map[string]domain.Pairing
	drops     map[string]domain.Drop
}

type persistedState struct {
	Tokens   map[string]domain.PairingToken `json:"pairing_tokens"`
	Pairings map[string]domain.Pairing      `json:"pairings"`
	Drops    map[string]domain.Drop         `json:"drops"`
}

func New(root string) (*Store, error) {
	if root == "" {
		root = "data"
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	dropsDir := filepath.Join(root, "drops")
	if err := os.MkdirAll(dropsDir, 0700); err != nil {
		return nil, err
	}

	store := &Store{
		root:      root,
		stateFile: filepath.Join(root, "state.json"),
		dropsDir:  dropsDir,
		tokens:    map[string]domain.PairingToken{},
		pairings:  map[string]domain.Pairing{},
		drops:     map[string]domain.Drop{},
	}

	if err := store.load(); err != nil {
		return nil, err
	}

	return store, nil
}

func (s *Store) CreatePairingToken(_ context.Context, token domain.PairingToken) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.tokens[token.Token]; exists {
		return storage.ErrConflict
	}
	s.tokens[token.Token] = token
	return s.persist()
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
		_ = s.persist()
		return storage.ErrNotFound
	}
	delete(s.tokens, token)
	s.pairings[pairing.ID] = pairing
	return s.persist()
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
	return s.persist()
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
	return s.persist()
}

func (s *Store) DeleteDrop(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	drop, ok := s.drops[id]
	if !ok {
		return storage.ErrNotFound
	}
	delete(s.drops, id)
	if err := s.deleteDropFilesLocked(drop); err != nil {
		return err
	}
	return s.persist()
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

	path := filepath.Join(s.dropsDir, dropID, "receiver.copy")
	if err := writeFileAtomic(path, data, 0600); err != nil {
		return err
	}
	drop.ReceiverCopyPath = path
	s.drops[dropID] = drop
	return s.persist()
}

func (s *Store) LoadReceiverCopy(_ context.Context, dropID string) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	drop, ok := s.drops[dropID]
	if !ok || drop.ReceiverCopyPath == "" {
		return nil, storage.ErrNotFound
	}
	data, err := os.ReadFile(drop.ReceiverCopyPath)
	if err != nil {
		return nil, storage.ErrNotFound
	}
	return data, nil
}

func (s *Store) DeleteReceiverCopy(_ context.Context, dropID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	drop, ok := s.drops[dropID]
	if !ok || drop.ReceiverCopyPath == "" {
		return storage.ErrNotFound
	}
	_ = os.Remove(drop.ReceiverCopyPath)
	drop.ReceiverCopyPath = ""
	s.drops[dropID] = drop
	return s.persist()
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

	path := filepath.Join(s.dropsDir, dropID, "scan.copy")
	if err := writeFileAtomic(path, data, 0600); err != nil {
		return err
	}
	drop.ScanCopyPath = path
	s.drops[dropID] = drop
	return s.persist()
}

func (s *Store) LoadScanCopy(_ context.Context, dropID string) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	drop, ok := s.drops[dropID]
	if !ok || drop.ScanCopyPath == "" {
		return nil, storage.ErrNotFound
	}
	data, err := os.ReadFile(drop.ScanCopyPath)
	if err != nil {
		return nil, storage.ErrNotFound
	}
	return data, nil
}

func (s *Store) DeleteScanCopy(_ context.Context, dropID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	drop, ok := s.drops[dropID]
	if !ok || drop.ScanCopyPath == "" {
		return storage.ErrNotFound
	}
	_ = os.Remove(drop.ScanCopyPath)
	drop.ScanCopyPath = ""
	s.drops[dropID] = drop
	return s.persist()
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
			report.Drops++
			report.ReceiverCopies += s.removeFileLocked(drop.ReceiverCopyPath)
			report.ScanCopies += s.removeFileLocked(drop.ScanCopyPath)
			_ = os.RemoveAll(filepath.Join(s.dropsDir, id))
		}
	}

	if report.Tokens == 0 && report.Drops == 0 {
		return report, nil
	}
	return report, s.persist()
}

func (s *Store) load() error {
	file, err := os.ReadFile(s.stateFile)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}

	var state persistedState
	if err := json.Unmarshal(file, &state); err != nil {
		return err
	}

	if state.Tokens != nil {
		s.tokens = state.Tokens
	}
	if state.Pairings != nil {
		s.pairings = state.Pairings
	}
	if state.Drops != nil {
		s.drops = state.Drops
	}
	return nil
}

func (s *Store) persist() error {
	state := persistedState{
		Tokens:   s.tokens,
		Pairings: s.pairings,
		Drops:    s.drops,
	}
	payload, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}

	tmp := s.stateFile + ".tmp"
	if err := os.WriteFile(tmp, payload, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, s.stateFile)
}

func (s *Store) deleteDropFilesLocked(drop domain.Drop) error {
	s.removeFileLocked(drop.ReceiverCopyPath)
	s.removeFileLocked(drop.ScanCopyPath)
	return os.RemoveAll(filepath.Join(s.dropsDir, drop.ID))
}

func (s *Store) removeFileLocked(path string) int {
	if path == "" {
		return 0
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return 0
	}
	return 1
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
