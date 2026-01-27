package scanner

import "context"

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
