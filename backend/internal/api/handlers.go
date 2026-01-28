package api

import (
	"context"
	"encoding/base64"
	"io"
	"net/http"
	"net/textproto"
	"net/url"
	"strconv"
	"strings"
	"time"

	"universaldrop/internal/config"
	"universaldrop/internal/domain"
	"universaldrop/internal/logging"
	"universaldrop/internal/storage"
)

type sessionCreateResponse struct {
	SessionID         string `json:"session_id"`
	ExpiresAt         string `json:"expires_at"`
	ClaimToken        string `json:"claim_token"`
	ReceiverPubKeyB64 string `json:"receiver_pubkey_b64"`
	QRPayload         string `json:"qr_payload"`
}

type sessionCreateRequest struct {
	ReceiverPubKeyB64 string `json:"receiver_pubkey_b64"`
}

type sessionClaimRequest struct {
	SessionID       string `json:"session_id"`
	ClaimToken      string `json:"claim_token"`
	SenderLabel     string `json:"sender_label"`
	SenderPubKeyB64 string `json:"sender_pubkey_b64"`
}

type sessionClaimResponse struct {
	ClaimID string `json:"claim_id"`
	Status  string `json:"status"`
}

type sessionPollClaimSummary struct {
	ClaimID          string `json:"claim_id"`
	SenderLabel      string `json:"sender_label"`
	ShortFingerprint string `json:"short_fingerprint"`
	SenderPubKeyB64  string `json:"sender_pubkey_b64,omitempty"`
	TransferID       string `json:"transfer_id,omitempty"`
	ScanRequired     bool   `json:"scan_required,omitempty"`
	ScanStatus       string `json:"scan_status,omitempty"`
	SASState         string `json:"sas_state"`
}

type sessionPollReceiverResponse struct {
	SessionID string                    `json:"session_id"`
	ExpiresAt string                    `json:"expires_at"`
	Claims    []sessionPollClaimSummary `json:"claims"`
	SASState  string                    `json:"sas_state"`
}

type sessionPollSenderResponse struct {
	SessionID         string `json:"session_id"`
	ExpiresAt         string `json:"expires_at"`
	ClaimID           string `json:"claim_id"`
	Status            string `json:"status"`
	SASState          string `json:"sas_state"`
	ReceiverPubKeyB64 string `json:"receiver_pubkey_b64,omitempty"`
	TransferToken     string `json:"transfer_token,omitempty"`
	ScanRequired      bool   `json:"scan_required,omitempty"`
	ScanStatus        string `json:"scan_status,omitempty"`
}

type sessionApproveRequest struct {
	SessionID    string `json:"session_id"`
	ClaimID      string `json:"claim_id"`
	Approve      bool   `json:"approve"`
	ScanRequired bool   `json:"scan_required,omitempty"`
}

type sessionApproveResponse struct {
	Status          string `json:"status"`
	TransferToken   string `json:"transfer_token,omitempty"`
	SenderPubKeyB64 string `json:"sender_pubkey_b64,omitempty"`
}

type sessionSASCommitRequest struct {
	SessionID    string `json:"session_id"`
	ClaimID      string `json:"claim_id"`
	Role         string `json:"role"`
	SASConfirmed bool   `json:"sas_confirmed"`
}

type sessionSASStatusResponse struct {
	SASState string `json:"sas_state"`
}

type transferInitRequest struct {
	SessionID                 string `json:"session_id"`
	TransferToken             string `json:"transfer_token"`
	FileManifestCiphertextB64 string `json:"file_manifest_ciphertext_b64"`
	TotalBytes                int64  `json:"total_bytes"`
	TransferID                string `json:"transfer_id,omitempty"`
}

type transferInitResponse struct {
	TransferID string `json:"transfer_id"`
}

type transferFinalizeRequest struct {
	SessionID     string `json:"session_id"`
	TransferID    string `json:"transfer_id"`
	TransferToken string `json:"transfer_token"`
}

type transferReceiptRequest struct {
	SessionID     string `json:"session_id"`
	TransferID    string `json:"transfer_id"`
	TransferToken string `json:"transfer_token"`
	Status        string `json:"status"`
}

