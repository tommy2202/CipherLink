package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"universaldrop/internal/auth"
	"universaldrop/internal/clock"
	"universaldrop/internal/config"
	"universaldrop/internal/domain"
	"universaldrop/internal/scanner"
	"universaldrop/internal/storage"
	"universaldrop/internal/sweeper"

	"golang.org/x/crypto/chacha20poly1305"
)

func newTestCapabilities() *auth.Service {
	secret := bytes.Repeat([]byte{0x42}, 32)
	clk := clock.RealClock{}
	return auth.NewService(secret, clk, auth.NewMemoryRevocationStore(clk))
}

func TestHealthz(t *testing.T) {
	server := NewServer(Dependencies{
		Config: config.Config{
			Address:               ":0",
			DataDir:               "data",
			RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:           config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
			MaxScanBytes:          config.DefaultMaxScanBytes,
			MaxScanDuration:       config.DefaultMaxScanDuration,
		},
		Store:        &stubStorage{},
		Capabilities: newTestCapabilities(),
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
}

func TestRateLimitTriggers(t *testing.T) {
	server := NewServer(Dependencies{
		Config: config.Config{
			Address:               ":0",
			DataDir:               "data",
			RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:           config.RateLimit{Max: 1, Window: time.Minute},
			RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
			MaxScanBytes:          config.DefaultMaxScanBytes,
			MaxScanDuration:       config.DefaultMaxScanDuration,
		},
		Store:        &stubStorage{},
		Capabilities: newTestCapabilities(),
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

func TestReadyzReportsSweeperOkAfterSweep(t *testing.T) {
	store := &stubStorage{}
	clk := clock.NewFake(time.Date(2025, 2, 1, 12, 0, 0, 0, time.UTC))
	liveness := sweeper.NewLiveness()
	sweep := sweeper.New(store, clk, time.Second, log.New(io.Discard, "", 0), liveness, nil)
	sweep.SweepOnce(context.Background())

	server := NewServer(Dependencies{
		Config: config.Config{
			Address:               ":0",
			DataDir:               "data",
			RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:           config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
			MaxScanBytes:          config.DefaultMaxScanBytes,
			MaxScanDuration:       config.DefaultMaxScanDuration,
		},
		Store:         store,
		Capabilities:  newTestCapabilities(),
		Clock:         clk,
		SweeperStatus: liveness,
	})

	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
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
	if payload["storage_ok"] != true {
		t.Fatalf("expected storage_ok true")
	}
	if payload["sweeper_ok"] != true {
		t.Fatalf("expected sweeper_ok true")
	}
}

func TestMetricszReturnsExpectedKeys(t *testing.T) {
	server := NewServer(Dependencies{
		Config: config.Config{
			Address:               ":0",
			DataDir:               "data",
			RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:           config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
			MaxScanBytes:          config.DefaultMaxScanBytes,
			MaxScanDuration:       config.DefaultMaxScanDuration,
		},
		Store:        &stubStorage{},
		Capabilities: newTestCapabilities(),
	})

	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metricsz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 got %d", rec.Code)
	}

	var payload map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	expected := map[string]bool{
		"sessions_created_total":        true,
		"transfers_started_total":       true,
		"transfers_completed_total":     true,
		"transfers_expired_total":       true,
		"sweeper_runs_total":            true,
		"relay_ice_config_issued_total": true,
	}
	if len(payload) != len(expected) {
		t.Fatalf("expected %d keys got %d", len(expected), len(payload))
	}
	for key := range expected {
		if _, ok := payload[key]; !ok {
			t.Fatalf("missing key %s", key)
		}
	}
	for key, value := range payload {
		if !expected[key] {
			t.Fatalf("unexpected key %s", key)
		}
		if _, ok := value.(float64); !ok {
			t.Fatalf("expected numeric value for %s", key)
		}
	}
}

func TestTransferRoutesSkipTimeoutMiddleware(t *testing.T) {
	originalTimeout := timeoutMiddleware
	timeoutMiddleware = func(_ time.Duration) func(http.Handler) http.Handler {
		return func(next http.Handler) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("X-Timeout-Applied", "true")
				next.ServeHTTP(w, r)
			})
		}
	}
	t.Cleanup(func() {
		timeoutMiddleware = originalTimeout
	})

	server := NewServer(Dependencies{
		Config: config.Config{
			Address:               ":0",
			DataDir:               "data",
			RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:           config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
			MaxScanBytes:          config.DefaultMaxScanBytes,
			MaxScanDuration:       config.DefaultMaxScanDuration,
		},
		Store:        &stubStorage{},
		Capabilities: newTestCapabilities(),
	})

	pingRec := httptest.NewRecorder()
	server.Router.ServeHTTP(pingRec, httptest.NewRequest(http.MethodGet, "/v1/ping", nil))
	if pingRec.Header().Get("X-Timeout-Applied") == "" {
		t.Fatalf("expected timeout middleware on non-transfer route")
	}

	chunkRec := httptest.NewRecorder()
	chunkReq := httptest.NewRequest(http.MethodPut, "/v1/transfer/chunk", bytes.NewBuffer([]byte("data")))
	server.Router.ServeHTTP(chunkRec, chunkReq)
	if chunkRec.Header().Get("X-Timeout-Applied") != "" {
		t.Fatalf("expected no timeout middleware on transfer upload")
	}

	downloadRec := httptest.NewRecorder()
	downloadReq := httptest.NewRequest(http.MethodGet, "/v1/transfer/download?session_id=missing&transfer_id=missing", nil)
	server.Router.ServeHTTP(downloadRec, downloadReq)
	if downloadRec.Header().Get("X-Timeout-Applied") != "" {
		t.Fatalf("expected no timeout middleware on transfer download")
	}
}

func TestQuotaBlocksExtraTransfers(t *testing.T) {
	store := &stubStorage{}
	server := NewServer(Dependencies{
		Config: config.Config{
			Address:               ":0",
			DataDir:               "data",
			RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:           config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
			ClaimTokenTTL:         config.DefaultClaimTokenTTL,
			TransferTokenTTL:      config.DefaultTransferTokenTTL,
			MaxScanBytes:          config.DefaultMaxScanBytes,
			MaxScanDuration:       config.DefaultMaxScanDuration,
			Quotas: config.QuotaConfig{
				TransfersPerDaySession: 1,
			},
		},
		Store:        store,
		Capabilities: newTestCapabilities(),
		Scanner:      scanner.UnavailableScanner{},
	})

	createResp := createSession(t, server)
	senderPubKey := base64.StdEncoding.EncodeToString([]byte("pubkey"))
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: senderPubKey,
	})
	commitSAS(t, server, createResp.SessionID, claimResp.ClaimID, "sender")
	commitSAS(t, server, createResp.SessionID, claimResp.ClaimID, "receiver")
	_ = approveSession(t, server, sessionApproveRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Approve:   true,
	}, createResp.ReceiverToken)

	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                4,
	})

	rec := initTransferRecorder(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest2")),
		TotalBytes:                4,
	})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 got %d", rec.Code)
	}
}

