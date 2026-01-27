package domain

import "time"

type PairingToken struct {
	Token     string    `json:"token"`
	ExpiresAt time.Time `json:"expires_at"`
	CreatedAt time.Time `json:"created_at"`
}

type Pairing struct {
	ID        string    `json:"id"`
	CreatedAt time.Time `json:"created_at"`
}

type ScanMode string

const (
	ScanModeNone     ScanMode = "none"
	ScanModeVerified ScanMode = "verified"
)

type ScanStatus string

const (
	ScanStatusNotRequired ScanStatus = "not_required"
	ScanStatusPending     ScanStatus = "pending"
	ScanStatusClean       ScanStatus = "clean"
	ScanStatusFailed      ScanStatus = "failed"
)

type DropStatus string

const (
	DropStatusPendingApproval      DropStatus = "pending_receiver_approval"
	DropStatusApproved             DropStatus = "approved"
	DropStatusReceiverCopyUploaded DropStatus = "receiver_copy_uploaded"
	DropStatusReceived             DropStatus = "received"
	DropStatusScanFailed           DropStatus = "scan_failed"
)

type Drop struct {
	ID                string     `json:"id"`
	PairingID         string     `json:"pairing_id"`
	CreatedAt         time.Time  `json:"created_at"`
	ExpiresAt         time.Time  `json:"expires_at"`
	Status            DropStatus `json:"status"`
	ReceiverApproved  bool       `json:"receiver_approved"`
	ReceiverCopyPath  string     `json:"receiver_copy_path,omitempty"`
	ScanCopyPath      string     `json:"scan_copy_path,omitempty"`
	ScanMode          ScanMode   `json:"scan_mode"`
	ScanStatus        ScanStatus `json:"scan_status"`
}
