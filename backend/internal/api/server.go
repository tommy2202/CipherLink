package api

import (
	"context"
	"io"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"universaldrop/internal/auth"
	"universaldrop/internal/clock"
	"universaldrop/internal/config"
	"universaldrop/internal/logging"
	"universaldrop/internal/metrics"
	"universaldrop/internal/ratelimit"
	"universaldrop/internal/scanner"
	"universaldrop/internal/storage"
	"universaldrop/internal/transfer"
)

type SweeperStatus interface {
	LastSweep() time.Time
}

type StorageHealthChecker interface {
	HealthCheck(ctx context.Context) error
}

type Dependencies struct {
	Config        config.Config
	Store         storage.Storage
	Logger        *log.Logger
	Version       string
	Scanner       scanner.Scanner
	Clock         clock.Clock
	Capabilities  *auth.Service
	SweeperStatus SweeperStatus
}

type Server struct {
	cfg            config.Config
	store          storage.Storage
	logger         *log.Logger
	version        string
	rateLimiters   map[string]*ratelimit.Limiter
	transfers      *transfer.Engine
	scanner        scanner.Scanner
	quotas         *quotaTracker
	throttles      *throttleManager
	downloadTokens *downloadTokenStore
	clock          clock.Clock
	sweeperStatus  SweeperStatus
	metrics        *metrics.Counters
	capabilities   *auth.Service
	Router         http.Handler
}

var nonTransferTimeout = 2 * time.Minute
var timeoutMiddleware = middleware.Timeout

const sweeperStaleThreshold = 10 * time.Minute

func NewServer(deps Dependencies) *Server {
	logSink := deps.Logger
	if logSink == nil {
		logSink = log.New(io.Discard, "", 0)
	}
	version := deps.Version
	if version == "" {
		version = "0.1"
	}
	scanService := deps.Scanner
	if scanService == nil {
		scanService = scanner.UnavailableScanner{}
	}
	clk := deps.Clock
	if clk == nil {
		clk = clock.RealClock{}
	}
	caps := deps.Capabilities
	if caps == nil {
		caps = auth.NewService(nil, clk, nil)
	}

	rateLimiters := map[string]*ratelimit.Limiter{}
	if deps.Config.RateLimitHealth.Max > 0 {
		rateLimiters["health"] = ratelimit.New(deps.Config.RateLimitHealth.Max, deps.Config.RateLimitHealth.Window, clk)
	}
	if deps.Config.RateLimitV1.Max > 0 {
		rateLimiters["v1"] = ratelimit.New(deps.Config.RateLimitV1.Max, deps.Config.RateLimitV1.Window, clk)
	}
	if deps.Config.RateLimitSessionClaim.Max > 0 {
		rateLimiters["session-claim"] = ratelimit.New(deps.Config.RateLimitSessionClaim.Max, deps.Config.RateLimitSessionClaim.Window, clk)
	}

	server := &Server{
		cfg:            deps.Config,
		store:          deps.Store,
		logger:         logSink,
		version:        version,
		rateLimiters:   rateLimiters,
		transfers:      transfer.New(deps.Store),
		scanner:        scanService,
		quotas:         newQuotaTracker(),
		throttles:      newThrottleManager(deps.Config.Throttles.TransferBandwidthCapBps, deps.Config.Throttles.GlobalBandwidthCapBps),
		downloadTokens: newDownloadTokenStore(),
		clock:          clk,
		sweeperStatus:  deps.SweeperStatus,
		metrics:        metrics.NewCounters(),
		capabilities:   caps,
	}

	server.Router = server.routes()
	return server
}

func (s *Server) routes() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Recoverer)

	r.With(timeoutMiddleware(nonTransferTimeout)).With(s.safeLogger).With(s.rateLimit("health")).Get("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})
	r.With(timeoutMiddleware(nonTransferTimeout)).With(s.safeLogger).With(s.rateLimit("health")).Get("/readyz", s.handleReadyz)
	r.With(timeoutMiddleware(nonTransferTimeout)).With(s.safeLogger).With(s.rateLimit("health")).Get("/metricsz", s.handleMetrics)

	r.Route("/v1", func(r chi.Router) {
		r.Group(func(r chi.Router) {
			r.Use(timeoutMiddleware(nonTransferTimeout))
			r.Use(s.safeLogger)
			r.Use(s.rateLimit("v1"))
			r.Get("/ping", s.handlePing)
			r.With(s.rateLimit("session-claim")).Post("/session/claim", s.handleClaimSession)
			r.Post("/session/approve", s.handleApproveSession)
			r.Post("/session/sas/commit", s.handleCommitSAS)
			r.Get("/session/sas/status", s.handleSASStatus)
			r.Get("/session/poll", s.handlePollSession)
			r.Post("/session/create", s.handleCreateSession)
			r.Route("/p2p", func(r chi.Router) {
				r.Post("/offer", s.handleP2POffer)
				r.Post("/answer", s.handleP2PAnswer)
				r.Post("/ice", s.handleP2PICE)
				r.Get("/poll", s.handleP2PPoll)
				r.Get("/ice_config", s.handleP2PIceConfig)
			})
		})
		r.Route("/transfer", func(r chi.Router) {
			r.Use(s.safeLogger)
			r.Use(s.rateLimit("v1"))
			r.Post("/init", s.handleInitTransfer)
			r.Put("/chunk", s.handleUploadChunk)
			r.Post("/finalize", s.handleFinalizeTransfer)
			r.Get("/manifest", s.handleGetTransferManifest)
			r.Post("/download_token", s.handleDownloadToken)
			r.Get("/download", s.handleDownloadTransfer)
			r.Post("/receipt", s.handleTransferReceipt)
			r.Post("/scan_init", s.handleScanInit)
			r.Put("/scan_chunk", s.handleScanChunk)
			r.Post("/scan_finalize", s.handleScanFinalize)
		})
	})

	return r
}

func (s *Server) Metrics() *metrics.Counters {
	return s.metrics
}

func (s *Server) safeLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)

		next.ServeHTTP(ww, r)

		route := chi.RouteContext(r.Context()).RoutePattern()
		if route == "" {
			route = "unknown"
		}
		logging.Allowlist(s.logger, map[string]string{
			"method":      r.Method,
			"route":       route,
			"status":      strconv.Itoa(ww.Status()),
			"duration_ms": strconv.FormatInt(time.Since(start).Milliseconds(), 10),
			"ip_hash":     anonHash(clientIP(r)),
		})
	})
}

func (s *Server) rateLimit(group string) func(http.Handler) http.Handler {
	limiter := s.rateLimiters[group]
	if limiter == nil {
		return func(next http.Handler) http.Handler {
			return next
		}
	}

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			key := group + ":" + clientIP(r)
			if !limiter.Allow(key) {
				writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "rate_limited"})
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	storageOK := s.storageOK(r.Context())
	sweeperOK := s.sweeperOK()
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":         storageOK && sweeperOK,
		"storage_ok": storageOK,
		"sweeper_ok": sweeperOK,
	})
}

func (s *Server) storageOK(ctx context.Context) bool {
	if s.store == nil {
		return false
	}
	checker, ok := s.store.(StorageHealthChecker)
	if !ok {
		return true
	}
	return checker.HealthCheck(ctx) == nil
}

func (s *Server) sweeperOK() bool {
	if s.sweeperStatus == nil {
		return false
	}
	lastSweep := s.sweeperStatus.LastSweep()
	if lastSweep.IsZero() {
		return false
	}
	now := s.clock.Now()
	if now.Before(lastSweep) {
		return true
	}
	return now.Sub(lastSweep) <= sweeperStaleThreshold
}
