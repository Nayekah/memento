package main

import (
	"errors"

	"github.com/jackc/pgx/v5/pgconn"
)

const displayNameUniqueIndex = "students_display_name_lower_key"

var errDisplayNameInUse = errors.New("that display name is already used by another student")

// mapDisplayNameConflict turns a violation of the unique display name index
// into errDisplayNameInUse and passes every other error through.
func mapDisplayNameConflict(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" && pgErr.ConstraintName == displayNameUniqueIndex {
		return errDisplayNameInUse
	}
	return err
}
