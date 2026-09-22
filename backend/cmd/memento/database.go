package main

import (
	"context"
	"fmt"
	"time"

	database "github.com/Nayekah/memento/backend/db"
	"github.com/jackc/pgx/v5/pgxpool"
)

type migration struct {
	version string
	sql     string
}

var migrations = []migration{
	{version: "001_initial", sql: database.InitMigration},
	{version: "002_vm_activations", sql: database.VMMigration},
	{version: "003_queue_hardening", sql: database.QueueMigration},
}

func openDatabase(ctx context.Context, cfg config) (*pgxpool.Pool, error) {
	poolConfig, err := pgxpool.ParseConfig(cfg.databaseURL)
	if err != nil {
		return nil, err
	}
	poolConfig.MaxConns = 12
	poolConfig.MinConns = 1
	poolConfig.MaxConnLifetime = 30 * time.Minute
	poolConfig.MaxConnIdleTime = 5 * time.Minute
	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	if err := migrate(ctx, pool); err != nil {
		pool.Close()
		return nil, err
	}
	return pool, nil
}

func migrate(ctx context.Context, db *pgxpool.Pool) error {
	tx, err := db.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('memento-schema-migrations'))`); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return err
	}
	for _, migration := range migrations {
		var applied bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version = $1)`, migration.version).Scan(&applied); err != nil {
			return err
		}
		if applied {
			continue
		}
		if _, err := tx.Exec(ctx, migration.sql); err != nil {
			return fmt.Errorf("apply migration %s: %w", migration.version, err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO schema_migrations (version) VALUES ($1)`, migration.version); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
