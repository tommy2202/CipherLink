package logging

import (
	"log"
	"os"
	"strings"
)

var allowlistOrder = []string{
	"event",
	"method",
	"route",
	"status",
	"duration_ms",
	"ip_hash",
	"session_id_hash",
	"transfer_id_hash",
	"scope",
	"error",
	"version",
}

var allowlistKeys = map[string]struct{}{
	"event":            {},
	"method":           {},
	"route":            {},
	"status":           {},
	"duration_ms":      {},
	"ip_hash":          {},
	"session_id_hash":  {},
	"transfer_id_hash": {},
	"scope":            {},
	"error":            {},
	"version":          {},
}

func Allowlist(logger *log.Logger, fields map[string]string) {
	if logger == nil {
		return
	}
	var parts []string
	for _, key := range allowlistOrder {
		value, ok := fields[key]
		if !ok || value == "" {
			continue
		}
		if _, allowed := allowlistKeys[key]; !allowed {
			continue
		}
		parts = append(parts, key+"="+value)
	}
	if len(parts) == 0 {
		return
	}
	logger.Print(strings.Join(parts, " "))
}

func Fatal(logger *log.Logger, fields map[string]string) {
	Allowlist(logger, fields)
	os.Exit(1)
}