type scanInitRequest struct {
	SessionID     string `json:"session_id"`
	TransferID    string `json:"transfer_id"`
	TransferToken string `json:"transfer_token"`
	TotalBytes    int64  `json:"total_bytes"`
	ChunkSize     int    `json:"chunk_size"`
}

type scanInitResponse struct {
	ScanID     string `json:"scan_id"`
	ScanKeyB64 string `json:"scan_key_b64"`
}

type scanFinalizeRequest struct {
	ScanID        string `json:"scan_id"`
	TransferToken string `json:"transfer_token"`
}

type scanFinalizeResponse struct {
	Status string `json:"status"`
}

func (s *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	ttl := s.cfg.ClaimTokenTTL
	if ttl == 0 || ttl < config.MinClaimTokenTTL || ttl > config.MaxClaimTokenTTL {
		ttl = config.DefaultClaimTokenTTL
	}

	var req sessionCreateRequest
	if r.ContentLength != 0 {
		if err := decodeJSON(w, r, &req, 8<<10); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
	}
	if req.ReceiverPubKeyB64 == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if keyBytes, err := base64.StdEncoding.DecodeString(req.ReceiverPubKeyB64); err != nil || len(keyBytes) != 32 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}

	var session domain.Session
	var claimToken string
	var err error
	for attempt := 0; attempt < 3; attempt++ {
		var sessionID string
		sessionID, err = randomBase64(18)
		if err != nil {
			break
		}
		claimToken, err = randomBase64(32)
		if err != nil {
			break
		}
		receiverPubKey := req.ReceiverPubKeyB64

		now := time.Now().UTC()
		expiresAt := now.Add(ttl)
		session = domain.Session{
			ID:                  sessionID,
			CreatedAt:           now,
			ExpiresAt:           expiresAt,
			ClaimTokenHash:      tokenHash(claimToken),
			ClaimTokenExpiresAt: expiresAt,
			ClaimTokenUsed:      false,
			ReceiverPubKeyB64:   receiverPubKey,
		}

		if err = s.store.CreateSession(r.Context(), session); err == storage.ErrConflict {
			continue
		}
		break
	}

	if err != nil {
		logging.Allowlist(s.logger, map[string]string{
			"event": "session_create_failed",
			"error": "storage_error",
		})
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	values := url.Values{}
	values.Set("session_id", session.ID)
	values.Set("claim_token", claimToken)
	qrPayload := "udrop://claim?" + values.Encode()

	logging.Allowlist(s.logger, map[string]string{
		"event":           "session_created",
		"session_id_hash": anonHash(session.ID),
	})

	writeJSON(w, http.StatusOK, sessionCreateResponse{
		SessionID:         session.ID,
		ExpiresAt:         session.ExpiresAt.Format(time.RFC3339),
		ClaimToken:        claimToken,
		ReceiverPubKeyB64: session.ReceiverPubKeyB64,
		QRPayload:         qrPayload,
	})
}

func (s *Server) handleClaimSession(w http.ResponseWriter, r *http.Request) {
	var req sessionClaimRequest
	if err := decodeJSON(w, r, &req, 16<<10); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if req.SessionID == "" || req.ClaimToken == "" || req.SenderPubKeyB64 == "" || req.SenderLabel == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}

	session, err := s.store.GetSession(r.Context(), req.SessionID)
	if err != nil {
		writeIndistinguishable(w)
		return
	}

	now := time.Now().UTC()
	if now.After(session.ExpiresAt) {
		writeIndistinguishable(w)
		return
	}
	if session.ClaimTokenUsed || session.ClaimTokenHash == "" {
		writeIndistinguishable(w)
		return
	}
	if now.After(session.ClaimTokenExpiresAt) {
		writeIndistinguishable(w)
		return
	}
	if tokenHash(req.ClaimToken) != session.ClaimTokenHash {
		writeIndistinguishable(w)
		return
	}

	claimID, err := randomBase64(18)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	claim := domain.SessionClaim{
		ID:              claimID,
		SenderLabel:     req.SenderLabel,
		SenderPubKeyB64: req.SenderPubKeyB64,
		Status:          domain.SessionClaimPending,
		CreatedAt:       now,
		UpdatedAt:       now,
	}
	session.ClaimTokenUsed = true
	session.Claims = append(session.Claims, claim)
	if err := s.store.UpdateSession(r.Context(), session); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	logging.Allowlist(s.logger, map[string]string{
		"event":           "session_claimed",
		"session_id_hash": anonHash(session.ID),
		"claim_id_hash":   anonHash(claimID),
	})

	writeJSON(w, http.StatusOK, sessionClaimResponse{
		ClaimID: claim.ID,
		Status:  string(claim.Status),
	})
}

