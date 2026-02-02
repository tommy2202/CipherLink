package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"universaldrop/internal/auth"
	"universaldrop/internal/config"
)

func setupTransferFixture(t *testing.T, server *Server, totalBytes int64) (sessionCreateResponse, sessionClaimResponse, sessionApproveResponse, transferInitResponse, string) {
	t.Helper()
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
		TotalBytes:                totalBytes,
	})
	receiverToken := receiverTransferToken(t, server, createResp.SessionID, claimResp.ClaimID)
	return createResp, claimResp, approveResp, initResp, receiverToken
}

func TestCapabilityTokenRequiredForEndpoints(t *testing.T) {
	server := newSessionTestServer(&stubStorage{})
	createResp := createSession(t, server)
	claimResp := claimSessionSuccess(t, server, sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      createResp.ClaimToken,
		SenderLabel:     "Sender",
		SenderPubKeyB64: base64.StdEncoding.EncodeToString([]byte("pubkey")),
	})
	_ = approveSession(t, server, sessionApproveRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Approve:   true,
	}, createResp.ReceiverToken)
	senderPoll := pollSender(t, server, createResp.SessionID, createResp.ClaimToken)
	initResp := initTransfer(t, server, transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             senderPoll.TransferToken,
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                4,
	})

	type endpointCase struct {
		name string
		req  *http.Request
	}
	receiverPubKeyB64 := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x01}, 32))
	createBody, _ := json.Marshal(sessionCreateRequest{ReceiverPubKeyB64: receiverPubKeyB64})
	claimBody, _ := json.Marshal(sessionClaimRequest{
		SessionID:       createResp.SessionID,
		ClaimToken:      "invalid-token",
		SenderLabel:     "Sender",
		SenderPubKeyB64: base64.StdEncoding.EncodeToString([]byte("pubkey")),
	})
	approveBody, _ := json.Marshal(sessionApproveRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Approve:   true,
	})
	initBody, _ := json.Marshal(transferInitRequest{
		SessionID:                 createResp.SessionID,
		TransferToken:             "",
		FileManifestCiphertextB64: base64.StdEncoding.EncodeToString([]byte("manifest")),
		TotalBytes:                4,
	})
	finalizeBody, _ := json.Marshal(transferFinalizeRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: "",
	})
	downloadTokenBody, _ := json.Marshal(downloadTokenRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: "",
	})
	receiptBody, _ := json.Marshal(transferReceiptRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: "",
		Status:        "complete",
	})
	p2pOfferBody, _ := json.Marshal(p2pOfferRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		SDP:       "offer",
	})
	p2pAnswerBody, _ := json.Marshal(p2pAnswerRequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		SDP:       "answer",
	})
	p2pICEBody, _ := json.Marshal(p2pICERequest{
		SessionID: createResp.SessionID,
		ClaimID:   claimResp.ClaimID,
		Candidate: "candidate",
	})

	cases := []endpointCase{
		{name: "session_create", req: httptest.NewRequest(http.MethodPost, "/v1/session/create", bytes.NewBuffer(createBody))},
		{name: "session_claim", req: httptest.NewRequest(http.MethodPost, "/v1/session/claim", bytes.NewBuffer(claimBody))},
		{name: "session_approve", req: httptest.NewRequest(http.MethodPost, "/v1/session/approve", bytes.NewBuffer(approveBody))},
		{name: "transfer_init", req: httptest.NewRequest(http.MethodPost, "/v1/transfer/init", bytes.NewBuffer(initBody))},
		{name: "transfer_chunk", req: func() *http.Request {
			req := httptest.NewRequest(http.MethodPut, "/v1/transfer/chunk", bytes.NewBuffer([]byte("data")))
			req.Header.Set("session_id", createResp.SessionID)
			req.Header.Set("transfer_id", initResp.TransferID)
			req.Header.Set("offset", "0")
			return req
		}()},
		{name: "transfer_finalize", req: httptest.NewRequest(http.MethodPost, "/v1/transfer/finalize", bytes.NewBuffer(finalizeBody))},
		{name: "transfer_manifest", req: httptest.NewRequest(http.MethodGet, "/v1/transfer/manifest?session_id="+createResp.SessionID+"&transfer_id="+initResp.TransferID, nil)},
		{name: "download_token", req: httptest.NewRequest(http.MethodPost, "/v1/transfer/download_token", bytes.NewBuffer(downloadTokenBody))},
		{name: "download_ciphertext", req: func() *http.Request {
			req := httptest.NewRequest(http.MethodGet, "/v1/transfer/download?session_id="+createResp.SessionID+"&transfer_id="+initResp.TransferID, nil)
			req.Header.Set("Range", "bytes=0-0")
			return req
		}()},
		{name: "transfer_receipt", req: httptest.NewRequest(http.MethodPost, "/v1/transfer/receipt", bytes.NewBuffer(receiptBody))},
		{name: "p2p_offer", req: httptest.NewRequest(http.MethodPost, "/v1/p2p/offer", bytes.NewBuffer(p2pOfferBody))},
		{name: "p2p_answer", req: httptest.NewRequest(http.MethodPost, "/v1/p2p/answer", bytes.NewBuffer(p2pAnswerBody))},
		{name: "p2p_ice", req: httptest.NewRequest(http.MethodPost, "/v1/p2p/ice", bytes.NewBuffer(p2pICEBody))},
		{name: "p2p_poll", req: httptest.NewRequest(http.MethodGet, "/v1/p2p/poll?session_id="+createResp.SessionID+"&claim_id="+claimResp.ClaimID, nil)},
		{name: "p2p_ice_config", req: httptest.NewRequest(http.MethodGet, "/v1/p2p/ice_config?session_id="+createResp.SessionID+"&claim_id="+claimResp.ClaimID+"&mode=relay", nil)},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			server.Router.ServeHTTP(rec, tc.req)
			if rec.Code != http.StatusNotFound {
				t.Fatalf("expected 404 got %d", rec.Code)
			}
		})
	}
}

