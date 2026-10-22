#!/usr/bin/env bash
# ABOUTME: Verifies release manifests against real SSH signatures and revocations.
# ABOUTME: Exercises the update and installer copies of the release trust gate.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

test_manifest_authentication() {
    local source_file out rc
    ssh-keygen -q -t ed25519 -N '' -C 'release@example.com' -f "$TEST_TMPDIR/key"
    ssh-keygen -q -t ed25519 -N '' -C 'other@example.com' -f "$TEST_TMPDIR/other"
    printf 'release namespaces="cs-release" %s\n' "$(cat "$TEST_TMPDIR/key.pub")" > "$TEST_TMPDIR/signers"
    : > "$TEST_TMPDIR/revoked"
    printf '%064d  install.sh\n' 0 > "$TEST_TMPDIR/SHA256SUMS"
    ssh-keygen -Y sign -f "$TEST_TMPDIR/key" -n cs-release "$TEST_TMPDIR/SHA256SUMS" > "$TEST_TMPDIR/sign.log" 2>&1
    cp "$TEST_TMPDIR/SHA256SUMS.sig" "$TEST_TMPDIR/good.sig"
    rm "$TEST_TMPDIR/SHA256SUMS.sig"
    ssh-keygen -Y sign -f "$TEST_TMPDIR/other" -n cs-release "$TEST_TMPDIR/SHA256SUMS" > "$TEST_TMPDIR/sign.log" 2>&1
    cp "$TEST_TMPDIR/SHA256SUMS.sig" "$TEST_TMPDIR/wrong.sig"
    mkdir "$TEST_TMPDIR/no-tools"
    for source_file in "$SCRIPT_DIR/../lib/20-update.sh" "$SCRIPT_DIR/../install.sh.in"; do
        sed -n '/^_verify_manifest() {/,/^}/p' "$source_file" > "$TEST_TMPDIR/verify.sh"
        source "$TEST_TMPDIR/verify.sh"
        export CS_RELEASE_SIGNERS_FILE="$TEST_TMPDIR/signers"
        export CS_RELEASE_REVOKED_FILE="$TEST_TMPDIR/revoked"
        out=$(_verify_manifest "$TEST_TMPDIR/SHA256SUMS" "$TEST_TMPDIR/good.sig" 2>&1) || {
            echo "  FAIL: a manifest signed by the release key must pass ($source_file): $out"
            return 1
        }
        assert_eq '' "$out" 'successful verification stays quiet' || return 1
        rc=0
        out=$(_verify_manifest "$TEST_TMPDIR/SHA256SUMS" "$TEST_TMPDIR/wrong.sig" 2>&1) || rc=$?
        assert_eq 1 "$rc" 'a different signer is refused' || return 1
        assert_eq 'Release manifest signature verification failed.' "$out" 'wrong signer diagnostic' || return 1
        printf '%064d  install.sh\n' 1 > "$TEST_TMPDIR/edited"
        rc=0
        out=$(_verify_manifest "$TEST_TMPDIR/edited" "$TEST_TMPDIR/good.sig" 2>&1) || rc=$?
        assert_eq 1 "$rc" 'editing a signed manifest is refused' || return 1
        assert_eq 'Release manifest signature verification failed.' "$out" 'edited manifest diagnostic' || return 1
        rc=0
        out=$(export PATH="$TEST_TMPDIR/no-tools"; hash -r; _verify_manifest "$TEST_TMPDIR/SHA256SUMS" "$TEST_TMPDIR/good.sig" 2>&1) || rc=$?
        assert_eq 1 "$rc" 'missing verifier is refused' || return 1
        assert_eq 'ssh-keygen is required to verify release manifests.' "$out" 'missing verifier diagnostic' || return 1
        cat "$TEST_TMPDIR/key.pub" > "$TEST_TMPDIR/revoked"
        rc=0
        out=$(_verify_manifest "$TEST_TMPDIR/SHA256SUMS" "$TEST_TMPDIR/good.sig" 2>&1) || rc=$?
        assert_eq 1 "$rc" 'a revoked allowed signer is refused' || return 1
        assert_eq 'Release manifest signature verification failed.' "$out" 'revocation diagnostic' || return 1
        : > "$TEST_TMPDIR/revoked"
        unset -f _verify_manifest
        unset CS_RELEASE_SIGNERS_FILE CS_RELEASE_REVOKED_FILE
    done
}

run_test test_manifest_authentication
report_results
