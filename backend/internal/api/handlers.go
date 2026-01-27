package api

import (
	"net/http"

	"github.com/go-chi/chi/v5"

	"universaldrop/internal/logging"
	"universaldrop/internal/storage"
)

const transferReadScope = "transfer:read"

func (s *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
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
