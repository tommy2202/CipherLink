package sweeper

import (
	"context"
	"log"
	"strconv"
	"time"

	"universaldrop/internal/clock"
	"universaldrop/internal/logging"
	"universaldrop/internal/metrics"
	"universaldrop/internal/storage"
)

type Sweeper struct {
	store    storage.Storage
	clock    clock.Clock
	interval time.Duration
	logger   *log.Logger
	liveness *Liveness
	metrics  *metrics.Counters
}

func New(store storage.Storage, clk clock.Clock, interval time.Duration, logger *log.Logger, liveness *Liveness, counters *metrics.Counters) *Sweeper {
	return &Sweeper{
		store:    store,
		clock:    clk,
		interval: interval,
		logger:   logger,
		liveness: liveness,
		metrics:  counters,
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

func (s *Sweeper) SweepOnce(ctx context.Context) {
	s.sweep(ctx)
}

func (s *Sweeper) sweep(ctx context.Context) {
	if s.metrics != nil {
		s.metrics.IncSweeperRuns()
	}
	result, err := s.store.SweepExpired(ctx, s.clock.Now())
	if err != nil {
		logging.Allowlist(s.logger, map[string]string{
			"event": "sweep_error",
			"error": "storage_error",
		})
		return
	}
	if s.metrics != nil {
		s.metrics.AddTransfersExpired(result.Transfers)
	}
	if s.liveness != nil {
		s.liveness.Mark(s.clock.Now())
	}
	if total := result.Total(); total > 0 {
		logging.Allowlist(s.logger, map[string]string{
			"event": "sweep_complete",
			"count": strconv.Itoa(total),
		})
	}
}
