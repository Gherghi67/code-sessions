#!/usr/bin/env bash
# ABOUTME: Tests for cs -update subcommand (manual update, check, force)
# ABOUTME: Validates help text, subcommand routing, and that auto-update is not offered

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"


# ============================================================================
# Help text tests
# ============================================================================

test_help_shows_update_command() {
    local output
    output=$("$CS_BIN" -help 2>&1)

    assert_output_contains "$output" "-update" \
        "Help should show -update command" || return 1
}

test_help_shows_check_and_force() {
    local output
    output=$("$CS_BIN" -help 2>&1)

    assert_output_contains "$output" "\-\-check" \
        "Help should show --check flag" || return 1
    assert_output_contains "$output" "\-\-force" \
        "Help should show --force flag" || return 1
}

test_help_does_not_show_auto_update() {
    local output
    output=$("$CS_BIN" -help 2>&1)

    assert_output_not_contains "$output" "CS_AUTO_UPDATE" \
        "Help should not reference CS_AUTO_UPDATE env var" || return 1
    local update_section
    update_section=$(echo "$output" | sed -n '/-update/,/^  -/p' | head -5)
    if grep -q -- "auto" <<< "$update_section"; then
        echo "  FAIL: Update section should not mention auto"
        return 1
    fi
}

# ============================================================================
# Subcommand routing tests
# ============================================================================

test_update_unknown_arg_errors() {
    local output
    if output=$("$CS_BIN" -update bogus 2>&1); then
        echo "  FAIL: Should have failed for unknown argument"
        return 1
    fi

    assert_output_contains "$output" "Unknown option" \
        "Should show unknown option error" || return 1
}

test_update_auto_is_unknown() {
    local output
    if output=$("$CS_BIN" -update auto 2>&1); then
        echo "  FAIL: 'cs -update auto' should fail (feature removed)"
        return 1
    fi

    assert_output_contains "$output" "Unknown option" \
        "auto should be treated as unknown option" || return 1
}

# ============================================================================
# Checksum verification tests
# ============================================================================

test_verify_checksum_present_in_source() {
    if ! grep -q 'verify_checksum()' "$CS_BIN"; then
        echo "  FAIL: bin/cs should define verify_checksum function"
        return 1
    fi
}

test_verify_checksum_catches_mismatch() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "hello world" > "$tmpdir/test.txt"
    echo "0000000000000000000000000000000000000000000000000000000000000000  test.txt" > "$tmpdir/test.txt.sha256"

    # source from a temp file: bash 3.2 (macOS stock) does not reliably define a
    # function via `source <(...)` process substitution.
    cp "$SCRIPT_DIR/../lib/20-update.sh" "$tmpdir/_vc.sh"
    if ( source "$tmpdir/_vc.sh"; verify_checksum "$tmpdir/test.txt" "$tmpdir/test.txt.sha256" ); then
        rm -rf "$tmpdir"
        echo "  FAIL: verify_checksum should reject mismatched checksum"
        return 1
    fi

    rm -rf "$tmpdir"
}

test_verify_checksum_accepts_match() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "hello world" > "$tmpdir/test.txt"

    if command -v sha256sum &>/dev/null; then
        sha256sum "$tmpdir/test.txt" > "$tmpdir/test.txt.sha256"
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$tmpdir/test.txt" > "$tmpdir/test.txt.sha256"
    else
        rm -rf "$tmpdir"
        echo "  SKIP: no sha256sum or shasum available"
        return 77
    fi

    awk '{print $1 "  test.txt"}' "$tmpdir/test.txt.sha256" > "$tmpdir/manifest"
    mv "$tmpdir/manifest" "$tmpdir/test.txt.sha256"
    cp "$SCRIPT_DIR/../lib/20-update.sh" "$tmpdir/_vc.sh"
    if ! ( source "$tmpdir/_vc.sh"; verify_checksum "$tmpdir/test.txt" "$tmpdir/test.txt.sha256" ); then
        rm -rf "$tmpdir"
        echo "  FAIL: verify_checksum should accept matching checksum"
        return 1
    fi

    rm -rf "$tmpdir"
}

# ============================================================================
# Release-notes pure functions (sourced from the fragment, no network)
# ============================================================================

_source_update_fragment() {
    YELLOW="" GREEN="" BOLD="" DIM="" NC="" COMMENT="" GOLD=""
    VERSION="0.0.0"
    RELEASES_BASE="https://github.com/hex/claude-sessions/releases"
    CHANGELOG_RAW_URL="test://unused"
    source "$SCRIPT_DIR/../lib/20-update.sh"
}