func TestCapabilityScopeEnforcement(t *testing.T) {
	server := newSessionTestServer(&stubStorage{})
	createResp, claimResp, _, initResp, receiverToken := setupTransferFixture(t, server, 4)

	rec := uploadChunkRecorder(t, server, createResp.SessionID, initResp.TransferID, receiverToken, 0, []byte("data"))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected receiver token to be rejected, got %d", rec.Code)
	}

	reqBody, _ := json.Marshal(downloadTokenRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: initResp.UploadToken,
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/transfer/download_token", bytes.NewBuffer(reqBody))
	req.Header.Set("Content-Type", "application/json")
	rec = httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected send token to be rejected, got %d", rec.Code)
	}
	_ = claimResp
}

func TestCapabilityBindingEnforced(t *testing.T) {
	server := newSessionTestServer(&stubStorage{})
	createResp, claimResp, _, initResp, receiverToken := setupTransferFixture(t, server, 4)

	wrongTransferToken := issueCapabilityToken(t, server, auth.IssueSpec{
		Scope:             auth.ScopeTransferReceive,
		TTL:               time.Minute,
		SessionID:         createResp.SessionID,
		ClaimID:           claimResp.ClaimID,
		TransferID:        "wrong",
		PeerID:            createResp.ReceiverPubKeyB64,
		SenderPubKeyB64:   claimResp.SenderPubKeyB64,
		ReceiverPubKeyB64: createResp.ReceiverPubKeyB64,
		Visibility:        auth.VisibilityE2E,
		AllowedRoutes:     []string{"/v1/transfer/manifest"},
	})
	rec := manifestRequestRecorder(t, server, createResp.SessionID, initResp.TransferID, wrongTransferToken)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected wrong transfer token to be rejected, got %d", rec.Code)
	}

	wrongHashToken := issueCapabilityToken(t, server, auth.IssueSpec{
		Scope:             auth.ScopeTransferReceive,
		TTL:               time.Minute,
		SessionID:         createResp.SessionID,
		ClaimID:           claimResp.ClaimID,
		TransferID:        initResp.TransferID,
		PeerID:            createResp.ReceiverPubKeyB64,
		SenderPubKeyB64:   claimResp.SenderPubKeyB64,
		ReceiverPubKeyB64: createResp.ReceiverPubKeyB64,
		ManifestHash:      "wrong",
		Visibility:        auth.VisibilityE2E,
		AllowedRoutes:     []string{"/v1/transfer/download_token"},
	})
	reqBody, _ := json.Marshal(downloadTokenRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: wrongHashToken,
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/transfer/download_token", bytes.NewBuffer(reqBody))
	req.Header.Set("Content-Type", "application/json")
	rec = httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected wrong manifest hash to be rejected, got %d", rec.Code)
	}

	wrongSenderToken := issueCapabilityToken(t, server, auth.IssueSpec{
		Scope:             auth.ScopeTransferSend,
		TTL:               time.Minute,
		SessionID:         createResp.SessionID,
		ClaimID:           claimResp.ClaimID,
		TransferID:        initResp.TransferID,
		PeerID:            "wrong",
		SenderPubKeyB64:   "wrong",
		ReceiverPubKeyB64: createResp.ReceiverPubKeyB64,
		ManifestHash:      meta.ManifestHash,
		Visibility:        auth.VisibilityE2E,
		AllowedRoutes:     []string{"/v1/transfer/chunk"},
	})
	rec = uploadChunkRecorder(t, server, createResp.SessionID, initResp.TransferID, wrongSenderToken, 0, []byte("data"))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected wrong sender token to be rejected, got %d", rec.Code)
	}

	_ = receiverToken
}

