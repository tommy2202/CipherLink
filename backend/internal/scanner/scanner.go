package scanner

import (
	"context"
	"errors"
)

var ErrUnavailable = errors.New("scanner unavailable")

type Result struct {
	Clean bool
}

type Scanner interface {
	Scan(ctx context.Context, data []byte) (Result, error)
}

type NoopScanner struct{}

func (NoopScanner) Scan(_ context.Context, _ []byte) (Result, error) {
	return Result{Clean: true}, nil
}

type UnavailableScanner struct{}

func (UnavailableScanner) Scan(_ context.Context, _ []byte) (Result, error) {
	return Result{Clean: false}, ErrUnavailable
}
