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

	createResp := createSession(t, server)
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: base64.StdEncoding.EncodeToString([]byte("pubkey")),
	})
	approveResp := approveSession(t, server, sessionApproveRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Approve:   true,
	})
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}

	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             approveResp.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                10,
	})

	invalidRec := manifestRequestRecorder(t, server, createResp.SessionID, initResp.TransferID, "invalid-token")
	missingRec := manifestRequestRecorder(t, server, createResp.SessionID, "missing", approveResp.TransferToken)

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

func TestCannotInitTransferBeforeApproval(t *testing.T) {
	store := &stubStorage{}
	server := newSessionTestServer(store)

	createResp := createSession(t, server)
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: base64.StdEncoding.EncodeToString([]byte("pubkey")),
	})

	scope := transferScope(createResp.SessionID, claimResp.ClaimID)
	transferToken, err := server.tokens.Issue(context.Background(), scope, time.Minute)
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}

	rec := initTransferRecorder(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             transferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                10,
	})
	invalidRec := initTransferRecorder(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             "invalid-token",
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                10,
	})

	if rec.Code != invalidRec.Code {
		t.Fatalf("expected same status got %d and %d", rec.Code, invalidRec.Code)
	}
	if rec.Body.String() != invalidRec.Body.String() {
		t.Fatalf("expected indistinguishable response body")
	}
}

func TestTransferTokenScopeEnforced(t *testing.T) {
	store := &stubStorage{}
	server := newSessionTestServer(store)

	createResp := createSession(t, server)
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: base64.StdEncoding.EncodeToString([]byte("pubkey")),
	})

	approveResp := approveSession(t, server, sessionApproveRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Approve:   true,
	})
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}

	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             approveResp.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                10,
	})

	wrongToken, err := server.tokens.Issue(context.Background(), "transfer:session:other:claim:other", time.Minute)
	if err != nil {
		t.Fatalf("issue wrong token: %v", err)
	}

	wrongRec := manifestRequestRecorder(t, server, createResp.SessionID, initResp.TransferID, wrongToken)
	invalidRec := manifestRequestRecorder(t, server, createResp.SessionID, initResp.TransferID, "invalid-token")

	if wrongRec.Code != invalidRec.Code {
		t.Fatalf("expected same status got %d and %d", wrongRec.Code, invalidRec.Code)
	}
	if wrongRec.Body.String() != invalidRec.Body.String() {
		t.Fatalf("expected indistinguishable response body")
	}
}

func TestManifestDownloadReturnsIdenticalBytes(t *testing.T) {
	store := &stubStorage{}
	server := newSessionTestServer(store)

	createResp := createSession(t, server)
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: base64.StdEncoding.EncodeToString([]byte("pubkey")),
	})
	approveResp := approveSession(t, server, sessionApproveRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Approve:   true,
	})
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}

	manifest := []byte("ciphertext-manifest")
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             approveResp.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString(manifest),
		TotalBytes:                10,
	})

	downloaded := fetchManifest(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken)
	if !bytes.Equal(downloaded, manifest) {
		t.Fatalf("manifest bytes mismatch")
	}
}

func TestWrongTokenVsMissingTransferIndistinguishable(t *testing.T) {
	store := &stubStorage{}
	server := newSessionTestServer(store)

	createResp := createSession(t, server)
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: base64.StdEncoding.EncodeToString([]byte("pubkey")),
	})
	approveResp := approveSession(t, server, sessionApproveRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Approve:   true,
	})
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}

	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             approveResp.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                10,
	})

	missingRec := manifestRequestRecorder(t, server, createResp.SessionID, "missing", approveResp.TransferToken)
	wrongRec := manifestRequestRecorder(t, server, createResp.SessionID, initResp.TransferID, "invalid-token")

	if missingRec.Code != wrongRec.Code {
		t.Fatalf("expected same status got %d and %d", missingRec.Code, wrongRec.Code)
	}
	if missingRec.Body.String() != wrongRec.Body.String() {
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
			TransferTokenTTL:      config.DefaultTransferTokenTTL,
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

func claimSessionSuccess(t *testing.T, server *Server, reqBody sessionClaimRequest) sessionClaimResponse {
	t.Helper()
	rec := claimSession(t, server, reqBody)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected claim 200 got %d", rec.Code)
	}
	var payload sessionClaimResponse
	if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
		t.Fatalf("decode claim response: %v", err)
	}
	return payload
}

func approveSession(t *testing.T, server *Server, reqBody sessionApproveRequest) sessionApproveResponse {
	t.Helper()
	payload, err := json.Marshal(reqBody)
	if err != nil {
		t.Fatalf("marshal approve request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/session/approve", bytes.NewBuffer(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected approve 200 got %d", rec.Code)
	}
	var resp sessionApproveResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode approve response: %v", err)
	}
	return resp
}

func initTransfer(t *testing.T, server *Server, reqBody transferInitRequest) transferInitResponse {
	t.Helper()
	payload, err := json.Marshal(reqBody)
	if err != nil {
		t.Fatalf("marshal init request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/transfer/init", bytes.NewBuffer(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected init 200 got %d", rec.Code)
	}
	var resp transferInitResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode init response: %v", err)
	}
	return resp
}

func initTransferRecorder(t *testing.T, server *Server, reqBody transferInitRequest) *httptest.ResponseRecorder {
	t.Helper()
	payload, err := json.Marshal(reqBody)
	if err != nil {
		t.Fatalf("marshal init request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/transfer/init", bytes.NewBuffer(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	return rec
}

func fetchManifest(t *testing.T, server *Server, sessionID string, transferID string, token string) []byte {
	t.Helper()
	rec := manifestRequestRecorder(t, server, sessionID, transferID, token)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected manifest 200 got %d", rec.Code)
	}
	return rec.Body.Bytes()
}

func manifestRequestRecorder(t *testing.T, server *Server, sessionID string, transferID string, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/v1/transfer/manifest?session_id="+sessionID+"&transfer_id="+transferID, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	return rec
}

type stubStorage struct {
	manifest map[string][]byte
	sessions map[string]domain.Session
	auth     map[string]domain.SessionAuthContext
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

func (s *stubStorage) SaveSessionAuthContext(_ context.Context, auth domain.SessionAuthContext) error {
	if s.auth == nil {
		s.auth = map[string]domain.SessionAuthContext{}
	}
	key := auth.SessionID + ":" + auth.ClaimID
	s.auth[key] = auth
	return nil
}

func (s *stubStorage) GetSessionAuthContext(_ context.Context, sessionID string, claimID string) (domain.SessionAuthContext, error) {
	if s.auth == nil {
		return domain.SessionAuthContext{}, storage.ErrNotFound
	}
	key := sessionID + ":" + claimID
	auth, ok := s.auth[key]
	if !ok {
		return domain.SessionAuthContext{}, storage.ErrNotFound
	}
	return auth, nil
}
