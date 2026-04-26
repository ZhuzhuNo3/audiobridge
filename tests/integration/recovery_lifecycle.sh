#!/bin/sh
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/audiobridge"
LOG_FILE="/tmp/audiobridge_recovery_lifecycle.log"

make -C "$ROOT" -s all || exit 1

if command -v rg >/dev/null 2>&1; then
    SEARCH_TOOL="rg"
    SEARCH_ARGS="-q"
else
    SEARCH_TOOL="grep"
    SEARCH_ARGS="-qE"
fi

search_log() {
    pattern="$1"
    if [ "$SEARCH_TOOL" = "rg" ]; then
        rg $SEARCH_ARGS "$pattern" "$LOG_FILE"
    else
        grep $SEARCH_ARGS "$pattern" "$LOG_FILE"
    fi
}

"$BIN" --integration-recovery-lifecycle >/dev/null 2>"$LOG_FILE"
ec=$?
test "$ec" -eq 0 || exit 1

search_log "trigger_source=listener_default_change state=begin" || exit 1
search_log "trigger_source=listener_default_change attempt=2 delay_seconds=0.2 state=retry_wait" || exit 1
search_log "trigger_source=listener_default_change state=streaming_restored attempt=3 delay_count=1" || exit 1
# Runtime compensation must coalesce same-flight triggers instead of spawning an extra pipeline.
search_log "trigger_source=listener_coalesced_probe state=coalesced_inflight attempt=1 delay_count=0 failure_summary=recovery already in flight" || exit 1
if search_log "trigger_source=listener_coalesced_probe state=failed"; then
    exit 1
fi
# Startup strict-exit semantics: when compensation was never enabled, runtime trigger reports disabled.
search_log "trigger_source=heartbeat_inactive state=begin" || exit 1
search_log "trigger_source=heartbeat_inactive state=failed attempt=1 delay_count=0 failure_summary=compensation disabled" || exit 1

exit 0