func (s *Server) handleApproveSession(w http.ResponseWriter, r *http.Request) {
	var req sessionApproveRequest
	if err := decodeJSON(w, r, &req, 8<<10); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if req.SessionID == "" || req.ClaimID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}

	session, err := s.store.GetSession(r.Context(), req.SessionID)
	if err != nil {
		writeIndistinguishable(w)
		return
	}
	if time.Now().UTC().After(session.ExpiresAt) {
		writeIndistinguishable(w)
		return
	}

	claimIndex := -1
	for i, claim := range session.Claims {
		if claim.ID == req.ClaimID {
			claimIndex = i
			break
		}
	}
	if claimIndex < 0 {
		writeIndistinguishable(w)
		return
	}

	now := time.Now().UTC()
	claim := session.Claims[claimIndex]
	if req.Approve && sasStateForClaim(claim) != "verified" {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "sas_required"})
		return
	}
	if req.Approve {
		claim.Status = domain.SessionClaimApproved
		claim.ScanRequired = req.ScanRequired
		if req.ScanRequired {
			claim.ScanStatus = domain.ScanStatusPending
		} else {
			claim.ScanStatus = domain.ScanStatusNotRequired
		}
	} else {
		claim.Status = domain.SessionClaimRejected
	}
	claim.UpdatedAt = now
	session.Claims[claimIndex] = claim

	if err := s.store.UpdateSession(r.Context(), session); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	if !req.Approve {
		logging.Allowlist(s.logger, map[string]string{
			"event":           "session_rejected",
			"session_id_hash": anonHash(session.ID),
			"claim_id_hash":   anonHash(req.ClaimID),
		})
		writeJSON(w, http.StatusOK, sessionApproveResponse{
			Status: string(domain.SessionClaimRejected),
		})
		return
	}

	auth := domain.SessionAuthContext{
		SessionID:         session.ID,
		ClaimID:           claim.ID,
		SenderPubKeyB64:   claim.SenderPubKeyB64,
		ReceiverPubKeyB64: session.ReceiverPubKeyB64,
		ApprovedAt:        now,
	}
	if err := s.store.SaveSessionAuthContext(r.Context(), auth); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	scope := transferScope(session.ID, claim.ID)
	transferToken, err := s.tokens.Issue(r.Context(), scope, s.cfg.TransferTokenTTL)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	logging.Allowlist(s.logger, map[string]string{
		"event":           "session_approved",
		"session_id_hash": anonHash(session.ID),
		"claim_id_hash":   anonHash(claim.ID),
	})

	writeJSON(w, http.StatusOK, sessionApproveResponse{
		Status:          string(domain.SessionClaimApproved),
		TransferToken:   transferToken,
		SenderPubKeyB64: claim.SenderPubKeyB64,
	})
}

