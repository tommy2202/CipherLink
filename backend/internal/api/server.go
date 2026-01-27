package api

import (
	"io"
	"log"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"universaldrop/internal/clock"
	"universaldrop/internal/config"
	"universaldrop/internal/ratelimit"
	"universaldrop/internal/scanner"
	"universaldrop/internal/storage"
)

type Dependencies struct {
	Config  config.Config
	Store   storage.Storage
	Scanner scanner.Scanner
	Clock   clock.Clock
	Logger  *log.Logger
}

type Server struct {
	cfg           config.Config
	store         storage.Storage
	scanner       scanner.Scanner
	clock         clock.Clock
	limiterCreate *ratelimit.Limiter
	limiterRedeem *ratelimit.Limiter
	logger        *log.Logger
	Router        http.Handler
}

func NewServer(deps Dependencies) *Server {
	clk := deps.Clock
	if clk == nil {
		clk = clock.RealClock{}
	}
	logSink := deps.Logger
	if logSink == nil {
		logSink = log.New(io.Discard, "", 0)
	}
	scan := deps.Scanner
	if scan == nil {
		scan = scanner.NoopScanner{}
	}

	server := &Server{
		cfg:           deps.Config,
		store:         deps.Store,
		scanner:       scan,
		clock:         clk,
		limiterCreate: ratelimit.New(deps.Config.RateLimitCreate.Max, deps.Config.RateLimitCreate.Window, clk),
		limiterRedeem: ratelimit.New(deps.Config.RateLimitRedeem.Max, deps.Config.RateLimitRedeem.Window, clk),
		logger:        logSink,
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

	r.Get("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	r.Route("/v1", func(r chi.Router) {
		r.Post("/pairings", s.handleCreatePairing)
		r.Post("/pairings/{token}/redeem", s.handleRedeemPairing)
		r.Post("/pairings/{pairingID}/drops", s.handleCreateDrop)
		r.Post("/drops/{dropID}/approve", s.handleApproveDrop)
		r.Put("/drops/{dropID}/receiver-copy", s.handleUploadReceiverCopy)
		r.Get("/drops/{dropID}/receiver-copy", s.handleDownloadReceiverCopy)
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
		s.logger.Printf("method=%s route=%s status=%d duration=%s",
			r.Method, route, ww.Status(), time.Since(start).Truncate(time.Millisecond))
	})
}
