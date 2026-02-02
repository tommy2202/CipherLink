package api

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"io"
	"net/http"
	"net/textproto"
	"net/url"
	"strconv"
	"strings"
	"time"

	"universaldrop/internal/auth"
	"universaldrop/internal/config"
	"universaldrop/internal/domain"
	"universaldrop/internal/logging"
	"universaldrop/internal/storage"
	"universaldrop/internal/transfer"
)

type sessionCreateResponse struct {
	SessionID         string `json:"session_id"`
	ExpiresAt         string `json:"expires_at"`
	ClaimToken        string `json:"claim_token"`
	ReceiverToken     string `json:"receiver_token"`
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
	TransferToken    string `json:"transfer_token,omitempty"`
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
	P2PToken          string `json:"p2p_token,omitempty"`
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
	P2PToken        string `json:"p2p_token,omitempty"`
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
	TransferID  string `json:"transfer_id"`
	UploadToken string `json:"upload_token,omitempty"`
}

type transferFinalizeRequest struct {
	SessionID     string `json:"session_id"`
	TransferID    string `json:"transfer_id"`
	TransferToken string `json:"transfer_token"`
}

type downloadTokenRequest struct {
	SessionID     string `json:"session_id"`
	TransferID    string `json:"transfer_id"`
	TransferToken string `json:"transfer_token"`
}