func (s *Server) handlePollSession(w http.ResponseWriter, r *http.Request) {
	sessionID := r.URL.Query().Get("session_id")
	if sessionID == "" {
		writeIndistinguishable(w)
		return
	}

	session, err := s.store.GetSession(r.Context(), sessionID)
	if err != nil {
		writeIndistinguishable(w)
		return
	}
	if time.Now().UTC().After(session.ExpiresAt) {
		writeIndistinguishable(w)
		return
	}

	claimToken := r.URL.Query().Get("claim_token")
	if claimToken != "" {
		if session.ClaimTokenHash == "" || tokenHash(claimToken) != session.ClaimTokenHash {
			writeIndistinguishable(w)
			return
		}
		status := domain.SessionClaimPending
		claimID := ""
		transferToken := ""
		sasState := "pending"
		if len(session.Claims) > 0 {
			claimID = session.Claims[0].ID
			status = session.Claims[0].Status
		}
		scanRequired := false
		scanStatus := ""
		if claimID != "" {
			claim, ok := findClaim(session, claimID)
			if ok {
				scanRequired = claim.ScanRequired
				if claim.ScanRequired {
					scanStatus = string(claim.ScanStatus)
				}
				sasState = sasStateForClaim(claim)
			}
		}
		if claimID != "" {
			scope := transferScope(session.ID, claimID)
			if status == domain.SessionClaimApproved {
				if _, err := s.store.GetSessionAuthContext(r.Context(), session.ID, claimID); err == nil {
					transferToken, _ = s.tokens.Issue(r.Context(), scope, s.cfg.TransferTokenTTL)
				}
			}
		}
		writeJSON(w, http.StatusOK, sessionPollSenderResponse{
			SessionID:         session.ID,
			ExpiresAt:         session.ExpiresAt.Format(time.RFC3339),
			ClaimID:           claimID,
			Status:            string(status),
			SASState:          sasState,
			ReceiverPubKeyB64: session.ReceiverPubKeyB64,
			TransferToken:     transferToken,
			ScanRequired:      scanRequired,
			ScanStatus:        scanStatus,
		})
		return
	}

	claims := make([]sessionPollClaimSummary, 0)
	for _, claim := range session.Claims {
		if claim.Status == domain.SessionClaimPending {
			summary := sessionPollClaimSummary{
				ClaimID:          claim.ID,
				SenderLabel:      claim.SenderLabel,
				ShortFingerprint: shortFingerprint(claim.SenderPubKeyB64),
				SenderPubKeyB64:  claim.SenderPubKeyB64,
				ScanRequired:     claim.ScanRequired,
				SASState:         sasStateForClaim(claim),
			}
			if claim.ScanRequired {
				summary.ScanStatus = string(claim.ScanStatus)
			}
			claims = append(claims, summary)
			continue
		}
		if claim.Status == domain.SessionClaimApproved && claim.TransferReady {
			summary := sessionPollClaimSummary{
				ClaimID:          claim.ID,
				SenderLabel:      claim.SenderLabel,
				ShortFingerprint: shortFingerprint(claim.SenderPubKeyB64),
				TransferID:       claim.TransferID,
				ScanRequired:     claim.ScanRequired,
				SASState:         sasStateForClaim(claim),
			}
			if claim.ScanRequired {
				summary.ScanStatus = string(claim.ScanStatus)
			}
			claims = append(claims, summary)
		}
	}

	writeJSON(w, http.StatusOK, sessionPollReceiverResponse{
		SessionID: session.ID,
		ExpiresAt: session.ExpiresAt.Format(time.RFC3339),
		Claims:    claims,
		SASState:  sasStateForClaims(claims),
	})
}

func (s *Server) handleCommitSAS(w http.ResponseWriter, r *http.Request) {
	var req sessionSASCommitRequest
	if err := decodeJSON(w, r, &req, 8<<10); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if req.SessionID == "" || req.ClaimID == "" || !req.SASConfirmed {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if req.Role != "sender" && req.Role != "receiver" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}

	session, err := s.store.GetSession(r.Context(), req.SessionID)
	if err != nil {
		writeIndistinguishable(w)
		return
	}
	if time.Now().UTC().After(session.ExpiresAt) {
		writeIndistinguishable(w)
		return
	}

	claimIndex := -1
	for i, claim := range session.Claims {
		if claim.ID == req.ClaimID {
			claimIndex = i
			break
		}
	}
	if claimIndex < 0 {
		writeIndistinguishable(w)
		return
	}
	now := time.Now().UTC()
	claim := session.Claims[claimIndex]
	if req.Role == "sender" {
		claim.SASSenderConfirmed = true
	} else {
		claim.SASReceiverConfirmed = true
	}
	claim.UpdatedAt = now
	session.Claims[claimIndex] = claim
	if err := s.store.UpdateSession(r.Context(), session); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	writeJSON(w, http.StatusOK, sessionSASStatusResponse{
		SASState: sasStateForClaim(claim),
	})
}

