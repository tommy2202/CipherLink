package api

import (
	"sync"
	"time"
)

const quotaDayWindow = 24 * time.Hour

type dailyCounter struct {
	start time.Time
	count int64
	bytes int64
}

type transferOwner struct {
	ip      string
	session string
}

type quotaTracker struct {
	mu sync.Mutex

	sessionsByIP       map[string]*dailyCounter
	sessionsBySession  map[string]*dailyCounter
	transfersByIP      map[string]*dailyCounter
	transfersBySession map[string]*dailyCounter
	bytesByIP          map[string]*dailyCounter
	bytesBySession     map[string]*dailyCounter

	concurrentByIP      map[string]int
	concurrentBySession map[string]int
	transferOwners      map[string]transferOwner

	relayByIdentity map[string]*dailyCounter
	relayActive     map[string][]time.Time
}

func newQuotaTracker() *quotaTracker {
	return &quotaTracker{
		sessionsByIP:        map[string]*dailyCounter{},
		sessionsBySession:   map[string]*dailyCounter{},
		transfersByIP:       map[string]*dailyCounter{},
		transfersBySession:  map[string]*dailyCounter{},
		bytesByIP:           map[string]*dailyCounter{},
		bytesBySession:      map[string]*dailyCounter{},
		concurrentByIP:      map[string]int{},
		concurrentBySession: map[string]int{},
		transferOwners:      map[string]transferOwner{},
		relayByIdentity:     map[string]*dailyCounter{},
		relayActive:         map[string][]time.Time{},
	}
}

func (q *quotaTracker) AllowSession(ip string, session string, limitIP int64, limitSession int64) bool {
	if limitIP <= 0 && limitSession <= 0 {
		return true
	}
	now := time.Now().UTC()
	q.mu.Lock()
	defer q.mu.Unlock()

	if !q.allowCount(q.sessionsByIP, ip, now, limitIP) {
		return false
	}
	if session != "" && !q.allowCount(q.sessionsBySession, session, now, limitSession) {
		return false
	}
	return true
}

func (q *quotaTracker) BeginTransfer(transferID string, ip string, session string, limitIP int64, limitSession int64, concurrentIP int, concurrentSession int) bool {
	if limitIP <= 0 && limitSession <= 0 && concurrentIP <= 0 && concurrentSession <= 0 {
		return true
	}
	now := time.Now().UTC()
	q.mu.Lock()
	defer q.mu.Unlock()

	if transferID == "" {
		return false
	}
	if owner, ok := q.transferOwners[transferID]; ok {
		_ = owner
		return true
	}

	if limitIP > 0 {
		counter := q.counter(q.transfersByIP, ip, now)
		if counter.count+1 > limitIP {
			return false
		}
	}
	if session != "" && limitSession > 0 {
		counter := q.counter(q.transfersBySession, session, now)
		if counter.count+1 > limitSession {
			return false
		}
	}
	if concurrentIP > 0 {
		if q.concurrentByIP[ip]+1 > concurrentIP {
			return false
		}
	}
	if session != "" && concurrentSession > 0 {
		if q.concurrentBySession[session]+1 > concurrentSession {
			return false
		}
	}

	if limitIP > 0 {
		counter := q.counter(q.transfersByIP, ip, now)
		counter.count++
	}
	if session != "" && limitSession > 0 {
		counter := q.counter(q.transfersBySession, session, now)
		counter.count++
	}
	if concurrentIP > 0 {
		q.concurrentByIP[ip] = q.concurrentByIP[ip] + 1
	}
	if session != "" && concurrentSession > 0 {
		q.concurrentBySession[session] = q.concurrentBySession[session] + 1
	}
	q.transferOwners[transferID] = transferOwner{ip: ip, session: session}
	return true
}

func (q *quotaTracker) EndTransfer(transferID string) {
	q.mu.Lock()
	defer q.mu.Unlock()

	owner, ok := q.transferOwners[transferID]
	if !ok {
		return
	}
	if owner.ip != "" {
		if q.concurrentByIP[owner.ip] > 0 {
			q.concurrentByIP[owner.ip]--
		}
	}
	if owner.session != "" {
		if q.concurrentBySession[owner.session] > 0 {
			q.concurrentBySession[owner.session]--
		}
	}
	delete(q.transferOwners, transferID)
}

func (q *quotaTracker) AddBytes(ip string, session string, bytes int64, limitIP int64, limitSession int64) bool {
	if bytes <= 0 {
		return true
	}
	if limitIP <= 0 && limitSession <= 0 {
		return true
	}
	now := time.Now().UTC()
	q.mu.Lock()
	defer q.mu.Unlock()

	var ipCounter *dailyCounter
	var sessionCounter *dailyCounter
	if limitIP > 0 {
		ipCounter = q.counter(q.bytesByIP, ip, now)
		if ipCounter.bytes+bytes > limitIP {
			return false
		}
	}
	if session != "" && limitSession > 0 {
		sessionCounter = q.counter(q.bytesBySession, session, now)
		if sessionCounter.bytes+bytes > limitSession {
			return false
		}
	}
	if ipCounter != nil {
		ipCounter.bytes += bytes
	}
	if sessionCounter != nil {
		sessionCounter.bytes += bytes
	}
	return true
}