_write_fixture_changelog() {
    cat > "$1" << 'EOF'
# Changelog

Intro prose with a [link](https://example.com).

<!-- authoring note -->

## 2026.99.3

One fix: the statusline is readable on light terminals.

### Fixes

- **Statusline: readable.** The `chiptext` token was **wrong** in [two places](https://example.com/x).

## 2026.99.2

One change: the locked-session menu is single-keypress.

### Changed

- **Menu: keypress.** Cancel stays the default, so a stray key never force-launches.

## 2026.99.1

One fix: the picker no longer feels laggy.

### Fixes

- **Picker: fast.** Drains the whole input queue before repainting.

## 2026.99.0

Old release that must never be emitted.
EOF
}

_write_fixture_changelog_oldstyle() {
    cat > "$1" << 'EOF'
# Changelog

## 2026.99.7

### Fixes

- **Bullet-first: no summary line.** Body text.

## 2026.99.6

- **Hard-wrapped bullet.** This bullet line is
  wrapped across two source lines by hand.

## 2026.99.5

One fix: normal section for contrast.

## 2026.99.4

Old release that must never be emitted.
EOF
}

test_span_extracts_versions_above_installed() {
    _source_update_fragment
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" out
    _write_fixture_changelog "$fix"
    out=$(changelog_span "$fix" "2026.99.0") || return 1
    assert_output_contains "$out" "## 2026.99.3" "newest section present" || return 1
    assert_output_contains "$out" "## 2026.99.2" "middle section present" || return 1
    assert_output_contains "$out" "## 2026.99.1" "oldest pending section present" || return 1
    assert_output_not_contains "$out" "2026.99.0" "installed version's section excluded" || return 1
    assert_output_not_contains "$out" "Intro prose" "preamble excluded" || return 1
}

test_span_empty_when_up_to_date() {
    _source_update_fragment
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" out
    _write_fixture_changelog "$fix"
    out=$(changelog_span "$fix" "2026.99.3") || return 1
    assert_eq "" "$out" "no sections when installed == newest" || return 1
}

test_summaries_cap_and_collapse() {
    _source_update_fragment
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" out
    _write_fixture_changelog "$fix"
    out=$(changelog_summaries "$fix" "2026.99.0" 2) || return 1
    assert_eq "3" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "two summaries plus collapse line" || return 1
    assert_output_contains "$out" "2026.99.3	One fix: the statusline is readable on light terminals." \
        "summary is the first prose line, tab-separated" || return 1
    assert_output_contains "$out" "+	… and 1 earlier versions" "collapse line counts the overflow" || return 1
    out=$(changelog_summaries "$fix" "2026.99.0" 5) || return 1
    assert_eq "3" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "three summaries, no collapse under the cap" || return 1
    assert_output_not_contains "$out" "earlier versions" "no collapse line when uncapped" || return 1
}

test_render_strips_markdown_and_joins_summary() {
    _source_update_fragment
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" out
    _write_fixture_changelog "$fix"
    out=$(changelog_span "$fix" "2026.99.0" | render_changelog) || return 1
    assert_output_contains "$out" "2026.99.3 One fix: the statusline is readable on light terminals." \
        "version and summary share a line" || return 1
    assert_output_contains "$out" "────" "dim rule follows the version heading" || return 1
    assert_output_contains "$out" "Statusline: readable." "bullet title survives" || return 1
    assert_output_contains "$out" "two places" "link renders as its text" || return 1
    GOLD="[G]"
    out=$(changelog_span "$fix" "2026.99.0" | render_changelog) || { GOLD=""; return 1; }
    GOLD=""
    assert_output_contains "$out" '\[G\]chiptext' "code spans in bullet bodies get the gold tint" || return 1
    assert_output_not_contains "$out" "##" "no literal heading markers" || return 1
    assert_output_not_contains "$out" '\*\*' "no literal bold markers" || return 1
    if grep -q '`' <<< "$out"; then
        echo "  FAIL: no literal backticks in rendered output"
        return 1
    fi
    if grep -q "example.com/x" <<< "$out"; then
        echo "  FAIL: link targets must not render"
        return 1
    fi
}

test_render_emits_escape_bytes_not_literal_backslash() {
    _source_update_fragment
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" out expected_esc
    _write_fixture_changelog "$fix"
    GOLD='\033[33m'
    expected_esc=$(printf '%b' "$GOLD")
    out=$(changelog_span "$fix" "2026.99.0" | render_changelog) || { GOLD=""; return 1; }
    GOLD=""
    if grep -q -- '\\033' <<< "$out"; then
        echo "  FAIL: color codes must be emitted as escape bytes, not literal backslash-033 text"
        return 1
    fi
    # BSD sed's replacement-string parser silently drops a literal backslash
    # before a digit (see 's/x/[\0]/' on a match), so the check above passes
    # vacuously on this platform even when the sed splice never expands the
    # escape: the leading backslash is eaten and only a bare '0' leaks into
    # the text. Assert byte-for-byte that the expanded escape sequence itself
    # (not a mangled remnant of it) wraps the code span.
    if ! grep -qF -- "${expected_esc}chiptext" <<< "$out"; then
        echo "  FAIL: code span must be wrapped in the expanded escape byte sequence"
        return 1
    fi
}

test_render_flushes_headers_for_bullet_first_sections() {
    _source_update_fragment
    local fix="$TEST_TMPDIR/CHANGELOG-oldstyle.md" out
    _write_fixture_changelog_oldstyle "$fix"
    out=$(changelog_span "$fix" "2026.99.4" | render_changelog) || return 1
    assert_output_contains "$out" "2026.99.7" "bullet-first section header renders" || return 1
    assert_output_contains "$out" "2026.99.6" "hard-wrapped section header renders" || return 1
    assert_output_contains "$out" "2026.99.5 One fix: normal section for contrast." "prose summary still joins its header" || return 1
    assert_output_contains "$out" "Bullet-first: no summary line." "bullet renders under its own header" || return 1
}

test_render_width_floor_survives_tiny_terminals() {
    _source_update_fragment
    local fix="$TEST_TMPDIR/CHANGELOG-oldstyle.md" out
    _write_fixture_changelog_oldstyle "$fix"
    COLUMNS=3
    export COLUMNS
    out=$(changelog_span "$fix" "2026.99.4" | render_changelog) || { unset COLUMNS; return 1; }
    unset COLUMNS
    assert_output_contains "$out" "2026.99.7" "renderer survives tiny width" || return 1
}

# ============================================================================
# Release-notes surfaces (curl stubbed via PATH; HOME faked)
# ============================================================================

# The e2e tests fake HOME; save the real one ONCE at file scope. test_lib.sh
# does NOT save it (only test_cs_secrets.sh does, locally to that file), and
# under set -u an unbound restore would abort the whole suite.
ORIGINAL_HOME="$HOME"

# Stub curl: the version probe (-w) reports v2026.99.3; the changelog fetch
# (-o) copies the fixture, or fails when no fixture path was baked in.
_make_curl_stub() {  # stub-dir, fixture-path-or-empty
    cat > "$1/curl" << STUB
#!/usr/bin/env bash
case "\$*" in
    *" -w "*|*"-w"*)
        printf '%s' "https://github.com/hex/claude-sessions/releases/tag/v2026.99.3"
        exit 0
        ;;
esac
out=""
prev=""
for a in "\$@"; do
    if [ "\$prev" = "-o" ]; then out="\$a"; fi
    prev="\$a"
done
if [ -n "$2" ] && [ -n "\$out" ]; then
    cp "$2" "\$out"
    exit 0
fi
exit 22
STUB
    chmod +x "$1/curl"
}

test_check_shows_rendered_span() {
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" stub="$TEST_TMPDIR/stub-bin" out
    _write_fixture_changelog "$fix"
    mkdir -p "$stub"
    _make_curl_stub "$stub" "$fix"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    out=$(PATH="$stub:$PATH" "$CS_BIN" -update --check 2>&1) || { export HOME="$ORIGINAL_HOME"; return 1; }
    export HOME="$ORIGINAL_HOME"
    assert_output_contains "$out" "Update available" "check still announces" || return 1
    assert_output_contains "$out" "2026.99.3 One fix: the statusline is readable on light terminals." \
        "check renders the span" || return 1
    assert_output_contains "$out" "Menu: keypress." "older pending section included" || return 1
    assert_output_not_contains "$out" "##" "no raw markdown in check output" || return 1
}

test_check_falls_back_when_fetch_fails() {
    local stub="$TEST_TMPDIR/stub-bin" out
    mkdir -p "$stub"
    _make_curl_stub "$stub" ""
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    out=$(PATH="$stub:$PATH" "$CS_BIN" -update --check 2>&1) || { export HOME="$ORIGINAL_HOME"; return 1; }
    export HOME="$ORIGINAL_HOME"
    assert_output_contains "$out" "Update available" "check still announces" || return 1
    assert_output_contains "$out" "releases" "fallback names the releases page" || return 1
}

# The transport serves local release assets; all authentication uses real keys.
# The served release is v2026.99.3 unless CS_TEST_REMOTE_VERSION names
# another; its manifest is signed in that release's namespace.
_update_with_manifest() {  # label, installer-exit-status, optional fault
    local stub="$TEST_TMPDIR/$1-stub" home="$TEST_TMPDIR/$1-home" tmp="$TEST_TMPDIR/$1-tmp"
    local installer="$TEST_TMPDIR/$1-install.sh" digest fault="${3:-}" revoked=''
    local remote="${CS_TEST_REMOTE_VERSION:-2026.99.3}" ref="v${CS_TEST_REMOTE_VERSION:-2026.99.3}"
    mkdir -p "$stub" "$home" "$tmp"
    ssh-keygen -q -t ed25519 -N '' -C release@example.com -f "$stub/key"
    ssh-keygen -q -t ed25519 -N '' -C other@example.com -f "$stub/other"
    printf 'release namespaces="cs-release-*" %s\n' "$(cat "$stub/key.pub")" > "$stub/signers"
    : > "$stub/revoked"
    case "$fault" in
        revoked-kept|revoked-lost)
            cat "$stub/other.pub" > "$stub/revoked"
            [ "$fault" != revoked-kept ] || revoked=$(cat "$stub/other.pub")
            ;;
    esac
    [ "$fault" != wrong-ref ] || ref=main
    cat > "$installer" << INSTALLER
#!/usr/bin/env bash
# cs-update-fixture-$1-$$-$RANDOM$RANDOM
CS_DEFAULT_REF=$ref
CS_RELEASE_REVOKED='$revoked'
mkdir -p "\$HOME/.local/bin"
printf 'VERSION="$remote"\n' > "\$HOME/.local/bin/cs"
echo "fixture installer ran at \$CS_INSTALL_REF"
exit $2
INSTALLER
    case "$fault" in
        duplicate-revoked) printf "CS_RELEASE_REVOKED=''\n" >> "$installer" ;;
        executable-revoked) printf 'CS_RELEASE_REVOKED=$(touch "%s/executed")\n' "$stub" >> "$installer" ;;
    esac
    digest=$(shasum -a 256 "$installer" | awk '{print $1}')
    [ -z "${CS_TEST_BAD_DIGEST:-}" ] || digest="0000000000000000000000000000000000000000000000000000000000000000"
    printf '%s  install.sh\n' "$digest" > "$stub/SHA256SUMS"
    case "$fault" in
        missing-entry) printf '%s  other.sh\n' "$digest" > "$stub/SHA256SUMS" ;;
        duplicate-entry) printf '%s  install.sh\n' "$digest" >> "$stub/SHA256SUMS" ;;
    esac
    local key="$stub/key" namespace="cs-release-v$remote"
    [ "$fault" != wrong-key ] || key="$stub/other"
    [ "$fault" != other-tag ] || namespace=cs-release-v2026.99.2
    ssh-keygen -Y sign -f "$key" -n "$namespace" "$stub/SHA256SUMS" > "$stub/sign.log" 2>&1
    [ "$fault" != edited ] || printf '\n' >> "$stub/SHA256SUMS"
    [ "$fault" != missing-sig ] || rm "$stub/SHA256SUMS.sig"
    [ "$fault" != missing-manifest ] || rm "$stub/SHA256SUMS"
    cat > "$stub/curl" << STUB
