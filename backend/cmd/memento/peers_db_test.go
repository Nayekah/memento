package main

import (
	"context"
	"errors"
	"net/netip"
	"strings"
	"testing"
)

func TestStudentPeerRegistration(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "alice", "bob")
	first, second := netip.MustParseAddr("10.66.0.10"), netip.MustParseAddr("10.66.0.11")

	var exists bool
	if err := db.QueryRow(ctx, `SELECT to_regclass('student_peers') IS NOT NULL`).Scan(&exists); err != nil || !exists {
		t.Fatalf("student_peers is missing after migration (err=%v)", err)
	}
	if _, found, err := studentPeer(ctx, db, "alice"); err != nil || found {
		t.Fatalf("before registration: found=%v err=%v", found, err)
	}
	if err := setStudentPeer(ctx, db, "alice", first); err != nil {
		t.Fatal(err)
	}
	if got, found, err := studentPeer(ctx, db, "alice"); err != nil || !found || got != first {
		t.Fatalf("after registration: %v found=%v err=%v", got, found, err)
	}
	if err := setStudentPeer(ctx, db, "alice", second); err != nil {
		t.Fatalf("replacing the address: %v", err)
	}
	if got, _, _ := studentPeer(ctx, db, "alice"); got != second {
		t.Errorf("after replacing the address: %v, want %v", got, second)
	}
	if err := setStudentPeer(ctx, db, "bob", second); !errors.Is(err, errPeerAddressTaken) {
		t.Errorf("an address that belongs to another student: error = %v, want errPeerAddressTaken", err)
	}
	if err := setStudentPeer(ctx, db, "ghost", first); !errors.Is(err, errStudentNotRegistered) {
		t.Errorf("an unregistered student: error = %v, want errStudentNotRegistered", err)
	}
	if err := setStudentPeer(ctx, db, "bob", netip.MustParseAddr("2001:db8::10")); err != nil {
		t.Errorf("an IPv6 address: %v", err)
	}
	if got, _, _ := studentPeer(ctx, db, "bob"); got.String() != "2001:db8::10" {
		t.Errorf("IPv6 round trip: %v", got)
	}
	if err := clearStudentPeer(ctx, db, "alice"); err != nil {
		t.Fatal(err)
	}
	if _, found, _ := studentPeer(ctx, db, "alice"); found {
		t.Error("the registration is still there after clearing it")
	}
	if err := runPeerCommand(ctx, db, []string{"alice", "10.66.0.12"}); err != nil {
		t.Errorf("peer command: %v", err)
	}
	if got, _, _ := studentPeer(ctx, db, "alice"); got.String() != "10.66.0.12" {
		t.Errorf("after the peer command: %v", got)
	}
	for _, args := range [][]string{{}, {"alice", "not-an-ip"}, {"alice", "0.0.0.0"}, {"alice", "224.0.0.1"}, {"bad id", "10.66.0.12"}, {"alice", "10.66.0.12", "extra"}} {
		if err := runPeerCommand(ctx, db, args); err == nil {
			t.Errorf("peer command %v: expected an error", args)
		}
	}
}

func TestNormalizePeerAddressUnwrapsIPv4InIPv6(t *testing.T) {
	got, err := normalizePeerAddress(" ::ffff:10.66.0.10 ")
	if err != nil || got.String() != "10.66.0.10" {
		t.Fatalf("got %v, %v; want 10.66.0.10", got, err)
	}
}

func TestImportPeers(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "18225001", "18225002", "18225003")
	manifest := "nim\tvpn_ip\tconfig_file\ttoken_file\r\n" +
		"18225001\t10.66.0.10\t/secure/18225001.conf\t/secure/18225001.token\r\n" +
		"\r\n" +
		"18225002\t10.66.0.11\t/secure/18225002.conf\t/secure/18225002.token\n" +
		"18225003\t10.66.0.12\n"
	imported, err := importPeers(ctx, db, strings.NewReader(manifest))
	if err != nil || imported != 3 {
		t.Fatalf("imported %d, %v; want 3", imported, err)
	}
	for student, want := range map[string]string{"18225001": "10.66.0.10", "18225002": "10.66.0.11", "18225003": "10.66.0.12"} {
		if got, found, _ := studentPeer(ctx, db, student); !found || got.String() != want {
			t.Errorf("%s: %v found=%v, want %s", student, got, found, want)
		}
	}
	again, err := importPeers(ctx, db, strings.NewReader(manifest))
	if err != nil || again != 3 {
		t.Errorf("importing the same file again: %d, %v; want 3 and no error", again, err)
	}
}

func TestImportPeersIsAllOrNothing(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "18225001", "18225002")
	cases := []struct {
		name string
		file string
		want string
	}{
		{"an unknown student", "18225001\t10.66.0.10\n99999999\t10.66.0.11\n", "line 2"},
		{"a malformed address", "18225001\t10.66.0.10\n18225002\tnot-an-ip\n", "line 2"},
		{"a row without an address", "18225001\t10.66.0.10\n18225002\n", "line 2"},
		{"an invalid student ID", "18225001\t10.66.0.10\nbad id\t10.66.0.11\n", "line 2"},
		{"one address for two students", "18225001\t10.66.0.10\n18225002\t10.66.0.10\n", "line 2"},
	}
	for _, c := range cases {
		imported, err := importPeers(ctx, db, strings.NewReader(c.file))
		if err == nil || imported != 0 || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: imported %d, error = %v; want 0 and an error naming %s", c.name, imported, err, c.want)
		}
		var rows int
		if err := db.QueryRow(ctx, `SELECT count(*) FROM student_peers`).Scan(&rows); err != nil || rows != 0 {
			t.Errorf("%s: %d registrations remain after the failed import (err=%v)", c.name, rows, err)
		}
	}
}