type downloadTokenResponse struct {
	DownloadToken string `json:"download_token"`
	ExpiresAt     string `json:"expires_at"`
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
	if _, ok := s.requireCapability(r, "", auth.Requirement{
		Scope:             auth.ScopeSessionCreate,
		ReceiverPubKeyB64: req.ReceiverPubKeyB64,
		Visibility:        auth.VisibilityE2E,
		SingleUse:         true,
	}); !ok {
		writeIndistinguishable(w)
		return
	}
	ip := clientIP(r)
	if !s.quotas.AllowSession(ip, "", s.cfg.Quotas.SessionsPerDayIP, s.cfg.Quotas.SessionsPerDaySession) {
		logging.Allowlist(s.logger, map[string]string{
			"event":   "quota_blocked",
			"scope":   "session_create",
			"ip_hash": anonHash(ip),
		})
		writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "quota_exceeded"})
		return
	}

	var session domain.Session
	var claimToken string
	var receiverToken string
	var err error
	for attempt := 0; attempt < 3; attempt++ {
		var sessionID string
		sessionID, err = randomBase64(18)
		if err != nil {
			break
		}
		receiverPubKey := req.ReceiverPubKeyB64

		now := time.Now().UTC()
		expiresAt := now.Add(ttl)
		claimToken, err = s.capabilities.Issue(auth.IssueSpec{
			Scope:             auth.ScopeSessionClaim,
			TTL:               ttl,
			SessionID:         sessionID,
			ReceiverPubKeyB64: receiverPubKey,
			PeerID:            receiverPubKey,
			Visibility:        auth.VisibilityE2E,
			AllowedRoutes:     []string{"/v1/session/claim", "/v1/session/poll"},
			SingleUse:         true,
		})
		if err != nil {
			break
		}
		receiverToken, err = s.capabilities.Issue(auth.IssueSpec{
			Scope:             auth.ScopeSessionApprove,
			TTL:               ttl,
			SessionID:         sessionID,
			ReceiverPubKeyB64: receiverPubKey,
			PeerID:            receiverPubKey,
			Visibility:        auth.VisibilityE2E,
			AllowedRoutes:     []string{"/v1/session/approve"},
			SingleUse:         true,
		})
		if err != nil {
			break
		}
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
	s.metrics.IncSessionsCreated()

	writeJSON(w, http.StatusOK, sessionCreateResponse{
		SessionID:         session.ID,
		ExpiresAt:         session.ExpiresAt.Format(time.RFC3339),
		ClaimToken:        claimToken,
		ReceiverToken:     receiverToken,
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
	if _, ok := s.requireCapability(r, req.ClaimToken, auth.Requirement{
		Scope:             auth.ScopeSessionClaim,
		SessionID:         session.ID,
		ReceiverPubKeyB64: session.ReceiverPubKeyB64,
		Visibility:        auth.VisibilityE2E,
		SingleUse:         true,
	}); !ok {
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
	if _, ok := s.requireCapability(r, "", auth.Requirement{
		Scope:             auth.ScopeSessionApprove,
		SessionID:         session.ID,
		ReceiverPubKeyB64: session.ReceiverPubKeyB64,
		Visibility:        auth.VisibilityE2E,
		SingleUse:         true,
	}); !ok {
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

	authCtx := domain.SessionAuthContext{
		SessionID:         session.ID,
		ClaimID:           claim.ID,
		SenderPubKeyB64:   claim.SenderPubKeyB64,
		ReceiverPubKeyB64: session.ReceiverPubKeyB64,
		ApprovedAt:        now,
	}
	if err := s.store.SaveSessionAuthContext(r.Context(), authCtx); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	transferToken, err := s.capabilities.Issue(auth.IssueSpec{
		Scope:             auth.ScopeTransferReceive,
		TTL:               s.cfg.TransferTokenTTL,
		SessionID:         session.ID,
		ClaimID:           claim.ID,
		PeerID:            session.ReceiverPubKeyB64,
		SenderPubKeyB64:   claim.SenderPubKeyB64,
		ReceiverPubKeyB64: session.ReceiverPubKeyB64,
		Visibility:        auth.VisibilityE2E,
		MaxRateBps:        s.cfg.Throttles.TransferBandwidthCapBps,
		AllowedRoutes:     []string{"/v1/transfer/manifest", "/v1/transfer/download_token", "/v1/transfer/receipt"},
	})
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}
	p2pToken, err := s.capabilities.Issue(auth.IssueSpec{
		Scope:             auth.ScopeTransferSignal,
		TTL:               s.cfg.TransferTokenTTL,
		SessionID:         session.ID,
		ClaimID:           claim.ID,
		PeerID:            session.ReceiverPubKeyB64,
		SenderPubKeyB64:   claim.SenderPubKeyB64,
		ReceiverPubKeyB64: session.ReceiverPubKeyB64,
		Visibility:        auth.VisibilityE2E,
		AllowedRoutes:     []string{"/v1/p2p/offer", "/v1/p2p/answer", "/v1/p2p/ice", "/v1/p2p/ice_config", "/v1/p2p/poll"},
	})
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
		P2PToken:        p2pToken,
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
		if _, ok := s.requireCapability(r, claimToken, auth.Requirement{
			Scope:             auth.ScopeSessionClaim,
			SessionID:         session.ID,
			ReceiverPubKeyB64: session.ReceiverPubKeyB64,
			Visibility:        auth.VisibilityE2E,
			SingleUse:         false,
		}); !ok {
			writeIndistinguishable(w)
			return
		}
		status := domain.SessionClaimPending
		claimID := ""
		transferToken := ""
		p2pToken := ""
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
			if status == domain.SessionClaimApproved {
				if _, err := s.store.GetSessionAuthContext(r.Context(), session.ID, claimID); err == nil {
					claim, ok := findClaim(session, claimID)
					if ok {
						transferToken, _ = s.capabilities.Issue(auth.IssueSpec{
							Scope:             auth.ScopeTransferInit,
							TTL:               s.cfg.TransferTokenTTL,
							SessionID:         session.ID,
							ClaimID:           claimID,
							PeerID:            claim.SenderPubKeyB64,
							SenderPubKeyB64:   claim.SenderPubKeyB64,
							ReceiverPubKeyB64: session.ReceiverPubKeyB64,
							Visibility:        auth.VisibilityE2E,
							MaxRateBps:        s.cfg.Throttles.TransferBandwidthCapBps,
							AllowedRoutes:     []string{"/v1/transfer/init"},
							SingleUse:         true,
						})
						p2pToken, _ = s.capabilities.Issue(auth.IssueSpec{
							Scope:             auth.ScopeTransferSignal,
							TTL:               s.cfg.TransferTokenTTL,
							SessionID:         session.ID,
							ClaimID:           claimID,
							PeerID:            claim.SenderPubKeyB64,
							SenderPubKeyB64:   claim.SenderPubKeyB64,
							ReceiverPubKeyB64: session.ReceiverPubKeyB64,
							Visibility:        auth.VisibilityE2E,
							AllowedRoutes:     []string{"/v1/p2p/offer", "/v1/p2p/answer", "/v1/p2p/ice", "/v1/p2p/ice_config", "/v1/p2p/poll"},
						})
					}
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
			P2PToken:          p2pToken,
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
		if claim.Status == domain.SessionClaimApproved && claim.TransferID != "" {
			summary := sessionPollClaimSummary{
				ClaimID:          claim.ID,
				SenderLabel:      claim.SenderLabel,
				ShortFingerprint: shortFingerprint(claim.SenderPubKeyB64),
				TransferID:       claim.TransferID,
				ScanRequired:     claim.ScanRequired,
				SASState:         sasStateForClaim(claim),
			}
			meta, err := s.store.GetTransferMeta(r.Context(), claim.TransferID)
			if err == nil {
				transferToken, _ := s.capabilities.Issue(auth.IssueSpec{
					Scope:             auth.ScopeTransferReceive,
					TTL:               s.cfg.TransferTokenTTL,
					SessionID:         session.ID,
					ClaimID:           claim.ID,
					TransferID:        claim.TransferID,
					PeerID:            session.ReceiverPubKeyB64,
					SenderPubKeyB64:   claim.SenderPubKeyB64,
					ReceiverPubKeyB64: session.ReceiverPubKeyB64,
					ManifestHash:      meta.ManifestHash,
					Visibility:        auth.VisibilityE2E,
					MaxBytes:          meta.TotalBytes,
					MaxRateBps:        s.cfg.Throttles.TransferBandwidthCapBps,
					AllowedRoutes:     []string{"/v1/transfer/manifest", "/v1/transfer/download_token", "/v1/transfer/receipt"},
				})
				summary.TransferToken = transferToken
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

func (s *Server) downloadTokenTTL() time.Duration {
	ttl := s.cfg.DownloadTokenTTL
	if ttl <= 0 {
		ttl = s.cfg.TransferTokenTTL
	}
	if ttl <= 0 {
		ttl = config.DefaultTransferTokenTTL
	}
	return ttl
}

func (s *Server) handleGetTransferManifest(w http.ResponseWriter, r *http.Request) {
	sessionID := r.URL.Query().Get("session_id")
	transferID := r.URL.Query().Get("transfer_id")
	if sessionID == "" || transferID == "" {
		writeIndistinguishable(w)
		return
	}

	token := bearerToken(r)
	authz, ok := s.authorizeTransfer(r, sessionID, transferID, token, auth.ScopeTransferReceive, 0, false)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	session := authz.Session
	claim := authz.Claim

	manifest, err := s.transfers.GetManifest(r.Context(), transferID)
	if err != nil {
		writeIndistinguishable(w)
		return
	}

	logging.Allowlist(s.logger, map[string]string{
		"event":            "transfer_manifest_read",
		"transfer_id_hash": anonHash(transferID),
		"session_id_hash":  anonHash(session.ID),
		"claim_id_hash":    anonHash(claim.ID),
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

	authz, ok := s.authorizeTransfer(r, req.SessionID, "", req.TransferToken, auth.ScopeTransferInit, 0, true)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	session := authz.Session
	claimID := authz.Claim.ID

	manifest, err := base64.StdEncoding.DecodeString(req.FileManifestCiphertextB64)
	if err != nil {
		writeIndistinguishable(w)
		return
	}

	transferID := req.TransferID
	manifestSum := sha256.Sum256(manifest)
	manifestHash := base64.RawURLEncoding.EncodeToString(manifestSum[:])
	expiresAt := session.ExpiresAt
	if transferID != "" {
		if err := s.transfers.CreateTransferWithID(r.Context(), transferID, manifest, req.TotalBytes, expiresAt, manifestHash); err != nil {
			writeIndistinguishable(w)
			return
		}
	} else {
		transferID, err = s.transfers.CreateTransfer(r.Context(), manifest, req.TotalBytes, expiresAt, manifestHash)
		if err != nil {
			writeIndistinguishable(w)
			return
		}
	}
	ip := clientIP(r)
	if !s.quotas.BeginTransfer(
		transferID,
		ip,
		session.ID,
		s.cfg.Quotas.TransfersPerDayIP,
		s.cfg.Quotas.TransfersPerDaySession,
		s.cfg.Quotas.ConcurrentTransfersIP,
		s.cfg.Quotas.ConcurrentTransfersSession,
	) {
		_ = s.transfers.DeleteOnReceipt(r.Context(), transferID)
		logging.Allowlist(s.logger, map[string]string{
			"event":            "quota_blocked",
			"scope":            "transfer_create",
			"ip_hash":          anonHash(ip),
			"session_id_hash":  anonHash(session.ID),
			"transfer_id_hash": anonHash(transferID),
		})
		writeIndistinguishable(w)
		return
	}

	if err := s.setTransferID(r.Context(), session, claimID, transferID); err != nil {
		s.quotas.EndTransfer(transferID)
		_ = s.transfers.DeleteOnReceipt(r.Context(), transferID)
		writeIndistinguishable(w)
		return
	}

	claim, ok := findClaim(session, claimID)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	uploadToken, err := s.capabilities.Issue(auth.IssueSpec{
		Scope:             auth.ScopeTransferSend,
		TTL:               s.cfg.TransferTokenTTL,
		SessionID:         session.ID,
		ClaimID:           claimID,
		TransferID:        transferID,
		PeerID:            claim.SenderPubKeyB64,
		SenderPubKeyB64:   claim.SenderPubKeyB64,
		ReceiverPubKeyB64: session.ReceiverPubKeyB64,
		ManifestHash:      manifestHash,
		Visibility:        auth.VisibilityE2E,
		MaxBytes:          req.TotalBytes,
		MaxRateBps:        s.cfg.Throttles.TransferBandwidthCapBps,
		AllowedRoutes:     []string{"/v1/transfer/chunk", "/v1/transfer/finalize", "/v1/transfer/scan_init", "/v1/transfer/scan_chunk", "/v1/transfer/scan_finalize"},
	})
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}
	s.metrics.IncTransfersStarted()
	writeJSON(w, http.StatusOK, transferInitResponse{TransferID: transferID, UploadToken: uploadToken})
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

	ip := clientIP(r)

	r.Body = http.MaxBytesReader(w, r.Body, 32<<20)
	data, err := io.ReadAll(r.Body)
	if err != nil || len(data) == 0 {
		writeIndistinguishable(w)
		return
	}
	token := bearerToken(r)
	authz, ok := s.authorizeTransfer(r, sessionID, transferID, token, auth.ScopeTransferSend, int64(len(data)), false)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	session := authz.Session
	if !s.quotas.AddBytes(ip, session.ID, int64(len(data)), s.cfg.Quotas.BytesPerDayIP, s.cfg.Quotas.BytesPerDaySession) {
		logging.Allowlist(s.logger, map[string]string{
			"event":            "quota_blocked",
			"scope":            "upload_bytes",
			"ip_hash":          anonHash(ip),
			"session_id_hash":  anonHash(session.ID),
			"transfer_id_hash": anonHash(transferID),
		})
		writeIndistinguishable(w)
		return
	}
	waitTransfer := s.throttles.ReserveTransfer(transferID, int64(len(data)))
	waitGlobal := s.throttles.ReserveGlobal(int64(len(data)))
	if delay := maxDuration(waitTransfer, waitGlobal); delay > 0 {
		time.Sleep(delay)
	}

	if err := s.transfers.AcceptChunk(r.Context(), transferID, offset, data); err != nil {
		if errors.Is(err, transfer.ErrChunkConflict) {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "chunk_conflict"})
			return
		}
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

	authz, ok := s.authorizeTransfer(r, req.SessionID, req.TransferID, req.TransferToken, auth.ScopeTransferSend, 0, false)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	session := authz.Session
	claimID := authz.Claim.ID

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

func (s *Server) handleDownloadToken(w http.ResponseWriter, r *http.Request) {
	var req downloadTokenRequest
	if err := decodeJSON(w, r, &req, 8<<10); err != nil {
		writeIndistinguishable(w)
		return
	}
	if req.SessionID == "" || req.TransferID == "" || req.TransferToken == "" {
		writeIndistinguishable(w)
		return
	}
	authz, ok := s.authorizeTransfer(r, req.SessionID, req.TransferID, req.TransferToken, auth.ScopeTransferReceive, 0, false)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	claim := authz.Claim
	session := authz.Session
	if !claim.TransferReady {
		writeIndistinguishable(w)
		return
	}
	ttl := s.downloadTokenTTL()
	expiresAt := time.Now().UTC().Add(ttl)
	token, err := s.capabilities.Issue(auth.IssueSpec{
		Scope:             auth.ScopeTransferDownload,
		TTL:               ttl,
		SessionID:         session.ID,
		ClaimID:           claim.ID,
		TransferID:        req.TransferID,
		PeerID:            session.ReceiverPubKeyB64,
		SenderPubKeyB64:   claim.SenderPubKeyB64,
		ReceiverPubKeyB64: session.ReceiverPubKeyB64,
		ManifestHash:      authz.Meta.ManifestHash,
		Visibility:        auth.VisibilityE2E,
		MaxBytes:          authz.Meta.TotalBytes,
		MaxRateBps:        s.cfg.Throttles.TransferBandwidthCapBps,
		AllowedRoutes:     []string{"/v1/transfer/download"},
		SingleUse:         true,
	})
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}
	logging.Allowlist(s.logger, map[string]string{
		"event":            "download_token_issued",
		"session_id_hash":  anonHash(session.ID),
		"claim_id_hash":    anonHash(claim.ID),
		"transfer_id_hash": anonHash(req.TransferID),
	})
	writeJSON(w, http.StatusOK, downloadTokenResponse{
		DownloadToken: token,
		ExpiresAt:     expiresAt.Format(time.RFC3339),
	})
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

	ip := clientIP(r)
	downloadToken := headerValue(r, "download_token")
	if downloadToken == "" {
		writeIndistinguishable(w)
		return
	}
	capClaims, ok := s.requireCapability(r, downloadToken, auth.Requirement{
		Scope:      auth.ScopeTransferDownload,
		SessionID:  sessionID,
		TransferID: transferID,
		SingleUse:  true,
	})
	if !ok {
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
	claim, ok := findClaim(session, capClaims.ClaimID)
	if !ok || claim.TransferID != transferID || !claim.TransferReady {
		writeIndistinguishable(w)
		return
	}
	meta, err := s.store.GetTransferMeta(r.Context(), transferID)
	if err != nil {
		writeIndistinguishable(w)
		return
	}
	if !s.capabilities.ValidateClaims(capClaims, auth.Requirement{
		ClaimID:           claim.ID,
		TransferID:        transferID,
		SenderPubKeyB64:   claim.SenderPubKeyB64,
		ReceiverPubKeyB64: session.ReceiverPubKeyB64,
		ManifestHash:      meta.ManifestHash,
		Visibility:        auth.VisibilityE2E,
		MaxBytes:          meta.TotalBytes,
		RequestBytes:      length,
		MaxRateBps:        s.cfg.Throttles.TransferBandwidthCapBps,
		Route:             routePattern(r),
	}) {
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
	if !s.quotas.AddBytes(ip, session.ID, int64(len(data)), s.cfg.Quotas.BytesPerDayIP, s.cfg.Quotas.BytesPerDaySession) {
		logging.Allowlist(s.logger, map[string]string{
			"event":            "quota_blocked",
			"scope":            "download_bytes",
			"ip_hash":          anonHash(ip),
			"session_id_hash":  anonHash(session.ID),
			"transfer_id_hash": anonHash(transferID),
		})
		writeIndistinguishable(w)
		return
	}
	waitTransfer := s.throttles.ReserveTransfer(transferID, int64(len(data)))
	waitGlobal := s.throttles.ReserveGlobal(int64(len(data)))
	if delay := maxDuration(waitTransfer, waitGlobal); delay > 0 {
		time.Sleep(delay)
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

	authz, ok := s.authorizeTransfer(r, req.SessionID, req.TransferID, req.TransferToken, auth.ScopeTransferReceive, 0, false)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	session := authz.Session
	claimID := authz.Claim.ID

	if err := s.transfers.DeleteOnReceipt(r.Context(), req.TransferID); err != nil {
		writeIndistinguishable(w)
		return
	}
	if err := s.markTransferDeleted(r.Context(), session, claimID); err != nil {
		writeIndistinguishable(w)
		return
	}
	s.quotas.EndTransfer(req.TransferID)
	s.throttles.ForgetTransfer(req.TransferID)
	s.capabilities.RevokeTransfer(req.TransferID)
	s.metrics.IncTransfersCompleted()

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

	authz, ok := s.authorizeTransfer(r, req.SessionID, req.TransferID, req.TransferToken, auth.ScopeTransferSend, 0, false)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	session := authz.Session
	claim := authz.Claim
	claimID := claim.ID
	if !claim.ScanRequired {
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

	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxScanBytes)
	data, err := io.ReadAll(r.Body)
	if err != nil || len(data) == 0 {
		writeIndistinguishable(w)
		return
	}
	authz, ok := s.authorizeTransfer(r, scanSession.SessionID, scanSession.TransferID, token, auth.ScopeTransferSend, 0, false)
	if !ok || authz.Claim.ID != scanSession.ClaimID {
		writeIndistinguishable(w)
		return
	}
	ip := clientIP(r)
	if !s.quotas.AddBytes(ip, scanSession.SessionID, int64(len(data)), s.cfg.Quotas.BytesPerDayIP, s.cfg.Quotas.BytesPerDaySession) {
		logging.Allowlist(s.logger, map[string]string{
			"event":           "quota_blocked",
			"scope":           "scan_bytes",
			"ip_hash":         anonHash(ip),
			"session_id_hash": anonHash(scanSession.SessionID),
		})
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
	authz, ok := s.authorizeTransfer(r, scanSession.SessionID, scanSession.TransferID, req.TransferToken, auth.ScopeTransferSend, 0, false)
	if !ok || authz.Claim.ID != scanSession.ClaimID {
		writeIndistinguishable(w)
		return
	}
	session := authz.Session
	claimID := authz.Claim.ID

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

func maxDuration(a time.Duration, b time.Duration) time.Duration {
	if a > b {
		return a
	}
	return b
}
