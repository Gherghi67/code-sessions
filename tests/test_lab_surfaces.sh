#!/usr/bin/env bash
# ABOUTME: Tests for the design lab's mod bundles under docs/surfaces: each committed bundle is what a rebuild prints, a plain script, and its fixtures typecheck.
# ABOUTME: A change to a mod's draw code without a rebuild of its bundle fails here.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
REPO="$SCRIPT_DIR/.."
SURFACES="$REPO/docs/surfaces"

setup() { :; }
teardown() { :; }

# Every mod source a bundle carries, and the ones the fixtures only take
# types from. Named here so run_all.sh --changed picks this suite when one of
# them changes; a test holds the first list to what the bundles carry.
MOD_SOURCES="
mods/cs/hooks/register.tsx
mods/cs-feed/hooks/draw.tsx
mods/cs-feed/hooks/settings.ts
mods/cs-feed/hooks/transcript.ts
mods/cs-feed/hooks/words.ts
mods/cs-mermaid/hooks/layout.ts
mods/cs-mermaid/hooks/parse.ts
mods/cs-mermaid/hooks/register.tsx
mods/cs-mermaid/hooks/text.ts
mods/cs-update/hooks/register.tsx
"
# shellcheck disable=SC2034 # read by run_all.sh --changed, which greps suites for a changed path
TYPED_SOURCES="
mods/cs-feed/hooks/session.ts
mods/cs-feed/hooks/verdict.ts
"

_entries() { (cd "$SURFACES" && ls ./*.entry.ts | sed 's|^\./||; s|\.entry\.ts$||'); }

# The bundles are built by the bun release CI installs; another release prints
# other bytes from the same source, so it cannot judge them. BUN names the
# bun to build with, as for docs/surfaces/build.sh.
test_committed_bundles_are_what_a_rebuild_prints() {
    require_tool bun || return $?
    local pin have
    pin="$(sed -n 's/^ *bun-version: *//p' "$REPO/.github/workflows/test.yml")"
    have="$("${BUN:-bun}" --version)"
    if [ "$have" != "$pin" ]; then
        echo "    SKIP: bun $have here; the bundles are built with bun $pin (CI's pin). Set BUN to a bun $pin to judge them."
        SKIP_REASON="bun $have is not CI's bun $pin"
        return 77
    fi
    local out mod stale=""
    out="$(mktemp -d "${TMPDIR:-/tmp}/cs-lab-surfaces.XXXXXX")"
    BUN="${BUN:-bun}" bash "$SURFACES/build.sh" "$out" || { rm -rf "$out"; echo "  FAIL: docs/surfaces/build.sh failed"; return 1; }
    for mod in $(_entries); do
        if [ ! -f "$SURFACES/$mod.js" ]; then
            stale="$stale $mod (no committed bundle)"
        elif ! cmp -s "$out/$mod.js" "$SURFACES/$mod.js"; then
            stale="$stale $mod"
            diff -u "$SURFACES/$mod.js" "$out/$mod.js" | head -40
        fi
    done
    rm -rf "$out"
    assert_eq "" "$stale" "every committed bundle matches a rebuild (rebuild with docs/surfaces/build.sh)" || return 1
}

# A bundle with no entry is a mod the lab no longer builds.
test_every_bundle_has_its_entry() {
    local mod f orphans=""
    for f in "$SURFACES"/*.js; do
        mod="$(basename "$f" .js)"
        case "$mod" in shim|surfaces) continue ;; esac
        [ -f "$SURFACES/$mod.entry.ts" ] || orphans="$orphans $mod"
    done
    assert_eq "" "$orphans" "every bundle under docs/surfaces has its entry" || return 1
    [ -n "$(_entries)" ] || { echo "  FAIL: docs/surfaces holds no *.entry.ts"; return 1; }
}

# The lab opens from file://, where a module script is blocked: a bundle is
# one plain script that assigns its global and imports nothing at run time.
test_bundles_are_plain_scripts() {
    local mod bad=""
    for mod in $(_entries); do
        [ -f "$SURFACES/$mod.js" ] || { bad="$bad $mod (no bundle)"; continue; }
        grep -qE '^(import|export) |require\(' "$SURFACES/$mod.js" && bad="$bad $mod"
    done
    assert_eq "" "$bad" "no bundle keeps module syntax or a require" || return 1
}

test_mod_sources_named_here_are_the_ones_the_bundles_carry() {
    local carried named
    carried="$(for mod in $(_entries); do cat "$SURFACES/$mod.js"; done | sed -n 's|^  // \(mods/[^ ]*\)$|\1|p' | sort -u)"
    named="$(printf '%s\n' $MOD_SOURCES | sort -u)"
    assert_eq "$named" "$carried" "MOD_SOURCES lists exactly the mod files the bundles carry" || return 1
}

# The fixtures are typed against the mods' exported view types, so a change
# to a view's shape breaks them here. The engine writes its types into a mod
# on first use and they are gitignored; the cs mod's copy is the contract. A
# config of the test's own is written beside the fixtures and removed after.
# The mods' own files carry errors of their own (five TS2532 in mods/cs, one in mods/cs-update),
# which this check does not judge: only errors in docs/surfaces fail it.
test_fixtures_typecheck_against_the_mods() {
    require_tool npx || return $?
    local types="$REPO/mods/cs/.claude-plugin/types"
    if [ ! -f "$types/tsconfig.json" ]; then
        echo "    SKIP: no engine-written types in mods/cs/.claude-plugin/types (the engine writes them on first use)"
        SKIP_REASON="no engine-written types in mods/cs"
        return 77
    fi
    local config out
    config="$(mktemp "$SURFACES/tsconfig.check.XXXXXX")" || { echo "  FAIL: could not write the check's tsconfig"; return 1; }
    printf '{"extends": "%s", "compilerOptions": {"allowImportingTsExtensions": true}, "include": ["*.ts"]}\n' "$types/tsconfig.json" > "$config"
    out="$(cd "$SURFACES" && npx --no-install tsc -p "$(basename "$config")" 2>&1)"
    rm -f "$config"
    local ours
    ours="$(printf '%s\n' "$out" | grep 'error TS' | grep -v '^\.\./\.\./mods/' || true)"
    assert_eq "" "$ours" "tsc reports nothing outside the mods' own files" || return 1
}

run_test test_committed_bundles_are_what_a_rebuild_prints
run_test test_every_bundle_has_its_entry
run_test test_bundles_are_plain_scripts
run_test test_mod_sources_named_here_are_the_ones_the_bundles_carry
run_test test_fixtures_typecheck_against_the_mods

report_results
