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

const transferReadScope = "transfer:read"

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
}

type sessionPollSenderResponse struct {
	SessionID string `json:"session_id"`
	ExpiresAt string `json:"expires_at"`
	ClaimID   string `json:"claim_id"`
	Status    string `json:"status"`
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

func (s *Server) handleGetTransferManifest(w http.ResponseWriter, r *http.Request) {
	transferID := chi.URLParam(r, "transferID")
	if transferID == "" {
		writeIndistinguishable(w)
		return
	}

	token := bearerToken(r)
	if token == "" {
		writeIndistinguishable(w)
		return
	}

	ok, err := s.tokens.Validate(r.Context(), token, transferReadScope)
	if err != nil || !ok {
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
		"scope":            transferReadScope,
	})

	w.Header().Set("Content-Type", "application/octet-stream")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(manifest)
}
