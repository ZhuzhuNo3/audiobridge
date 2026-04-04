#!/bin/sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
failed=0
for name in cli_help_list.sh cli_resolve_errors.sh; do
    sh "$ROOT/tests/$name" || failed=1
done
exit "$failed"
