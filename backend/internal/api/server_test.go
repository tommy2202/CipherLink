package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sort"
	"strconv"
	"testing"
	"time"

	"universaldrop/internal/config"
	"universaldrop/internal/domain"
	"universaldrop/internal/scanner"
	"universaldrop/internal/storage"
	"universaldrop/internal/token"

	"golang.org/x/crypto/chacha20poly1305"
)

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
			MaxScanBytes:          config.DefaultMaxScanBytes,
			MaxScanDuration:       config.DefaultMaxScanDuration,
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
			MaxScanBytes:          config.DefaultMaxScanBytes,
			MaxScanDuration:       config.DefaultMaxScanDuration,
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
	})
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             approveResp.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                8,
	})

	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken, 0, []byte("abcd"))
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken, 4, []byte("efgh"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken)

	first := downloadRange(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken, 0, 3)
	if string(first) != "abcd" {
		t.Fatalf("expected first range to match")
	}
	second := downloadRange(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken, 4, 7)
	if string(second) != "efgh" {
		t.Fatalf("expected second range to match")
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
	})
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             approveResp.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                4,
	})
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken, 0, []byte("data"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken)
	receiptTransfer(t, server, transferReceiptRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: approveResp.TransferToken,
		Status:        "complete",
	})

	missingRec := manifestRequestRecorder(t, server, createResp.SessionID, "missing", approveResp.TransferToken)
	deletedRec := manifestRequestRecorder(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken)
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
	})
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}

	manifest := []byte("manifest-cipher")
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             approveResp.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString(manifest),
		TotalBytes:                5,
	})

	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken, 0, []byte("hello"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken)

	downloadedManifest := fetchManifest(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken)
	if !bytes.Equal(downloadedManifest, manifest) {
		t.Fatalf("expected manifest to match")
	}

	payload := downloadRange(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken, 0, 4)
	if string(payload) != "hello" {
		t.Fatalf("expected payload to match")
	}

	receiptTransfer(t, server, transferReceiptRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: approveResp.TransferToken,
		Status:        "complete",
	})

	missingRec := manifestRequestRecorder(t, server, createResp.SessionID, "missing", approveResp.TransferToken)
	deletedRec := manifestRequestRecorder(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken)
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
	approveResp := approveSession(t, server, sessionApproveRequest{
		SessionID:    createResp.SessionID,
		ClaimID:      claimResp.ClaimID,
		Approve:      true,
		ScanRequired: true,
	})
	if approveResp.TransferToken == "" {
		t.Fatalf("expected transfer token")
	}

	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             approveResp.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                4,
	})
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken, 0, []byte("data"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken)

	scanInit := scanInitTransfer(t, server, scanInitRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: approveResp.TransferToken,
		TotalBytes:    4,
		ChunkSize:     4,
	})
	encrypted := encryptScanChunk(t, scanInit.ScanKeyB64, 0, []byte("data"))
	uploadScanChunk(t, server, scanInit.ScanID, approveResp.TransferToken, 0, encrypted)
	finalize := finalizeScan(t, server, scanFinalizeRequest{
		ScanID:        scanInit.ScanID,
		TransferToken: approveResp.TransferToken,
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
	approveResp := approveSession(t, server, sessionApproveRequest{
		SessionID:    createResp.SessionID,
		ClaimID:      claimResp.ClaimID,
		Approve:      true,
		ScanRequired: true,
	})
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             approveResp.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                4,
	})
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken, 0, []byte("data"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken)

	scanInit := scanInitTransfer(t, server, scanInitRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: approveResp.TransferToken,
		TotalBytes:    4,
		ChunkSize:     4,
	})
	encrypted := encryptScanChunk(t, scanInit.ScanKeyB64, 0, []byte("data"))
	uploadScanChunk(t, server, scanInit.ScanID, approveResp.TransferToken, 0, encrypted)
	_ = finalizeScan(t, server, scanFinalizeRequest{
		ScanID:        scanInit.ScanID,
		TransferToken: approveResp.TransferToken,
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
	approveResp := approveSession(t, server, sessionApproveRequest{
		SessionID:    createResp.SessionID,
		ClaimID:      claimResp.ClaimID,
		Approve:      true,
		ScanRequired: true,
	})
	auth, err := store.GetSessionAuthContext(context.Background(), createResp.SessionID, claimResp.ClaimID)
	if err != nil {
		t.Fatalf("auth context missing: %v", err)
	}
	receiverKey := auth.ReceiverPubKeyB64

	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             approveResp.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                4,
	})
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken, 0, []byte("data"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, approveResp.TransferToken)

	scanInit := scanInitTransfer(t, server, scanInitRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: approveResp.TransferToken,
		TotalBytes:    4,
		ChunkSize:     4,
	})
	encrypted := encryptScanChunk(t, scanInit.ScanKeyB64, 0, []byte("data"))
	uploadScanChunk(t, server, scanInit.ScanID, approveResp.TransferToken, 0, encrypted)
	_ = finalizeScan(t, server, scanFinalizeRequest{
		ScanID:        scanInit.ScanID,
		TransferToken: approveResp.TransferToken,
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
		Store:   store,
		Tokens:  token.NewMemoryService(),
		Scanner: scanner.UnavailableScanner{},
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
	req := httptest.NewRequest(http.MethodPut, "/v1/transfer/chunk", bytes.NewBuffer(data))
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("session_id", sessionID)
	req.Header.Set("transfer_id", transferID)
	req.Header.Set("offset", strconv.FormatInt(offset, 10))
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected chunk 200 got %d", rec.Code)
	}
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
	req := httptest.NewRequest(
		http.MethodGet,
		"/v1/transfer/download?session_id="+sessionID+"&transfer_id="+transferID,
		nil,
	)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Range", "bytes="+strconv.FormatInt(start, 10)+"-"+strconv.FormatInt(end, 10))
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusPartialContent {
		t.Fatalf("expected 206 got %d", rec.Code)
	}
	return rec.Body.Bytes()
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
