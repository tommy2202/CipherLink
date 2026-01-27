package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"universaldrop/internal/config"
	"universaldrop/internal/storage"
	"universaldrop/internal/token"
)

func TestHealthz(t *testing.T) {
	server := NewServer(Dependencies{
		Config: config.Config{
			Address:         ":0",
			DataDir:         "data",
			RateLimitHealth: config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:     config.RateLimit{Max: 100, Window: time.Minute},
		},
		Store:  &stubStorage{},
		Tokens: token.NewMemoryService(),
	})

	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 got %d", rec.Code)
	}

	var payload map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if payload["ok"] != true {
		t.Fatalf("expected ok true")
	}
	if payload["version"] != "0.1" {
		t.Fatalf("expected version 0.1 got %v", payload["version"])
	}
}

func TestRateLimitTriggers(t *testing.T) {
	server := NewServer(Dependencies{
		Config: config.Config{
			Address:         ":0",
			DataDir:         "data",
			RateLimitHealth: config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:     config.RateLimit{Max: 1, Window: time.Minute},
		},
		Store:  &stubStorage{},
		Tokens: token.NewMemoryService(),
	})

	req := httptest.NewRequest(http.MethodGet, "/v1/ping", nil)
	req.Header.Set("X-Forwarded-For", "10.0.0.1")

	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 got %d", rec.Code)
	}

	rec2 := httptest.NewRecorder()
	server.Router.ServeHTTP(rec2, req)
	if rec2.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 got %d", rec2.Code)
	}
}

func TestIndistinguishableErrors(t *testing.T) {
	store := &stubStorage{}
	tokens := token.NewMemoryService()
	server := NewServer(Dependencies{
		Config: config.Config{
			Address:         ":0",
			DataDir:         "data",
			RateLimitHealth: config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:     config.RateLimit{Max: 100, Window: time.Minute},
		},
		Store:  store,
		Tokens: tokens,
	})

	invalidReq := httptest.NewRequest(http.MethodGet, "/v1/transfers/alpha/manifest", nil)
	invalidReq.Header.Set("Authorization", "Bearer invalid-token")
	invalidRec := httptest.NewRecorder()
	server.Router.ServeHTTP(invalidRec, invalidReq)

	validToken, err := tokens.Issue(context.Background(), transferReadScope, time.Minute)
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}
	missingReq := httptest.NewRequest(http.MethodGet, "/v1/transfers/alpha/manifest", nil)
	missingReq.Header.Set("Authorization", "Bearer "+validToken)
	missingRec := httptest.NewRecorder()
	server.Router.ServeHTTP(missingRec, missingReq)

	if invalidRec.Code != missingRec.Code {
		t.Fatalf("expected same status got %d and %d", invalidRec.Code, missingRec.Code)
	}
	if invalidRec.Body.String() != missingRec.Body.String() {
		t.Fatalf("expected same response body")
	}
}

type stubStorage struct {
	manifest map[string][]byte
}

func (s *stubStorage) SaveManifest(_ context.Context, transferID string, manifest []byte) error {
	if s.manifest == nil {
		s.manifest = map[string][]byte{}
	}
	s.manifest[transferID] = append([]byte(nil), manifest...)
	return nil
}

func (s *stubStorage) LoadManifest(_ context.Context, transferID string) ([]byte, error) {
	if s.manifest == nil {
		return nil, storage.ErrNotFound
	}
	data, ok := s.manifest[transferID]
	if !ok {
		return nil, storage.ErrNotFound
	}
	return append([]byte(nil), data...), nil
}

func (s *stubStorage) WriteChunk(_ context.Context, _ string, _ int64, _ []byte) error {
	return nil
}

func (s *stubStorage) ReadRange(_ context.Context, _ string, _ int64, _ int64) ([]byte, error) {
	return nil, storage.ErrNotFound
}

func (s *stubStorage) DeleteTransfer(_ context.Context, _ string) error {
	return nil
}

func (s *stubStorage) SweepExpired(_ context.Context, _ time.Time) (int, error) {
	return 0, nil
}
