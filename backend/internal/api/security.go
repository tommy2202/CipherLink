package api

import (
	"crypto/sha256"
	"encoding/base64"
	"net"
	"net/http"
	"strings"
)

const indistinguishableErrorCode = "not_found"

func writeIndistinguishable(w http.ResponseWriter) {
	writeJSON(w, http.StatusNotFound, map[string]string{"error": indistinguishableErrorCode})
}

func anonHash(value string) string {
	if value == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(value))
	encoded := base64.RawURLEncoding.EncodeToString(sum[:])
	if len(encoded) > 16 {
		return encoded[:16]
	}
	return encoded
}

func clientIP(r *http.Request) string {
	if forwarded := r.Header.Get("X-Forwarded-For"); forwarded != "" {
		parts := strings.Split(forwarded, ",")
		if len(parts) > 0 {
			candidate := strings.TrimSpace(parts[0])
			if candidate != "" {
				return candidate
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil && host != "" {
		return host
	}
	return "unknown"
}

func bearerToken(r *http.Request) string {
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if auth == "" {
		return ""
	}
	if !strings.HasPrefix(strings.ToLower(auth), "bearer ") {
		return ""
	}
	return strings.TrimSpace(auth[7:])
}