func TestUploadThrottleDelaysResponse(t *testing.T) {
	store := &stubStorage{}
	server := NewServer(Dependencies{
		Config: config.Config{
			Address:               ":0",
			DataDir:               "data",
			RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:           config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
			ClaimTokenTTL:         config.DefaultClaimTokenTTL,
			TransferTokenTTL:      config.DefaultTransferTokenTTL,
			MaxScanBytes:          config.DefaultMaxScanBytes,
			MaxScanDuration:       config.DefaultMaxScanDuration,
			Throttles: config.ThrottleConfig{
				TransferBandwidthCapBps: 50,
			},
		},
		Store:        store,
		Capabilities: newTestCapabilities(),
		Scanner:      scanner.UnavailableScanner{},
	})

	createResp := createSession(t, server)
	senderPubKey := base64.StdEncoding.EncodeToString([]byte("pubkey"))
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: senderPubKey,
	})
	commitSAS(t, server, createResp.SessionID, claimResp.ClaimID, "sender")
	commitSAS(t, server, createResp.SessionID, claimResp.ClaimID, "receiver")
	_ = approveSession(t, server, sessionApproveRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Approve:   true,
	}, createResp.ReceiverToken)
	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                10,
	})

	data := bytes.Repeat([]byte("a"), 10)
	req := httptest.NewRequest(http.MethodPut, "/v1/transfer/chunk", bytes.NewBuffer(data))
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Authorization", "Bearer "+initResp.UploadToken)
	req.Header.Set("session_id", createResp.SessionID)
	req.Header.Set("transfer_id", initResp.TransferID)
	req.Header.Set("offset", "0")
	rec := httptest.NewRecorder()
	start := time.Now()
	server.Router.ServeHTTP(rec, req)
	elapsed := time.Since(start)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected chunk 200 got %d", rec.Code)
	}
	if elapsed < 150*time.Millisecond {
		t.Fatalf("expected throttle delay, got %v", elapsed)
	}
}

func TestRelayQuotaBlocksExtraIssuance(t *testing.T) {
	store := &stubStorage{}
	server := NewServer(Dependencies{
		Config: config.Config{
			Address:               ":0",
			DataDir:               "data",
			RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:           config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
			ClaimTokenTTL:         config.DefaultClaimTokenTTL,
			TransferTokenTTL:      config.DefaultTransferTokenTTL,
			MaxScanBytes:          config.DefaultMaxScanBytes,
			MaxScanDuration:       config.DefaultMaxScanDuration,
			TURNURLs:              []string{"turn:relay.example"},
			TURNSharedSecret:      []byte("secret"),
			Quotas: config.QuotaConfig{
				RelayPerIdentityPerDay: 1,
			},
		},
		Store:        store,
		Capabilities: newTestCapabilities(),
		Scanner:      scanner.UnavailableScanner{},
	})

	createResp := createSession(t, server)
	senderPubKey := base64.StdEncoding.EncodeToString([]byte("pubkey"))
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: senderPubKey,
	})
	commitSAS(t, server, createResp.SessionID, claimResp.ClaimID, "sender")
	commitSAS(t, server, createResp.SessionID, claimResp.ClaimID, "receiver")
	_ = approveSession(t, server, sessionApproveRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Approve:   true,
	}, createResp.ReceiverToken)
	tokenValue := approveResp.P2PToken
	if tokenValue == "" {
		t.Fatalf("expected p2p token")
	}

	first := p2pIceConfigRecorder(t, server, tokenValue, createResp.SessionID, claimResp.ClaimID, "relay")
	if first.Code != http.StatusOK {
		t.Fatalf("expected 200 got %d", first.Code)
	}
	second := p2pIceConfigRecorder(t, server, tokenValue, createResp.SessionID, claimResp.ClaimID, "relay")
	if second.Code != http.StatusNotFound {
		t.Fatalf("expected 404 got %d", second.Code)
	}
}

func TestCreateSessionRequiresReceiverPubKey(t *testing.T) {
	server := newSessionTestServer(&stubStorage{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/session/create", nil)
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected create 400 got %d", rec.Code)
	}
	var payload map[string]string
	if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
		t.Fatalf("decode create response: %v", err)
	}
	if payload["error"] != "invalid_request" {
		t.Fatalf("expected invalid_request error")
	}
}

func TestCreateSessionRejectsInvalidReceiverPubKey(t *testing.T) {
	server := newSessionTestServer(&stubStorage{})

	tests := []struct {
		name              string
		receiverPubKeyB64 string
	}{
		{
			name:              "malformed_base64",
			receiverPubKeyB64: "not*base64",
		},
		{
			name:              "wrong_length",
			receiverPubKeyB64: base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x01}, 31)),
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			payload, err := json.Marshal(sessionCreateRequest{ReceiverPubKeyB64: tc.receiverPubKeyB64})
			if err != nil {
				t.Fatalf("marshal create request: %v", err)
			}
			req := httptest.NewRequest(http.MethodPost, "/v1/session/create", bytes.NewBuffer(payload))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			server.Router.ServeHTTP(rec, req)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("expected create 400 got %d", rec.Code)
			}
			var body map[string]string
			if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
				t.Fatalf("decode create response: %v", err)
			}
			if body["error"] != "invalid_request" {
				t.Fatalf("expected invalid_request error")
			}
		})
	}
}

