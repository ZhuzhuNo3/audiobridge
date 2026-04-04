#!/bin/sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/audiobridge"
make -C "$ROOT" -s || exit 1
"$BIN" -i - -o - 2>/tmp/e.txt
ec=$?
test "$ec" -eq 1 || exit 1
"$BIN" -o - -r 0 2>/tmp/e_rate0.txt
ec=$?
test "$ec" -eq 1 || exit 1
"$BIN" -o - -r -5 2>/tmp/e_rateneg.txt
ec=$?
test "$ec" -eq 1 || exit 1
"$BIN" -o - -r abc 2>/tmp/e_rateabc.txt
ec=$?
test "$ec" -eq 1 || exit 1
"$BIN" -o 1 -r 48000 2>/tmp/e_rate_no_stdout.txt
ec=$?
test "$ec" -eq 1 || exit 1
"$BIN" --list-all -r 48000 2>/tmp/e_list_rate.txt
ec=$?
test "$ec" -eq 2 || exit 1
exit 0