#!/usr/bin/env bash
case "\$*" in
    *" -w "*)
        printf '%s' "https://example.com/releases/tag/v$remote"
        exit 0
        ;;
esac
out=""
prev=""
for a in "\$@"; do
    if [ "\$prev" = "-o" ]; then out="\$a"; fi
    prev="\$a"
done
case "\$*" in
    *"/v$remote/install.sh -o "*) cp "$installer" "\$out"; exit 0 ;;
    *"/v$remote/SHA256SUMS -o "*) cp "$stub/SHA256SUMS" "\$out"; exit \$? ;;
    *"/v$remote/SHA256SUMS.sig -o "*) cp "$stub/SHA256SUMS.sig" "\$out"; exit \$? ;;
esac
exit 22
STUB
    chmod +x "$stub/curl"
    local rc=0 out
    out=$(CS_RELEASE_SIGNERS_FILE="$stub/signers" CS_RELEASE_REVOKED_FILE="$stub/revoked" HOME="$home" TMPDIR="$tmp" PATH="$stub:$PATH" "$CS_BIN" -update 2>&1) || rc=$?
    assert_not_exists "$stub/executed" 'revocation data never executes' || return 1
    printf '%s' "$rc" > "$TEST_TMPDIR/update-rc"
    printf '%s\n' "$out"
}

