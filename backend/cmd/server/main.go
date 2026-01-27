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
	"universaldrop/internal/clock"
	"universaldrop/internal/config"
	"universaldrop/internal/scanner"
	"universaldrop/internal/storage/localfs"
	"universaldrop/internal/sweeper"
)

func main() {
	cfg := config.Load()
	logger := log.New(os.Stdout, "", log.LstdFlags)
	clk := clock.RealClock{}

	store, err := localfs.New(cfg.DataDir)
	if err != nil {
		logger.Fatalf("storage_init_failed=true")
	}

	server := api.NewServer(api.Dependencies{
		Config:  cfg,
		Store:   store,
		Scanner: scanner.NoopScanner{},
		Clock:   clk,
		Logger:  logger,
	})

	httpServer := &http.Server{
		Addr:              cfg.Address,
		Handler:           server.Router,
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	sweep := sweeper.New(store, clk, cfg.SweepInterval, logger)
	sweep.Start(ctx)

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