func TestCapabilityExpiryEnforced(t *testing.T) {
	server := newSessionTestServer(&stubStorage{})
	createResp, claimResp, _, initResp, _ := setupTransferFixture(t, server, 4)
	expiredToken := issueCapabilityToken(t, server, auth.IssueSpec{
		Scope:             auth.ScopeTransferReceive,
		TTL:               -time.Minute,
		SessionID:         createResp.SessionID,
		ClaimID:           claimResp.ClaimID,
		TransferID:        initResp.TransferID,
		PeerID:            createResp.ReceiverPubKeyB64,
		SenderPubKeyB64:   claimResp.SenderPubKeyB64,
		ReceiverPubKeyB64: createResp.ReceiverPubKeyB64,
		Visibility:        auth.VisibilityE2E,
		AllowedRoutes:     []string{"/v1/transfer/manifest"},
	})
	rec := manifestRequestRecorder(t, server, createResp.SessionID, initResp.TransferID, expiredToken)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected expired token to be rejected, got %d", rec.Code)
	}
}

func TestCapabilityReplayProtection(t *testing.T) {
	server := newSessionTestServer(&stubStorage{})
	createResp, claimResp, _, initResp, receiverToken := setupTransferFixture(t, server, 4)
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 0, []byte("data"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken)

	downloadResp := mintDownloadToken(t, server, downloadTokenRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: receiverToken,
	})
	first := downloadRangeRecorder(t, server, createResp.SessionID, initResp.TransferID, downloadResp.DownloadToken, 0, 0)
	if first.Code != http.StatusPartialContent {
		t.Fatalf("expected first download 206 got %d", first.Code)
	}
	second := downloadRangeRecorder(t, server, createResp.SessionID, initResp.TransferID, downloadResp.DownloadToken, 0, 0)
	if second.Code != http.StatusNotFound {
		t.Fatalf("expected replay to be rejected, got %d", second.Code)
	}
	_ = claimResp
}

func TestCapabilityRevocation(t *testing.T) {
	server := newSessionTestServer(&stubStorage{})
	createResp, _, _, initResp, receiverToken := setupTransferFixture(t, server, 4)
	uploadChunk(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken, 0, []byte("data"))
	finalizeTransfer(t, server, createResp.SessionID, initResp.TransferID, initResp.UploadToken)

	server.capabilities.RevokeTransfer(initResp.TransferID)
	reqBody, _ := json.Marshal(downloadTokenRequest{
		SessionID:     createResp.SessionID,
		TransferID:    initResp.TransferID,
		TransferToken: receiverToken,
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/transfer/download_token", bytes.NewBuffer(reqBody))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected revoked transfer to be rejected, got %d", rec.Code)
	}
}

func TestAllowlistLogsDoNotIncludeTokens(t *testing.T) {
	var buf bytes.Buffer
	server := NewServer(Dependencies{
		Config:       testConfig(),
		Store:        &stubStorage{},
		Logger:       log.New(&buf, "", 0),
		Capabilities: newTestCapabilities(),
	})
	receiverPubKeyB64 := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x01}, 32))
	token := issueCapabilityToken(t, server, auth.IssueSpec{
		Scope:             auth.ScopeSessionCreate,
		TTL:               time.Minute,
		ReceiverPubKeyB64: receiverPubKeyB64,
		PeerID:            receiverPubKeyB64,
		Visibility:        auth.VisibilityE2E,
		AllowedRoutes:     []string{"/v1/session/create"},
		SingleUse:         true,
	})
	payload, _ := json.Marshal(sessionCreateRequest{ReceiverPubKeyB64: receiverPubKeyB64})
	req := httptest.NewRequest(http.MethodPost, "/v1/session/create", bytes.NewBuffer(payload))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected create 200 got %d", rec.Code)
	}
	if bytes.Contains(buf.Bytes(), []byte(token)) {
		t.Fatalf("expected logs to exclude token")
	}
}

func testConfig() config.Config {
	return config.Config{
		Address:               ":0",
		DataDir:               "data",
		RateLimitHealth:       config.RateLimit{Max: 100, Window: time.Minute},
		RateLimitV1:           config.RateLimit{Max: 100, Window: time.Minute},
		RateLimitSessionClaim: config.RateLimit{Max: 100, Window: time.Minute},
		ClaimTokenTTL:         config.DefaultClaimTokenTTL,
		TransferTokenTTL:      config.DefaultTransferTokenTTL,
		MaxScanBytes:          config.DefaultMaxScanBytes,
		MaxScanDuration:       config.DefaultMaxScanDuration,
	}
}