# Prints every copy of label $1's fixture installer left in a temp dir after
# the update: under the TMPDIR the update ran with, and under the system's
# default temp dir, which BSD `mktemp -d` uses whatever TMPDIR says.
_update_leftovers() {  # label
    local token sysdir f
    token=$(sed -n 2p "$TEST_TMPDIR/$1-install.sh")
    sysdir=$(dirname "$(mktemp -u)")
    for f in "$TEST_TMPDIR/$1-tmp"/*/install.sh "$sysdir"/*/install.sh; do
        [ -f "$f" ] || continue
        if grep -qxF "$token" "$f" 2>/dev/null; then
            printf '%s\n' "$f"
        fi
    done
}

test_update_authenticates_the_installer() {
    local out
    out=$(_update_with_manifest signed 0)
    assert_eq "0" "$(cat "$TEST_TMPDIR/update-rc")" "cs -update exit status" || { echo "$out"; return 1; }
    assert_output_contains "$out" "Verified" "the checksum gate passed" || return 1
    assert_output_contains "$out" "fixture installer ran at v2026\.99\.3" "the verified installer ran, pinned to the tag" || return 1
    local fault expected
    for fault in missing-sig missing-manifest wrong-key other-tag edited missing-entry duplicate-entry wrong-ref revoked-lost duplicate-revoked executable-revoked; do
        out=$(_update_with_manifest "$fault" 0 "$fault")
        assert_eq 1 "$(cat "$TEST_TMPDIR/update-rc")" "$fault refuses the update" || { echo "$out"; return 1; }
        assert_output_not_contains "$out" "fixture installer ran" "$fault never executes installer" || return 1
        case "$fault" in
            missing-sig) expected='Error: Failed to download release manifest signature.' ;;
            missing-manifest) expected='Error: Failed to download release manifest.' ;;
            wrong-key|other-tag|edited) expected='Error: Release manifest signature verification failed. Update aborted.' ;;
            wrong-ref) expected='Error: Downloaded installer is not pinned to v2026.99.3. Update aborted.' ;;
            missing-entry|duplicate-entry) expected='Error: Checksum verification failed. Update aborted.' ;;
            revoked-lost) expected="Error: Release dropped revoked key: $(awk '{print $1, $2}' "$TEST_TMPDIR/$fault-stub/other.pub")" ;;
            *) expected='Error: Malformed CS_RELEASE_REVOKED in downloaded installer.' ;;
        esac
        assert_eq "$expected" "$(printf '%s\n' "$out" | tail -n 1)" "$fault diagnostic" || return 1
    done
    out=$(_update_with_manifest revoked-kept 0 revoked-kept)
    assert_eq 0 "$(cat "$TEST_TMPDIR/update-rc")" 'revocations carried forward permit update' || { echo "$out"; return 1; }
}

