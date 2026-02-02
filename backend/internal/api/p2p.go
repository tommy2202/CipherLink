package api

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"net/http"
	"strconv"
	"time"

	"universaldrop/internal/auth"
	"universaldrop/internal/config"
	"universaldrop/internal/domain"
	"universaldrop/internal/logging"
	"universaldrop/internal/storage"
)

type p2pOfferRequest struct {
	SessionID string `json:"session_id"`
	ClaimID   string `json:"claim_id"`
	SDP       string `json:"sdp"`
}

type p2pAnswerRequest struct {
	SessionID string `json:"session_id"`
	ClaimID   string `json:"claim_id"`
	SDP       string `json:"sdp"`
}

type p2pICERequest struct {
	SessionID string `json:"session_id"`
	ClaimID   string `json:"claim_id"`
	Candidate string `json:"candidate"`
}

type p2pPollResponse struct {
	Messages []domain.P2PMessage `json:"messages"`
}

type p2pIceConfigResponse struct {
	STUNURLs   []string `json:"stun_urls,omitempty"`
	TURNURLs   []string `json:"turn_urls,omitempty"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
	TTLSeconds int64    `json:"ttl_seconds,omitempty"`
}

func (s *Server) handleP2POffer(w http.ResponseWriter, r *http.Request) {
	var req p2pOfferRequest
	if err := decodeJSON(w, r, &req, 64<<10); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if req.SessionID == "" || req.ClaimID == "" || req.SDP == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	token := bearerToken(r)
	session, _, ok := s.authorizeP2P(r, req.SessionID, req.ClaimID, token)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	if err := s.appendP2PMessage(r.Context(), session, req.ClaimID, domain.P2PMessage{
		Type: "offer",
		SDP:  req.SDP,
	}); err != nil {
		writeIndistinguishable(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleP2PAnswer(w http.ResponseWriter, r *http.Request) {
	var req p2pAnswerRequest
	if err := decodeJSON(w, r, &req, 64<<10); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if req.SessionID == "" || req.ClaimID == "" || req.SDP == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	token := bearerToken(r)
	session, _, ok := s.authorizeP2P(r, req.SessionID, req.ClaimID, token)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	if err := s.appendP2PMessage(r.Context(), session, req.ClaimID, domain.P2PMessage{
		Type: "answer",
		SDP:  req.SDP,
	}); err != nil {
		writeIndistinguishable(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleP2PICE(w http.ResponseWriter, r *http.Request) {
	var req p2pICERequest
	if err := decodeJSON(w, r, &req, 32<<10); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if req.SessionID == "" || req.ClaimID == "" || req.Candidate == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	token := bearerToken(r)
	session, _, ok := s.authorizeP2P(r, req.SessionID, req.ClaimID, token)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	if err := s.appendP2PMessage(r.Context(), session, req.ClaimID, domain.P2PMessage{
		Type:      "ice",
		Candidate: req.Candidate,
	}); err != nil {
		writeIndistinguishable(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleP2PPoll(w http.ResponseWriter, r *http.Request) {
	sessionID := r.URL.Query().Get("session_id")
	claimID := r.URL.Query().Get("claim_id")
	if sessionID == "" || claimID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	token := bearerToken(r)
	session, _, ok := s.authorizeP2P(r, sessionID, claimID, token)
	if !ok {
		writeIndistinguishable(w)
		return
	}
	messages, err := s.drainP2PMessages(r.Context(), session, claimID)
	if err != nil {
		writeIndistinguishable(w)
		return
	}
	writeJSON(w, http.StatusOK, p2pPollResponse{
		Messages: messages,
	})
}

func (s *Server) handleP2PIceConfig(w http.ResponseWriter, r *http.Request) {
	sessionID := r.URL.Query().Get("session_id")
	claimID := r.URL.Query().Get("claim_id")
	mode := r.URL.Query().Get("mode")
	if sessionID == "" || claimID == "" || (mode != "direct" && mode != "relay") {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	token := bearerToken(r)
	if _, _, ok := s.authorizeP2P(r, sessionID, claimID, token); !ok {
		writeIndistinguishable(w)
		return
	}
	if mode == "relay" && (len(s.cfg.TURNURLs) == 0 || len(s.cfg.TURNSharedSecret) == 0) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "turn_unavailable"})
		return
	}
	if mode == "relay" {
		ttl := s.turnCredentialTTL()
		identity := sessionID + ":" + claimID
		if !s.quotas.AllowRelay(identity, s.cfg.Quotas.RelayPerIdentityPerDay, s.cfg.Quotas.RelayConcurrentPerIdentity, ttl) {
			logging.Allowlist(s.logger, map[string]string{
				"event":           "quota_blocked",
				"scope":           "relay_issue",
				"session_id_hash": anonHash(sessionID),
				"claim_id_hash":   anonHash(claimID),
			})
			writeIndistinguishable(w)
			return
		}
	}

	response := p2pIceConfigResponse{
		STUNURLs: s.cfg.STUNURLs,
		TURNURLs: s.cfg.TURNURLs,
	}
	if mode == "relay" {
		response.STUNURLs = nil
	}
	if len(s.cfg.TURNURLs) > 0 && len(s.cfg.TURNSharedSecret) > 0 {
		username, credential, ttlSeconds := s.issueTurnCredentials(sessionID, claimID)
		response.Username = username
		response.Credential = credential
		response.TTLSeconds = ttlSeconds
	} else {
		response.TURNURLs = nil
	}

	if mode == "relay" {
		s.metrics.IncRelayIceConfigIssued()
	}
	writeJSON(w, http.StatusOK, response)
}

func (s *Server) authorizeP2P(r *http.Request, sessionID string, claimID string, token string) (domain.Session, domain.SessionClaim, bool) {
	if sessionID == "" || claimID == "" || token == "" {
		return domain.Session{}, domain.SessionClaim{}, false
	}
	capClaims, ok := s.requireCapability(r, token, auth.Requirement{
		Scope:     auth.ScopeTransferSignal,
		SessionID: sessionID,
		ClaimID:   claimID,
	})
	if !ok {
		return domain.Session{}, domain.SessionClaim{}, false
	}
	session, err := s.store.GetSession(r.Context(), sessionID)
	if err != nil {
		return domain.Session{}, domain.SessionClaim{}, false
	}
	if time.Now().UTC().After(session.ExpiresAt) {
		return domain.Session{}, domain.SessionClaim{}, false
	}
	claim, ok := findClaim(session, claimID)
	if !ok {
		return domain.Session{}, domain.SessionClaim{}, false
	}
	if claim.Status != domain.SessionClaimApproved {
		return domain.Session{}, domain.SessionClaim{}, false
	}
	if sasStateForClaim(claim) != "verified" {
		return domain.Session{}, domain.SessionClaim{}, false
	}
	if _, err := s.store.GetSessionAuthContext(r.Context(), sessionID, claimID); err != nil {
		return domain.Session{}, domain.SessionClaim{}, false
	}
	if !s.capabilities.ValidateClaims(capClaims, auth.Requirement{
		ClaimID:           claimID,
		SenderPubKeyB64:   claim.SenderPubKeyB64,
		ReceiverPubKeyB64: session.ReceiverPubKeyB64,
		Visibility:        auth.VisibilityE2E,
		Route:             routePattern(r),
	}) {
		return domain.Session{}, domain.SessionClaim{}, false
	}
	if capClaims.PeerID != "" && capClaims.PeerID != claim.SenderPubKeyB64 && capClaims.PeerID != session.ReceiverPubKeyB64 {
		return domain.Session{}, domain.SessionClaim{}, false
	}
	return session, claim, true
}

func (s *Server) appendP2PMessage(ctx context.Context, session domain.Session, claimID string, message domain.P2PMessage) error {
	for i, claim := range session.Claims {
		if claim.ID != claimID {
			continue
		}
		claim.P2PMessages = append(claim.P2PMessages, message)
		claim.UpdatedAt = time.Now().UTC()
		session.Claims[i] = claim
		return s.store.UpdateSession(ctx, session)
	}
	return storage.ErrNotFound
}

func (s *Server) drainP2PMessages(ctx context.Context, session domain.Session, claimID string) ([]domain.P2PMessage, error) {
	for i, claim := range session.Claims {
		if claim.ID != claimID {
			continue
		}
		messages := claim.P2PMessages
		claim.P2PMessages = nil
		claim.UpdatedAt = time.Now().UTC()
		session.Claims[i] = claim
		if err := s.store.UpdateSession(ctx, session); err != nil {
			return nil, err
		}
		return messages, nil
	}
	return nil, storage.ErrNotFound
}

func (s *Server) issueTurnCredentials(sessionID string, claimID string) (string, string, int64) {
	ttl := s.turnCredentialTTL()
	expiresAt := time.Now().UTC().Add(ttl).Unix()
	username := sessionID + ":" + claimID + ":" + strconv.FormatInt(expiresAt, 10)
	mac := hmac.New(sha1.New, s.cfg.TURNSharedSecret)
	_, _ = mac.Write([]byte(username))
	credential := base64.StdEncoding.EncodeToString(mac.Sum(nil))
	return username, credential, int64(ttl.Seconds())
}

func (s *Server) turnCredentialTTL() time.Duration {
	ttl := s.cfg.TransferTokenTTL
	if ttl <= 0 {
		ttl = config.DefaultTransferTokenTTL
	}
	return ttl
}