func TestApproveRequiresSAS(t *testing.T) {
	store := &stubStorage{}
	server := newSessionTestServer(store)

	createResp := createSession(t, server)
	senderPubKey := base64.StdEncoding.EncodeToString([]byte("pubkey"))
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: senderPubKey,
	})

	rec := approveSessionRecorder(t, server, sessionApproveRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Approve:   true,
	}, createResp.ReceiverToken)
	if rec.Code != http.StatusConflict {
		t.Fatalf("expected approve 409 got %d", rec.Code)
	}
	var payload map[string]string
	if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
		t.Fatalf("decode approve response: %v", err)
	}
	if payload["error"] != "sas_required" {
		t.Fatalf("expected sas_required error")
	}
}

func TestApproveSucceedsAfterSASConfirmed(t *testing.T) {
	store := &stubStorage{}
	server := newSessionTestServer(store)

	createResp := createSession(t, server)
	senderPubKey := base64.StdEncoding.EncodeToString([]byte("pubkey"))
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: senderPubKey,
	})

	commitSAS(t, server, createResp.SessionID, claimResp.ClaimID, "sender")
	commitSAS(t, server, createResp.SessionID, claimResp.ClaimID, "receiver")

	rec := approveSessionRecorder(t, server, sessionApproveRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Approve:   true,
	}, createResp.ReceiverToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected approve 200 got %d", rec.Code)
	}
	var resp sessionApproveResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode approve response: %v", err)
	}
	if resp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}
}

func TestP2PSignalingRejectsWithoutSAS(t *testing.T) {
	store := &stubStorage{}
	server := newSessionTestServer(store)

	createResp := createSession(t, server)
	senderPubKey := base64.StdEncoding.EncodeToString([]byte("pubkey"))
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: senderPubKey,
	})

	session, err := store.GetSession(context.Background(), createResp.SessionID)
	if err != nil {
		t.Fatalf("get session: %v", err)
	}
	for i, claim := range session.Claims {
		if claim.ID != claimResp.ClaimID {
			continue
		}
		claim.Status = domain.SessionClaimApproved
		claim.UpdatedAt = time.Now().UTC()
		session.Claims[i] = claim
	}
	if err := store.UpdateSession(context.Background(), session); err != nil {
		t.Fatalf("update session: %v", err)
	}
	if err := store.SaveSessionAuthContext(context.Background(), domain.SessionAuthContext{
		SessionID:         session.ID,
		ClaimID:           claimResp.ClaimID,
		SenderPubKeyB64:   senderPubKey,
		ReceiverPubKeyB64: session.ReceiverPubKeyB64,
		ApprovedAt:        time.Now().UTC(),
	}); err != nil {
		t.Fatalf("save auth: %v", err)
	}
	tokenValue := issueCapabilityToken(t, server, auth.IssueSpec{
		Scope:             auth.ScopeTransferSignal,
		TTL:               time.Minute,
		SessionID:         session.ID,
		ClaimID:           claimResp.ClaimID,
		PeerID:            senderPubKey,
		SenderPubKeyB64:   senderPubKey,
		ReceiverPubKeyB64: session.ReceiverPubKeyB64,
		Visibility:        auth.VisibilityE2E,
		AllowedRoutes:     []string{"/v1/p2p/offer", "/v1/p2p/answer", "/v1/p2p/ice", "/v1/p2p/poll"},
	})

	rec := p2pOfferRecorder(t, server, tokenValue, p2pOfferRequest{
		SessionID: session.ID,
		ClaimID:   claimResp.ClaimID,
		SDP:       "v=0",
	})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 got %d", rec.Code)
	}
}

func TestP2PSignalingRejectsWithoutAuth(t *testing.T) {
	store := &stubStorage{}
	server := newSessionTestServer(store)

	createResp := createSession(t, server)
	senderPubKey := base64.StdEncoding.EncodeToString([]byte("pubkey"))
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: senderPubKey,
	})

	commitSAS(t, server, createResp.SessionID, claimResp.ClaimID, "sender")
	commitSAS(t, server, createResp.SessionID, claimResp.ClaimID, "receiver")

	approveSession(t, server, sessionApproveRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Approve:   true,
	}, createResp.ReceiverToken)

	rec := p2pOfferRecorder(t, server, "", p2pOfferRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		SDP:       "v=0",
	})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 got %d", rec.Code)
	}
}

func TestP2PIceConfigRelayRequiresTurn(t *testing.T) {
	store := &stubStorage{}
	server := newSessionTestServer(store)

	createResp := createSession(t, server)
	senderPubKey := base64.StdEncoding.EncodeToString([]byte("pubkey"))
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: senderPubKey,
	})

	commitSAS(t, server, createResp.SessionID, claimResp.ClaimID, "sender")
	commitSAS(t, server, createResp.SessionID, claimResp.ClaimID, "receiver")

	_ = approveSession(t, server, sessionApproveRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Approve:   true,
	}, createResp.ReceiverToken)

	rec := p2pIceConfigRecorder(t, server, approveResp.P2PToken, createResp.SessionID, claimResp.ClaimID, "relay")
	if rec.Code != http.StatusConflict {
		t.Fatalf("expected 409 got %d", rec.Code)
	}
	var payload map[string]string
	if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if payload["error"] != "turn_unavailable" {
		t.Fatalf("expected turn_unavailable")
	}
}