# A release older than the installed cs is refused before anything is run,
# however well it is signed: "latest" pointing at an old tag is not an update.
test_update_refuses_a_downgrade() {
    local out installed
    installed=$(grep -m1 '^VERSION=' "$CS_BIN" | cut -d'"' -f2)
    out=$(CS_TEST_REMOTE_VERSION=2000.1.1 _update_with_manifest downgrade 0)
    assert_eq 1 "$(cat "$TEST_TMPDIR/update-rc")" 'a downgrade refuses the update' || { echo "$out"; return 1; }
    assert_output_not_contains "$out" "fixture installer ran" 'the older installer never runs' || return 1
    assert_eq "Error: Release v2000.1.1 is older than the installed cs $installed. Update aborted." \
        "$(printf '%s\n' "$out" | tail -n 1)" 'downgrade diagnostic' || return 1
}

# The update's temp dir (installer, checksum, signature) is removed however the
# update ends: here the installer itself fails, after verification passed.
test_update_removes_its_temp_dir_when_the_installer_fails() {
    local out
    out=$(_update_with_manifest failinst 3)
    assert_eq "3" "$(cat "$TEST_TMPDIR/update-rc")" "cs -update passes the installer's failure on" || { echo "$out"; return 1; }
    assert_output_contains "$out" "fixture installer ran at v2026\.99\.3" "the installer was reached" || return 1
    assert_eq "" "$(_update_leftovers failinst)" "no temp copy of the installer left behind" || return 1
}

# And when it ends on a refused checksum.
test_update_removes_its_temp_dir_when_the_checksum_is_refused() {
    local out
    out=$(CS_TEST_BAD_DIGEST=1 _update_with_manifest badsum 0)
    assert_eq "1" "$(cat "$TEST_TMPDIR/update-rc")" "cs -update refuses the installer" || { echo "$out"; return 1; }
    assert_output_contains "$out" "Checksum verification failed" "the refusal is reported" || return 1
    assert_output_not_contains "$out" "fixture installer ran" "the refused installer never runs" || return 1
    assert_eq "" "$(_update_leftovers badsum)" "no temp copy of the installer left behind" || return 1
}

# A launch asks GitHub for the latest version at most once an hour: a fresh
# cache answers it whether or not it names a newer version. A stale cache asks
# again (the positive control that the stub sees the probe at all).
_launch_with_cache() {  # cache-epoch -> prints the curl calls the launch made
    local stub="$TEST_TMPDIR/stub-bin"
    mkdir -p "$stub" "$TEST_TMPDIR/home/.cache/cs"
    printf '#!/bin/sh\necho "$*" >> "%s/curl-calls"\nexit 22\n' "$TEST_TMPDIR" > "$stub/curl"
    chmod +x "$stub/curl"
    : > "$TEST_TMPDIR/curl-calls"
    printf '%s 2000.1.1\n' "$1" > "$TEST_TMPDIR/home/.cache/cs/update-check"
    HOME="$TEST_TMPDIR/home" PATH="$stub:$PATH" CS_NO_UPDATE_CHECK='' \
        "$CS_BIN" "cache-session-$1" < /dev/null > /dev/null 2>&1 || true
    cat "$TEST_TMPDIR/curl-calls"
}

test_launch_with_a_fresh_cache_and_no_update_skips_the_network() {
    assert_eq "" "$(_launch_with_cache "$(date +%s)")" "a fresh cache saying no update asks nothing" || return 1
}

test_launch_with_a_stale_cache_asks_again() {
    assert_output_contains "$(_launch_with_cache 1000)" "/latest" "a stale cache asks for the latest version" || return 1
}

# The cache's first word is read as a time and reaches arithmetic, which bash
# evaluates recursively: an array subscript there runs a command substitution.
# A token that is not all digits is no cache at all, so the launch asks again.
# The launch is inlined because _launch_with_cache names the session after the
# epoch, and this token is no valid session name.
test_launch_with_a_non_numeric_cache_time_runs_nothing_and_asks_again() {
    local stub="$TEST_TMPDIR/stub-bin"
    mkdir -p "$stub" "$TEST_TMPDIR/home/.cache/cs"
    printf '#!/bin/sh\necho "$*" >> "%s/curl-calls"\nexit 22\n' "$TEST_TMPDIR" > "$stub/curl"
    chmod +x "$stub/curl"
    : > "$TEST_TMPDIR/curl-calls"
    printf '%s 2000.1.1\n' 'HOME[$(touch${IFS}'"$TEST_TMPDIR"'/sentinel)]' > "$TEST_TMPDIR/home/.cache/cs/update-check"
    HOME="$TEST_TMPDIR/home" PATH="$stub:$PATH" CS_NO_UPDATE_CHECK='' \
        "$CS_BIN" "cache-session-malformed" < /dev/null > /dev/null 2>&1 || true
    assert_not_exists "$TEST_TMPDIR/sentinel" "the cache time is never evaluated as code" || return 1
    assert_output_contains "$(cat "$TEST_TMPDIR/curl-calls")" "/latest" "a malformed cache time reads as stale" || return 1
}

