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

	"universaldrop/internal/clock"
	"universaldrop/internal/config"
	"universaldrop/internal/scanner"
	"universaldrop/internal/storage"
	"universaldrop/internal/storage/memory"
)

func newTestServer(t *testing.T, clk *clock.FakeClock, scan scanner.Scanner, createLimit int) (*Server, *memory.Store) {
	t.Helper()
	store := memory.New()
	cfg := config.Config{
		Address:         ":0",
		DataDir:         "unused",
		PairingTokenTTL: 2 * time.Minute,
		DropTTL:         5 * time.Minute,
		MaxDropTTL:      1 * time.Hour,
		SweepInterval:   0,
		MaxCopyBytes:    1024,
		RateLimitCreate: config.RateLimit{Max: createLimit, Window: time.Minute},
		RateLimitRedeem: config.RateLimit{Max: 5, Window: time.Minute},
	}
	server := NewServer(Dependencies{
		Config:  cfg,
		Store:   store,
		Scanner: scan,
		Clock:   clk,
	})
	return server, store
}

func TestPairingTokenSingleUseAndExpiry(t *testing.T) {
	clk := clock.NewFake(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	server, _ := newTestServer(t, clk, scanner.NoopScanner{}, 10)

	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/pairings", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 got %d", rec.Code)
	}

	var created pairingResponse
	if err := json.NewDecoder(rec.Body).Decode(&created); err != nil {
		t.Fatalf("decode pairing response: %v", err)
	}

	redeemPath := "/v1/pairings/" + created.PairingToken + "/redeem"
	redeemRec := httptest.NewRecorder()
	server.Router.ServeHTTP(redeemRec, httptest.NewRequest(http.MethodPost, redeemPath, nil))
	if redeemRec.Code != http.StatusOK {
		t.Fatalf("expected redeem 200 got %d", redeemRec.Code)
	}

	reuseRec := httptest.NewRecorder()
	server.Router.ServeHTTP(reuseRec, httptest.NewRequest(http.MethodPost, redeemPath, nil))
	if reuseRec.Code != http.StatusNotFound {
		t.Fatalf("expected reuse 404 got %d", reuseRec.Code)
	}
	reuseBody := reuseRec.Body.String()

	expireRec := httptest.NewRecorder()
	server.Router.ServeHTTP(expireRec, httptest.NewRequest(http.MethodPost, "/v1/pairings", nil))
	if expireRec.Code != http.StatusOK {
		t.Fatalf("expected second token 200 got %d", expireRec.Code)
	}
	var expired pairingResponse
	if err := json.NewDecoder(expireRec.Body).Decode(&expired); err != nil {
		t.Fatalf("decode second pairing: %v", err)
	}

	clk.Advance(3 * time.Minute)
	expiredRedeem := httptest.NewRecorder()
	server.Router.ServeHTTP(expiredRedeem, httptest.NewRequest(http.MethodPost, "/v1/pairings/"+expired.PairingToken+"/redeem", nil))
	if expiredRedeem.Code != http.StatusNotFound {
		t.Fatalf("expected expired 404 got %d", expiredRedeem.Code)
	}
	if reuseBody != expiredRedeem.Body.String() {
		t.Fatalf("expected indistinguishable errors")
	}
}

func TestReceiverApprovalRequired(t *testing.T) {
	clk := clock.NewFake(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	server, _ := newTestServer(t, clk, scanner.NoopScanner{}, 10)

	pairingToken := createPairingToken(t, server)
	pairingID := redeemPairingToken(t, server, pairingToken)
	dropID := createDrop(t, server, pairingID, `{"scan_mode":"none"}`)

	uploadBody := `{"receiver_copy":"` + base64.StdEncoding.EncodeToString([]byte("copy")) + `"}`
	uploadReq := httptest.NewRequest(http.MethodPut, "/v1/drops/"+dropID+"/receiver-copy", bytes.NewBufferString(uploadBody))
	uploadReq.Header.Set("Content-Type", "application/json")
	uploadRec := httptest.NewRecorder()
	server.Router.ServeHTTP(uploadRec, uploadReq)
	if uploadRec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 got %d", uploadRec.Code)
	}

	approveRec := httptest.NewRecorder()
	server.Router.ServeHTTP(approveRec, httptest.NewRequest(http.MethodPost, "/v1/drops/"+dropID+"/approve", nil))
	if approveRec.Code != http.StatusOK {
		t.Fatalf("expected approve 200 got %d", approveRec.Code)
	}

	uploadRec = httptest.NewRecorder()
	server.Router.ServeHTTP(uploadRec, uploadReq)
	if uploadRec.Code != http.StatusOK {
		t.Fatalf("expected upload 200 got %d", uploadRec.Code)
	}
}

