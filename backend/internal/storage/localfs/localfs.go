package localfs

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	"universaldrop/internal/storage"
)

type Store struct {
	mu           sync.Mutex
	root         string
	transfersDir string
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

	return &Store{
		root:         root,
		transfersDir: transfersDir,
	}, nil
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

func (s *Store) SweepExpired(_ context.Context, _ time.Time) (int, error) {
	return 0, nil
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
