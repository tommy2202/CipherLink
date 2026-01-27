package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"universaldrop/internal/config"
)

func TestHealthz(t *testing.T) {
	server := NewServer(Dependencies{
		Config: config.Config{Address: ":0", DataDir: "data"},
	})

	rec := httptest.NewRecorder()
	server.Router.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 got %d", rec.Code)
	}

	var payload map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if payload["ok"] != true {
		t.Fatalf("expected ok true")
	}
	if payload["version"] != "0.1" {
		t.Fatalf("expected version 0.1 got %v", payload["version"])
	}
}
