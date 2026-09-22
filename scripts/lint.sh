#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repository_root"

find_tool() {
    for candidate in "$@"; do
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done
    return 1
}

go_binary=$(find_tool go go.exe || true)
gofmt_binary=$(find_tool gofmt gofmt.exe || true)
if [ -z "$go_binary" ] || [ -z "$gofmt_binary" ]; then
    echo 'Go and gofmt must be installed and available in PATH.' >&2
    exit 127
fi

unformatted=$("$gofmt_binary" -l backend/cmd/memento/*.go backend/db/*.go)
if [ -n "$unformatted" ]; then
    echo 'Go files must be formatted with gofmt:' >&2
    printf '%s\n' "$unformatted" >&2
    exit 1
fi

(
    cd backend
    "$go_binary" vet ./cmd/memento ./db
)

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck backend/grader/grade.sh backend/scripts/smoke-test.sh \
        sandbox/scripts/build-vm.sh sandbox/vm/scripts/provision.sh
else
    echo 'ShellCheck is not installed; shell linting was skipped.'
fi
