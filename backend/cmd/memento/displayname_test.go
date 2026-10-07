package main

import (
	"errors"
	"testing"
)

func TestNormalizeDisplayName(t *testing.T) {
	cases := []struct {
		in   string
		want string
		err  error
	}{
		{"nullptr_nina", "nullptr_nina", nil},
		{"  Budi   Santoso  ", "Budi Santoso", nil},
		{"Ayu.Lestari-2", "Ayu.Lestari-2", nil},
		{"ゼータ", "ゼータ", nil},
		{"12345678901234567890", "12345678901234567890", nil},
		{"", "", errDisplayNameEmpty},
		{"   \t ", "", errDisplayNameEmpty},
		{"123456789012345678901", "", errDisplayNameTooLong},
		{"_leading", "", errDisplayNameInvalid},
		{"-dash", "", errDisplayNameInvalid},
		{"<script>", "", errDisplayNameInvalid},
		{"a\"quote", "", errDisplayNameInvalid},
		{"emoji😀", "", errDisplayNameInvalid},
		{"tab\tinside", "tab inside", nil},
	}
	for _, c := range cases {
		got, err := normalizeDisplayName(c.in)
		if !errors.Is(err, c.err) || got != c.want {
			t.Errorf("normalizeDisplayName(%q) = %q, %v; want %q, %v", c.in, got, err, c.want, c.err)
		}
	}
}

func TestMaxDisplayNameCountsCharactersNotBytes(t *testing.T) {
	name := "ああああああああああああああああああああ" // 20 characters, 60 bytes
	if _, err := normalizeDisplayName(name); err != nil {
		t.Fatalf("20 multi-byte characters should be allowed: %v", err)
	}
	if _, err := normalizeDisplayName(name + "あ"); !errors.Is(err, errDisplayNameTooLong) {
		t.Fatalf("21 characters should be rejected, got %v", err)
	}
}
