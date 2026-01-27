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
