package domain

import "time"

type TransferStatus string

const (
	TransferStatusPending  TransferStatus = "pending"
	TransferStatusActive   TransferStatus = "active"
	TransferStatusComplete TransferStatus = "complete"
)

type ScanStatus string

const (
	ScanStatusNotRequired ScanStatus = "not_required"
	ScanStatusPending     ScanStatus = "pending"
	ScanStatusClean       ScanStatus = "clean"
	ScanStatusFailed      ScanStatus = "failed"
)

type TransferMeta struct {
	Status        TransferStatus `json:"status"`
	BytesReceived int64          `json:"bytes_received"`
	CreatedAt     time.Time      `json:"created_at"`
	ExpiresAt     time.Time      `json:"expires_at"`
	ScanStatus    ScanStatus     `json:"scan_status"`
}

type SessionClaimStatus string

const (
	SessionClaimPending  SessionClaimStatus = "pending"
	SessionClaimApproved SessionClaimStatus = "approved"
	SessionClaimRejected SessionClaimStatus = "rejected"
)

type SessionClaim struct {
	ID              string             `json:"id"`
	SenderLabel     string             `json:"sender_label"`
	SenderPubKeyB64 string             `json:"sender_pubkey_b64"`
	Status          SessionClaimStatus `json:"status"`
	CreatedAt       time.Time          `json:"created_at"`
	UpdatedAt       time.Time          `json:"updated_at"`
}

type Session struct {
	ID                  string         `json:"id"`
	CreatedAt           time.Time      `json:"created_at"`
	ExpiresAt           time.Time      `json:"expires_at"`
	ClaimTokenHash      string         `json:"claim_token_hash"`
	ClaimTokenExpiresAt time.Time      `json:"claim_token_expires_at"`
	ClaimTokenUsed      bool           `json:"claim_token_used"`
	ReceiverPubKeyB64   string         `json:"receiver_pubkey_b64"`
	Claims              []SessionClaim `json:"claims,omitempty"`
}
