package api

import (
	"encoding/base64"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"universaldrop/internal/domain"
	"universaldrop/internal/storage"
)

type createDropRequest struct {
	ScanMode         string `json:"scan_mode"`
	ScanCopy         string `json:"scan_copy,omitempty"`
	ExpiresInSeconds int64  `json:"expires_in_seconds,omitempty"`
	ReceiverCopy     string `json:"receiver_copy,omitempty"`
}

type receiverCopyRequest struct {
	ReceiverCopy string `json:"receiver_copy"`
}

type pairingResponse struct {
	PairingToken string `json:"pairing_token"`
	ExpiresAt    string `json:"expires_at"`
}

type pairingRedeemResponse struct {
	PairingID string `json:"pairing_id"`
}

type dropResponse struct {
	DropID    string `json:"drop_id"`
	Status    string `json:"status"`
	ExpiresAt string `json:"expires_at,omitempty"`
}

type receiverCopyResponse struct {
	ReceiverCopy string `json:"receiver_copy"`
}

func (s *Server) handleCreatePairing(w http.ResponseWriter, r *http.Request) {
	if !s.limiterCreate.Allow(clientKey(r)) {
		writeError(w, http.StatusTooManyRequests, errRateLimited)
		return
	}

	token, err := randomToken(32)
	if err != nil {
		writeError(w, http.StatusInternalServerError, errInvalidRequest)
		return
	}

	now := s.clock.Now()
	record := domain.PairingToken{
		Token:     token,
		ExpiresAt: now.Add(s.cfg.PairingTokenTTL),
		CreatedAt: now,
	}

	if err := s.store.CreatePairingToken(r.Context(), record); err != nil {
		writeError(w, http.StatusInternalServerError, errInvalidRequest)
		return
	}

	writeJSON(w, http.StatusOK, pairingResponse{
		PairingToken: token,
		ExpiresAt:    record.ExpiresAt.Format(time.RFC3339),
	})
}

