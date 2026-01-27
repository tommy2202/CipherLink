package ratelimit

import (
	"sync"
	"time"

	"universaldrop/internal/clock"
)

type Limiter struct {
	mu     sync.Mutex
	limit  int
	window time.Duration
	clock  clock.Clock
	buckets map[string]bucket
}

type bucket struct {
	start time.Time
	count int
}

func New(limit int, window time.Duration, clk clock.Clock) *Limiter {
	return &Limiter{
		limit:   limit,
		window: window,
		clock:  clk,
		buckets: map[string]bucket{},
	}
}

func (l *Limiter) Allow(key string) bool {
	if l.limit <= 0 {
		return true
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	now := l.clock.Now()
	entry := l.buckets[key]
	if entry.start.IsZero() || now.Sub(entry.start) >= l.window {
		entry = bucket{start: now, count: 0}
	}

	if entry.count >= l.limit {
		l.buckets[key] = entry
		return false
	}

	entry.count++
	l.buckets[key] = entry
	return true
}
