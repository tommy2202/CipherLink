package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"universaldrop/internal/config"
	"universaldrop/internal/domain"
	"universaldrop/internal/storage"
	"universaldrop/internal/token"
)

func TestHealthz(t *testing.T) {
	server := NewServer(Dependencies{
		Config: config.Config{
			Address:               ":0",
			DataDir:               "data",
			RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:           config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
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
			Address:               ":0",
			DataDir:               "data",
			RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:           config.RateLimit{Max: 1, Window: time.Minute},
			RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
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
			Address:               ":0",
			DataDir:               "data",
			RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:           config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
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

func TestClaimTokenSingleUse(t *testing.T) {
	store := &stubStorage{}
	server := newSessionTestServer(store)

	createResp := createSession(t, server)
	claimBody := sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: base64.StdEncoding.EncodeToString([]byte("pubkey")),
	}

	firstRec := claimSession(t, server, claimBody)
	if firstRec.Code != http.StatusOK {
		t.Fatalf("expected claim 200 got %d", firstRec.Code)
	}

	secondRec := claimSession(t, server, claimBody)
	invalidRec := claimSession(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      "invalid-token",
		SenderLabel:     "Sender",
		SenderPubKeyB64: base64.StdEncoding.EncodeToString([]byte("pubkey")),
	})

	if secondRec.Code != invalidRec.Code {
		t.Fatalf("expected same status got %d and %d", secondRec.Code, invalidRec.Code)
	}
	if secondRec.Body.String() != invalidRec.Body.String() {
		t.Fatalf("expected indistinguishable response body")
	}
}

func TestClaimTokenExpiryBlocksClaim(t *testing.T) {
	store := &stubStorage{}
	server := newSessionTestServer(store)

	createResp := createSession(t, server)
	session, err := store.GetSession(context.Background(), createResp.SessionID)
	if err != nil {
		t.Fatalf("get session: %v", err)
	}
	session.ClaimTokenExpiresAt = time.Now().UTC().Add(-time.Minute)
	if err := store.UpdateSession(context.Background(), session); err != nil {
		t.Fatalf("update session: %v", err)
	}

	expiredRec := claimSession(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: base64.StdEncoding.EncodeToString([]byte("pubkey")),
	})

	invalidRec := claimSession(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      "invalid-token",
		SenderLabel:     "Sender",
		SenderPubKeyB64: base64.StdEncoding.EncodeToString([]byte("pubkey")),
	})

	if expiredRec.Code != invalidRec.Code {
		t.Fatalf("expected same status got %d and %d", expiredRec.Code, invalidRec.Code)
	}
	if expiredRec.Body.String() != invalidRec.Body.String() {
		t.Fatalf("expected indistinguishable response body")
	}
}

func newSessionTestServer(store *stubStorage) *Server {
	return NewServer(Dependencies{
		Config: config.Config{
			Address:               ":0",
			DataDir:               "data",
			RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:           config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
			ClaimTokenTTL:         config.DefaultClaimTokenTTL,
		},
		Store:  store,
		Tokens: token.NewMemoryService(),
	})
}

func createSession(t *testing.T, server *Server) sessionCreateResponse {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/session/create", nil)
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected create 200 got %d", rec.Code)
	}
	var payload sessionCreateResponse
	if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
		t.Fatalf("decode create response: %v", err)
	}
	return payload
}

func claimSession(t *testing.T, server *Server, reqBody sessionClaimRequest) *httptest.ResponseRecorder {
	t.Helper()
	payload, err := json.Marshal(reqBody)
	if err != nil {
		t.Fatalf("marshal claim request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/session/claim", bytes.NewBuffer(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	return rec
}

type stubStorage struct {
	manifest map[string][]byte
	sessions map[string]domain.Session
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

func (s *stubStorage) CreateSession(_ context.Context, session domain.Session) error {
	if s.sessions == nil {
		s.sessions = map[string]domain.Session{}
	}
	if _, exists := s.sessions[session.ID]; exists {
		return storage.ErrConflict
	}
	s.sessions[session.ID] = session
	return nil
}

func (s *stubStorage) GetSession(_ context.Context, sessionID string) (domain.Session, error) {
	if s.sessions == nil {
		return domain.Session{}, storage.ErrNotFound
	}
	session, ok := s.sessions[sessionID]
	if !ok {
		return domain.Session{}, storage.ErrNotFound
	}
	return session, nil
}

func (s *stubStorage) UpdateSession(_ context.Context, session domain.Session) error {
	if s.sessions == nil {
		return storage.ErrNotFound
	}
	if _, ok := s.sessions[session.ID]; !ok {
		return storage.ErrNotFound
	}
	s.sessions[session.ID] = session
	return nil
}

func (s *stubStorage) DeleteSession(_ context.Context, sessionID string) error {
	if s.sessions == nil {
		return storage.ErrNotFound
	}
	if _, ok := s.sessions[sessionID]; !ok {
		return storage.ErrNotFound
	}
	delete(s.sessions, sessionID)
	return nil
}
