package api

import (
	"io"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"universaldrop/internal/clock"
	"universaldrop/internal/config"
	"universaldrop/internal/logging"
	"universaldrop/internal/ratelimit"
	"universaldrop/internal/storage"
	"universaldrop/internal/token"
)

type Dependencies struct {
	Config config.Config
	Store  storage.Storage
	Tokens token.TokenService
	Logger *log.Logger
	Version string
}

type Server struct {
	cfg          config.Config
	store        storage.Storage
	tokens       token.TokenService
	logger       *log.Logger
	version      string
	rateLimiters map[string]*ratelimit.Limiter
	Router       http.Handler
}

func NewServer(deps Dependencies) *Server {
	logSink := deps.Logger
	if logSink == nil {
		logSink = log.New(io.Discard, "", 0)
	}
	version := deps.Version
	if version == "" {
		version = "0.1"
	}
	tokenService := deps.Tokens
	if tokenService == nil {
		tokenService = token.NewMemoryService()
	}

	rateLimiters := map[string]*ratelimit.Limiter{}
	clk := clock.RealClock{}
	if deps.Config.RateLimitHealth.Max > 0 {
		rateLimiters["health"] = ratelimit.New(deps.Config.RateLimitHealth.Max, deps.Config.RateLimitHealth.Window, clk)
	}
	if deps.Config.RateLimitV1.Max > 0 {
		rateLimiters["v1"] = ratelimit.New(deps.Config.RateLimitV1.Max, deps.Config.RateLimitV1.Window, clk)
	}

	server := &Server{
		cfg:          deps.Config,
		store:        deps.Store,
		tokens:       tokenService,
		logger:       logSink,
		version:      version,
		rateLimiters: rateLimiters,
	}

	server.Router = server.routes()
	return server
}

func (s *Server) routes() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Recoverer)
	r.Use(middleware.Timeout(15 * time.Second))
	r.Use(s.safeLogger)

	r.With(s.rateLimit("health")).Get("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "version": s.version})
	})

	r.Route("/v1", func(r chi.Router) {
		r.Use(s.rateLimit("v1"))
		r.Get("/ping", s.handlePing)
		r.Post("/session/create", s.handleCreateSession)
		r.Get("/transfers/{transferID}/manifest", s.handleGetTransferManifest)
	})

	return r
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
