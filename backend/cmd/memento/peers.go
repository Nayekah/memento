package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

var errPeerAddressTaken = errors.New("that VPN address is already registered to another student")

// normalizePeerAddress parses a VPN address, unwrapping IPv4-in-IPv6 forms.
func normalizePeerAddress(raw string) (netip.Addr, error) {
	addr, err := netip.ParseAddr(strings.TrimSpace(raw))
	if err != nil {
		return netip.Addr{}, fmt.Errorf("%q is not an IP address", strings.TrimSpace(raw))
	}
	addr = addr.Unmap().WithZone("")
	if addr.IsUnspecified() || addr.IsMulticast() {
		return netip.Addr{}, fmt.Errorf("%s cannot be a student's VPN address", addr)
	}
	return addr, nil
}

type execer interface {
	Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error)
}

func setStudentPeer(ctx context.Context, db execer, student string, addr netip.Addr) error {
	_, err := db.Exec(ctx, `
		INSERT INTO student_peers (student_id, peer_ip) VALUES ($1, $2::inet)
		ON CONFLICT (student_id) DO UPDATE SET peer_ip = EXCLUDED.peer_ip`, student, addr.String())
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		switch {
		case pgErr.Code == "23505" && pgErr.ConstraintName == "student_peers_peer_ip_key":
			return errPeerAddressTaken
		case pgErr.Code == "23503":
			return errStudentNotRegistered
		}
	}
	return err
}

func clearStudentPeer(ctx context.Context, db execer, student string) error {
	_, err := db.Exec(ctx, `DELETE FROM student_peers WHERE student_id = $1`, student)
	return err
}

func studentPeer(ctx context.Context, db *pgxpool.Pool, student string) (netip.Addr, bool, error) {
	var text string
	err := db.QueryRow(ctx, `SELECT host(peer_ip) FROM student_peers WHERE student_id = $1`, student).Scan(&text)
	if errors.Is(err, pgx.ErrNoRows) {
		return netip.Addr{}, false, nil
	}
	if err != nil {
		return netip.Addr{}, false, err
	}
	addr, err := netip.ParseAddr(text)
	if err != nil {
		return netip.Addr{}, false, err
	}
	return addr.Unmap(), true, nil
}

func databasePeerLookup(db *pgxpool.Pool) func(context.Context, string) (netip.Addr, bool, error) {
	return func(ctx context.Context, student string) (netip.Addr, bool, error) {
		return studentPeer(ctx, db, student)
	}
}

// importPeers registers the VPN addresses listed in a tab separated file whose
// first two columns are the student ID and the address, such as the manifest
// that provision-cohort.sh writes. A header row starting with "nim" is
// skipped. Either every row is registered or none is.
func importPeers(ctx context.Context, db *pgxpool.Pool, input io.Reader) (int, error) {
	tx, err := db.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	scanner := bufio.NewScanner(input)
	imported := 0
	for line := 1; scanner.Scan(); line++ {
		fields := strings.Split(strings.TrimRight(scanner.Text(), "\r"), "\t")
		if len(fields) == 1 && strings.TrimSpace(fields[0]) == "" {
			continue
		}
		if line == 1 && strings.EqualFold(strings.TrimSpace(fields[0]), "nim") {
			continue
		}
		if len(fields) < 2 {
			return 0, fmt.Errorf("line %d: expected a student ID and a VPN address separated by a tab", line)
		}
		student := strings.TrimSpace(fields[0])
		if !studentIDPattern.MatchString(student) {
			return 0, fmt.Errorf("line %d: %q is not a valid student ID", line, student)
		}
		addr, err := normalizePeerAddress(fields[1])
		if err != nil {
			return 0, fmt.Errorf("line %d: %w", line, err)
		}
		if err := setStudentPeer(ctx, tx, student, addr); err != nil {
			return 0, fmt.Errorf("line %d (%s): %w", line, student, err)
		}
		imported++
	}
	if err := scanner.Err(); err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return imported, nil
}

func runPeerCommand(ctx context.Context, db *pgxpool.Pool, args []string) error {
	usageError := errors.New("usage: memento peer STUDENT_ID [IP|--clear]")
	if len(args) < 1 || len(args) > 2 || !studentIDPattern.MatchString(args[0]) {
		return usageError
	}
	student := args[0]
	switch {
	case len(args) == 1:
		addr, found, err := studentPeer(ctx, db, student)
		if err != nil {
			return err
		}
		if !found {
			fmt.Println("none")
			return nil
		}
		fmt.Println(addr)
		return nil
	case args[1] == "--clear":
		return clearStudentPeer(ctx, db, student)
	default:
		addr, err := normalizePeerAddress(args[1])
		if err != nil {
			return err
		}
		return setStudentPeer(ctx, db, student, addr)
	}
}

func runPeersCommand(ctx context.Context, db *pgxpool.Pool, args []string, input io.Reader) error {
	if len(args) != 1 || args[0] != "import" {
		return errors.New("usage: memento peers import < students.tsv")
	}
	imported, err := importPeers(ctx, db, input)
	if err != nil {
		return err
	}
	fmt.Printf("Registered %d VPN addresses\n", imported)
	return nil
}
