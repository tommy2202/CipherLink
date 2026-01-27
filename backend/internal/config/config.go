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
	RateLimitHealth RateLimit
	RateLimitV1     RateLimit
}

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
