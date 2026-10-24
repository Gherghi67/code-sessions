#!/bin/bash
# ABOUTME: Stands in for cs in the oracle: `-vet-session <dir>` passes (exit 0) only for the directory named in trusted-dir beside this script.
# ABOUTME: Any other directory or verb exits 1 with one refusal line on stderr, the shape cs's own refusals have.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
trusted="$(cat "$here/trusted-dir")"
if [ "${1:-}" = "-vet-session" ] && [ -n "${2:-}" ] && [ "$2" -ef "$trusted" ]; then
    exit 0
fi
echo "cs: the oracle's stub trusts only $trusted, not ${2:-<none>}" >&2
exit 1