func TestP2PIceConfigRelayOmitsStunWhenTurnAvailable(t *testing.T) {
	store := &stubStorage{}
	server := NewServer(Dependencies{
		Config: config.Config{
			Address:               ":0",
			DataDir:               "data",
			RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:           config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
			ClaimTokenTTL:         config.DefaultClaimTokenTTL,
			TransferTokenTTL:      config.DefaultTransferTokenTTL,
			MaxScanBytes:          config.DefaultMaxScanBytes,
			MaxScanDuration:       config.DefaultMaxScanDuration,
			STUNURLs:              []string{"stun:stun.example"},
			TURNURLs:              []string{"turn:relay.example?transport=udp"},
			TURNSharedSecret:      []byte("secret"),
		},
		Store:        store,
		Capabilities: newTestCapabilities(),
		Scanner:      scanner.UnavailableScanner{},
	})

	createResp := createSession(t, server)
	senderPubKey := base64.StdEncoding.EncodeToString([]byte("pubkey"))
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: senderPubKey,
	})
	approveResp := approveSession(t, server, sessionApproveRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Approve:   true,
	}, createResp.ReceiverToken)

	rec := p2pIceConfigRecorder(t, server, approveResp.P2PToken, createResp.SessionID, claimResp.ClaimID, "relay")
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 got %d", rec.Code)
	}
	var resp p2pIceConfigResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode relay ice config: %v", err)
	}
	if len(resp.STUNURLs) != 0 {
		t.Fatalf("expected no stun urls, got %v", resp.STUNURLs)
	}
	if len(resp.TURNURLs) == 0 {
		t.Fatalf("expected turn urls to be present")
	}
	for _, url := range resp.TURNURLs {
		if !strings.HasPrefix(url, "turn:") && !strings.HasPrefix(url, "turns:") {
			t.Fatalf("expected turn url, got %q", url)
		}
	}
}

func TestIndistinguishableErrors(t *testing.T) {
	store := &stubStorage{}
	server := NewServer(Dependencies{
		Config: config.Config{
			Address:               ":0",
			DataDir:               "data",
			RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitV1:           config.RateLimit{Max: 100, Window: time.Minute},
			RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
			MaxScanBytes:          config.DefaultMaxScanBytes,
			MaxScanDuration:       config.DefaultMaxScanDuration,
		},
		Store:        store,
		Capabilities: newTestCapabilities(),
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
	}, createResp.ReceiverToken)
	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                10,
	})
	receiverToken := receiverTransferToken(t, server, createResp.SessionID, claimResp.ClaimID)

	invalidRec := manifestRequestRecorder(t, server, createResp.SessionID, initResp.TransferID, "invalid-token")
	missingRec := manifestRequestRecorder(t, server, createResp.SessionID, "missing", receiverToken)

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

	transferToken := issueCapabilityToken(t, server, auth.IssueSpec{
		Scope:             auth.ScopeTransferInit,
		TTL:               time.Minute,
		SessionID:         createResp.SessionID,
		ClaimID:           claimResp.ClaimID,
		PeerID:            senderPubKey,
		SenderPubKeyB64:   senderPubKey,
		ReceiverPubKeyB64: createResp.ReceiverPubKeyB64,
		Visibility:        auth.VisibilityE2E,
		AllowedRoutes:     []string{"/v1/transfer/init"},
		SingleUse:         true,
	})

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
	}, createResp.ReceiverToken)
	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                10,
	})
	wrongToken := issueCapabilityToken(t, server, auth.IssueSpec{
		Scope:             auth.ScopeTransferReceive,
		TTL:               time.Minute,
		SessionID:         "other",
		ClaimID:           "other",
		PeerID:            "other",
		SenderPubKeyB64:   "other",
		ReceiverPubKeyB64: "other",
		Visibility:        auth.VisibilityE2E,
		AllowedRoutes:     []string{"/v1/transfer/manifest"},
	})

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
	}, createResp.ReceiverToken)
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}

	manifest := []byte("ciphertext-manifest")
	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString(manifest),
		TotalBytes:                10,
	})
	receiverToken := receiverTransferToken(t, server, createResp.SessionID, claimResp.ClaimID)
	downloaded := fetchManifest(t, server, createResp.SessionID, initResp.TransferID, receiverToken)
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
	}, createResp.ReceiverToken)
	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                10,
	})
	receiverToken := receiverTransferToken(t, server, createResp.SessionID, claimResp.ClaimID)
	missingRec := manifestRequestRecorder(t, server, createResp.SessionID, "missing", receiverToken)
	wrongRec := manifestRequestRecorder(t, server, createResp.SessionID, initResp.TransferID, "invalid-token")

	if missingRec.Code != wrongRec.Code {
		t.Fatalf("expected same status got %d and %d", missingRec.Code, wrongRec.Code)
	}
	if missingRec.Body.String() != wrongRec.Body.String() {
		t.Fatalf("expected indistinguishable response body")
	}
}

func TestRangeResumeWorks(t *testing.T) {
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
	}, createResp.ReceiverToken)
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}
	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                8,
	})

	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 0, []byte("abcd"))
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 4, []byte("efgh"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken)

	receiverToken := receiverTransferToken(t, server, createResp.SessionID, claimResp.ClaimID)
	downloadResp := mintDownloadToken(t, server, downloadTokenRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: receiverToken,
	})
	first := downloadRange(t, server, createResp.SessionID, initResp.TransferID, downloadResp.DownloadToken, 0, 3)
	if string(first) != "abcd" {
		t.Fatalf("expected first range to match")
	}
	second := downloadRange(t, server, createResp.SessionID, initResp.TransferID, downloadResp.DownloadToken, 4, 7)
	if string(second) != "efgh" {
		t.Fatalf("expected second range to match")
	}
}