func (s *Server) handleSASStatus(w http.ResponseWriter, r *http.Request) {
	sessionID := r.URL.Query().Get("session_id")
	claimID := r.URL.Query().Get("claim_id")
	if sessionID == "" || claimID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	session, err := s.store.GetSession(r.Context(), sessionID)
	if err != nil {
		writeIndistinguishable(w)
		return
	}
	if time.Now().UTC().After(session.ExpiresAt) {
		writeIndistinguishable(w)
		return
	}
	for _, claim := range session.Claims {
		if claim.ID == claimID {
			writeJSON(w, http.StatusOK, sessionSASStatusResponse{
				SASState: sasStateForClaim(claim),
			})
			return
		}
	}
	writeIndistinguishable(w)
}

func shortFingerprint(value string) string {
	hash := anonHash(value)
	if hash == "" {
		return ""
	}
	if len(hash) <= 8 {
		return strings.ToUpper(hash)
	}
	return strings.ToUpper(hash[:8])
}

func sasStateForClaim(claim domain.SessionClaim) string {
	if claim.SASSenderConfirmed && claim.SASReceiverConfirmed {
		return "verified"
	}
	if claim.SASSenderConfirmed {
		return "sender_confirmed"
	}
	if claim.SASReceiverConfirmed {
		return "receiver_confirmed"
	}
	return "pending"
}

func sasStateForClaims(claims []sessionPollClaimSummary) string {
	state := "pending"
	for _, claim := range claims {
		switch claim.SASState {
		case "verified":
			return "verified"
		case "sender_confirmed", "receiver_confirmed":
			state = claim.SASState
		}
	}
	return state
}

func transferScope(sessionID string, claimID string) string {
	return "transfer:session:" + sessionID + ":claim:" + claimID
}

func (s *Server) handleGetTransferManifest(w http.ResponseWriter, r *http.Request) {
	sessionID := r.URL.Query().Get("session_id")
	transferID := r.URL.Query().Get("transfer_id")
	if sessionID == "" || transferID == "" {
		writeIndistinguishable(w)
		return
	}

	token := bearerToken(r)
	session, claimID, ok := s.authorizeTransfer(r.Context(), sessionID, token)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	claim, ok := findClaim(session, claimID)
	if !ok || claim.TransferID == "" || claim.TransferID != transferID {
		writeIndistinguishable(w)
		return
	}

	manifest, err := s.transfers.GetManifest(r.Context(), transferID)
	if err != nil {
		writeIndistinguishable(w)
		return
	}

	logging.Allowlist(s.logger, map[string]string{
		"event":            "transfer_manifest_read",
		"transfer_id_hash": anonHash(transferID),
		"session_id_hash":  anonHash(session.ID),
		"claim_id_hash":    anonHash(claimID),
	})

	w.Header().Set("Content-Type", "application/octet-stream")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(manifest)
}

func (s *Server) handleInitTransfer(w http.ResponseWriter, r *http.Request) {
	var req transferInitRequest
	if err := decodeJSON(w, r, &req, 32<<10); err != nil {
		writeIndistinguishable(w)
		return
	}
	if req.SessionID == "" || req.TransferToken == "" || req.FileManifestCiphertextB64 == "" || req.TotalBytes < 0 {
		writeIndistinguishable(w)
		return
	}

	session, claimID, ok := s.authorizeTransfer(r.Context(), req.SessionID, req.TransferToken)
	if !ok {
		writeIndistinguishable(w)
		return
	}

	manifest, err := base64.StdEncoding.DecodeString(req.FileManifestCiphertextB64)
	if err != nil {
		writeIndistinguishable(w)
		return
	}

	transferID := req.TransferID
	expiresAt := session.ExpiresAt
	if transferID != "" {
		if err := s.transfers.CreateTransferWithID(r.Context(), transferID, manifest, req.TotalBytes, expiresAt); err != nil {
			writeIndistinguishable(w)
			return
		}
	} else {
		transferID, err = s.transfers.CreateTransfer(r.Context(), manifest, req.TotalBytes, expiresAt)
		if err != nil {
			writeIndistinguishable(w)
			return
		}
	}

	if err := s.setTransferID(r.Context(), session, claimID, transferID); err != nil {
		writeIndistinguishable(w)
		return
	}

	writeJSON(w, http.StatusOK, transferInitResponse{TransferID: transferID})
}

