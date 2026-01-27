package api

import (
	"io"
	"log"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"universaldrop/internal/config"
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
	cfg     config.Config
	store   storage.Storage
	tokens  token.TokenService
	logger  *log.Logger
	version string
	Router  http.Handler
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

	server := &Server{
		cfg:     deps.Config,
		store:   deps.Store,
		tokens:  deps.Tokens,
		logger:  logSink,
		version: version,
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
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "version": s.version})
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
