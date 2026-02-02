package api

import (
	"net/http"
	"time"

	"universaldrop/internal/auth"
	"universaldrop/internal/domain"
)

type transferAuth struct {
	Session domain.Session
	Claim   domain.SessionClaim
	Meta    domain.TransferMeta
	Cap     auth.Claims
}

func (s *Server) authorizeTransfer(r *http.Request, sessionID string, transferID string, token string, scope string, reqBytes int64, requireSingleUse bool) (transferAuth, bool) {
	if sessionID == "" || token == "" {
		return transferAuth{}, false
	}
	capClaims, ok := s.requireCapability(r, token, auth.Requirement{
		Scope:     scope,
		SessionID: sessionID,
		SingleUse: requireSingleUse,
	})
	if !ok {
		return transferAuth{}, false
	}
	session, err := s.store.GetSession(r.Context(), sessionID)
	if err != nil {
		return transferAuth{}, false
	}
	if time.Now().UTC().After(session.ExpiresAt) {
		return transferAuth{}, false
	}
	claim, ok := findClaim(session, capClaims.ClaimID)
	if !ok {
		return transferAuth{}, false
	}
	peerID := ""
	switch scope {
	case auth.ScopeTransferInit, auth.ScopeTransferSend:
		peerID = claim.SenderPubKeyB64
	case auth.ScopeTransferReceive:
		peerID = session.ReceiverPubKeyB64
	}
	if _, err := s.store.GetSessionAuthContext(r.Context(), session.ID, claim.ID); err != nil {
		return transferAuth{}, false
	}
	if transferID == "" {
		if !s.capabilities.ValidateClaims(capClaims, auth.Requirement{
			ClaimID:           claim.ID,
			PeerID:            peerID,
			SenderPubKeyB64:   claim.SenderPubKeyB64,
			ReceiverPubKeyB64: session.ReceiverPubKeyB64,
			Visibility:        auth.VisibilityE2E,
			MaxRateBps:        s.cfg.Throttles.TransferBandwidthCapBps,
			Route:             routePattern(r),
		}) {
			return transferAuth{}, false
		}
		return transferAuth{Session: session, Claim: claim, Cap: capClaims}, true
	}
	if claim.TransferID == "" || claim.TransferID != transferID {
		return transferAuth{}, false
	}
	meta, err := s.store.GetTransferMeta(r.Context(), transferID)
	if err != nil {
		return transferAuth{}, false
	}
	if !s.capabilities.ValidateClaims(capClaims, auth.Requirement{
		ClaimID:           claim.ID,
		TransferID:        transferID,
		PeerID:            peerID,
		SenderPubKeyB64:   claim.SenderPubKeyB64,
		ReceiverPubKeyB64: session.ReceiverPubKeyB64,
		ManifestHash:      meta.ManifestHash,
		Visibility:        auth.VisibilityE2E,
		MaxBytes:          meta.TotalBytes,
		RequestBytes:      reqBytes,
		MaxRateBps:        s.cfg.Throttles.TransferBandwidthCapBps,
		Route:             routePattern(r),
	}) {
		return transferAuth{}, false
	}
	return transferAuth{Session: session, Claim: claim, Meta: meta, Cap: capClaims}, true
}