func (q *quotaTracker) AllowRelay(identity string, perDay int64, concurrentLimit int, ttl time.Duration) bool {
	if perDay <= 0 && concurrentLimit <= 0 {
		return true
	}
	now := time.Now().UTC()
	q.mu.Lock()
	defer q.mu.Unlock()

	active := q.relayActive[identity]
	if len(active) > 0 {
		filtered := active[:0]
		for _, expiresAt := range active {
			if now.Before(expiresAt) {
				filtered = append(filtered, expiresAt)
			}
		}
		active = filtered
	}

	if concurrentLimit > 0 && len(active) >= concurrentLimit {
		q.relayActive[identity] = active
		return false
	}
	if perDay > 0 {
		counter := q.counter(q.relayByIdentity, identity, now)
		if counter.count+1 > perDay {
			q.relayActive[identity] = active
			return false
		}
		counter.count++
	}
	if concurrentLimit > 0 {
		active = append(active, now.Add(ttl))
	}
	q.relayActive[identity] = active
	return true
}

func (q *quotaTracker) counter(store map[string]*dailyCounter, key string, now time.Time) *dailyCounter {
	if key == "" {
		key = "unknown"
	}
	entry, ok := store[key]
	if !ok || entry == nil {
		entry = &dailyCounter{start: now}
		store[key] = entry
	}
	if entry.start.IsZero() || now.Sub(entry.start) >= quotaDayWindow {
		entry.start = now
		entry.count = 0
		entry.bytes = 0
	}
	return entry
}

func (q *quotaTracker) allowCount(store map[string]*dailyCounter, key string, now time.Time, limit int64) bool {
	if limit <= 0 {
		return true
	}
	entry := q.counter(store, key, now)
	if entry.count+1 > limit {
		return false
	}
	entry.count++
	return true
}

type bandwidthLimiter struct {
	rateBps int64
	next    time.Time
}

func (b *bandwidthLimiter) Reserve(bytes int64) time.Duration {
	if b.rateBps <= 0 || bytes <= 0 {
		return 0
	}
	now := time.Now()
	duration := time.Duration(float64(bytes) / float64(b.rateBps) * float64(time.Second))
	start := b.next
	if start.IsZero() || now.After(start) {
		start = now
	}
	end := start.Add(duration)
	b.next = end
	wait := end.Sub(now)
	if wait < 0 {
		return 0
	}
	return wait
}

type throttleManager struct {
	mu              sync.Mutex
	perTransferRate int64
	perTransfer     map[string]*bandwidthLimiter
	globalRate      int64
	global          bandwidthLimiter
}

func newThrottleManager(perTransfer int64, global int64) *throttleManager {
	return &throttleManager{
		perTransferRate: perTransfer,
		perTransfer:     map[string]*bandwidthLimiter{},
		globalRate:      global,
		global:          bandwidthLimiter{rateBps: global},
	}
}

func (t *throttleManager) ReserveTransfer(transferID string, bytes int64) time.Duration {
	if t.perTransferRate <= 0 {
		return 0
	}
	t.mu.Lock()
	defer t.mu.Unlock()

	limiter := t.perTransfer[transferID]
	if limiter == nil {
		limiter = &bandwidthLimiter{rateBps: t.perTransferRate}
		t.perTransfer[transferID] = limiter
	}
	return limiter.Reserve(bytes)
}

func (t *throttleManager) ReserveGlobal(bytes int64) time.Duration {
	if t.globalRate <= 0 {
		return 0
	}
	t.mu.Lock()
	defer t.mu.Unlock()

	t.global.rateBps = t.globalRate
	return t.global.Reserve(bytes)
}

func (t *throttleManager) ForgetTransfer(transferID string) {
	if transferID == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.perTransfer, transferID)
}

type downloadTokenStore struct {
	mu     sync.Mutex
	tokens map[string]downloadToken
}

type downloadToken struct {
	sessionID  string
	claimID    string
	transferID string
	expiresAt  time.Time
	used       bool
}

func newDownloadTokenStore() *downloadTokenStore {
	return &downloadTokenStore{
		tokens: map[string]downloadToken{},
	}
}

func (d *downloadTokenStore) Issue(sessionID string, claimID string, transferID string, ttl time.Duration) (string, time.Time, error) {
	token, err := randomBase64(24)
	if err != nil {
		return "", time.Time{}, err
	}
	expiresAt := time.Now().UTC().Add(ttl)
	hash := tokenHash(token)

	d.mu.Lock()
	defer d.mu.Unlock()
	d.prune(time.Now().UTC())
	d.tokens[hash] = downloadToken{
		sessionID:  sessionID,
		claimID:    claimID,
		transferID: transferID,
		expiresAt:  expiresAt,
		used:       false,
	}
	return token, expiresAt, nil
}

func (d *downloadTokenStore) Consume(sessionID string, claimID string, transferID string, token string) bool {
	if token == "" {
		return false
	}
	hash := tokenHash(token)
	now := time.Now().UTC()
	d.mu.Lock()
	defer d.mu.Unlock()
	d.prune(now)
	entry, ok := d.tokens[hash]
	if !ok {
		return false
	}
	if entry.used || now.After(entry.expiresAt) {
		delete(d.tokens, hash)
		return false
	}
	if entry.sessionID != sessionID || entry.claimID != claimID || entry.transferID != transferID {
		return false
	}
	entry.used = true
	d.tokens[hash] = entry
	return true
}

func (d *downloadTokenStore) prune(now time.Time) {
	for key, entry := range d.tokens {
		if entry.used || now.After(entry.expiresAt) {
			delete(d.tokens, key)
		}
	}
}
