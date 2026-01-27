package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"universaldrop/internal/api"
	"universaldrop/internal/config"
	"universaldrop/internal/logging"
	"universaldrop/internal/storage/localfs"
	"universaldrop/internal/token"
)

func main() {
	cfg := config.Load()
	logger := log.New(os.Stdout, "", log.LstdFlags)

	store, err := localfs.New(cfg.DataDir)
	if err != nil {
		logging.Fatal(logger, map[string]string{
			"event": "storage_init_failed",
		})
	}
	tokens := token.NewMemoryService()

	server := api.NewServer(api.Dependencies{
		Config: cfg,
		Store:  store,
		Tokens: tokens,
		Logger: logger,
	})

	httpServer := &http.Server{
		Addr:              cfg.Address,
		Handler:           server.Router,
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Printf("server_error=true")
		}
	}()

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_ = httpServer.Shutdown(shutdownCtx)
}
