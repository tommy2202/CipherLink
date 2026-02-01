package localfs

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"universaldrop/internal/domain"
	"universaldrop/internal/storage"
)

type Store struct {
	mu           sync.Mutex
	root         string
	transfersDir string
	sessionsDir  string
	authDir      string
	scansDir     string
}

func New(root string) (*Store, error) {
	if root == "" {
		root = "data"
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	transfersDir := filepath.Join(root, "transfers")
	if err := os.MkdirAll(transfersDir, 0700); err != nil {
		return nil, err
	}
	sessionsDir := filepath.Join(root, "sessions")
	if err := os.MkdirAll(sessionsDir, 0700); err != nil {
		return nil, err
	}
	authDir := filepath.Join(root, "session_auth")
	if err := os.MkdirAll(authDir, 0700); err != nil {
		return nil, err
	}
	scansDir := filepath.Join(root, "scans")
	if err := os.MkdirAll(scansDir, 0700); err != nil {
		return nil, err
	}

	return &Store{
		root:         root,
		transfersDir: transfersDir,
		sessionsDir:  sessionsDir,
		authDir:      authDir,
		scansDir:     scansDir,
	}, nil
}

func (s *Store) HealthCheck(_ context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := os.Stat(s.root)
	return err
}

func (s *Store) SaveManifest(_ context.Context, transferID string, manifest []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.manifestPath(transferID)
	return writeFileAtomic(path, manifest, 0600)
}

func (s *Store) LoadManifest(_ context.Context, transferID string) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.manifestPath(transferID)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, storage.ErrNotFound
		}
		return nil, err
	}
	return data, nil
}

func (s *Store) SaveTransferMeta(_ context.Context, transferID string, meta domain.TransferMeta) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.transferMetaPath(transferID)
	return writeJSONAtomic(path, meta)
}

func (s *Store) GetTransferMeta(_ context.Context, transferID string) (domain.TransferMeta, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.transferMetaPath(transferID)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return domain.TransferMeta{}, storage.ErrNotFound
		}
		return domain.TransferMeta{}, err
	}
	var meta domain.TransferMeta
	if err := json.Unmarshal(data, &meta); err != nil {
		return domain.TransferMeta{}, err
	}
	return meta, nil
}

func (s *Store) DeleteTransferMeta(_ context.Context, transferID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.transferMetaPath(transferID)
	if err := os.Remove(path); err != nil {
		if os.IsNotExist(err) {
			return storage.ErrNotFound
		}
		return err
	}
	return nil
}

func (s *Store) WriteChunk(_ context.Context, transferID string, offset int64, data []byte) error {
	if offset < 0 {
		return storage.ErrInvalidRange
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.dataPath(transferID)
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE, 0600)
	if err != nil {
		return err
	}
	defer file.Close()

	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return err
	}
	_, err = file.Write(data)
	return err
}

func (s *Store) ReadRange(_ context.Context, transferID string, offset int64, length int64) ([]byte, error) {
	if offset < 0 || length < 0 {
		return nil, storage.ErrInvalidRange
	}
	if length == 0 {
		return []byte{}, nil
	}
	if length > int64(int(^uint(0)>>1)) {
		return nil, storage.ErrInvalidRange
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.dataPath(transferID)
	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, storage.ErrNotFound
		}
		return nil, err
	}
	defer file.Close()

	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return nil, err
	}

	buf := make([]byte, length)
	n, err := file.Read(buf)
	if err != nil && err != io.EOF {
		return nil, err
	}
	return buf[:n], nil
}

func (s *Store) DeleteTransfer(_ context.Context, transferID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.transferDir(transferID)
	if err := os.RemoveAll(path); err != nil {
		return err
	}
	return nil
}

