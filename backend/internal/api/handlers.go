package api

import (
	"net/http"
	"net/url"
	"time"

	"github.com/go-chi/chi/v5"

	"universaldrop/internal/config"
	"universaldrop/internal/domain"
	"universaldrop/internal/logging"
	"universaldrop/internal/storage"
)

const transferReadScope = "transfer:read"

type sessionCreateResponse struct {
	SessionID        string `json:"session_id"`
	ExpiresAt        string `json:"expires_at"`
	ClaimToken       string `json:"claim_token"`
	ReceiverPubKeyB64 string `json:"receiver_pubkey_b64"`
	QRPayload        string `json:"qr_payload"`
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