func (s *Server) handleUploadChunk(w http.ResponseWriter, r *http.Request) {
	sessionID := headerValue(r, "session_id")
	transferID := headerValue(r, "transfer_id")
	offsetRaw := headerValue(r, "offset")
	if sessionID == "" || transferID == "" || offsetRaw == "" {
		writeIndistinguishable(w)
		return
	}
	offset, err := strconv.ParseInt(offsetRaw, 10, 64)
	if err != nil || offset < 0 {
		writeIndistinguishable(w)
		return
	}

	token := bearerToken(r)
	session, claimID, ok := s.authorizeTransfer(r.Context(), sessionID, token)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	claim, ok := findClaim(session, claimID)
	if !ok || claim.TransferID == "" || claim.TransferID != transferID {
		writeIndistinguishable(w)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 32<<20)
	data, err := io.ReadAll(r.Body)
	if err != nil || len(data) == 0 {
		writeIndistinguishable(w)
		return
	}

	if err := s.transfers.AcceptChunk(r.Context(), transferID, offset, data); err != nil {
		writeIndistinguishable(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleFinalizeTransfer(w http.ResponseWriter, r *http.Request) {
	var req transferFinalizeRequest
	if err := decodeJSON(w, r, &req, 8<<10); err != nil {
		writeIndistinguishable(w)
		return
	}
	if req.SessionID == "" || req.TransferID == "" || req.TransferToken == "" {
		writeIndistinguishable(w)
		return
	}

	session, claimID, ok := s.authorizeTransfer(r.Context(), req.SessionID, req.TransferToken)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	claim, ok := findClaim(session, claimID)
	if !ok || (claim.TransferID != "" && claim.TransferID != req.TransferID) {
		writeIndistinguishable(w)
		return
	}

	if err := s.transfers.FinalizeTransfer(r.Context(), req.TransferID); err != nil {
		writeIndistinguishable(w)
		return
	}

	if err := s.markTransferReady(r.Context(), session, claimID, req.TransferID); err != nil {
		writeIndistinguishable(w)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleDownloadTransfer(w http.ResponseWriter, r *http.Request) {
	sessionID := r.URL.Query().Get("session_id")
	transferID := r.URL.Query().Get("transfer_id")
	if sessionID == "" || transferID == "" {
		writeIndistinguishable(w)
		return
	}

	rangeHeader := r.Header.Get("Range")
	start, length, ok := parseRange(rangeHeader)
	if !ok {
		writeIndistinguishable(w)
		return
	}

	token := bearerToken(r)
	session, claimID, ok := s.authorizeTransfer(r.Context(), sessionID, token)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	claim, ok := findClaim(session, claimID)
	if !ok || claim.TransferID == "" || claim.TransferID != transferID || !claim.TransferReady {
		writeIndistinguishable(w)
		return
	}

	data, err := s.transfers.ReadRange(r.Context(), transferID, start, length)
	if err != nil {
		writeIndistinguishable(w)
		return
	}
	if len(data) == 0 {
		writeIndistinguishable(w)
		return
	}
	meta, err := s.store.GetTransferMeta(r.Context(), transferID)
	if err != nil {
		writeIndistinguishable(w)
		return
	}

	end := start + int64(len(data)) - 1
	totalBytes := meta.TotalBytes
	if totalBytes <= 0 {
		totalBytes = end + 1
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Content-Range", "bytes "+strconv.FormatInt(start, 10)+"-"+strconv.FormatInt(end, 10)+"/"+strconv.FormatInt(totalBytes, 10))
	w.Header().Set("Content-Length", strconv.FormatInt(int64(len(data)), 10))
	w.WriteHeader(http.StatusPartialContent)
	_, _ = w.Write(data)
}

func (s *Server) handleTransferReceipt(w http.ResponseWriter, r *http.Request) {
	var req transferReceiptRequest
	if err := decodeJSON(w, r, &req, 8<<10); err != nil {
		writeIndistinguishable(w)
		return
	}
	if req.SessionID == "" || req.TransferID == "" || req.TransferToken == "" || req.Status != "complete" {
		writeIndistinguishable(w)
		return
	}

	session, claimID, ok := s.authorizeTransfer(r.Context(), req.SessionID, req.TransferToken)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	claim, ok := findClaim(session, claimID)
	if !ok || claim.TransferID == "" || claim.TransferID != req.TransferID {
		writeIndistinguishable(w)
		return
	}

	if err := s.transfers.DeleteOnReceipt(r.Context(), req.TransferID); err != nil {
		writeIndistinguishable(w)
		return
	}
	if err := s.markTransferDeleted(r.Context(), session, claimID); err != nil {
		writeIndistinguishable(w)
		return
	}

	logging.Allowlist(s.logger, map[string]string{
		"event":            "transfer_receipt",
		"session_id_hash":  anonHash(session.ID),
		"claim_id_hash":    anonHash(claimID),
		"transfer_id_hash": anonHash(req.TransferID),
	})

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleScanInit(w http.ResponseWriter, r *http.Request) {
	var req scanInitRequest
	if err := decodeJSON(w, r, &req, 8<<10); err != nil {
		writeIndistinguishable(w)
		return
	}
	if req.SessionID == "" || req.TransferID == "" || req.TransferToken == "" || req.TotalBytes < 0 {
		writeIndistinguishable(w)
		return
	}

	session, claimID, ok := s.authorizeTransfer(r.Context(), req.SessionID, req.TransferToken)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	claim, ok := findClaim(session, claimID)
	if !ok || claim.TransferID != req.TransferID || !claim.ScanRequired {
		writeIndistinguishable(w)
		return
	}

	if req.ChunkSize <= 0 {
		req.ChunkSize = 64 * 1024
	}
	scanID, scanKey, err := s.transfers.InitScan(
		r.Context(),
		session.ID,
		claimID,
		req.TransferID,
		req.TotalBytes,
		req.ChunkSize,
		session.ExpiresAt,
	)
	if err != nil {
		writeIndistinguishable(w)
		return
	}

	writeJSON(w, http.StatusOK, scanInitResponse{
		ScanID:     scanID,
		ScanKeyB64: scanKey,
	})
}

func (s *Server) handleScanChunk(w http.ResponseWriter, r *http.Request) {
	scanID := headerValue(r, "scan_id")
	chunkIndexRaw := headerValue(r, "chunk_index")
	token := bearerToken(r)
	if scanID == "" || chunkIndexRaw == "" || token == "" {
		writeIndistinguishable(w)
		return
	}
	chunkIndex, err := strconv.Atoi(chunkIndexRaw)
	if err != nil || chunkIndex < 0 {
		writeIndistinguishable(w)
		return
	}

	scanSession, err := s.store.GetScanSession(r.Context(), scanID)
	if err != nil {
		writeIndistinguishable(w)
		return
	}
	if time.Now().UTC().After(scanSession.ExpiresAt) {
		writeIndistinguishable(w)
		return
	}

	session, claimID, ok := s.authorizeTransfer(r.Context(), scanSession.SessionID, token)
	if !ok || claimID != scanSession.ClaimID {
		writeIndistinguishable(w)
		return
	}
	_ = session

	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxScanBytes)
	data, err := io.ReadAll(r.Body)
	if err != nil || len(data) == 0 {
		writeIndistinguishable(w)
		return
	}
	if err := s.transfers.StoreScanChunk(r.Context(), scanID, chunkIndex, data); err != nil {
		writeIndistinguishable(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleScanFinalize(w http.ResponseWriter, r *http.Request) {
	var req scanFinalizeRequest
	if err := decodeJSON(w, r, &req, 8<<10); err != nil {
		writeIndistinguishable(w)
		return
	}
	if req.ScanID == "" || req.TransferToken == "" {
		writeIndistinguishable(w)
		return
	}

	scanSession, err := s.store.GetScanSession(r.Context(), req.ScanID)
	if err != nil {
		writeIndistinguishable(w)
		return
	}
	if time.Now().UTC().After(scanSession.ExpiresAt) {
		writeIndistinguishable(w)
		return
	}
	session, claimID, ok := s.authorizeTransfer(r.Context(), scanSession.SessionID, req.TransferToken)
	if !ok || claimID != scanSession.ClaimID {
		writeIndistinguishable(w)
		return
	}

	status, err := s.transfers.FinalizeScan(r.Context(), req.ScanID, s.scanner, s.cfg.MaxScanBytes, s.cfg.MaxScanDuration)
	if err != nil {
		writeIndistinguishable(w)
		return
	}
	if err := s.updateClaimScanStatus(r.Context(), session, claimID, status); err != nil {
		writeIndistinguishable(w)
		return
	}

	writeJSON(w, http.StatusOK, scanFinalizeResponse{
		Status: string(status),
	})
}

func (s *Server) authorizeTransfer(ctx context.Context, sessionID string, token string) (domain.Session, string, bool) {
	if sessionID == "" || token == "" {
		return domain.Session{}, "", false
	}
	session, err := s.store.GetSession(ctx, sessionID)
	if err != nil {
		return domain.Session{}, "", false
	}
	if time.Now().UTC().After(session.ExpiresAt) {
		return domain.Session{}, "", false
	}

	claimID := ""
	for _, claim := range session.Claims {
		scope := transferScope(session.ID, claim.ID)
		ok, err := s.tokens.Validate(ctx, token, scope)
		if err != nil {
			return domain.Session{}, "", false
		}
		if ok {
			claimID = claim.ID
			break
		}
	}
	if claimID == "" {
		return domain.Session{}, "", false
	}
	if _, err := s.store.GetSessionAuthContext(ctx, session.ID, claimID); err != nil {
		return domain.Session{}, "", false
	}
	return session, claimID, true
}

func (s *Server) setTransferID(ctx context.Context, session domain.Session, claimID string, transferID string) error {
	for i, claim := range session.Claims {
		if claim.ID != claimID {
			continue
		}
		if claim.TransferID != "" {
			return storage.ErrConflict
		}
		claim.TransferID = transferID
		claim.TransferReady = false
		claim.UpdatedAt = time.Now().UTC()
		session.Claims[i] = claim
		return s.store.UpdateSession(ctx, session)
	}
	return storage.ErrNotFound
}

func (s *Server) markTransferReady(ctx context.Context, session domain.Session, claimID string, transferID string) error {
	for i, claim := range session.Claims {
		if claim.ID != claimID {
			continue
		}
		if claim.TransferID != "" && claim.TransferID != transferID {
			return storage.ErrConflict
		}
		claim.TransferID = transferID
		claim.TransferReady = true
		claim.UpdatedAt = time.Now().UTC()
		session.Claims[i] = claim
		return s.store.UpdateSession(ctx, session)
	}
	return storage.ErrNotFound
}

func (s *Server) markTransferDeleted(ctx context.Context, session domain.Session, claimID string) error {
	for i, claim := range session.Claims {
		if claim.ID != claimID {
			continue
		}
		claim.TransferID = ""
		claim.TransferReady = false
		claim.UpdatedAt = time.Now().UTC()
		session.Claims[i] = claim
		return s.store.UpdateSession(ctx, session)
	}
	return storage.ErrNotFound
}

func findClaim(session domain.Session, claimID string) (domain.SessionClaim, bool) {
	for _, claim := range session.Claims {
		if claim.ID == claimID {
			return claim, true
		}
	}
	return domain.SessionClaim{}, false
}

func (s *Server) updateClaimScanStatus(ctx context.Context, session domain.Session, claimID string, status domain.ScanStatus) error {
	for i, claim := range session.Claims {
		if claim.ID != claimID {
			continue
		}
		claim.ScanStatus = status
		claim.UpdatedAt = time.Now().UTC()
		session.Claims[i] = claim
		return s.store.UpdateSession(ctx, session)
	}
	return storage.ErrNotFound
}

func headerValue(r *http.Request, key string) string {
	if value := r.Header.Get(key); value != "" {
		return value
	}
	canonical := textproto.CanonicalMIMEHeaderKey(strings.ReplaceAll(key, "_", "-"))
	return r.Header.Get(canonical)
}

func parseRange(header string) (int64, int64, bool) {
	if header == "" {
		return 0, 0, false
	}
	if !strings.HasPrefix(header, "bytes=") {
		return 0, 0, false
	}
	parts := strings.Split(strings.TrimPrefix(header, "bytes="), "-")
	if len(parts) != 2 {
		return 0, 0, false
	}
	if parts[0] == "" || parts[1] == "" {
		return 0, 0, false
	}
	start, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || start < 0 {
		return 0, 0, false
	}
	end, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || end < start {
		return 0, 0, false
	}
	return start, end - start + 1, true
}
