package token

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"universaldrop/internal/clock"
)

const (
	hmacVersion        = 1
	hmacSecretMinBytes = 32
)

type hmacPayload struct {
	Scope string `json:"scope"`
	Exp   int64  `json:"exp"`
	Iat   int64  `json:"iat"`
	V     int    `json:"v"`
}

type HMACService struct {
	secret []byte
	clock  clock.Clock
}

func NewHMACService(secret []byte) *HMACService {
	return newHMACServiceWithClock(secret, clock.RealClock{})
}

func newHMACServiceWithClock(secret []byte, clk clock.Clock) *HMACService {
	if clk == nil {
		clk = clock.RealClock{}
	}
	return &HMACService{
		secret: append([]byte(nil), secret...),
		clock:  clk,
	}
}

func (s *HMACService) Issue(_ context.Context, scope string, ttl time.Duration) (string, error) {
	now := s.now()
	payload := hmacPayload{
		Scope: scope,
		Exp:   now.Add(ttl).Unix(),
		Iat:   now.Unix(),
		V:     hmacVersion,
	}
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	signature := signHMAC(payloadBytes, s.secret)
	return base64.RawURLEncoding.EncodeToString(payloadBytes) + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}

func (s *HMACService) Validate(_ context.Context, token string, scope string) (bool, error) {
	if strings.Count(token, ".") != 1 {
		return false, nil
	}
	parts := strings.Split(token, ".")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return false, nil
	}
	payloadBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return false, nil
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return false, nil
	}
	expected := signHMAC(payloadBytes, s.secret)
	if !hmac.Equal(signature, expected) {
		return false, nil
	}
	var payload hmacPayload
	if err := json.Unmarshal(payloadBytes, &payload); err != nil {
		return false, nil
	}
	if payload.V != hmacVersion {
		return false, nil
	}
	if payload.Scope != scope {
		return false, nil
	}
	if payload.Exp < s.now().Unix() {
		return false, nil
	}
	return true, nil
}

func LoadOrCreateHMACSecret(dataDir string) ([]byte, error) {
	if raw := os.Getenv("UD_TOKEN_HMAC_SECRET_B64"); raw != "" {
		secret, err := decodeHMACSecret(raw)
		if err != nil {
			return nil, err
		}
		return secret, nil
	}
	if dataDir == "" {
		return nil, errors.New("data dir required for token secret")
	}
	secretPath := filepath.Join(dataDir, "secrets", "token_hmac.key")
	secret, err := os.ReadFile(secretPath)
	if err == nil {
		if len(secret) < hmacSecretMinBytes {
			return nil, fmt.Errorf("token secret must be at least %d bytes", hmacSecretMinBytes)
		}
		return secret, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	secret = make([]byte, hmacSecretMinBytes)
	if _, err := rand.Read(secret); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(secretPath), 0o700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(secretPath, secret, 0o600); err != nil {
		return nil, err
	}
	return secret, nil
}

func decodeHMACSecret(raw string) ([]byte, error) {
	secret, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		secret, err = base64.StdEncoding.DecodeString(raw)
		if err != nil {
			return nil, err
		}
	}
	if len(secret) < hmacSecretMinBytes {
		return nil, fmt.Errorf("token secret must be at least %d bytes", hmacSecretMinBytes)
	}
	return secret, nil
}

func (s *HMACService) now() time.Time {
	return s.clock.Now().UTC()
}

func signHMAC(payload []byte, secret []byte) []byte {
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write(payload)
	return mac.Sum(nil)
}
