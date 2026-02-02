package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"universaldrop/internal/clock"
)

const (
	capabilityVersion = 1
	minSecretBytes    = 32

	VisibilityE2E = "e2e"

	ScopeSessionCreate         = "session.create"
	ScopeSessionClaim          = "session.claim"
	ScopeSessionApprove        = "session.approve"
	ScopeTransferInit          = "xfer.send_init"
	ScopeTransferSend          = "xfer.send"
	ScopeTransferReceive       = "xfer.receive"
	ScopeTransferDownload      = "xfer.download"
	ScopeTransferReceipt       = "xfer.receipt"
	ScopeTransferResume        = "xfer.resume"
	ScopeTransferDownloadToken = "xfer.download_token"
	ScopeTransferSignal        = "xfer.signal"
)

type Claims struct {
	Scope             string   `json:"scope"`
	Exp               int64    `json:"exp"`
	Iat               int64    `json:"iat"`
	Jti               string   `json:"jti"`
	SessionID         string   `json:"session_id,omitempty"`
	ClaimID           string   `json:"claim_id,omitempty"`
	TransferID        string   `json:"transfer_id,omitempty"`
	PeerID            string   `json:"peer_id,omitempty"`
	SenderPubKeyB64   string   `json:"sender_pubkey_b64,omitempty"`
	ReceiverPubKeyB64 string   `json:"receiver_pubkey_b64,omitempty"`
	ManifestHash      string   `json:"manifest_hash,omitempty"`
	Visibility        string   `json:"visibility,omitempty"`
	MaxBytes          int64    `json:"max_bytes,omitempty"`
	MaxRateBps        int64    `json:"max_rate_bps,omitempty"`
	AllowedRoutes     []string `json:"allowed_routes,omitempty"`
	SingleUse         bool     `json:"single_use,omitempty"`
	V                 int      `json:"v"`
}

type IssueSpec struct {
	Scope             string
	TTL               time.Duration
	SessionID         string
	ClaimID           string
	TransferID        string
	PeerID            string
	SenderPubKeyB64   string
	ReceiverPubKeyB64 string
	ManifestHash      string
	Visibility        string
	MaxBytes          int64
	MaxRateBps        int64
	AllowedRoutes     []string
	SingleUse         bool
}

type Requirement struct {
	Scope             string
	SessionID         string
	ClaimID           string
	TransferID        string
	PeerID            string
	SenderPubKeyB64   string
	ReceiverPubKeyB64 string
	ManifestHash      string
	Visibility        string
	MaxBytes          int64
	RequestBytes      int64
	MaxRateBps        int64
	Route             string
	SingleUse         bool
}

type RevocationStore interface {
	RevokeTransfer(transferID string)
	RevokeDevice(deviceID string)
	RevokeGlobal()
	RevokeJTI(jti string, exp time.Time)
	UseJTI(jti string, exp time.Time) bool
	IsRevoked(claims Claims) bool
}

type MemoryRevocationStore struct {
	mu               sync.Mutex
	clock            clock.Clock
	revokedJTIs      map[string]time.Time
	usedJTIs         map[string]time.Time
	revokedTransfers map[string]time.Time
	revokedDevices   map[string]time.Time
	globalRevoked    bool
}

func NewMemoryRevocationStore(clk clock.Clock) *MemoryRevocationStore {
	if clk == nil {
		clk = clock.RealClock{}
	}
	return &MemoryRevocationStore{
		clock:            clk,
		revokedJTIs:      map[string]time.Time{},
		usedJTIs:         map[string]time.Time{},
		revokedTransfers: map[string]time.Time{},
		revokedDevices:   map[string]time.Time{},
	}
}

func (m *MemoryRevocationStore) RevokeTransfer(transferID string) {
	if transferID == "" {
		return
	}
	m.mu.Lock()
	m.revokedTransfers[transferID] = m.clock.Now().UTC()
	m.mu.Unlock()
}

func (m *MemoryRevocationStore) RevokeDevice(deviceID string) {
	if deviceID == "" {
		return
	}
	m.mu.Lock()
	m.revokedDevices[deviceID] = m.clock.Now().UTC()
	m.mu.Unlock()
}

func (m *MemoryRevocationStore) RevokeGlobal() {
	m.mu.Lock()
	m.globalRevoked = true
	m.mu.Unlock()
}

func (m *MemoryRevocationStore) RevokeJTI(jti string, exp time.Time) {
	if jti == "" {
		return
	}
	m.mu.Lock()
	m.revokedJTIs[jti] = exp.UTC()
	m.mu.Unlock()
}

func (m *MemoryRevocationStore) UseJTI(jti string, exp time.Time) bool {
	if jti == "" {
		return false
	}
	now := m.clock.Now().UTC()
	m.mu.Lock()
	defer m.mu.Unlock()
	m.cleanupLocked(now)
	if _, exists := m.usedJTIs[jti]; exists {
		return false
	}
	m.usedJTIs[jti] = exp.UTC()
	return true
}

func (m *MemoryRevocationStore) IsRevoked(claims Claims) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.clock.Now().UTC()
	m.cleanupLocked(now)
	if m.globalRevoked {
		return true
	}
	if claims.TransferID != "" {
		if _, ok := m.revokedTransfers[claims.TransferID]; ok {
			return true
		}
	}
	if claims.PeerID != "" {
		if _, ok := m.revokedDevices[claims.PeerID]; ok {
			return true
		}
	}
	if claims.Jti != "" {
		if _, ok := m.revokedJTIs[claims.Jti]; ok {
			return true
		}
	}
	return false
}

