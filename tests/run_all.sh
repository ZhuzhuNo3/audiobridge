#!/bin/sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
failed=0
make -C "$ROOT" -s test-unit || failed=1
if command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
    xcodebuild test -scheme audiobridge-tests >/tmp/ab_xcodebuild.out 2>/tmp/ab_xcodebuild.err || failed=1
else
    echo "[tests/run_all] skip xcodebuild test: xcodebuild unavailable or unusable in current developer directory" >&2
fi
for name in cli_help_list.sh cli_resolve_errors.sh integration/recovery_lifecycle.sh; do
    sh "$ROOT/tests/$name" || failed=1
done
exit "$failed"
