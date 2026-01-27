package config

import "os"

type Config struct {
	Address string
	DataDir string
}

func Load() Config {
	cfg := Config{
		Address: ":8080",
		DataDir: "data",
	}

	if value := os.Getenv("UD_ADDRESS"); value != "" {
		cfg.Address = value
	}
	if value := os.Getenv("UD_DATA_DIR"); value != "" {
		cfg.DataDir = value
	}

	return cfg
}
