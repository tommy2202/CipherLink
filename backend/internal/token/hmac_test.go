package token

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"universaldrop/internal/clock"
)

func TestHMACServiceIssueValidateRestart(t *testing.T) {
	secret := bytes.Repeat([]byte{0x11}, 32)
	svc1 := NewHMACService(secret)
	tokenStr, err := svc1.Issue(context.Background(), "scopeA", time.Minute)
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}

	svc2 := NewHMACService(secret)
	ok, err := svc2.Validate(context.Background(), tokenStr, "scopeA")
	if err != nil {
		t.Fatalf("validate token: %v", err)
	}
	if !ok {
		t.Fatalf("expected token to validate across restarts")
	}
}

func TestHMACServiceRejectsWrongScope(t *testing.T) {
	secret := bytes.Repeat([]byte{0x22}, 32)
	svc := NewHMACService(secret)
	tokenStr, err := svc.Issue(context.Background(), "scopeA", time.Minute)
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}
	ok, err := svc.Validate(context.Background(), tokenStr, "scopeB")
	if err != nil {
		t.Fatalf("validate token: %v", err)
	}
	if ok {
		t.Fatalf("expected wrong scope to fail validation")
	}
}

func TestHMACServiceRejectsExpiredToken(t *testing.T) {
	secret := bytes.Repeat([]byte{0x33}, 32)
	fakeClock := clock.NewFake(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	svc := newHMACServiceWithClock(secret, fakeClock)
	tokenStr, err := svc.Issue(context.Background(), "scopeA", 10*time.Second)
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}
	fakeClock.Advance(11 * time.Second)
	ok, err := svc.Validate(context.Background(), tokenStr, "scopeA")
	if err != nil {
		t.Fatalf("validate token: %v", err)
	}
	if ok {
		t.Fatalf("expected expired token to fail validation")
	}
}

func TestHMACServiceRejectsTamperedToken(t *testing.T) {
	secret := bytes.Repeat([]byte{0x44}, 32)
	svc := NewHMACService(secret)
	tokenStr, err := svc.Issue(context.Background(), "scopeA", time.Minute)
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}
	tampered := tamperTokenPayload(tokenStr)
	ok, err := svc.Validate(context.Background(), tampered, "scopeA")
	if err != nil {
		t.Fatalf("validate token: %v", err)
	}
	if ok {
		t.Fatalf("expected tampered token to fail validation")
	}
}

func tamperTokenPayload(token string) string {
	parts := strings.Split(token, ".")
	if len(parts) != 2 || parts[0] == "" {
		return token
	}
	payload := []byte(parts[0])
	replacement := byte('a')
	if payload[0] == 'a' {
		replacement = 'b'
	}
	payload[0] = replacement
	parts[0] = string(payload)
	return strings.Join(parts, ".")
}
