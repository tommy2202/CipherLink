package sweeper

import (
	"context"
	"log"
	"strconv"
	"time"

	"universaldrop/internal/clock"
	"universaldrop/internal/logging"
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
	count, err := s.store.SweepExpired(ctx, s.clock.Now())
	if err != nil {
		logging.Allowlist(s.logger, map[string]string{
			"event": "sweep_error",
			"error": "storage_error",
		})
		return
	}
	if count > 0 {
		logging.Allowlist(s.logger, map[string]string{
			"event": "sweep_complete",
			"count": strconv.Itoa(count),
		})
	}
}
