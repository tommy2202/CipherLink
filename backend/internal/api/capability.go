package api

import (
	"net/http"

	"github.com/go-chi/chi/v5"

	"universaldrop/internal/auth"
)

func routePattern(r *http.Request) string {
	if r == nil {
		return ""
	}
	if ctx := chi.RouteContext(r.Context()); ctx != nil {
		if pattern := ctx.RoutePattern(); pattern != "" {
			return pattern
		}
	}
	return r.URL.Path
}

func (s *Server) requireCapability(r *http.Request, token string, req auth.Requirement) (auth.Claims, bool) {
	if token == "" {
		token = bearerToken(r)
	}
	if req.Route == "" {
		req.Route = routePattern(r)
	}
	return s.capabilities.Validate(token, req)
}
