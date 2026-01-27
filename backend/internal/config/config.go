package config

import (
	"os"
	"strconv"
	"time"
)

type RateLimit struct {
	Max    int
	Window time.Duration
}

type Config struct {
	Address         string
	DataDir         string
	PairingTokenTTL time.Duration
	DropTTL         time.Duration
	MaxDropTTL      time.Duration
	SweepInterval   time.Duration
	MaxCopyBytes    int64
	RateLimitCreate RateLimit
	RateLimitRedeem RateLimit
}

func Load() Config {
	cfg := Config{
		Address:         ":8080",
		DataDir:         "data",
		PairingTokenTTL: 5 * time.Minute,
		DropTTL:         1 * time.Hour,
		MaxDropTTL:      24 * time.Hour,
		SweepInterval:   30 * time.Second,
		MaxCopyBytes:    10 << 20,
		RateLimitCreate: RateLimit{Max: 5, Window: time.Minute},
		RateLimitRedeem: RateLimit{Max: 10, Window: time.Minute},
	}

	if value := os.Getenv("UD_ADDRESS"); value != "" {
		cfg.Address = value
	}
	if value := os.Getenv("UD_DATA_DIR"); value != "" {
		cfg.DataDir = value
	}

	if value := parseDurationEnv("UD_PAIRING_TOKEN_TTL"); value > 0 {
		cfg.PairingTokenTTL = value
	}
	if value := parseDurationEnv("UD_DROP_TTL"); value > 0 {
		cfg.DropTTL = value
	}
	if value := parseDurationEnv("UD_MAX_DROP_TTL"); value > 0 {
		cfg.MaxDropTTL = value
	}
	if value := parseDurationEnv("UD_SWEEP_INTERVAL"); value > 0 {
		cfg.SweepInterval = value
	}
	if value := parseIntEnv("UD_MAX_COPY_BYTES"); value > 0 {
		cfg.MaxCopyBytes = value
	}

	if value := parseIntEnv("UD_RATE_LIMIT_CREATE"); value > 0 {
		cfg.RateLimitCreate.Max = int(value)
	}
	if value := parseIntEnv("UD_RATE_LIMIT_REDEEM"); value > 0 {
		cfg.RateLimitRedeem.Max = int(value)
	}
	if value := parseDurationEnv("UD_RATE_LIMIT_WINDOW"); value > 0 {
		cfg.RateLimitCreate.Window = value
		cfg.RateLimitRedeem.Window = value
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