func TestDownloadRangeContentRangeHeader(t *testing.T) {
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
	}, createResp.ReceiverToken)
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}

	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                8,
	})
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 0, []byte("abcd"))
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 4, []byte("efgh"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken)

	receiverToken := receiverTransferToken(t, server, createResp.SessionID, claimResp.ClaimID)
	downloadResp := mintDownloadToken(t, server, downloadTokenRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: receiverToken,
	})
	rec := downloadRangeRecorder(t, server, createResp.SessionID, initResp.TransferID, downloadResp.DownloadToken, 0, 3)
	if rec.Code != http.StatusPartialContent {
		t.Fatalf("expected 206 got %d", rec.Code)
	}
	if rec.Header().Get("Content-Range") != "bytes 0-3/8" {
		t.Fatalf("unexpected content range: %s", rec.Header().Get("Content-Range"))
	}
	if rec.Header().Get("Content-Length") != "4" {
		t.Fatalf("unexpected content length: %s", rec.Header().Get("Content-Length"))
	}
}

func TestChunkRetryIdempotent(t *testing.T) {
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
	}, createResp.ReceiverToken)
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}

	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                4,
	})

	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 0, []byte("data"))
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 0, []byte("data"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken)

	receiverToken := receiverTransferToken(t, server, createResp.SessionID, claimResp.ClaimID)
	downloadResp := mintDownloadToken(t, server, downloadTokenRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: receiverToken,
	})
	downloaded := downloadRange(t, server, createResp.SessionID, initResp.TransferID, downloadResp.DownloadToken, 0, 3)
	if string(downloaded) != "data" {
		t.Fatalf("expected data after retry")
	}
}

func TestChunkConflictRejected(t *testing.T) {
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
	}, createResp.ReceiverToken)
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}

	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                4,
	})

	rec := uploadChunkRecorder(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 0, []byte("data"))
	if rec.Code != http.StatusOK {
		t.Fatalf("expected chunk 200 got %d", rec.Code)
	}
	rec = uploadChunkRecorder(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 0, []byte("data"))
	if rec.Code != http.StatusOK {
		t.Fatalf("expected retry 200 got %d", rec.Code)
	}
	rec = uploadChunkRecorder(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 0, []byte("diff"))
	if rec.Code != http.StatusConflict {
		t.Fatalf("expected conflict 409 got %d", rec.Code)
	}
	var resp map[string]string
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode conflict response: %v", err)
	}
	if resp["error"] != "chunk_conflict" {
		t.Fatalf("expected chunk_conflict error got %q", resp["error"])
	}
}

func TestReceiptDeletesTransferArtifacts(t *testing.T) {
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
	}, createResp.ReceiverToken)
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}
	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                4,
	})
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 0, []byte("data"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken)
	receiverToken := receiverTransferToken(t, server, createResp.SessionID, claimResp.ClaimID)
	receiptTransfer(t, server, transferReceiptRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: receiverToken,
		Status:        "complete",
	})

	missingRec := manifestRequestRecorder(t, server, createResp.SessionID, "missing", receiverToken)
	deletedRec := manifestRequestRecorder(t, server, createResp.SessionID, initResp.TransferID, receiverToken)
	if missingRec.Code != deletedRec.Code {
		t.Fatalf("expected same status got %d and %d", missingRec.Code, deletedRec.Code)
	}
	if missingRec.Body.String() != deletedRec.Body.String() {
		t.Fatalf("expected indistinguishable response body")
	}
}

func TestSmallPayloadLifecycle(t *testing.T) {
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
	}, createResp.ReceiverToken)
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}

	manifest := []byte("manifest-cipher")
	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString(manifest),
		TotalBytes:                5,
	})

	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 0, []byte("hello"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken)

	receiverToken := receiverTransferToken(t, server, createResp.SessionID, claimResp.ClaimID)
	downloadedManifest := fetchManifest(t, server, createResp.SessionID, initResp.TransferID, receiverToken)
	if !bytes.Equal(downloadedManifest, manifest) {
		t.Fatalf("expected manifest to match")
	}

	downloadResp := mintDownloadToken(t, server, downloadTokenRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: receiverToken,
	})
	payload := downloadRange(t, server, createResp.SessionID, initResp.TransferID, downloadResp.DownloadToken, 0, 4)
	if string(payload) != "hello" {
		t.Fatalf("expected payload to match")
	}

	receiptTransfer(t, server, transferReceiptRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: receiverToken,
		Status:        "complete",
	})

	missingRec := manifestRequestRecorder(t, server, createResp.SessionID, "missing", receiverToken)
	deletedRec := manifestRequestRecorder(t, server, createResp.SessionID, initResp.TransferID, receiverToken)
	if missingRec.Code != deletedRec.Code {
		t.Fatalf("expected same status got %d and %d", missingRec.Code, deletedRec.Code)
	}
}

func TestScannerUnavailableReturnsUnavailable(t *testing.T) {
	store := &stubStorage{}
	server := newSessionTestServer(store)

	createResp := createSession(t, server)
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: base64.StdEncoding.EncodeToString([]byte("pubkey")),
	})
	_ = approveSession(t, server, sessionApproveRequest{
		SessionID:    createResp.SessionID,
		ClaimID:      claimResp.ClaimID,
		Approve:      true,
		ScanRequired: true,
	}, createResp.ReceiverToken)
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}

	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                4,
	})
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 0, []byte("data"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken)

	scanInit := scanInitTransfer(t, server, scanInitRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: initResp.UploadToken,
		TotalBytes:    4,
		ChunkSize:     4,
	})
	encrypted := encryptScanChunk(t, scanInit.ScanKeyB64, 0, []byte("data"))
	uploadScanChunk(t, server, scanInit.ScanID, initResp.UploadToken, 0, encrypted)
	finalize := finalizeScan(t, server, scanFinalizeRequest{
		ScanID:        scanInit.ScanID,
		TransferToken: initResp.UploadToken,
	})
	if finalize.Status != string(domain.ScanStatusUnavailable) {
		t.Fatalf("expected unavailable got %s", finalize.Status)
	}
}

