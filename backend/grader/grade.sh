#!/usr/bin/env bash
set -euo pipefail

source_file=${1:?usage: grade /input/bits.c}
test -r "$source_file"

mkdir -p /work/lab
cp -a /opt/memento/src/. /work/lab/
install -m 0644 "$source_file" /work/lab/bits.c
cd /work/lab

exec timeout --signal=KILL 45s perl ./driver.pl -f bits.c -A
