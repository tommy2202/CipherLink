package sweeper

import (
	"context"
	"log"
	"time"

	"universaldrop/internal/clock"
	"universaldrop/internal/storage"
)

type Sweeper struct {
	store    storage.Storage
	clock    clock.Clock
	interval time.Duration
	logger   *log.Logger
}

func New(store storage.Storage, clk clock.Clock, interval time.Duration, logger *log.Logger) *Sweeper {
	return &Sweeper{
		store:    store,
		clock:    clk,
		interval: interval,
		logger:   logger,
	}
}

func (s *Sweeper) Start(ctx context.Context) {
	if s.interval <= 0 {
		return
	}

	ticker := time.NewTicker(s.interval)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				s.sweep(ctx)
			}
		}
	}()
}

func (s *Sweeper) sweep(ctx context.Context) {
	report, err := s.store.PurgeExpired(ctx, s.clock.Now())
	if err != nil {
		if s.logger != nil {
			s.logger.Printf("sweeper_error=true")
		}
		return
	}

	if s.logger != nil && (report.Tokens > 0 || report.Drops > 0) {
		s.logger.Printf("sweeper_tokens=%d sweeper_drops=%d sweeper_receiver_copies=%d sweeper_scan_copies=%d",
			report.Tokens, report.Drops, report.ReceiverCopies, report.ScanCopies)
	}
}
