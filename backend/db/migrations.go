package database

import _ "embed"

// InitMigration defines the persistent data model for the first release.
//
//go:embed migrations/init.sql
var InitMigration string

//go:embed migrations/vm.sql
var VMMigration string

//go:embed migrations/queue.sql
var QueueMigration string