test_launch_banner_shows_notes_card() {
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME/.cache/cs"
    printf '%s 2026.99.3\n' "$(date +%s)" > "$HOME/.cache/cs/update-check"
    printf '2026.99.3\tOne fix: the statusline is readable.\n2026.99.2\tOne change: the menu is single-keypress.\n+\t… and 1 earlier versions\n' \
        > "$HOME/.cache/cs/update-notes-2026.99.3"
    : > "$HOME/.cache/cs/update-notes-full-2026.99.3"
    unset CS_NO_UPDATE_CHECK
    local out
    # CS_NO_FUNCTION_HOOKS=1 withholds the cs-update mod, which is the
    # fallback path this test covers: the card only draws when the mod will
    # not run this launch.
    out=$(CS_NO_FUNCTION_HOOKS=1 "$CS_BIN" "notes-card-session" < /dev/null 2>&1) || {
        export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"
        return 1
    }
    export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"
    # The row names the new version and how to get it. Pinned as two facts
    # rather than one literal sentence: the wording is design, the pair is the
    # contract.
    assert_output_contains "$out" "2026.99.3 available" "the row announces the version" || return 1
    assert_output_contains "$out" "cs -update" "and names the command that gets it" || return 1
    assert_output_contains "$out" "2026.99.3" "card shows the newest version" || return 1
    assert_output_contains "$out" "One fix: the statusline is readable." "card shows its summary" || return 1
    assert_output_contains "$out" "and 1 earlier versions" "card shows the collapse line" || return 1
}

test_launch_banner_quiet_on_empty_notes_cache() {
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME/.cache/cs"
    printf '%s 2026.99.3\n' "$(date +%s)" > "$HOME/.cache/cs/update-check"
    : > "$HOME/.cache/cs/update-notes-2026.99.3"
    : > "$HOME/.cache/cs/update-notes-full-2026.99.3"
    unset CS_NO_UPDATE_CHECK
    local out
    # CS_NO_FUNCTION_HOOKS=1 withholds the cs-update mod, which is the
    # fallback path this test covers: the card only draws when the mod will
    # not run this launch.
    out=$(CS_NO_FUNCTION_HOOKS=1 "$CS_BIN" "notes-quiet-session" < /dev/null 2>&1) || {
        export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"
        return 1
    }
    export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"
    assert_output_contains "$out" "2026.99.3 available" "the row is still shown" || return 1
    assert_output_contains "$out" "cs -update" "and still names the command" || return 1
    assert_output_not_contains "$out" "One fix: the statusline is readable." \
        "no card rows from the tombstone (the populated-cache test proves this string DOES render when present)" || return 1
    assert_output_not_contains "$out" "earlier versions" "no collapse line from the tombstone" || return 1
}

test_launch_banner_card_yields_to_the_mod() {
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME/.cache/cs"
    printf '%s 2026.99.3\n' "$(date +%s)" > "$HOME/.cache/cs/update-check"
    printf '2026.99.3\tOne fix: the statusline is readable.\n2026.99.2\tOne change: the menu is single-keypress.\n+\t… and 1 earlier versions\n' \
        > "$HOME/.cache/cs/update-notes-2026.99.3"
    : > "$HOME/.cache/cs/update-notes-full-2026.99.3"
    unset CS_NO_UPDATE_CHECK
    local out
    # Same seed as test_launch_banner_shows_notes_card, but launched with the
    # mod eligible to run: no CS_NO_FUNCTION_HOOKS and CLAUDE_CODE_ENABLE_FUNCTION_HOOKS
    # unset going in, so the launch's own export turns the flag on. The
    # yellow row still announces the version; the card's summary line must
    # not repeat it, since the mod draws the full notes inside the session.
    out=$(env -u CLAUDE_CODE_ENABLE_FUNCTION_HOOKS -u CS_NO_FUNCTION_HOOKS "$CS_BIN" "notes-card-yields-session" < /dev/null 2>&1) || {
        export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"
        return 1
    }
    export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"
    assert_output_contains "$out" "2026.99.3 available" "the row still announces the version" || return 1
    assert_output_not_contains "$out" "One fix: the statusline is readable." \
        "no card summary when the mod will draw the notes (the populated-card test proves this string renders when the card is drawn)" || return 1
}

