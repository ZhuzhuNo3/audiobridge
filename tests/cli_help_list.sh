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
"$BIN" -h 2>/tmp/ab_help.err || exit 1
grep -q "  -d " /tmp/ab_help.err || exit 1
grep -qi "overrid" /tmp/ab_help.err || exit 1
"$BIN" --diag 2>/tmp/e_long_diag.err
ec=$?
test "$ec" -eq 2 || exit 1
# -d with -q: quiet overrides -d; no runtime logs.
"$BIN" -d -q -f >/dev/null 2>/tmp/ab_dq.err &
pid=$!
sleep 1.2
kill -TERM "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
if grep -qE ' (DEBUG|INFO|WARN|ERROR) ' /tmp/ab_dq.err; then
  exit 1
fi
if grep -q '\[audiobridge\]' /tmp/ab_dq.err; then
  exit 1
fi
if grep -q 'diag:' /tmp/ab_dq.err; then
  exit 1
fi
# -d without -q: DEBUG cli_flags event appears in unified format.
"$BIN" -d -f >/dev/null 2>/tmp/ab_d.err &
pid=$!
sleep 1.2
kill -TERM "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
grep -qE ' DEBUG  .*reason=cli_flags' /tmp/ab_d.err || exit 1
if grep -q 'periodic_30s' /tmp/ab_d.err; then
  exit 1
fi
if grep -q '\[audiobridge\] diag:' /tmp/ab_d.err; then
  exit 1
fi
exit 0