func TestScanCopyDeletedAfterScan(t *testing.T) {
	store := &stubStorage{}
	server := newSessionTestServer(store)

	createResp := createSession(t, server)
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: base64.StdEncoding.EncodeToString([]byte("pubkey")),
	})
	_ = approveSession(t, server, sessionApproveRequest{
		SessionID:    createResp.SessionID,
		ClaimID:      claimResp.ClaimID,
		Approve:      true,
		ScanRequired: true,
	}, createResp.ReceiverToken)
	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                4,
	})
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 0, []byte("data"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken)

	scanInit := scanInitTransfer(t, server, scanInitRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: initResp.UploadToken,
		TotalBytes:    4,
		ChunkSize:     4,
	})
	encrypted := encryptScanChunk(t, scanInit.ScanKeyB64, 0, []byte("data"))
	uploadScanChunk(t, server, scanInit.ScanID, initResp.UploadToken, 0, encrypted)
	_ = finalizeScan(t, server, scanFinalizeRequest{
		ScanID:        scanInit.ScanID,
		TransferToken: initResp.UploadToken,
	})

	if _, err := store.GetScanSession(context.Background(), scanInit.ScanID); err != storage.ErrNotFound {
		t.Fatalf("expected scan session deleted")
	}
	if _, err := store.LoadScanChunk(context.Background(), scanInit.ScanID, 0); err != storage.ErrNotFound {
		t.Fatalf("expected scan chunk deleted")
	}
}

func TestScanDoesNotAffectReceiverKeys(t *testing.T) {
	store := &stubStorage{}
	server := newSessionTestServer(store)

	createResp := createSession(t, server)
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: base64.StdEncoding.EncodeToString([]byte("pubkey")),
	})
	_ = approveSession(t, server, sessionApproveRequest{
		SessionID:    createResp.SessionID,
		ClaimID:      claimResp.ClaimID,
		Approve:      true,
		ScanRequired: true,
	}, createResp.ReceiverToken)
	auth, err := store.GetSessionAuthContext(context.Background(), createResp.SessionID, claimResp.ClaimID)
	if err != nil {
		t.Fatalf("auth context missing: %v", err)
	}
	receiverKey := auth.ReceiverPubKeyB64

	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	if senderPoll.TransferToken == "" {
		t.Fatalf("expected sender init token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                4,
	})
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 0, []byte("data"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken)

	scanInit := scanInitTransfer(t, server, scanInitRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: initResp.UploadToken,
		TotalBytes:    4,
		ChunkSize:     4,
	})
	encrypted := encryptScanChunk(t, scanInit.ScanKeyB64, 0, []byte("data"))
	uploadScanChunk(t, server, scanInit.ScanID, initResp.UploadToken, 0, encrypted)
	_ = finalizeScan(t, server, scanFinalizeRequest{
		ScanID:        scanInit.ScanID,
		TransferToken: initResp.UploadToken,
	})

	authAfter, err := store.GetSessionAuthContext(context.Background(), createResp.SessionID, claimResp.ClaimID)
	if err != nil {
		t.Fatalf("auth context missing: %v", err)
	}
	if authAfter.ReceiverPubKeyB64 != receiverKey {
		t.Fatalf("receiver key changed")
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
			MaxScanBytes:          config.DefaultMaxScanBytes,
			MaxScanDuration:       config.DefaultMaxScanDuration,
		},
		Store:        store,
		Capabilities: newTestCapabilities(),
		Scanner:      scanner.UnavailableScanner{},
	})
}