# The cs-update mod reads the launch's verdict from the environment: which
# version is pending, exported only when one is, so the mod stays silent by
# absence. Where cs lives is exported on every launch as CS_BIN, since
# A torn cache line (a fresh time, no version) answers nothing: the launch asks
# GitHub and records the answer, rather than stay silent for the hour.
test_launch_with_a_time_only_cache_asks_again() {
    local stub="$TEST_TMPDIR/stub-bin"
    mkdir -p "$stub" "$TEST_TMPDIR/home/.cache/cs"
    printf '#!/bin/sh\necho "$*" >> "%s/curl-calls"\ncase "$*" in *url_effective*) printf "https://example.com/releases/tag/v2099.1.1" ;; *) exit 22 ;; esac\n' \
        "$TEST_TMPDIR" > "$stub/curl"
    chmod +x "$stub/curl"
    : > "$TEST_TMPDIR/curl-calls"
    printf '%s\n' "$(date +%s)" > "$TEST_TMPDIR/home/.cache/cs/update-check"
    HOME="$TEST_TMPDIR/home" PATH="$stub:$PATH" CS_NO_UPDATE_CHECK='' \
        "$CS_BIN" "cache-session-torn" < /dev/null > /dev/null 2>&1 || true
    assert_output_contains "$(cat "$TEST_TMPDIR/curl-calls")" "/latest" "a time-only cache reads as no cache" || return 1
    local cached_version
    read -r _ cached_version < "$TEST_TMPDIR/home/.cache/cs/update-check"
    assert_eq "2099.1.1" "$cached_version" "the answer is recorded with its version" || return 1
}

# `$.process.run` takes no shell and the claude process's PATH is not the
# launching shell's; the cs mod's /queue needs it with nothing pending.
test_launch_exports_update_verdict_to_the_mod() {
    local stub="$TEST_TMPDIR/claude-env-stub"
    cat > "$stub" << 'SCRIPT'
#!/bin/bash
echo "UPDATE_AVAILABLE=${CS_UPDATE_AVAILABLE-unset}"
echo "CS_BIN=${CS_BIN-unset}"
exit 0
SCRIPT
    chmod +x "$stub"
    local want_bin
    want_bin="$(cd "$(dirname "$CS_BIN")" && pwd -P)/cs"
    export HOME="$TEST_TMPDIR/home-export"
    mkdir -p "$HOME/.cache/cs"
    printf '%s 2026.99.3\n' "$(date +%s)" > "$HOME/.cache/cs/update-check"
    : > "$HOME/.cache/cs/update-notes-2026.99.3"
    : > "$HOME/.cache/cs/update-notes-full-2026.99.3"
    unset CS_NO_UPDATE_CHECK
    local out
    out=$(CLAUDE_CODE_BIN="$stub" "$CS_BIN" "export-verdict-session" < /dev/null 2>&1) || {
        export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"; return 1
    }
    export CS_NO_UPDATE_CHECK=1
    assert_output_contains "$out" "UPDATE_AVAILABLE=2026.99.3" "the pending version is exported" || { export HOME="$ORIGINAL_HOME"; return 1; }
    assert_output_contains "$out" "CS_BIN=$want_bin" "the absolute path of the running cs is exported" || { export HOME="$ORIGINAL_HOME"; return 1; }
    # Nothing pending exports no version, even when the launching shell
    # carries a parent launch's verdict (a nested cs): it is cleared before
    # the conditional export. CS_BIN is still exported, and an inherited one
    # is overwritten with this launch's own path. CS_NO_UPDATE_CHECK=1 is the
    # no-network way to have nothing pending: check_update_notify returns
    # before it reads the cache or asks GitHub, so UPDATE_AVAILABLE stays empty.
    export CS_NO_UPDATE_CHECK=1
    out=$(CS_UPDATE_AVAILABLE=2026.1.1 CS_BIN=/stale/cs CLAUDE_CODE_BIN="$stub" "$CS_BIN" "export-current-session" < /dev/null 2>&1) || {
        export HOME="$ORIGINAL_HOME"; return 1
    }
    export HOME="$ORIGINAL_HOME"
    assert_output_contains "$out" "UPDATE_AVAILABLE=unset" "an inherited version is cleared when nothing is pending" || return 1
    assert_output_contains "$out" "CS_BIN=$want_bin" "an inherited path is replaced by this launch's own" || return 1
}

# Both notes caches are written through a uniquely named temp file, so a
# leftover at the fixed name <cache>.tmp that cannot be written (here: a
# read-only file) does not cost the launch its notes.
test_notify_writes_notes_cache_past_stale_tmp_files() {
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" stub="$TEST_TMPDIR/stub-bin"
    _write_fixture_changelog "$fix"
    mkdir -p "$stub"
    _make_curl_stub "$stub" "$fix"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME/.cache/cs"
    local cache="$HOME/.cache/cs/update-notes-2026.99.3" full="$HOME/.cache/cs/update-notes-full-2026.99.3"
    _deny_file_write "$cache.tmp" || { export HOME="$ORIGINAL_HOME"; return 77; }
    _deny_file_write "$full.tmp" || { export HOME="$ORIGINAL_HOME"; return 77; }
    unset CS_NO_UPDATE_CHECK
    PATH="$stub:$PATH" "$CS_BIN" "notes-stale-session" < /dev/null > /dev/null 2>&1 || true
    export CS_NO_UPDATE_CHECK=1
    assert_file_contains "$cache" "2026.99.3	One fix: the statusline is readable on light terminals." \
        "the notes cache is written past a stale .tmp" || { export HOME="$ORIGINAL_HOME"; return 1; }
    assert_file_contains "$full" "^## 2026\.99\.3$" \
        "the full-notes cache is written past a stale .tmp" || { export HOME="$ORIGINAL_HOME"; return 1; }
    export HOME="$ORIGINAL_HOME"
}