func TestDeleteOnReceipt(t *testing.T) {
	clk := clock.NewFake(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	server, store := newTestServer(t, clk, scanner.NoopScanner{}, 10)

	pairingToken := createPairingToken(t, server)
	pairingID := redeemPairingToken(t, server, pairingToken)
	dropID := createDrop(t, server, pairingID, `{"scan_mode":"none"}`)

	approveRec := httptest.NewRecorder()
	server.Router.ServeHTTP(approveRec, httptest.NewRequest(http.MethodPost, "/v1/drops/"+dropID+"/approve", nil))
	if approveRec.Code != http.StatusOK {
		t.Fatalf("expected approve 200 got %d", approveRec.Code)
	}

	payload := base64.StdEncoding.EncodeToString([]byte("secret"))
	uploadBody := `{"receiver_copy":"` + payload + `"}`
	uploadReq := httptest.NewRequest(http.MethodPut, "/v1/drops/"+dropID+"/receiver-copy", bytes.NewBufferString(uploadBody))
	uploadReq.Header.Set("Content-Type", "application/json")
	uploadRec := httptest.NewRecorder()
	server.Router.ServeHTTP(uploadRec, uploadReq)
	if uploadRec.Code != http.StatusOK {
		t.Fatalf("expected upload 200 got %d", uploadRec.Code)
	}

	downloadRec := httptest.NewRecorder()
	server.Router.ServeHTTP(downloadRec, httptest.NewRequest(http.MethodGet, "/v1/drops/"+dropID+"/receiver-copy", nil))
	if downloadRec.Code != http.StatusOK {
		t.Fatalf("expected download 200 got %d", downloadRec.Code)
	}

	var response receiverCopyResponse
	if err := json.NewDecoder(downloadRec.Body).Decode(&response); err != nil {
		t.Fatalf("decode receiver copy: %v", err)
	}
	if response.ReceiverCopy != payload {
		t.Fatalf("expected payload to match")
	}

	secondRec := httptest.NewRecorder()
	server.Router.ServeHTTP(secondRec, httptest.NewRequest(http.MethodGet, "/v1/drops/"+dropID+"/receiver-copy", nil))
	if secondRec.Code != http.StatusNotFound {
		t.Fatalf("expected second download 404 got %d", secondRec.Code)
	}

	if _, err := store.LoadReceiverCopy(context.Background(), dropID); err != storage.ErrNotFound {
		t.Fatalf("expected receiver copy removed")
	}
}

func TestRateLimiting(t *testing.T) {
	clk := clock.NewFake(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	server, _ := newTestServer(t, clk, scanner.NoopScanner{}, 1)

	req := httptest.NewRequest(http.MethodPost, "/v1/pairings", nil)
	req.Header.Set("X-Forwarded-For", "10.10.10.10")
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

func TestVerifiedScanModeUsesScanCopy(t *testing.T) {
	clk := clock.NewFake(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	recorder := &recordingScanner{}
	server, _ := newTestServer(t, clk, recorder, 10)

	pairingToken := createPairingToken(t, server)
	pairingID := redeemPairingToken(t, server, pairingToken)

	scanPayload := base64.StdEncoding.EncodeToString([]byte("scan-copy"))
	dropID := createDrop(t, server, pairingID, `{"scan_mode":"verified","scan_copy":"`+scanPayload+`"}`)

	approveRec := httptest.NewRecorder()
	server.Router.ServeHTTP(approveRec, httptest.NewRequest(http.MethodPost, "/v1/drops/"+dropID+"/approve", nil))
	if approveRec.Code != http.StatusOK {
		t.Fatalf("expected approve 200 got %d", approveRec.Code)
	}
	if len(recorder.data) != 1 || string(recorder.data[0]) != "scan-copy" {
		t.Fatalf("expected scanner to receive scan-copy only")
	}

	uploadBody := `{"receiver_copy":"` + base64.StdEncoding.EncodeToString([]byte("receiver-copy")) + `"}`
	uploadReq := httptest.NewRequest(http.MethodPut, "/v1/drops/"+dropID+"/receiver-copy", bytes.NewBufferString(uploadBody))
	uploadReq.Header.Set("Content-Type", "application/json")
	uploadRec := httptest.NewRecorder()
	server.Router.ServeHTTP(uploadRec, uploadReq)
	if uploadRec.Code != http.StatusOK {
		t.Fatalf("expected upload 200 got %d", uploadRec.Code)
	}
	if len(recorder.data) != 1 {
		t.Fatalf("expected scanner called once")
	}
}

func createPairingToken(t *testing.T, server *Server) string {
	t.Helper()
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/pairings", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("pairing token expected 200 got %d", rec.Code)
	}
	var response pairingResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("decode pairing token: %v", err)
	}
	return response.PairingToken
}

func redeemPairingToken(t *testing.T, server *Server, token string) string {
	t.Helper()
	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/pairings/"+token+"/redeem", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("redeem expected 200 got %d", rec.Code)
	}
	var response pairingRedeemResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("decode redeem: %v", err)
	}
	return response.PairingID
}

func createDrop(t *testing.T, server *Server, pairingID string, payload string) string {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/pairings/"+pairingID+"/drops", bytes.NewBufferString(payload))
	req.Header.Set("Content-Type", "application/json")
	server.Router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("create drop expected 200 got %d", rec.Code)
	}
	var response dropResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("decode drop response: %v", err)
	}
	return response.DropID
}

type recordingScanner struct {
	data [][]byte
}

func (r *recordingScanner) Scan(_ context.Context, data []byte) (scanner.Result, error) {
	r.data = append(r.data, append([]byte(nil), data...))
	return scanner.Result{Clean: true}, nil
}
