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
	ScanStatusUnavailable ScanStatus = "unavailable"
)

type TransferMeta struct {
	Status        TransferStatus `json:"status"`
	BytesReceived int64          `json:"bytes_received"`
	TotalBytes    int64          `json:"total_bytes"`
	CreatedAt     time.Time      `json:"created_at"`
	ExpiresAt     time.Time      `json:"expires_at"`
	ScanStatus    ScanStatus     `json:"scan_status"`
}

type P2PMessage struct {
	Type      string `json:"type"`
	SDP       string `json:"sdp,omitempty"`
	Candidate string `json:"candidate,omitempty"`
}

type SessionClaimStatus string

const (
	SessionClaimPending  SessionClaimStatus = "pending"
	SessionClaimApproved SessionClaimStatus = "approved"
	SessionClaimRejected SessionClaimStatus = "rejected"
)

type SessionClaim struct {
	ID                   string             `json:"id"`
	SenderLabel          string             `json:"sender_label"`
	SenderPubKeyB64      string             `json:"sender_pubkey_b64"`
	SASSenderConfirmed   bool               `json:"sas_sender_confirmed,omitempty"`
	SASReceiverConfirmed bool               `json:"sas_receiver_confirmed,omitempty"`
	Status               SessionClaimStatus `json:"status"`
	CreatedAt            time.Time          `json:"created_at"`
	UpdatedAt            time.Time          `json:"updated_at"`
	TransferID           string             `json:"transfer_id,omitempty"`
	TransferReady        bool               `json:"transfer_ready,omitempty"`
	ScanRequired         bool               `json:"scan_required,omitempty"`
	ScanStatus           ScanStatus         `json:"scan_status,omitempty"`
	P2PMessages          []P2PMessage       `json:"p2p_messages,omitempty"`
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

type SessionAuthContext struct {
	SessionID         string    `json:"session_id"`
	ClaimID           string    `json:"claim_id"`
	SenderPubKeyB64   string    `json:"sender_pubkey_b64"`
	ReceiverPubKeyB64 string    `json:"receiver_pubkey_b64"`
	ApprovedAt        time.Time `json:"approved_at"`
}

type ScanSession struct {
	ID         string    `json:"id"`
	SessionID  string    `json:"session_id"`
	ClaimID    string    `json:"claim_id"`
	TransferID string    `json:"transfer_id"`
	CreatedAt  time.Time `json:"created_at"`
	ExpiresAt  time.Time `json:"expires_at"`
	ScanKeyB64 string    `json:"scan_key_b64"`
	TotalBytes int64     `json:"total_bytes"`
	ChunkSize  int       `json:"chunk_size"`
}