func createSession(t *testing.T, server *Server) sessionCreateResponse {
	t.Helper()
	rec := httptest.NewRecorder()
	receiverPubKeyB64 := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x01}, 32))
	requestBody, err := json.Marshal(sessionCreateRequest{ReceiverPubKeyB64: receiverPubKeyB64})
	if err != nil {
		t.Fatalf("marshal create request: %v", err)
	}
	createToken := issueCapabilityToken(t, server, auth.IssueSpec{
		Scope:             auth.ScopeSessionCreate,
		TTL:               config.DefaultClaimTokenTTL,
		ReceiverPubKeyB64: receiverPubKeyB64,
		PeerID:            receiverPubKeyB64,
		Visibility:        auth.VisibilityE2E,
		AllowedRoutes:     []string{"/v1/session/create"},
		SingleUse:         true,
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/session/create", bytes.NewBuffer(requestBody))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+createToken)
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

func issueCapabilityToken(t *testing.T, server *Server, spec auth.IssueSpec) string {
	t.Helper()
	if spec.TTL == 0 {
		spec.TTL = config.DefaultTransferTokenTTL
	}
	token, err := server.capabilities.Issue(spec)
	if err != nil {
		t.Fatalf("issue capability: %v", err)
	}
	return token
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

func commitSAS(t *testing.T, server *Server, sessionID string, claimID string, role string) {
	t.Helper()
	payload, err := json.Marshal(sessionSASCommitRequest{
		SessionID:    sessionID,
		ClaimID:      claimID,
		Role:         role,
		SASConfirmed: true,
	})
	if err != nil {
		t.Fatalf("marshal sas commit request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/session/sas/commit", bytes.NewBuffer(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected sas commit 200 got %d", rec.Code)
	}
}

func approveSessionRecorder(t *testing.T, server *Server, reqBody sessionApproveRequest, receiverToken string) *httptest.ResponseRecorder {
	t.Helper()
	payload, err := json.Marshal(reqBody)
	if err != nil {
		t.Fatalf("marshal approve request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/session/approve", bytes.NewBuffer(payload))
	req.Header.Set("Content-Type", "application/json")
	if receiverToken != "" {
		req.Header.Set("Authorization", "Bearer "+receiverToken)
	}
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	return rec
}

func approveSession(t *testing.T, server *Server, reqBody sessionApproveRequest, receiverToken string) sessionApproveResponse {
	t.Helper()
	if reqBody.Approve {
		commitSAS(t, server, reqBody.SessionID, reqBody.ClaimID, "sender")
		commitSAS(t, server, reqBody.SessionID, reqBody.ClaimID, "receiver")
	}
	rec := approveSessionRecorder(t, server, reqBody, receiverToken)
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

func pollSender(t *testing.T, server *Server, sessionID string, claimToken string) sessionPollSenderResponse {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/v1/session/poll?session_id="+url.QueryEscape(sessionID)+"&claim_token="+url.QueryEscape(claimToken), nil)
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected poll sender 200 got %d", rec.Code)
	}
	var resp sessionPollSenderResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode poll sender response: %v", err)
	}
	return resp
}

func pollReceiver(t *testing.T, server *Server, sessionID string) sessionPollReceiverResponse {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/v1/session/poll?session_id="+url.QueryEscape(sessionID), nil)
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected poll receiver 200 got %d", rec.Code)
	}
	var resp sessionPollReceiverResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode poll receiver response: %v", err)
	}
	return resp
}

func receiverTransferToken(t *testing.T, server *Server, sessionID string, claimID string) string {
	t.Helper()
	resp := pollReceiver(t, server, sessionID)
	for _, claim := range resp.Claims {
		if claim.ClaimID == claimID {
			return claim.TransferToken
		}
	}
	t.Fatalf("receiver transfer token missing")
	return ""
}

func scanInitTransfer(t *testing.T, server *Server, reqBody scanInitRequest) scanInitResponse {
	t.Helper()
	payload, err := json.Marshal(reqBody)
	if err != nil {
		t.Fatalf("marshal scan init request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/transfer/scan_init", bytes.NewBuffer(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected scan init 200 got %d", rec.Code)
	}
	var resp scanInitResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode scan init response: %v", err)
	}
	return resp
}

func uploadScanChunk(t *testing.T, server *Server, scanID string, token string, chunkIndex int, data []byte) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPut, "/v1/transfer/scan_chunk", bytes.NewBuffer(data))
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("scan_id", scanID)
	req.Header.Set("chunk_index", strconv.Itoa(chunkIndex))
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected scan chunk 200 got %d", rec.Code)
	}
}

func finalizeScan(t *testing.T, server *Server, reqBody scanFinalizeRequest) scanFinalizeResponse {
	t.Helper()
	payload, err := json.Marshal(reqBody)
	if err != nil {
		t.Fatalf("marshal scan finalize request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/transfer/scan_finalize", bytes.NewBuffer(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected scan finalize 200 got %d", rec.Code)
	}
	var resp scanFinalizeResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode scan finalize response: %v", err)
	}
	return resp
}

func encryptScanChunk(t *testing.T, scanKeyB64 string, chunkIndex int, plaintext []byte) []byte {
	t.Helper()
	key, err := base64.RawURLEncoding.DecodeString(scanKeyB64)
	if err != nil {
		t.Fatalf("decode scan key: %v", err)
	}
	if len(key) != 32 {
		t.Fatalf("invalid scan key length")
	}
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		t.Fatalf("new aead: %v", err)
	}
	nonce := make([]byte, chacha20poly1305.NonceSize)
	binary.BigEndian.PutUint64(nonce[4:], uint64(chunkIndex))
	return aead.Seal(nil, nonce, plaintext, nil)
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

func uploadChunk(t *testing.T, server *Server, sessionID string, transferID string, token string, offset int64, data []byte) {
	t.Helper()
	rec := uploadChunkRecorder(t, server, sessionID, transferID, token, offset, data)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected chunk 200 got %d", rec.Code)
	}
}

func uploadChunkRecorder(t *testing.T, server *Server, sessionID string, transferID string, token string, offset int64, data []byte) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPut, "/v1/transfer/chunk", bytes.NewBuffer(data))
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("session_id", sessionID)
	req.Header.Set("transfer_id", transferID)
	req.Header.Set("offset", strconv.FormatInt(offset, 10))
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	return rec
}

