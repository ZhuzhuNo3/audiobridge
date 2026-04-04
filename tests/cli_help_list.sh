#!/bin/sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/audiobridge"
make -C "$ROOT" -s || exit 1
"$BIN" >/dev/null 2>/tmp/ab0.err
test "$?" -eq 0 || exit 1
grep -q "audiobridge" /tmp/ab0.err || exit 1
"$BIN" --list-all 2>/tmp/ab1.err || exit 1
grep -q "^# audiobridge device list" /tmp/ab1.err || exit 1
grep -q "^INPUT$" /tmp/ab1.err || exit 1
grep -q "^OUTPUT$" /tmp/ab1.err || exit 1
"$BIN" --list-all -i 1 2>/tmp/e.txt
ec=$?
test "$ec" -eq 2 || exit 1
"$BIN" --list-all -q 2>/tmp/ab2.err || exit 1
cmp -s /tmp/ab1.err /tmp/ab2.err || exit 1
"$BIN" -h -f 2>/tmp/e_help_combo.err
ec=$?
test "$ec" -eq 2 || exit 1
exit 0
