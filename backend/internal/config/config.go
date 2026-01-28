package config

import (
	"encoding/base64"
	"os"
	"strconv"
	"strings"
	"time"
)

type RateLimit struct {
	Max    int
	Window time.Duration
}

type Config struct {
	Address               string
	DataDir               string
	RateLimitHealth       RateLimit
	RateLimitV1           RateLimit
	RateLimitSessionClaim RateLimit
	ClaimTokenTTL         time.Duration
	TransferTokenTTL      time.Duration
	SweepInterval         time.Duration
	MaxScanBytes          int64
	MaxScanDuration       time.Duration
	STUNURLs              []string
	TURNURLs              []string
	TURNSharedSecret      []byte
}

const (
	DefaultClaimTokenTTL    = 3 * time.Minute
	MinClaimTokenTTL        = 2 * time.Minute
	MaxClaimTokenTTL        = 5 * time.Minute
	DefaultTransferTokenTTL = 5 * time.Minute
	MinTransferTokenTTL     = 1 * time.Minute
	MaxTransferTokenTTL     = 15 * time.Minute
	DefaultSweepInterval    = 30 * time.Second
	DefaultMaxScanBytes     = 50 << 20
	DefaultMaxScanDuration  = 10 * time.Second
)

func Load() Config {
	cfg := Config{
		Address: ":8080",
		DataDir: "data",
		RateLimitHealth: RateLimit{
			Max:    60,
			Window: time.Minute,
		},
		RateLimitV1: RateLimit{
			Max:    30,
			Window: time.Minute,
		},
		RateLimitSessionClaim: RateLimit{
			Max:    10,
			Window: time.Minute,
		},
		ClaimTokenTTL:    DefaultClaimTokenTTL,
		TransferTokenTTL: DefaultTransferTokenTTL,
		SweepInterval:    DefaultSweepInterval,
		MaxScanBytes:     DefaultMaxScanBytes,
		MaxScanDuration:  DefaultMaxScanDuration,
	}

	if value := os.Getenv("UD_ADDRESS"); value != "" {
		cfg.Address = value
	}
	if value := os.Getenv("UD_DATA_DIR"); value != "" {
		cfg.DataDir = value
	}

	if value := parseIntEnv("UD_RATE_LIMIT_HEALTH_MAX"); value > 0 {
		cfg.RateLimitHealth.Max = int(value)
	}
	if value := parseDurationEnv("UD_RATE_LIMIT_HEALTH_WINDOW"); value > 0 {
		cfg.RateLimitHealth.Window = value
	}
	if value := parseIntEnv("UD_RATE_LIMIT_V1_MAX"); value > 0 {
		cfg.RateLimitV1.Max = int(value)
	}
	if value := parseDurationEnv("UD_RATE_LIMIT_V1_WINDOW"); value > 0 {
		cfg.RateLimitV1.Window = value
	}
	if value := parseIntEnv("UD_RATE_LIMIT_SESSION_CLAIM_MAX"); value > 0 {
		cfg.RateLimitSessionClaim.Max = int(value)
	}
	if value := parseDurationEnv("UD_RATE_LIMIT_SESSION_CLAIM_WINDOW"); value > 0 {
		cfg.RateLimitSessionClaim.Window = value
	}
	if value := parseDurationEnv("UD_CLAIM_TOKEN_TTL"); value > 0 {
		cfg.ClaimTokenTTL = value
	}
	if cfg.ClaimTokenTTL < MinClaimTokenTTL || cfg.ClaimTokenTTL > MaxClaimTokenTTL {
		cfg.ClaimTokenTTL = DefaultClaimTokenTTL
	}
	if value := parseDurationEnv("UD_TRANSFER_TOKEN_TTL"); value > 0 {
		cfg.TransferTokenTTL = value
	}
	if cfg.TransferTokenTTL < MinTransferTokenTTL || cfg.TransferTokenTTL > MaxTransferTokenTTL {
		cfg.TransferTokenTTL = DefaultTransferTokenTTL
	}
	if value := parseDurationEnv("UD_SWEEP_INTERVAL"); value > 0 {
		cfg.SweepInterval = value
	}
	if value := parseIntEnv("UD_MAX_SCAN_BYTES"); value > 0 {
		cfg.MaxScanBytes = value
	}
	if value := parseDurationEnv("UD_MAX_SCAN_DURATION"); value > 0 {
		cfg.MaxScanDuration = value
	}
	if values := parseCSVEnv("UD_STUN_URLS"); len(values) > 0 {
		cfg.STUNURLs = values
	}
	if values := parseCSVEnv("UD_TURN_URLS"); len(values) > 0 {
		cfg.TURNURLs = values
	}
	if secret := parseBase64Env("UD_TURN_SHARED_SECRET_B64"); len(secret) > 0 {
		cfg.TURNSharedSecret = secret
	}

	return cfg
}

func parseDurationEnv(key string) time.Duration {
	raw := os.Getenv(key)
	if raw == "" {
		return 0
	}
	value, err := time.ParseDuration(raw)
	if err != nil {
		return 0
	}
	return value
}

func parseIntEnv(key string) int64 {
	raw := os.Getenv(key)
	if raw == "" {
		return 0
	}
	value, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0
	}
	return value
}

func parseCSVEnv(key string) []string {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	values := make([]string, 0, len(parts))
	for _, part := range parts {
		trimmed := strings.TrimSpace(part)
		if trimmed == "" {
			continue
		}
		values = append(values, trimmed)
	}
	return values
}

func parseBase64Env(key string) []byte {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return nil
	}
	decoded, err := base64.RawURLEncoding.DecodeString(raw)
	if err == nil {
		return decoded
	}
	decoded, err = base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return nil
	}
	return decoded
}
