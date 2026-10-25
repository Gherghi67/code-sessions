#!/usr/bin/env bash
# ABOUTME: Builds each cs mod's design-lab bundle: docs/surfaces/<mod>.entry.ts into docs/surfaces/<mod>.js, one IIFE per mod.
# ABOUTME: Usage: docs/surfaces/build.sh [out-dir]; BUN names the bun binary, which must be the version CI pins.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
mkdir -p "${1:-$here}"
out="$(cd "${1:-$here}" && pwd)"
bun="${BUN:-bun}"

# Two bun releases print different bundles from one source, so the committed
# bundles are built with the release CI installs, and CI's rebuild of them in
# tests/test_lab_surfaces.sh matches byte for byte.
pin="$(sed -n 's/^ *bun-version: *//p' "$repo/.github/workflows/test.yml")"
[ -n "$pin" ] || { echo "build.sh: .github/workflows/test.yml names no bun-version" >&2; exit 2; }
have="$("$bun" --version)"
if [ "$have" != "$pin" ]; then
    echo "build.sh: $bun is bun $have; the bundles are built with bun $pin, the release CI pins in .github/workflows/test.yml. Set BUN to a bun $pin." >&2
    exit 2
fi

# Paths in the bundles' comments are relative to the repo root, so the build
# runs there and its output does not depend on where it is written.
cd "$repo"
built=0
for entry in docs/surfaces/*.entry.ts; do
    [ -e "$entry" ] || continue
    "$bun" build "$entry" --format iife --target browser --external claude-code \
        --jsx-runtime classic --jsx-factory h --jsx-fragment Fragment \
        --outfile "$out/$(basename "$entry" .entry.ts).js" >/dev/null
    built=$((built + 1))
done
[ "$built" -gt 0 ] || { echo "build.sh: no docs/surfaces/*.entry.ts to build" >&2; exit 1; }
