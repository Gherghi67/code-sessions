#!/usr/bin/env bash
# ABOUTME: Tests for user consent prompts before auto-downloading age binaries
# ABOUTME: Validates that non-interactive contexts skip download and interactive contexts show prompt

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_SECRETS_BIN="$SCRIPT_DIR/../bin/cs-secrets"

# ============================================================================
# Release verification requires SSH signatures and manifest digests.
# ============================================================================

# Neither the minisign verifier nor its download prompt nor its public key
# remains in the shipped scripts.
test_no_release_minisign() {
    local file
    for file in "$CS_BIN" "$SCRIPT_DIR/../install.sh"; do
        if grep -Eq 'minisign|CS_SIGN_PUBKEY' "$file"; then
            echo "  FAIL: release verification must not contain minisign or CS_SIGN_PUBKEY ($file)"
            return 1
        fi
    done
}

test_has_verify_checksum() {
    assert_file_contains "$CS_BIN" 'verify_checksum' \
        "bin/cs should have verify_checksum function" || return 1
}

test_has_sha256_verification() {
    assert_file_contains "$CS_BIN" 'sha256sum\|shasum' \
        "bin/cs should use sha256sum or shasum for checksum verification" || return 1
}

# ============================================================================
# age_ensure_binary prompt tests (bin/cs-secrets)
# ============================================================================

test_age_has_consent_prompt() {
    assert_file_contains "$CS_SECRETS_BIN" 'Download age?' \
        "age_ensure_binary should prompt for consent" || return 1
}

test_age_has_noninteractive_guard() {
    assert_file_contains "$CS_SECRETS_BIN" 'Non-interactive shell' \
        "age_ensure_binary should handle non-interactive shells" || return 1
}

test_age_has_manual_install_hint() {
    assert_file_contains "$CS_SECRETS_BIN" 'brew install age' \
        "age decline should suggest manual install" || return 1
}

test_age_has_download_source_disclosure() {
    assert_file_contains "$CS_SECRETS_BIN" 'github.com/FiloSottile/age' \
        "age prompt should disclose the download source" || return 1
}

test_age_download_is_checksum_pinned() {
    assert_file_contains "$CS_SECRETS_BIN" '_age_expected_sha' \
        "age download must be verified against a pinned checksum" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs download prompt tests"
echo "========================"
echo ""

# Release authentication has no minisign download prompt.
run_test test_no_release_minisign
run_test test_has_verify_checksum
run_test test_has_sha256_verification

# age prompt
run_test test_age_has_consent_prompt
run_test test_age_has_noninteractive_guard
run_test test_age_has_manual_install_hint
run_test test_age_has_download_source_disclosure
run_test test_age_download_is_checksum_pinned

report_results
