#!/usr/bin/env bash
# ABOUTME: Verifies release manifests against real SSH signatures and revocations.
# ABOUTME: Exercises the update and installer copies of the release trust gate.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

test_manifest_authentication() {
    local source_file out rc
    ssh-keygen -q -t ed25519 -N '' -C 'release@example.com' -f "$TEST_TMPDIR/key"
    ssh-keygen -q -t ed25519 -N '' -C 'other@example.com' -f "$TEST_TMPDIR/other"
    printf 'release namespaces="cs-release-*" %s\n' "$(cat "$TEST_TMPDIR/key.pub")" > "$TEST_TMPDIR/signers"
    : > "$TEST_TMPDIR/revoked"
    printf '%064d  install.sh\n' 0 > "$TEST_TMPDIR/SHA256SUMS"
    # A signature is bound to one release tag through its namespace: good.sig
    # is for v9.9.9, oldtag.sig for v0.0.0, plain.sig carries no tag at all.
    local sig
    for sig in good:key:cs-release-v9.9.9 wrong:other:cs-release-v9.9.9 oldtag:key:cs-release-v0.0.0 plain:key:cs-release; do
        local label="${sig%%:*}" rest="${sig#*:}"
        ssh-keygen -Y sign -f "$TEST_TMPDIR/${rest%%:*}" -n "${rest#*:}" "$TEST_TMPDIR/SHA256SUMS" > "$TEST_TMPDIR/sign.log" 2>&1
        mv "$TEST_TMPDIR/SHA256SUMS.sig" "$TEST_TMPDIR/$label.sig"
    done
    mkdir "$TEST_TMPDIR/no-tools"
    for source_file in "$SCRIPT_DIR/../lib/20-update.sh" "$SCRIPT_DIR/../install.sh.in"; do
        sed -n '/^_verify_manifest() {/,/^}/p' "$source_file" > "$TEST_TMPDIR/verify.sh"
        source "$TEST_TMPDIR/verify.sh"
        CS_RELEASE_SIGNERS=$(cat "$TEST_TMPDIR/signers")
        CS_RELEASE_REVOKED=''
        out=$(_verify_manifest "$TEST_TMPDIR/SHA256SUMS" "$TEST_TMPDIR/good.sig" 9.9.9 2>&1) || {
            echo "  FAIL: a manifest signed by the release key must pass ($source_file): $out"
            return 1
        }
        assert_eq '' "$out" 'successful verification stays quiet' || return 1
        rc=0
        out=$(_verify_manifest "$TEST_TMPDIR/SHA256SUMS" "$TEST_TMPDIR/wrong.sig" 9.9.9 2>&1) || rc=$?
        assert_eq 1 "$rc" 'a different signer is refused' || return 1
        assert_eq 'Release manifest signature verification failed.' "$out" 'wrong signer diagnostic' || return 1
        for sig in oldtag plain; do
            rc=0
            out=$(_verify_manifest "$TEST_TMPDIR/SHA256SUMS" "$TEST_TMPDIR/$sig.sig" 9.9.9 2>&1) || rc=$?
            assert_eq 1 "$rc" "a signature for another tag is refused ($sig)" || return 1
            assert_eq 'Release manifest signature verification failed.' "$out" "other-tag diagnostic ($sig)" || return 1
        done
        printf '%064d  install.sh\n' 1 > "$TEST_TMPDIR/edited"
        rc=0
        out=$(_verify_manifest "$TEST_TMPDIR/edited" "$TEST_TMPDIR/good.sig" 9.9.9 2>&1) || rc=$?
        assert_eq 1 "$rc" 'editing a signed manifest is refused' || return 1
        assert_eq 'Release manifest signature verification failed.' "$out" 'edited manifest diagnostic' || return 1
        rc=0
        out=$(export PATH="$TEST_TMPDIR/no-tools"; hash -r; _verify_manifest "$TEST_TMPDIR/SHA256SUMS" "$TEST_TMPDIR/good.sig" 9.9.9 2>&1) || rc=$?
        assert_eq 1 "$rc" 'missing verifier is refused' || return 1
        assert_eq 'ssh-keygen is required to verify release manifests.' "$out" 'missing verifier diagnostic' || return 1
        CS_RELEASE_REVOKED=$(cat "$TEST_TMPDIR/key.pub")
        rc=0
        out=$(_verify_manifest "$TEST_TMPDIR/SHA256SUMS" "$TEST_TMPDIR/good.sig" 9.9.9 2>&1) || rc=$?
        assert_eq 1 "$rc" 'a revoked allowed signer is refused' || return 1
        assert_eq 'Release manifest signature verification failed.' "$out" 'revocation diagnostic' || return 1
        # The trust lists are the embedded ones alone: nothing in the
        # environment can point the verifier at other files.
        CS_RELEASE_REVOKED=''
        CS_RELEASE_SIGNERS="release namespaces=\"cs-release-*\" $(cat "$TEST_TMPDIR/other.pub")"
        rc=0
        out=$(CS_RELEASE_SIGNERS_FILE="$TEST_TMPDIR/signers" CS_RELEASE_REVOKED_FILE="$TEST_TMPDIR/revoked" \
            _verify_manifest "$TEST_TMPDIR/SHA256SUMS" "$TEST_TMPDIR/good.sig" 9.9.9 2>&1) || rc=$?
        assert_eq 1 "$rc" 'the environment cannot replace the embedded trust lists' || return 1
        unset -f _verify_manifest
        unset CS_RELEASE_SIGNERS CS_RELEASE_REVOKED
    done
}

