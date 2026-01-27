package token

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"sync"
	"time"
)

type TokenService interface {
	Issue(ctx context.Context, scope string, ttl time.Duration) (string, error)
	Validate(ctx context.Context, token string, scope string) (bool, error)
}

type MemoryService struct {
	mu     sync.Mutex
	tokens map[string]record
}

type record struct {
	scope     string
	expiresAt time.Time
}

func NewMemoryService() *MemoryService {
	return &MemoryService{
		tokens: map[string]record{},
	}
}

func (m *MemoryService) Issue(_ context.Context, scope string, ttl time.Duration) (string, error) {
	token, err := randomToken(32)
	if err != nil {
		return "", err
	}

	var expiresAt time.Time
	if ttl > 0 {
		expiresAt = time.Now().UTC().Add(ttl)
	}

	m.mu.Lock()
	m.tokens[token] = record{scope: scope, expiresAt: expiresAt}
	m.mu.Unlock()

	return token, nil
}

func (m *MemoryService) Validate(_ context.Context, token string, scope string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	entry, ok := m.tokens[token]
	if !ok {
		return false, nil
	}
	if entry.scope != scope {
		return false, nil
	}
	if !entry.expiresAt.IsZero() && time.Now().UTC().After(entry.expiresAt) {
		delete(m.tokens, token)
		return false, nil
	}
	return true, nil
}

func randomToken(size int) (string, error) {
	buf := make([]byte, size)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}
