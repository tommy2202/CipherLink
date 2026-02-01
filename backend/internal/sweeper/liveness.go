package sweeper

import (
	"sync"
	"time"
)

type Liveness struct {
	mu        sync.Mutex
	lastSweep time.Time
}

func NewLiveness() *Liveness {
	return &Liveness{}
}

func (l *Liveness) Mark(at time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lastSweep = at
}

func (l *Liveness) LastSweep() time.Time {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.lastSweep
}