func finalizeTransfer(t *testing.T, server *Server, sessionID string, transferID string, token string) {
	t.Helper()
	payload, err := json.Marshal(transferFinalizeRequest{
		SessionID:     sessionID,
		TransferID:    transferID,
		TransferToken: token,
	})
	if err != nil {
		t.Fatalf("marshal finalize request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/transfer/finalize", bytes.NewBuffer(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected finalize 200 got %d", rec.Code)
	}
}

func downloadRange(t *testing.T, server *Server, sessionID string, transferID string, token string, start int64, end int64) []byte {
	t.Helper()
	rec := downloadRangeRecorder(t, server, sessionID, transferID, token, start, end)
	if rec.Code != http.StatusPartialContent {
		t.Fatalf("expected 206 got %d", rec.Code)
	}
	return rec.Body.Bytes()
}

func downloadRangeRecorder(t *testing.T, server *Server, sessionID string, transferID string, token string, start int64, end int64) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(
		http.MethodGet,
		"/v1/transfer/download?session_id="+sessionID+"&transfer_id="+transferID,
		nil,
	)
	req.Header.Set("download_token", token)
	req.Header.Set("Range", "bytes="+strconv.FormatInt(start, 10)+"-"+strconv.FormatInt(end, 10))
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	return rec
}

func receiptTransfer(t *testing.T, server *Server, reqBody transferReceiptRequest) {
	t.Helper()
	payload, err := json.Marshal(reqBody)
	if err != nil {
		t.Fatalf("marshal receipt request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/transfer/receipt", bytes.NewBuffer(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected receipt 200 got %d", rec.Code)
	}
}

func mintDownloadToken(t *testing.T, server *Server, reqBody downloadTokenRequest) downloadTokenResponse {
	t.Helper()
	payload, err := json.Marshal(reqBody)
	if err != nil {
		t.Fatalf("marshal download token request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/transfer/download_token", bytes.NewBuffer(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected download token 200 got %d", rec.Code)
	}
	var resp downloadTokenResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode download token response: %v", err)
	}
	return resp
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

func p2pOfferRecorder(t *testing.T, server *Server, token string, reqBody p2pOfferRequest) *httptest.ResponseRecorder {
	t.Helper()
	payload, err := json.Marshal(reqBody)
	if err != nil {
		t.Fatalf("marshal p2p offer: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/p2p/offer", bytes.NewBuffer(payload))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	return rec
}

func p2pIceConfigRecorder(t *testing.T, server *Server, token string, sessionID string, claimID string, mode string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(
		http.MethodGet,
		"/v1/p2p/ice_config?session_id="+sessionID+"&claim_id="+claimID+"&mode="+mode,
		nil,
	)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	return rec
}

type stubStorage struct {
	manifest   map[string][]byte
	meta       map[string]domain.TransferMeta
	chunks     map[string][]byte
	sessions   map[string]domain.Session
	auth       map[string]domain.SessionAuthContext
	scans      map[string]domain.ScanSession
	scanChunks map[string]map[int][]byte
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

func (s *stubStorage) SaveTransferMeta(_ context.Context, transferID string, meta domain.TransferMeta) error {
	if s.meta == nil {
		s.meta = map[string]domain.TransferMeta{}
	}
	s.meta[transferID] = meta
	return nil
}

func (s *stubStorage) GetTransferMeta(_ context.Context, transferID string) (domain.TransferMeta, error) {
	if s.meta == nil {
		return domain.TransferMeta{}, storage.ErrNotFound
	}
	meta, ok := s.meta[transferID]
	if !ok {
		return domain.TransferMeta{}, storage.ErrNotFound
	}
	return meta, nil
}

func (s *stubStorage) DeleteTransferMeta(_ context.Context, transferID string) error {
	if s.meta == nil {
		return storage.ErrNotFound
	}
	if _, ok := s.meta[transferID]; !ok {
		return storage.ErrNotFound
	}
	delete(s.meta, transferID)
	return nil
}

func (s *stubStorage) WriteChunk(_ context.Context, transferID string, offset int64, data []byte) error {
	if offset < 0 {
		return storage.ErrInvalidRange
	}
	if s.chunks == nil {
		s.chunks = map[string][]byte{}
	}
	existing := s.chunks[transferID]
	end := int(offset) + len(data)
	if end > len(existing) {
		next := make([]byte, end)
		copy(next, existing)
		existing = next
	}
	copy(existing[offset:], data)
	s.chunks[transferID] = existing
	return nil
}

func (s *stubStorage) ReadRange(_ context.Context, transferID string, offset int64, length int64) ([]byte, error) {
	if offset < 0 || length < 0 {
		return nil, storage.ErrInvalidRange
	}
	data, ok := s.chunks[transferID]
	if !ok {
		return nil, storage.ErrNotFound
	}
	if offset >= int64(len(data)) {
		return nil, storage.ErrInvalidRange
	}
	end := int(offset + length)
	if end > len(data) {
		end = len(data)
	}
	return append([]byte(nil), data[offset:end]...), nil
}

func (s *stubStorage) DeleteTransfer(_ context.Context, transferID string) error {
	if s.chunks == nil {
		return nil
	}
	delete(s.chunks, transferID)
	delete(s.manifest, transferID)
	delete(s.meta, transferID)
	return nil
}

func (s *stubStorage) SweepExpired(_ context.Context, _ time.Time) (storage.SweepResult, error) {
	return storage.SweepResult{}, nil
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

func (s *stubStorage) CreateScanSession(_ context.Context, scan domain.ScanSession) error {
	if s.scans == nil {
		s.scans = map[string]domain.ScanSession{}
	}
	if _, exists := s.scans[scan.ID]; exists {
		return storage.ErrConflict
	}
	s.scans[scan.ID] = scan
	return nil
}

func (s *stubStorage) GetScanSession(_ context.Context, scanID string) (domain.ScanSession, error) {
	if s.scans == nil {
		return domain.ScanSession{}, storage.ErrNotFound
	}
	scan, ok := s.scans[scanID]
	if !ok {
		return domain.ScanSession{}, storage.ErrNotFound
	}
	return scan, nil
}

func (s *stubStorage) DeleteScanSession(_ context.Context, scanID string) error {
	if s.scans == nil {
		return storage.ErrNotFound
	}
	delete(s.scans, scanID)
	delete(s.scanChunks, scanID)
	return nil
}

func (s *stubStorage) StoreScanChunk(_ context.Context, scanID string, chunkIndex int, data []byte) error {
	if s.scanChunks == nil {
		s.scanChunks = map[string]map[int][]byte{}
	}
	if _, ok := s.scanChunks[scanID]; !ok {
		s.scanChunks[scanID] = map[int][]byte{}
	}
	s.scanChunks[scanID][chunkIndex] = append([]byte(nil), data...)
	return nil
}

func (s *stubStorage) ListScanChunks(_ context.Context, scanID string) ([]int, error) {
	if s.scanChunks == nil {
		return nil, storage.ErrNotFound
	}
	chunks, ok := s.scanChunks[scanID]
	if !ok {
		return nil, storage.ErrNotFound
	}
	indexes := make([]int, 0, len(chunks))
	for idx := range chunks {
		indexes = append(indexes, idx)
	}
	sort.Ints(indexes)
	return indexes, nil
}

func (s *stubStorage) LoadScanChunk(_ context.Context, scanID string, chunkIndex int) ([]byte, error) {
	if s.scanChunks == nil {
		return nil, storage.ErrNotFound
	}
	chunks, ok := s.scanChunks[scanID]
	if !ok {
		return nil, storage.ErrNotFound
	}
	data, ok := chunks[chunkIndex]
	if !ok {
		return nil, storage.ErrNotFound
	}
	return append([]byte(nil), data...), nil
}

func (s *stubStorage) DeleteScanChunks(_ context.Context, scanID string) error {
	if s.scanChunks == nil {
		return storage.ErrNotFound
	}
	delete(s.scanChunks, scanID)
	return nil
}