test_notify_writes_notes_cache() {
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" stub="$TEST_TMPDIR/stub-bin"
    _write_fixture_changelog "$fix"
    mkdir -p "$stub"
    _make_curl_stub "$stub" "$fix"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME/.cache/cs"
    printf 'stale\n' > "$HOME/.cache/cs/update-notes-2026.90.0"
    printf 'stale\n' > "$HOME/.cache/cs/update-notes-full-2026.90.0"
    unset CS_NO_UPDATE_CHECK
    PATH="$stub:$PATH" "$CS_BIN" "notes-notify-session" < /dev/null > /dev/null 2>&1 || {
        export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"
        return 1
    }
    export CS_NO_UPDATE_CHECK=1
    local cache="$HOME/.cache/cs/update-notes-2026.99.3"
    assert_file_exists "$cache" "notify writes the notes cache" || { export HOME="$ORIGINAL_HOME"; return 1; }
    assert_file_contains "$cache" "2026.99.3	One fix: the statusline is readable on light terminals." \
        "cache holds tab-separated summaries" || { export HOME="$ORIGINAL_HOME"; return 1; }
    assert_not_exists "$HOME/.cache/cs/update-notes-2026.90.0" "stale notes caches pruned" || { export HOME="$ORIGINAL_HOME"; return 1; }
    assert_not_exists "$HOME/.cache/cs/update-notes-full-2026.90.0" "stale full caches pruned" || { export HOME="$ORIGINAL_HOME"; return 1; }
    local full="$HOME/.cache/cs/update-notes-full-2026.99.3"
    assert_file_exists "$full" "notify writes the full-notes cache" || { export HOME="$ORIGINAL_HOME"; return 1; }
    assert_file_contains "$full" "^## 2026\.99\.3$" "the span starts at the newest version" || { export HOME="$ORIGINAL_HOME"; return 1; }
    assert_file_contains "$full" "Statusline: readable" "and keeps the bullets" || { export HOME="$ORIGINAL_HOME"; return 1; }
    # The fixture's every version is above the installed one (2026.99.x), so
    # the span's stop-at-installed rule is not testable here; it is pinned by
    # test_span_extracts_versions_above_installed on the function itself.
    export HOME="$ORIGINAL_HOME"
}

# A failed fetch writes an empty full file, as it writes an empty summaries
# file: the next launch must not retry the network, and the mod must be able
# to tell "no notes" from "no file".
test_notify_writes_empty_full_cache_when_fetch_fails() {
    local stub="$TEST_TMPDIR/stub-bin-nofetch"
    mkdir -p "$stub"
    _make_curl_stub "$stub" ""
    export HOME="$TEST_TMPDIR/home-nofetch"
    mkdir -p "$HOME/.cache/cs"
    unset CS_NO_UPDATE_CHECK
    PATH="$stub:$PATH" "$CS_BIN" "notes-nofetch-session" < /dev/null > /dev/null 2>&1 || {
        export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"
        return 1
    }
    export CS_NO_UPDATE_CHECK=1
    local full="$HOME/.cache/cs/update-notes-full-2026.99.3"
    [ -f "$full" ] || { echo "  FAIL: no full-notes tombstone written"; export HOME="$ORIGINAL_HOME"; return 1; }
    [ ! -s "$full" ] || { echo "  FAIL: the tombstone is not empty"; export HOME="$ORIGINAL_HOME"; return 1; }
    export HOME="$ORIGINAL_HOME"
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs update tests"
echo "==============="
echo ""

run_test test_help_shows_update_command
run_test test_help_shows_check_and_force
run_test test_help_does_not_show_auto_update
run_test test_update_unknown_arg_errors
run_test test_update_auto_is_unknown
run_test test_verify_checksum_present_in_source
run_test test_verify_checksum_catches_mismatch
run_test test_verify_checksum_accepts_match
run_test test_span_extracts_versions_above_installed
run_test test_span_empty_when_up_to_date
run_test test_summaries_cap_and_collapse
run_test test_render_strips_markdown_and_joins_summary
run_test test_render_emits_escape_bytes_not_literal_backslash
run_test test_render_flushes_headers_for_bullet_first_sections
run_test test_render_width_floor_survives_tiny_terminals
run_test test_check_shows_rendered_span
run_test test_check_falls_back_when_fetch_fails
run_test test_update_authenticates_the_installer
run_test test_update_refuses_a_downgrade
run_test test_update_removes_its_temp_dir_when_the_installer_fails
run_test test_update_removes_its_temp_dir_when_the_checksum_is_refused
run_test test_launch_with_a_fresh_cache_and_no_update_skips_the_network
run_test test_launch_with_a_stale_cache_asks_again
run_test test_launch_with_a_non_numeric_cache_time_runs_nothing_and_asks_again
run_test test_launch_with_a_time_only_cache_asks_again
run_test test_launch_banner_shows_notes_card
run_test test_launch_banner_quiet_on_empty_notes_cache
run_test test_launch_banner_card_yields_to_the_mod
run_test test_launch_exports_update_verdict_to_the_mod
run_test test_notify_writes_notes_cache
run_test test_notify_writes_notes_cache_past_stale_tmp_files
run_test test_notify_writes_empty_full_cache_when_fetch_fails

report_results
