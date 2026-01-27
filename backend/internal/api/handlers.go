package api

import (
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

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
}

type sessionPollReceiverResponse struct {
	SessionID string                    `json:"session_id"`
	ExpiresAt string                    `json:"expires_at"`
	Claims    []sessionPollClaimSummary `json:"claims"`
	SASState  string                    `json:"sas_state"`
}

type sessionPollSenderResponse struct {
	SessionID string `json:"session_id"`
	ExpiresAt string `json:"expires_at"`
	ClaimID   string `json:"claim_id"`
	Status    string `json:"status"`
	SASState  string `json:"sas_state"`
}

type sessionApproveRequest struct {
	SessionID string `json:"session_id"`
	ClaimID   string `json:"claim_id"`
	Approve   bool   `json:"approve"`
}

type sessionApproveResponse struct {
	Status        string `json:"status"`
	TransferToken string `json:"transfer_token,omitempty"`
}

func (s *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	ttl := s.cfg.ClaimTokenTTL
	if ttl == 0 || ttl < config.MinClaimTokenTTL || ttl > config.MaxClaimTokenTTL {
		ttl = config.DefaultClaimTokenTTL
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
		receiverPubKey, err := randomBase64(32)
		if err != nil {
			break
		}

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
	if req.Approve {
		claim.Status = domain.SessionClaimApproved
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
		Status:        string(domain.SessionClaimApproved),
		TransferToken: transferToken,
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
		if len(session.Claims) > 0 {
			claimID = session.Claims[0].ID
			status = session.Claims[0].Status
		}
		writeJSON(w, http.StatusOK, sessionPollSenderResponse{
			SessionID: session.ID,
			ExpiresAt: session.ExpiresAt.Format(time.RFC3339),
			ClaimID:   claimID,
			Status:    string(status),
			SASState:  "not_supported_yet",
		})
		return
	}

	claims := make([]sessionPollClaimSummary, 0)
	for _, claim := range session.Claims {
		if claim.Status != domain.SessionClaimPending {
			continue
		}
		claims = append(claims, sessionPollClaimSummary{
			ClaimID:          claim.ID,
			SenderLabel:      claim.SenderLabel,
			ShortFingerprint: shortFingerprint(claim.SenderPubKeyB64),
		})
	}

	writeJSON(w, http.StatusOK, sessionPollReceiverResponse{
		SessionID: session.ID,
		ExpiresAt: session.ExpiresAt.Format(time.RFC3339),
		Claims:    claims,
		SASState:  "not_supported_yet",
	})
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

func transferScope(sessionID string, claimID string) string {
	return "transfer:session:" + sessionID + ":claim:" + claimID
}

func (s *Server) handleGetTransferManifest(w http.ResponseWriter, r *http.Request) {
	transferID := chi.URLParam(r, "transferID")
	if transferID == "" {
		writeIndistinguishable(w)
		return
	}

	sessionID := r.URL.Query().Get("session_id")
	claimID := r.URL.Query().Get("claim_id")
	if sessionID == "" || claimID == "" {
		writeIndistinguishable(w)
		return
	}

	token := bearerToken(r)
	if token == "" {
		writeIndistinguishable(w)
		return
	}

	scope := transferScope(sessionID, claimID)
	ok, err := s.tokens.Validate(r.Context(), token, scope)
	if err != nil || !ok {
		writeIndistinguishable(w)
		return
	}

	if _, err := s.store.GetSessionAuthContext(r.Context(), sessionID, claimID); err != nil {
		writeIndistinguishable(w)
		return
	}

	manifest, err := s.store.LoadManifest(r.Context(), transferID)
	if err != nil {
		if err == storage.ErrNotFound {
			writeIndistinguishable(w)
			return
		}
		writeIndistinguishable(w)
		return
	}

	logging.Allowlist(s.logger, map[string]string{
		"event":            "transfer_manifest_read",
		"transfer_id_hash": anonHash(transferID),
		"session_id_hash":  anonHash(sessionID),
		"claim_id_hash":    anonHash(claimID),
	})

	w.Header().Set("Content-Type", "application/octet-stream")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(manifest)
}