func (m *MemoryRevocationStore) cleanupLocked(now time.Time) {
	for jti, exp := range m.revokedJTIs {
		if !exp.IsZero() && now.After(exp) {
			delete(m.revokedJTIs, jti)
		}
	}
	for jti, exp := range m.usedJTIs {
		if !exp.IsZero() && now.After(exp) {
			delete(m.usedJTIs, jti)
		}
	}
}

type Service struct {
	secret      []byte
	clock       clock.Clock
	revocations RevocationStore
}

func NewService(secret []byte, clk clock.Clock, revocations RevocationStore) *Service {
	if clk == nil {
		clk = clock.RealClock{}
	}
	if len(secret) < minSecretBytes {
		buf := make([]byte, minSecretBytes)
		_, _ = rand.Read(buf)
		secret = buf
	}
	if revocations == nil {
		revocations = NewMemoryRevocationStore(clk)
	}
	return &Service{
		secret:      append([]byte(nil), secret...),
		clock:       clk,
		revocations: revocations,
	}
}

func (s *Service) RevokeTransfer(transferID string) {
	if s.revocations == nil {
		return
	}
	s.revocations.RevokeTransfer(transferID)
}

func (s *Service) RevokeDevice(deviceID string) {
	if s.revocations == nil {
		return
	}
	s.revocations.RevokeDevice(deviceID)
}

func (s *Service) RevokeGlobal() {
	if s.revocations == nil {
		return
	}
	s.revocations.RevokeGlobal()
}

func (s *Service) Issue(spec IssueSpec) (string, error) {
	now := s.clock.Now().UTC()
	jti, err := randomJTI(16)
	if err != nil {
		return "", err
	}
	claims := Claims{
		Scope:             spec.Scope,
		Exp:               now.Add(spec.TTL).Unix(),
		Iat:               now.Unix(),
		Jti:               jti,
		SessionID:         spec.SessionID,
		ClaimID:           spec.ClaimID,
		TransferID:        spec.TransferID,
		PeerID:            spec.PeerID,
		SenderPubKeyB64:   spec.SenderPubKeyB64,
		ReceiverPubKeyB64: spec.ReceiverPubKeyB64,
		ManifestHash:      spec.ManifestHash,
		Visibility:        spec.Visibility,
		MaxBytes:          spec.MaxBytes,
		MaxRateBps:        spec.MaxRateBps,
		AllowedRoutes:     spec.AllowedRoutes,
		SingleUse:         spec.SingleUse,
		V:                 capabilityVersion,
	}
	payload, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	signature := signHMAC(payload, s.secret)
	return base64.RawURLEncoding.EncodeToString(payload) + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}

func (s *Service) Validate(token string, req Requirement) (Claims, bool) {
	payload, ok := parseToken(token, s.secret)
	if !ok {
		return Claims{}, false
	}
	if payload.V != capabilityVersion {
		return Claims{}, false
	}
	if payload.Exp > 0 && payload.Exp < s.clock.Now().UTC().Unix() {
		return Claims{}, false
	}
	if !s.ValidateClaims(payload, req) {
		return Claims{}, false
	}
	if s.revocations != nil {
		if s.revocations.IsRevoked(payload) {
			return Claims{}, false
		}
		if req.SingleUse {
			exp := time.Unix(payload.Exp, 0).UTC()
			if !s.revocations.UseJTI(payload.Jti, exp) {
				return Claims{}, false
			}
		}
	}
	return payload, true
}

func (s *Service) ValidateClaims(payload Claims, req Requirement) bool {
	if req.Scope != "" && payload.Scope != req.Scope {
		return false
	}
	if req.SessionID != "" && payload.SessionID != req.SessionID {
		return false
	}
	if req.ClaimID != "" && payload.ClaimID != req.ClaimID {
		return false
	}
	if req.TransferID != "" && payload.TransferID != req.TransferID {
		return false
	}
	if req.PeerID != "" && payload.PeerID != req.PeerID {
		return false
	}
	if req.SenderPubKeyB64 != "" && payload.SenderPubKeyB64 != req.SenderPubKeyB64 {
		return false
	}
	if req.ReceiverPubKeyB64 != "" && payload.ReceiverPubKeyB64 != req.ReceiverPubKeyB64 {
		return false
	}
	if req.ManifestHash != "" && payload.ManifestHash != req.ManifestHash {
		return false
	}
	if req.Visibility != "" && payload.Visibility != req.Visibility {
		return false
	}
	if req.MaxBytes > 0 && payload.MaxBytes > 0 && payload.MaxBytes != req.MaxBytes {
		return false
	}
	if req.RequestBytes > 0 && payload.MaxBytes > 0 && req.RequestBytes > payload.MaxBytes {
		return false
	}
	if req.MaxRateBps > 0 && payload.MaxRateBps > 0 && payload.MaxRateBps != req.MaxRateBps {
		return false
	}
	if req.SingleUse && !payload.SingleUse {
		return false
	}
	if req.Route != "" && len(payload.AllowedRoutes) > 0 {
		allowed := false
		for _, route := range payload.AllowedRoutes {
			if route == req.Route {
				allowed = true
				break
			}
		}
		if !allowed {
			return false
		}
	}
	return true
}

func parseToken(token string, secret []byte) (Claims, bool) {
	if strings.Count(token, ".") != 1 {
		return Claims{}, false
	}
	parts := strings.Split(token, ".")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return Claims{}, false
	}
	payloadBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return Claims{}, false
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return Claims{}, false
	}
	expected := signHMAC(payloadBytes, secret)
	if !hmac.Equal(signature, expected) {
		return Claims{}, false
	}
	var payload Claims
	if err := json.Unmarshal(payloadBytes, &payload); err != nil {
		return Claims{}, false
	}
	return payload, true
}

func signHMAC(payload []byte, secret []byte) []byte {
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write(payload)
	return mac.Sum(nil)
}

func randomJTI(size int) (string, error) {
	buf := make([]byte, size)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}
