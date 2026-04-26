#!/bin/sh
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/audiobridge"
LOG_FILE="/tmp/audiobridge_recovery_lifecycle.log"

make -C "$ROOT" -s all || exit 1

"$BIN" --integration-recovery-lifecycle >/dev/null 2>"$LOG_FILE"
ec=$?
test "$ec" -eq 0 || exit 1

rg -q "trigger_source=listener_default_change state=begin" "$LOG_FILE" || exit 1
rg -q "trigger_source=listener_default_change attempt=2 delay_seconds=0.2 state=retry_wait" "$LOG_FILE" || exit 1
rg -q "trigger_source=listener_default_change state=streaming_restored attempt=3 delay_count=1" "$LOG_FILE" || exit 1
# Runtime compensation must coalesce same-flight triggers instead of spawning an extra pipeline.
rg -q "trigger_source=listener_coalesced_probe state=coalesced_inflight attempt=1 delay_count=0 failure_summary=recovery already in flight" "$LOG_FILE" || exit 1
if rg -q "trigger_source=listener_coalesced_probe state=failed" "$LOG_FILE"; then
    exit 1
fi
# Startup strict-exit semantics: when compensation was never enabled, runtime trigger reports disabled.
rg -q "trigger_source=heartbeat_inactive state=begin" "$LOG_FILE" || exit 1
rg -q "trigger_source=heartbeat_inactive state=failed attempt=1 delay_count=0 failure_summary=compensation disabled" "$LOG_FILE" || exit 1

exit 0
