package metrics

import "sync/atomic"

type Counters struct {
	sessionsCreatedTotal      atomic.Uint64
	transfersStartedTotal     atomic.Uint64
	transfersCompletedTotal   atomic.Uint64
	transfersExpiredTotal     atomic.Uint64
	sweeperRunsTotal          atomic.Uint64
	relayIceConfigIssuedTotal atomic.Uint64
}

func NewCounters() *Counters {
	return &Counters{}
}

func (c *Counters) IncSessionsCreated() {
	c.sessionsCreatedTotal.Add(1)
}

func (c *Counters) IncTransfersStarted() {
	c.transfersStartedTotal.Add(1)
}

func (c *Counters) IncTransfersCompleted() {
	c.transfersCompletedTotal.Add(1)
}

func (c *Counters) AddTransfersExpired(count int) {
	if count <= 0 {
		return
	}
	c.transfersExpiredTotal.Add(uint64(count))
}

func (c *Counters) IncSweeperRuns() {
	c.sweeperRunsTotal.Add(1)
}

func (c *Counters) IncRelayIceConfigIssued() {
	c.relayIceConfigIssuedTotal.Add(1)
}

func (c *Counters) Snapshot() map[string]uint64 {
	return map[string]uint64{
		"sessions_created_total":        c.sessionsCreatedTotal.Load(),
		"transfers_started_total":       c.transfersStartedTotal.Load(),
		"transfers_completed_total":     c.transfersCompletedTotal.Load(),
		"transfers_expired_total":       c.transfersExpiredTotal.Load(),
		"sweeper_runs_total":            c.sweeperRunsTotal.Load(),
		"relay_ice_config_issued_total": c.relayIceConfigIssuedTotal.Load(),
	}
}