func (s *Store) SweepExpired(_ context.Context, now time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now = now.UTC()
	deleted := 0

	sessionEntries, err := os.ReadDir(s.sessionsDir)
	if err != nil {
		return 0, err
	}
	for _, entry := range sessionEntries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		path := filepath.Join(s.sessionsDir, entry.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var session domain.Session
		if err := json.Unmarshal(data, &session); err != nil {
			continue
		}
		if now.Before(session.ExpiresAt) {
			continue
		}
		_ = os.Remove(path)
		deleted++
		s.deleteAuthContextsLocked(session.ID)
		for _, claim := range session.Claims {
			if claim.TransferID == "" {
				continue
			}
			_ = os.RemoveAll(s.transferDir(claim.TransferID))
			deleted++
		}
	}

	transferEntries, err := os.ReadDir(s.transfersDir)
	if err != nil {
		return deleted, err
	}
	for _, entry := range transferEntries {
		if !entry.IsDir() {
			continue
		}
		metaPath := filepath.Join(s.transfersDir, entry.Name(), "meta.json")
		data, err := os.ReadFile(metaPath)
		if err != nil {
			continue
		}
		var meta domain.TransferMeta
		if err := json.Unmarshal(data, &meta); err != nil {
			continue
		}
		if now.Before(meta.ExpiresAt) {
			continue
		}
		_ = os.RemoveAll(filepath.Join(s.transfersDir, entry.Name()))
		deleted++
	}

	scanEntries, err := os.ReadDir(s.scansDir)
	if err != nil {
		return deleted, err
	}
	for _, entry := range scanEntries {
		if !entry.IsDir() {
			continue
		}
		metaPath := filepath.Join(s.scansDir, entry.Name(), "meta.json")
		data, err := os.ReadFile(metaPath)
		if err != nil {
			continue
		}
		var scan domain.ScanSession
		if err := json.Unmarshal(data, &scan); err != nil {
			continue
		}
		if now.Before(scan.ExpiresAt) {
			continue
		}
		_ = os.RemoveAll(filepath.Join(s.scansDir, entry.Name()))
		deleted++
	}

	return deleted, nil
}

func (s *Store) CreateScanSession(_ context.Context, scan domain.ScanSession) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.scanMetaPath(scan.ID)
	if _, err := os.Stat(path); err == nil {
		return storage.ErrConflict
	} else if err != nil && !os.IsNotExist(err) {
		return err
	}
	return writeJSONAtomic(path, scan)
}

func (s *Store) GetScanSession(_ context.Context, scanID string) (domain.ScanSession, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.scanMetaPath(scanID)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return domain.ScanSession{}, storage.ErrNotFound
		}
		return domain.ScanSession{}, err
	}
	var scan domain.ScanSession
	if err := json.Unmarshal(data, &scan); err != nil {
		return domain.ScanSession{}, err
	}
	return scan, nil
}

func (s *Store) DeleteScanSession(_ context.Context, scanID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.scanDir(scanID)
	if err := os.RemoveAll(path); err != nil {
		return err
	}
	return nil
}

func (s *Store) StoreScanChunk(_ context.Context, scanID string, chunkIndex int, data []byte) error {
	if chunkIndex < 0 {
		return storage.ErrInvalidRange
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	chunkPath := filepath.Join(s.scanChunksDir(scanID), strconv.Itoa(chunkIndex)+".bin")
	return writeFileAtomic(chunkPath, data, 0600)
}

func (s *Store) ListScanChunks(_ context.Context, scanID string) ([]int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	dir := s.scanChunksDir(scanID)
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, storage.ErrNotFound
		}
		return nil, err
	}
	var indexes []int
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".bin") {
			continue
		}
		raw := strings.TrimSuffix(entry.Name(), ".bin")
		value, err := strconv.Atoi(raw)
		if err != nil {
			continue
		}
		indexes = append(indexes, value)
	}
	sort.Ints(indexes)
	return indexes, nil
}