func (s *Server) handleRedeemPairing(w http.ResponseWriter, r *http.Request) {
	if !s.limiterRedeem.Allow(clientKey(r)) {
		writeError(w, http.StatusTooManyRequests, errRateLimited)
		return
	}

	token := chi.URLParam(r, "token")
	if token == "" {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	pairingID, err := randomID(18)
	if err != nil {
		writeError(w, http.StatusInternalServerError, errInvalidRequest)
		return
	}

	pairing := domain.Pairing{
		ID:        pairingID,
		CreatedAt: s.clock.Now(),
	}

	if err := s.store.RedeemPairingToken(r.Context(), token, pairing, s.clock.Now()); err != nil {
		if err == storage.ErrNotFound {
			writeError(w, http.StatusNotFound, errNotFound)
			return
		}
		writeError(w, http.StatusInternalServerError, errInvalidRequest)
		return
	}

	writeJSON(w, http.StatusOK, pairingRedeemResponse{PairingID: pairingID})
}

func (s *Server) handleCreateDrop(w http.ResponseWriter, r *http.Request) {
	pairingID := chi.URLParam(r, "pairingID")
	if pairingID == "" {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	if _, err := s.store.GetPairing(r.Context(), pairingID); err != nil {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	var req createDropRequest
	maxBody := s.cfg.MaxCopyBytes*2 + 2048
	if err := decodeJSON(w, r, &req, maxBody); err != nil {
		writeError(w, http.StatusBadRequest, errInvalidRequest)
		return
	}

	if req.ReceiverCopy != "" {
		writeError(w, http.StatusBadRequest, errInvalidRequest)
		return
	}

	scanMode := parseScanMode(req.ScanMode)
	if scanMode == "" {
		writeError(w, http.StatusBadRequest, errInvalidRequest)
		return
	}

	if scanMode == domain.ScanModeVerified && req.ScanCopy == "" {
		writeError(w, http.StatusBadRequest, errInvalidRequest)
		return
	}

	ttl := s.cfg.DropTTL
	if req.ExpiresInSeconds > 0 {
		ttl = time.Duration(req.ExpiresInSeconds) * time.Second
		if ttl <= 0 || ttl > s.cfg.MaxDropTTL {
			writeError(w, http.StatusBadRequest, errInvalidRequest)
			return
		}
	}

	dropID, err := randomID(18)
	if err != nil {
		writeError(w, http.StatusInternalServerError, errInvalidRequest)
		return
	}

	scanStatus := domain.ScanStatusNotRequired
	if scanMode == domain.ScanModeVerified {
		scanStatus = domain.ScanStatusPending
	}

	now := s.clock.Now()
	drop := domain.Drop{
		ID:               dropID,
		PairingID:        pairingID,
		CreatedAt:        now,
		ExpiresAt:        now.Add(ttl),
		Status:           domain.DropStatusPendingApproval,
		ReceiverApproved: false,
		ScanMode:         scanMode,
		ScanStatus:       scanStatus,
	}

	if err := s.store.CreateDrop(r.Context(), drop); err != nil {
		writeError(w, http.StatusInternalServerError, errInvalidRequest)
		return
	}

	if req.ScanCopy != "" {
		data, err := base64.StdEncoding.DecodeString(req.ScanCopy)
		if err != nil || int64(len(data)) > s.cfg.MaxCopyBytes {
			_ = s.store.DeleteDrop(r.Context(), dropID)
			writeError(w, http.StatusBadRequest, errInvalidRequest)
			return
		}
		if err := s.store.StoreScanCopy(r.Context(), dropID, data); err != nil {
			_ = s.store.DeleteDrop(r.Context(), dropID)
			writeError(w, http.StatusInternalServerError, errInvalidRequest)
			return
		}
	}

	writeJSON(w, http.StatusOK, dropResponse{
		DropID:    dropID,
		Status:    string(drop.Status),
		ExpiresAt: drop.ExpiresAt.Format(time.RFC3339),
	})
}

func (s *Server) handleApproveDrop(w http.ResponseWriter, r *http.Request) {
	dropID := chi.URLParam(r, "dropID")
	if dropID == "" {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	drop, err := s.store.GetDrop(r.Context(), dropID)
	if err != nil || !drop.ExpiresAt.After(s.clock.Now()) {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	if drop.ScanMode == domain.ScanModeVerified && drop.ScanStatus != domain.ScanStatusClean {
		data, err := s.store.LoadScanCopy(r.Context(), dropID)
		if err != nil {
			writeError(w, http.StatusNotFound, errNotFound)
			return
		}
		result, err := s.scanner.Scan(r.Context(), data)
		if err != nil || !result.Clean {
			drop.ScanStatus = domain.ScanStatusFailed
			drop.Status = domain.DropStatusScanFailed
			_ = s.store.UpdateDrop(r.Context(), drop)
			writeError(w, http.StatusNotFound, errNotFound)
			return
		}
		drop.ScanStatus = domain.ScanStatusClean
		_ = s.store.DeleteScanCopy(r.Context(), dropID)
		drop.ScanCopyPath = ""
	}

	drop.ReceiverApproved = true
	if drop.Status == domain.DropStatusPendingApproval {
		drop.Status = domain.DropStatusApproved
	}
	if err := s.store.UpdateDrop(r.Context(), drop); err != nil {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	writeJSON(w, http.StatusOK, dropResponse{
		DropID: drop.ID,
		Status: string(drop.Status),
	})
}

func (s *Server) handleUploadReceiverCopy(w http.ResponseWriter, r *http.Request) {
	dropID := chi.URLParam(r, "dropID")
	if dropID == "" {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	drop, err := s.store.GetDrop(r.Context(), dropID)
	if err != nil || !drop.ExpiresAt.After(s.clock.Now()) {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	if !drop.ReceiverApproved || (drop.ScanMode == domain.ScanModeVerified && drop.ScanStatus != domain.ScanStatusClean) || drop.ReceiverCopyPath != "" {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	var req receiverCopyRequest
	maxBody := s.cfg.MaxCopyBytes*2 + 2048
	if err := decodeJSON(w, r, &req, maxBody); err != nil || req.ReceiverCopy == "" {
		writeError(w, http.StatusBadRequest, errInvalidRequest)
		return
	}

	data, err := base64.StdEncoding.DecodeString(req.ReceiverCopy)
	if err != nil || int64(len(data)) > s.cfg.MaxCopyBytes {
		writeError(w, http.StatusBadRequest, errInvalidRequest)
		return
	}

	if err := s.store.StoreReceiverCopy(r.Context(), dropID, data); err != nil {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	drop, err = s.store.GetDrop(r.Context(), dropID)
	if err != nil {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}
	drop.Status = domain.DropStatusReceiverCopyUploaded
	if err := s.store.UpdateDrop(r.Context(), drop); err != nil {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	writeJSON(w, http.StatusOK, dropResponse{
		DropID: drop.ID,
		Status: string(drop.Status),
	})
}

func (s *Server) handleDownloadReceiverCopy(w http.ResponseWriter, r *http.Request) {
	dropID := chi.URLParam(r, "dropID")
	if dropID == "" {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	drop, err := s.store.GetDrop(r.Context(), dropID)
	if err != nil || !drop.ExpiresAt.After(s.clock.Now()) {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	if !drop.ReceiverApproved || drop.ReceiverCopyPath == "" {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	data, err := s.store.LoadReceiverCopy(r.Context(), dropID)
	if err != nil {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	if err := s.store.DeleteReceiverCopy(r.Context(), dropID); err != nil {
		writeError(w, http.StatusNotFound, errNotFound)
		return
	}

	drop.Status = domain.DropStatusReceived
	drop.ReceiverCopyPath = ""
	if err := s.store.UpdateDrop(r.Context(), drop); err != nil {
		s.logger.Printf("drop_update_error=true")
	}

	writeJSON(w, http.StatusOK, receiverCopyResponse{
		ReceiverCopy: base64.StdEncoding.EncodeToString(data),
	})
}

func parseScanMode(input string) domain.ScanMode {
	mode := strings.TrimSpace(strings.ToLower(input))
	if mode == "" {
		return domain.ScanModeNone
	}
	if mode == string(domain.ScanModeNone) {
		return domain.ScanModeNone
	}
	if mode == string(domain.ScanModeVerified) {
		return domain.ScanModeVerified
	}
	return ""
}