test_ci_release_manifest() {
    local workflow="$SCRIPT_DIR/../.github/workflows/release.yml" step
    mkdir "$TEST_TMPDIR/assets"
    printf 'installer\n' > "$TEST_TMPDIR/assets/install.sh"
    printf 'linux\n' > "$TEST_TMPDIR/assets/cs-tui-linux-amd64"
    printf 'darwin\n' > "$TEST_TMPDIR/assets/cs-tui-darwin-arm64"
    for step in 'Generate manifest' 'Generate checksums'; do
        awk -v step="$step" '
            /^      - / { selected=($0 == "      - name: " step); body=0 }
            selected && /^        run: \|/ { body=1; next }
            body && /^          / { print substr($0, 11) }
        ' "$workflow" > "$TEST_TMPDIR/step.sh"
        [ -s "$TEST_TMPDIR/step.sh" ] || { echo "  FAIL: release workflow must $step"; return 1; }
        (
            cd "$TEST_TMPDIR/assets" || exit 1
            if ! command -v sha256sum >/dev/null 2>&1; then
                sha256sum() { shasum -a 256 "$@"; }
                export -f sha256sum
            fi
            bash -e "$TEST_TMPDIR/step.sh"
        ) || return 1
    done
    local names
    names=$(awk '{print $2}' "$TEST_TMPDIR/assets/SHA256SUMS")
    assert_eq $'install.sh\ncs-tui-darwin-arm64\ncs-tui-linux-amd64' "$names" 'manifest names installer first, then sorted binaries' || return 1
    (cd "$TEST_TMPDIR/assets" && shasum -a 256 -c SHA256SUMS > "$TEST_TMPDIR/check.log") || return 1
    for step in install.sh cs-tui-darwin-arm64 cs-tui-linux-amd64; do
        (cd "$TEST_TMPDIR/assets" && shasum -a 256 -c "$step.sha256" > "$TEST_TMPDIR/check.log") || return 1
    done
    if grep -Eq 'minisign|MINISIGN_KEY|SHA256SUMS.sig' "$workflow"; then
        echo '  FAIL: CI must not hold a signing key or publish signatures'
        return 1
    fi
    assert_file_contains "$workflow" '^            SHA256SUMS$' 'the manifest is a release asset' || return 1
}

test_release_verification_documented() {
    local docs="$SCRIPT_DIR/../docs"
    local file
    for file in "$docs/configuration.md" "$SCRIPT_DIR/../lib/20-update.sh" "$SCRIPT_DIR/../install.sh.in"; do
        if grep -q 'CS_RELEASE_SIGNERS_FILE\|CS_RELEASE_REVOKED_FILE' "$file"; then
            echo "  FAIL: no environment seam replaces the embedded trust lists ($file)"
            return 1
        fi
    done
    assert_file_contains "$docs/configuration.md" 'ssh-keygen -Y verify' 'configuration must name the required verifier' || return 1
    assert_file_contains "$docs/commands.md" 'SHA256SUMS' 'update documentation must name the authenticated manifest' || return 1
    assert_file_contains "$SCRIPT_DIR/../README.md" 'ssh-keygen' 'README must name the release verifier requirement' || return 1
    local features
    features=$(awk '/^## 2026.10.10$/ {release=1; next} release && /^## / {exit} release && /^### Features$/ {features=1; next} features && /^### / {exit} features {print}' "$SCRIPT_DIR/../CHANGELOG.md")
    assert_output_contains "$features" 'SSH.*minisign' 'release feature must describe SSH authentication and minisign removal' || return 1
}

run_test test_manifest_authentication
run_test test_ci_release_manifest
run_test test_release_verification_documented
report_results