func (s *Store) LoadScanChunk(_ context.Context, scanID string, chunkIndex int) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	chunkPath := filepath.Join(s.scanChunksDir(scanID), strconv.Itoa(chunkIndex)+".bin")
	data, err := os.ReadFile(chunkPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, storage.ErrNotFound
		}
		return nil, err
	}
	return data, nil
}

func (s *Store) DeleteScanChunks(_ context.Context, scanID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	dir := s.scanChunksDir(scanID)
	if err := os.RemoveAll(dir); err != nil {
		return err
	}
	return nil
}

func (s *Store) CreateSession(_ context.Context, session domain.Session) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.sessionPath(session.ID)
	if _, err := os.Stat(path); err == nil {
		return storage.ErrConflict
	} else if err != nil && !os.IsNotExist(err) {
		return err
	}

	return writeJSONAtomic(path, session)
}

func (s *Store) GetSession(_ context.Context, sessionID string) (domain.Session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.sessionPath(sessionID)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return domain.Session{}, storage.ErrNotFound
		}
		return domain.Session{}, err
	}

	var session domain.Session
	if err := json.Unmarshal(data, &session); err != nil {
		return domain.Session{}, err
	}
	return session, nil
}

func (s *Store) UpdateSession(_ context.Context, session domain.Session) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.sessionPath(session.ID)
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return storage.ErrNotFound
		}
		return err
	}
	return writeJSONAtomic(path, session)
}

func (s *Store) DeleteSession(_ context.Context, sessionID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.sessionPath(sessionID)
	if err := os.Remove(path); err != nil {
		if os.IsNotExist(err) {
			return storage.ErrNotFound
		}
		return err
	}
	return nil
}

func (s *Store) SaveSessionAuthContext(_ context.Context, auth domain.SessionAuthContext) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.authPath(auth.SessionID, auth.ClaimID)
	return writeJSONAtomic(path, auth)
}

func (s *Store) GetSessionAuthContext(_ context.Context, sessionID string, claimID string) (domain.SessionAuthContext, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.authPath(sessionID, claimID)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return domain.SessionAuthContext{}, storage.ErrNotFound
		}
		return domain.SessionAuthContext{}, err
	}

	var auth domain.SessionAuthContext
	if err := json.Unmarshal(data, &auth); err != nil {
		return domain.SessionAuthContext{}, err
	}
	return auth, nil
}

func (s *Store) transferDir(transferID string) string {
	return filepath.Join(s.transfersDir, transferID)
}

func (s *Store) manifestPath(transferID string) string {
	return filepath.Join(s.transferDir(transferID), "manifest.json")
}

func (s *Store) dataPath(transferID string) string {
	return filepath.Join(s.transferDir(transferID), "data.bin")
}

func (s *Store) transferMetaPath(transferID string) string {
	return filepath.Join(s.transferDir(transferID), "meta.json")
}

func (s *Store) sessionPath(sessionID string) string {
	return filepath.Join(s.sessionsDir, sessionID+".json")
}

func (s *Store) authPath(sessionID string, claimID string) string {
	file := sessionID + "_" + claimID + ".json"
	return filepath.Join(s.authDir, file)
}

func (s *Store) scanDir(scanID string) string {
	return filepath.Join(s.scansDir, scanID)
}

func (s *Store) scanMetaPath(scanID string) string {
	return filepath.Join(s.scanDir(scanID), "meta.json")
}

func (s *Store) scanChunksDir(scanID string) string {
	return filepath.Join(s.scanDir(scanID), "chunks")
}

func (s *Store) deleteAuthContextsLocked(sessionID string) {
	entries, err := os.ReadDir(s.authDir)
	if err != nil {
		return
	}
	prefix := sessionID + "_"
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if !strings.HasPrefix(entry.Name(), prefix) {
			continue
		}
		_ = os.Remove(filepath.Join(s.authDir, entry.Name()))
	}
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

func writeJSONAtomic(path string, payload any) error {
	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, data, 0600)
}
