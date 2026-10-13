#!/usr/bin/env bash
# ABOUTME: Tests for cs-secrets encrypted file backend and CLI dispatch
# ABOUTME: Validates store/get/list/delete/purge/export and backend detection
#
# The concurrency tests live in test_cs_secrets_concurrency.sh, not here: they
# hold a writer inside its critical section with deliberate sleeps, which made
# this file the parallel gate's long pole. A new test belongs there only when it
# is slow BECAUSE it synchronises two processes.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_SECRETS_BIN="$SCRIPT_DIR/../bin/cs-secrets"

# Override setup to use encrypted backend with a test-scoped secrets dir
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    export CS_SECRETS_BACKEND="encrypted"
    export CS_SECRETS_PASSWORD="test-password-for-ci"
    export HOME="$TEST_TMPDIR/home"
    export CLAUDE_SESSION_NAME="test-session"
    # No age anywhere, so export-file deterministically takes the password
    # (.enc) path even on a host that has age installed. The path does not
    # exist, which the CS_AGE_BIN seam reads as "no age on this machine".
    export CS_AGE_BIN="$TEST_TMPDIR/no-such-age"
    mkdir -p "$CS_SESSIONS_ROOT" "$HOME"
    # The session CLAUDE_SESSION_NAME names: export-file and the age commands
    # refuse a name the sessions root does not have.
    mkdir -p "$CS_SESSIONS_ROOT/test-session/.cs"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_SECRETS_BACKEND CS_SECRETS_PASSWORD CLAUDE_SESSION_NAME 2>/dev/null || true
    # Restore HOME
    export HOME="$ORIGINAL_HOME"
}

# Save real HOME before tests override it
ORIGINAL_HOME="$HOME"

# --- Sync-file test helpers ---

# Reproduce the machine identifier cs-secrets uses to name per-machine sync
# files (hostname-derived, matches age_get_machine_id in bin/cs-secrets).
_machine_id() {
    local user host
    user="${USER:-}"
    [ -n "$user" ] || user=$(id -un 2>/dev/null) || user=""
    host=$(hostname -s 2>/dev/null || hostname 2>/dev/null) || host=""
    host=${host//$'\r'/}
    printf '%s@%s' "${user:-unknown}" "${host:-unknown}"
}

# The PATH to run cs-secrets under when a test needs the password (.enc) export
# path. age is disabled through the CS_AGE_BIN seam that setup exports, so the
# PATH itself needs no surgery: a whitelist-rebuilt PATH could not start the
# interpreter at all on some hosts, which surfaced as a bare exit 127.
_ageless_path() {
    printf '%s' "$PATH"
}

# Encrypt a JSON payload into a sync file with the shared test password, to
# simulate a file another machine (or a legacy export) committed to git. Fails
# loud: a seed that silently produced nothing turns every downstream assertion
# into a lie about the import rather than about the seeding.
_seed_enc_sync_file() {
    local path="$1" json="$2" rc=0
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$json" | openssl enc -aes-256-cbc -e -pbkdf2 -iter 100000 \
        -out "$path" -pass "pass:$CS_SECRETS_PASSWORD" || rc=$?
    if [ "$rc" -ne 0 ] || [ ! -s "$path" ]; then
        echo "  FAIL: could not seed sync file $path (openssl exit $rc, $(ls -l "$path" 2>&1))"
        return 1
    fi
}

# Print what an import actually did when an assertion about its result fails.
# The import's own summary ("Imported N secret(s) from M sync file(s)" /
# "Skipped X undecryptable file(s)") names which candidate files it accepted,
# which distinguishes a file that was never a candidate from one that was
# rejected during decrypt or validation.
_report_import() {
    local rc="$1" out="$2" meta="$3"
    echo "    import rc=$rc, output: $out"
    ls -l "$meta"/secrets*.enc 2>&1 | sed 's/^/    /'
    # Which keys actually landed. A key that lists but will not `get` is a name
    # mangled on the way in; a key missing from the list never reached the
    # store, whatever the import's own count claimed.
    echo "    backend now holds:"
    "$CS_SECRETS_BIN" list 2>&1 | sed 's/^/      /'
    ls -l "$HOME/.cs-secrets" 2>&1 | sed 's/^/      /'
}

# Build a sandbox bin dir holding a fake `security` (never touches the real
# macOS Keychain). Callers PREPEND it to PATH so the fake shadows the real tool
# while the rest of the system stays reachable -- a rebuilt PATH holding only
# copies of the tools cannot always start `#!/usr/bin/env bash`, which surfaces
# as a bare exit 127.
# FAKE_SECURITY_MODE selects the behaviour: "fail" makes `dump-keychain` exit
# nonzero (a real enumeration failure); "readfail" enumerates one credential but
# makes the per-item `find-generic-password` read fail; anything else is a
# healthy empty keychain. Echoes the bin dir.
_make_fake_security() {
    local bindir="$TEST_TMPDIR/kc-bin"
    mkdir -p "$bindir"
    cat > "$bindir/security" <<'FAKE'
#!/usr/bin/env bash
set -u
sub="${1:-}"
sess="${FAKE_SECURITY_SESSION:-test-session}"

# FAKE_SECURITY_ARGVLOG records the argv this process was started with, which
# is exactly what `ps` would show, so a test can prove a value never reached it.
[ -n "${FAKE_SECURITY_ARGVLOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_SECURITY_ARGVLOG"

# `security -i` reads its command line from stdin. Parse that line the way the
# real tokenizer does for what cs-secrets sends (double-quoted words with \\
# and \" escapes) and carry on as if it had been argv.
if [ "$sub" = "-i" ]; then
    IFS= read -r line || true
    eval "set -- $line"
    sub="${1:-}"
fi

# Argument shape used by cs-secrets: -a <account> -s <service> [-w [value] | -X <hex>] [-U]
acct=""; service=""; value=""; have_value=0; hex=""; have_hex=0
while [ $# -gt 0 ]; do
    case "$1" in
        -a) acct="${2:-}"; shift 2 ;;
        -s) service="${2:-}"; shift 2 ;;
        -w) if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then value="$2"; have_value=1; shift 2; else shift; fi ;;
        -X) hex="${2:-}"; have_hex=1; shift 2 ;;
        *)  shift ;;
    esac
done

# FAKE_SECURITY_STORE turns the fake into a functional credential store, which
# is what the migration tests need: a real second backend to move secrets into
# and read back. Without it the fixed-response modes below apply, which is what
# the error-path tests need.
store="${FAKE_SECURITY_STORE:-}"
slot() { printf '%s/%s' "$store" "$(printf '%s' "$service" | tr -c 'A-Za-z0-9_.-' '_')"; }

case "$sub" in
    dump-keychain)
        case "${FAKE_SECURITY_MODE:-}" in
            fail)
                echo "security: keychain access failed" >&2
                exit 1
                ;;
            readfail|readok)
                # Enumerate exactly one matching credential so the caller
                # proceeds to read it (readfail then hits a read failure,
                # readok returns a value).
                printf '    "svce"<blob>="cs:%s:K1"\n' "$sess"
                exit 0
                ;;
            *)
                if [ -n "$store" ]; then
                    for f in "$store"/*; do
                        [ -f "$f" ] || continue
                        printf '    "svce"<blob>="%s"\n' "$(head -1 "$f")"
                    done
                fi
                exit 0
                ;;
        esac
        ;;
    find-generic-password)
        # A per-item read. readfail = a real read error (exit 1); readok =
        # success with a value; anything else = errSecItemNotFound (exit 44).
        case "${FAKE_SECURITY_MODE:-}" in
            readfail) exit 1 ;;
            readok)   printf 'v_from_keychain\n'; exit 0 ;;
        esac
        if [ -n "$store" ] && [ -f "$(slot)" ]; then
            tail -n +2 "$(slot)"; exit 0
        fi
        exit 44
        ;;
    add-generic-password)
        # Record that a store was attempted (without recording the value) so a
        # test can prove no overwrite happened when it should have aborted.
        [ -n "${FAKE_SECURITY_ADDLOG:-}" ] && printf 'store\n' >> "$FAKE_SECURITY_ADDLOG"
        # A store that touches a marker then waits lets a test interleave a
        # concurrent mutation while this write is still in flight.
        if [ -n "${FAKE_SECURITY_SLOW_STORE:-}" ]; then
            : > "$FAKE_SECURITY_SLOW_STORE"
            sleep 1
        fi
        case "${FAKE_SECURITY_MODE:-}" in
            storefail) echo "security: could not add credential" >&2; exit 1 ;;
        esac
        if [ -n "$store" ]; then
            mkdir -p "$store"
            {
                printf '%s\n' "$service"
                [ "$have_value" -eq 1 ] && printf '%s' "$value"
                [ "$have_hex" -eq 1 ] && printf '%s' "$hex" | perl -ne 'print pack("H*", $_)'
            } > "$(slot)"
        fi
        exit 0
        ;;
    delete-generic-password)
        if [ -n "$store" ]; then
            [ -f "$(slot)" ] || exit 44
            rm -f "$(slot)"
        fi
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
FAKE
    chmod +x "$bindir/security"
    echo "$bindir"
}

# ============================================================================
# Backend detection
# ============================================================================

test_backend_shows_encrypted() {
    local output
    output=$("$CS_SECRETS_BIN" backend 2>&1)
    assert_output_contains "$output" "encrypted" "Should show encrypted backend" || return 1
}

test_backend_override_via_env() {
    export CS_SECRETS_BACKEND="encrypted"
    local output
    output=$("$CS_SECRETS_BIN" backend 2>&1)
    assert_output_contains "$output" "encrypted" "Should respect CS_SECRETS_BACKEND" || return 1
}

test_backend_wsl_defaults_encrypted_not_keychain() {
    unset CS_SECRETS_BACKEND
    local output
    output=$(CS_PLATFORM_OVERRIDE=wsl "$CS_SECRETS_BIN" backend 2>&1)
    assert_output_contains "$output" "Storage backend: encrypted" "WSL should default to encrypted, not keychain" || return 1
}

# ============================================================================
# Store and retrieve
# ============================================================================

test_store_and_get() {
    "$CS_SECRETS_BIN" set api_key "sk_test_123" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get api_key 2>&1)
    assert_eq "sk_test_123" "$value" "Should retrieve stored value" || return 1
}

# A value on argv is still stored, with a warning that names the one place it
# shows (ps) and the stdin form that avoids it.
test_set_warns_about_a_value_on_argv() {
    local err
    err=$("$CS_SECRETS_BIN" set api_key "sk_test_123" 2>&1 >/dev/null)
    assert_eq "$(printf '%s\n%s' \
        "Warning: passing the value on the command line exposes it via ps." \
        "         Prefer stdin: cs -secrets set api_key < valuefile")" "$err" \
        "the argv warning names ps and the stdin form" || return 1
}

test_store_with_spaces_in_value() {
    "$CS_SECRETS_BIN" set db_url "postgres://user:pass@localhost/my db" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get db_url 2>&1)
    assert_eq "postgres://user:pass@localhost/my db" "$value" "Should handle spaces" || return 1
}

# The value can be supplied on stdin (never argv) so it stays out of ps.
test_set_reads_value_from_stdin() {
    printf 'sk_from_stdin' | "$CS_SECRETS_BIN" set api_key >/dev/null 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get api_key 2>&1)
    assert_eq "sk_from_stdin" "$value" "Should store the value read from stdin" || return 1
}

test_set_reads_value_from_file_redirect() {
    printf 'sk_from_file\n' > "$TEST_TMPDIR/secret.txt"
    "$CS_SECRETS_BIN" set api_key < "$TEST_TMPDIR/secret.txt" >/dev/null 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get api_key 2>&1)
    assert_eq "sk_from_file" "$value" "Should store the value from a redirected file" || return 1
}

# A value copied out of a redacted transcript or a config template is a mask,
# not a secret. Storing it would overwrite a working secret with junk and fail
# only much later, at whatever reads it. Each is refused by name and never
# reaches the store; a real value that merely contains asterisks is kept.
test_set_refuses_placeholder_values() {
    local p out rc
    for p in '[REDACTED: stored in keychain as api_key]' '***' '********' '<redacted>' 'YOUR_API_KEY'; do
        rc=0
        out=$(printf '%s' "$p" | "$CS_SECRETS_BIN" set api_key 2>&1) || rc=$?
        assert_eq "1" "$rc" "set refuses the placeholder '$p'" || return 1
        assert_eq "Error: Refusing to store api_key: its value '$p' is a placeholder, not a secret. Pass the real value on stdin." \
            "$out" "the refusal names the secret and the placeholder" || return 1
        assert_output_not_contains "$("$CS_SECRETS_BIN" list 2>&1)" "api_key" \
            "a refused placeholder never reaches the store" || return 1
    done
    printf 'p***word' | "$CS_SECRETS_BIN" set api_key >/dev/null 2>&1 || return 1
    assert_eq "p***word" "$("$CS_SECRETS_BIN" get api_key 2>&1)" \
        "a real value containing asterisks is stored" || return 1
}

# Typed at a terminal, the value must not echo: it would sit on screen, in the
# terminal's scrollback and in any recording of the pane. Driven through a real
# pty. The value is written only once the terminal's ECHO flag is off, so a
# prompt that never disables echo shows the value and fails, while one that
# does can never race the write.
test_set_on_a_tty_does_not_echo_the_value() {
    local out
    out=$(python3 - "$CS_SECRETS_BIN" <<'PY' 2>&1
import os, pty, select, sys, termios, time
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], "set", "api_key"])
seen = b""
def drain(until):
    global seen
    while time.time() < until:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 1024)
            except OSError:
                return
            if not chunk:
                return
            seen += chunk
deadline = time.time() + 10
while b"Enter value" not in seen and time.time() < deadline:
    drain(time.time() + 0.1)
deadline = time.time() + 5
while time.time() < deadline and termios.tcgetattr(fd)[3] & termios.ECHO:
    drain(time.time() + 0.05)
os.write(fd, b"sk_typed_7f3a\n")
drain(time.time() + 5)
os.waitpid(pid, 0)
sys.stdout.write(seen.decode("utf-8", "replace"))
PY
)
    assert_output_contains "$out" "Enter value for api_key" "the prompt is shown" || return 1
    assert_output_not_contains "$out" "sk_typed_7f3a" "the typed value is not echoed" || return 1
    assert_eq "sk_typed_7f3a" "$("$CS_SECRETS_BIN" get api_key 2>&1)" \
        "the typed value is stored" || return 1
}

test_store_with_special_chars() {
    "$CS_SECRETS_BIN" set token 'abc!@#$%^&*()_+' 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get token 2>&1)
    assert_eq 'abc!@#$%^&*()_+' "$value" "Should handle special chars" || return 1
}

test_store_overwrites_existing() {
    "$CS_SECRETS_BIN" set api_key "old_value" 2>&1
    "$CS_SECRETS_BIN" set api_key "new_value" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get api_key 2>&1)
    assert_eq "new_value" "$value" "Should overwrite with new value" || return 1
}

test_get_nonexistent_fails() {
    local output
    if output=$("$CS_SECRETS_BIN" get nonexistent 2>&1); then
        echo "  FAIL: Should fail for nonexistent secret"
        return 1
    fi
    assert_output_contains "$output" "not found" "Error should mention not found" || return 1
}

# ============================================================================
# List
# ============================================================================

test_list_empty() {
    local output
    output=$("$CS_SECRETS_BIN" list 2>&1)
    assert_output_contains "$output" "No secrets" "Should say no secrets" || return 1
}

test_list_shows_stored_secrets() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    "$CS_SECRETS_BIN" set db_pass "xyz" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" list 2>&1)
    assert_output_contains "$output" "api_key" "Should list api_key" || return 1
    assert_output_contains "$output" "db_pass" "Should list db_pass" || return 1
}

test_list_does_not_show_values() {
    "$CS_SECRETS_BIN" set api_key "supersecret" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" list 2>&1)
    assert_output_not_contains "$output" "supersecret" "List should not show values" || return 1
}

# ============================================================================
# Delete
# ============================================================================

test_delete_removes_secret() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    "$CS_SECRETS_BIN" delete api_key 2>&1
    local output
    if "$CS_SECRETS_BIN" get api_key 2>&1; then
        echo "  FAIL: Secret should be deleted"
        return 1
    fi
}

test_delete_nonexistent_fails() {
    local output
    if output=$("$CS_SECRETS_BIN" delete nonexistent 2>&1); then
        echo "  FAIL: Should fail for nonexistent secret"
        return 1
    fi
    assert_output_contains "$output" "not found" "Error should mention not found" || return 1
}

test_delete_preserves_other_secrets() {
    "$CS_SECRETS_BIN" set key1 "val1" 2>&1
    "$CS_SECRETS_BIN" set key2 "val2" 2>&1
    "$CS_SECRETS_BIN" delete key1 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get key2 2>&1)
    assert_eq "val2" "$value" "Other secrets should be preserved" || return 1
}

# ============================================================================
# Purge
# ============================================================================

test_purge_removes_all() {
    "$CS_SECRETS_BIN" set key1 "val1" 2>&1
    "$CS_SECRETS_BIN" set key2 "val2" 2>&1
    "$CS_SECRETS_BIN" set key3 "val3" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" purge 2>&1)
    assert_output_contains "$output" "Purged 3" "Should purge 3 secrets" || return 1

    local list_output
    list_output=$("$CS_SECRETS_BIN" list 2>&1)
    assert_output_contains "$list_output" "No secrets" "All secrets should be gone" || return 1
}

# The pin list and digest record live under ~/.cs-secrets, so they outlive the
# session directory. `purge` deletes ALL of a session's secrets, and the trust
# that went with them goes too: a later session under the same name must not
# inherit recipients nobody pinned for it.
test_purge_drops_the_sessions_age_state() {
    _use_real_age || return $?
    local state="$HOME/.cs-secrets/sessions/test-session"
    printf 'age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq\n' > "$TEST_TMPDIR/peer.pub"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" age add "$TEST_TMPDIR/peer.pub" >/dev/null 2>&1 || { echo "  FAIL: age add failed"; return 1; }
    assert_file_exists "$state/age-trusted" "fixture: age add wrote the pin list" || return 1
    "$CS_SECRETS_BIN" purge >/dev/null 2>&1 || { echo "  FAIL: purge failed"; return 1; }
    if [ -e "$state" ]; then
        echo "  FAIL: purge left the session's age state behind: $(ls -A "$state" | tr '\n' ' ')"
        return 1
    fi
}

# The age recipients and the sync file live in a session's .cs, and the pin
# list under ~/.cs-secrets is keyed by the session's name. A name the sessions
# root does not have (a removed session, a mistyped --session) must be refused
# before anything is written: creating it would bring a removed session back
# as a directory holding nothing but recipients, with a pin list a later
# session of that name would inherit.
_assert_no_trace_of_session() {  # name
    assert_not_exists "$CS_SESSIONS_ROOT/$1" "no directory is created for the session" || return 1
    assert_not_exists "$HOME/.cs-secrets/sessions/$1" "no age state is created for the session" || return 1
}

test_age_add_refuses_a_session_the_root_does_not_have() {
    local out rc=0
    out=$("$CS_SECRETS_BIN" --session ghost age add age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq0000000 2>&1) || rc=$?
    assert_eq "1" "$rc" "age add exits 1" || return 1
    assert_eq "Error: No session named 'ghost' in $CS_SESSIONS_ROOT" "$out" "the refusal names the session and the root" || return 1
    _assert_no_trace_of_session ghost || return 1
}

# A directory in the sessions root that holds no .cs is not a session, and an
# age add must not make it look like one.
test_age_add_refuses_a_directory_that_is_not_a_session() {
    local out rc=0
    mkdir -p "$CS_SESSIONS_ROOT/plain"
    out=$("$CS_SECRETS_BIN" --session plain age add age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq0000000 2>&1) || rc=$?
    assert_eq "1" "$rc" "age add exits 1" || return 1
    assert_eq "Error: No session named 'plain' in $CS_SESSIONS_ROOT" "$out" "the refusal names the session and the root" || return 1
    assert_eq "" "$(ls -A "$CS_SESSIONS_ROOT/plain")" "the directory stays empty" || return 1
    assert_not_exists "$HOME/.cs-secrets/sessions/plain" "no age state is created for it" || return 1
}

# A session is one entry of the sessions root, so a name that is a path is
# refused even where the path leads to a directory holding .cs: ".." would put
# the recipients in the root's parent and the pin list in ~/.cs-secrets itself,
# where no session removal looks.
test_age_add_refuses_a_name_that_is_a_path() {
    local name out rc
    mkdir -p "$TEST_TMPDIR/.cs" "$CS_SESSIONS_ROOT/test-session/nested/.cs"
    for name in .. . test-session/nested test-session/; do
        rc=0
        out=$("$CS_SECRETS_BIN" --session "$name" age add age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq0000000 2>&1) || rc=$?
        assert_eq "1" "$rc" "age add exits 1 for '$name'" || return 1
        assert_eq "Error: No session named '$name' in $CS_SESSIONS_ROOT" "$out" "the refusal names '$name' and the root" || return 1
    done
    assert_not_exists "$TEST_TMPDIR/.cs/age-recipients" "nothing is written beside the sessions root" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/.cs" "nothing is written into the sessions root" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/test-session/nested/.cs/age-recipients" "nothing is written into the nested directory" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/test-session/.cs/age-recipients" "nothing is written into the session through a trailing slash" || return 1
    assert_not_exists "$HOME/.cs-secrets/age-trusted" "no pin list lands in ~/.cs-secrets itself" || return 1
    assert_not_exists "$HOME/.cs-secrets/sessions" "no age state is created" || return 1
}

# Purge ends in an rm -rf of the session's age state under ~/.cs-secrets, so a
# name that is a path would delete whatever it leads to: the machine key one
# level up, a directory beside ~/.cs-secrets two levels up. Every verb that
# takes a session refuses such a name before touching any store.
test_session_verbs_refuse_a_name_that_is_a_path() {
    local bindir; bindir=$(_make_fake_security)
    mkdir -p "$HOME/.cs-secrets/sessions/test-session" "$HOME/victim"
    printf 'keep\n' > "$HOME/victim/file.txt"
    printf 'PRIVATE\n' > "$HOME/.cs-secrets/id_ed25519"
    local backend name verb out rc
    for backend in keychain encrypted; do
        for name in ../../victim ../id_ed25519 .. test-session/x; do
            for verb in purge list; do
                rc=0
                out=$(PATH="$bindir:$PATH" CS_SECRETS_BACKEND=$backend FAKE_SECURITY_MODE=empty \
                    "$CS_SECRETS_BIN" --session "$name" "$verb" 2>&1) || rc=$?
                assert_eq "1" "$rc" "$backend $verb exits 1 for '$name'" || return 1
                assert_eq "Error: No session named '$name' in $CS_SESSIONS_ROOT" "$out" \
                    "$backend $verb names '$name' and the root" || return 1
            done
        done
    done
    assert_file_exists "$HOME/victim/file.txt" "the directory beside ~/.cs-secrets survives" || return 1
    assert_file_exists "$HOME/.cs-secrets/id_ed25519" "the machine key survives" || return 1
}

test_age_remove_refuses_a_session_the_root_does_not_have() {
    local out rc=0
    out=$("$CS_SECRETS_BIN" --session ghost age remove peer 2>&1) || rc=$?
    assert_eq "1" "$rc" "age remove exits 1" || return 1
    assert_eq "Error: No session named 'ghost' in $CS_SESSIONS_ROOT" "$out" "the refusal names the session and the root" || return 1
    _assert_no_trace_of_session ghost || return 1
}

# Stored secrets outlive `cs -rm`, so an export under a removed session's name
# has something to write.
test_export_file_refuses_a_session_the_root_does_not_have() {
    local out rc=0
    mkdir -p "$CS_SESSIONS_ROOT/ghost/.cs"
    "$CS_SECRETS_BIN" --session ghost set api_key "sk_123" >/dev/null 2>&1 || { echo "  FAIL: fixture: set failed"; return 1; }
    rm -rf "$CS_SESSIONS_ROOT/ghost"
    out=$("$CS_SECRETS_BIN" --session ghost export-file 2>&1) || rc=$?
    assert_eq "1" "$rc" "export-file exits 1" || return 1
    assert_eq "Error: No session named 'ghost' in $CS_SESSIONS_ROOT" "$out" "the refusal names the session and the root" || return 1
    _assert_no_trace_of_session ghost || return 1
}

test_import_file_refuses_a_session_the_root_does_not_have() {
    local out rc=0
    out=$("$CS_SECRETS_BIN" --session ghost import-file 2>&1) || rc=$?
    assert_eq "1" "$rc" "import-file exits 1" || return 1
    assert_eq "Error: No session named 'ghost' in $CS_SESSIONS_ROOT" "$out" "the refusal names the session and the root" || return 1
    _assert_no_trace_of_session ghost || return 1
}

test_purge_empty_session() {
    local output
    output=$("$CS_SECRETS_BIN" purge 2>&1)
    assert_output_contains "$output" "No secrets to purge" "Should handle empty purge" || return 1
}

# ============================================================================
# Export
# ============================================================================

test_export_produces_eval_format() {
    "$CS_SECRETS_BIN" set api_key "sk_123" 2>&1
    "$CS_SECRETS_BIN" set db_pass "hunter2" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" export 2>&1)
    assert_output_contains "$output" "export CS_SECRET_API_KEY=" "Should export api_key" || return 1
    assert_output_contains "$output" "export CS_SECRET_DB_PASS=" "Should export db_pass" || return 1
}

# Multiple multi-line secrets must ALL survive byte-exact -- not just the last.
# Multi-line values are load-bearing here: a single-line value cannot carry an
# interior newline, so it could not tell a working json_value from one that
# mangles the value path. More than one secret is load-bearing too, because a
# per-line defect corrupts every value but the final one, which is precisely
# the shape that reads as healthy when only one secret is checked.
test_multi_line_secrets_survive_get_and_export() {
    local pem_a pem_b
    pem_a=$'-----BEGIN A-----\nalpha-one\nalpha-two\n-----END A-----'
    pem_b=$'-----BEGIN B-----\nbeta-one\nbeta-two\n-----END B-----'

    printf '%s' "$pem_a" | "$CS_SECRETS_BIN" set key_a >/dev/null 2>&1 || return 1
    printf '%s' "$pem_b" | "$CS_SECRETS_BIN" set key_b >/dev/null 2>&1 || return 1

    local got_a got_b
    got_a=$("$CS_SECRETS_BIN" get key_a 2>/dev/null) || return 1
    got_b=$("$CS_SECRETS_BIN" get key_b 2>/dev/null) || return 1
    assert_eq "$pem_a" "$got_a" "get must return the first multi-line secret unchanged" || return 1
    assert_eq "$pem_b" "$got_b" "get must return the second multi-line secret unchanged" || return 1

    local out
    out=$("$CS_SECRETS_BIN" export 2>/dev/null) || return 1
    ( eval "$out"
      assert_eq "$pem_a" "${CS_SECRET_KEY_A:-}" "export must carry the first secret unchanged" || exit 1
      assert_eq "$pem_b" "${CS_SECRET_KEY_B:-}" "export must carry the second secret unchanged" || exit 1
    ) || return 1
}

test_export_is_eval_safe() {
    "$CS_SECRETS_BIN" set test_key "value with spaces" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" export 2>&1)
    # The export should be eval-safe (properly quoted)
    eval "$output" 2>/dev/null
    assert_eq "value with spaces" "$CS_SECRET_TEST_KEY" "Eval'd export should set correct value" || return 1
}

# ============================================================================
# Encrypted file internals
# ============================================================================

test_encrypted_file_created() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    local enc_file="$HOME/.cs-secrets/test-session.enc"
    assert_exists "$enc_file" "Encrypted file should exist" || return 1
}

test_encrypted_file_not_plaintext() {
    "$CS_SECRETS_BIN" set api_key "visible_secret_value" 2>&1
    local enc_file="$HOME/.cs-secrets/test-session.enc"
    if grep -q "visible_secret_value" "$enc_file" 2>/dev/null; then
        echo "  FAIL: Encrypted file should not contain plaintext secret"
        return 1
    fi
}

test_encrypted_file_permissions() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    local enc_file="$HOME/.cs-secrets/test-session.enc"
    local perms
    perms=$(_file_mode "$enc_file")
    assert_eq "600" "$perms" "Encrypted file should be 600" || return 1
}

test_secrets_dir_permissions() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    local perms
    perms=$(_file_mode "$HOME/.cs-secrets")
    assert_eq "700" "$perms" "Secrets dir should be 700" || return 1
}

# Build a bin dir with a fake `openssl` that simulates a mid-write encryption
# failure: on `enc -e` it truncates the -out target (as real openssl does when
# it opens the output before erroring) and exits nonzero; all other invocations
# (notably `enc -d` decrypt) pass through to the real openssl. Echoes the dir.
_make_openssl_writefail_bin() {
    local bindir="$TEST_TMPDIR/ossl-fail-bin"
    mkdir -p "$bindir"
    local real_openssl; real_openssl=$(command -v openssl)
    cat > "$bindir/openssl" <<OSSL
#!/usr/bin/env bash
enc=0; e=0; out=""; prev=""
for a in "\$@"; do
    case "\$prev" in -out) out="\$a" ;; esac
    case "\$a" in enc) enc=1 ;; -e) e=1 ;; esac
    prev="\$a"
done
if [[ \$enc -eq 1 && \$e -eq 1 ]]; then
    # Reproduce a real partial write: the -out file is opened (truncated) and
    # partially written before openssl errors out.
    [[ -n "\$out" ]] && printf 'PARTIAL' > "\$out"
    echo "openssl: simulated write failure" >&2
    exit 1
fi
exec "$real_openssl" "\$@"
OSSL
    chmod +x "$bindir/openssl"
    echo "$bindir"
}

# A failed encrypted write must NEVER destroy the existing store: the prior
# ciphertext must be byte-for-byte intact and still decryptable to the old value.
test_encrypted_write_failure_preserves_prior_store() {
    "$CS_SECRETS_BIN" set K1 v1 >/dev/null 2>&1
    assert_eq "v1" "$("$CS_SECRETS_BIN" get K1 2>&1)" "precondition: K1=v1 stored" || return 1

    local enc_file="$HOME/.cs-secrets/test-session.enc"
    assert_file_exists "$enc_file" "precondition: store file exists" || return 1
    local before; before=$(openssl dgst -sha256 < "$enc_file")

    local bindir; bindir=$(_make_openssl_writefail_bin)
    local out rc=0
    out=$(PATH="$bindir:$PATH" "$CS_SECRETS_BIN" set K1 v2_should_fail 2>&1) || rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: set must return nonzero when the encrypted write fails"
        echo "    output: $out"
        return 1
    fi
    local after; after=$(openssl dgst -sha256 < "$enc_file")
    assert_eq "$before" "$after" "prior ciphertext must be byte-for-byte unchanged after a failed write" || return 1
    assert_eq "v1" "$("$CS_SECRETS_BIN" get K1 2>&1)" "the old secret must still decrypt after a failed write" || return 1

    local tmpcount
    tmpcount=$(find "$HOME/.cs-secrets" -maxdepth 1 -name '.??????' -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_eq 0 "$tmpcount" "no stray temp file must remain after a failed write" || return 1
}

# The success path must persist updates, preserve other secrets, and leave no
# temp file behind.
test_encrypted_write_success_updates_and_leaves_no_temp() {
    "$CS_SECRETS_BIN" set K1 v1 >/dev/null 2>&1
    "$CS_SECRETS_BIN" set K1 v2 >/dev/null 2>&1
    "$CS_SECRETS_BIN" set K2 w1 >/dev/null 2>&1

    assert_eq "v2" "$("$CS_SECRETS_BIN" get K1 2>&1)" "update must persist" || return 1
    assert_eq "w1" "$("$CS_SECRETS_BIN" get K2 2>&1)" "second secret must be stored" || return 1

    local perms; perms=$(_file_mode "$HOME/.cs-secrets/test-session.enc")
    assert_eq "600" "$perms" "committed store must keep mode 600" || return 1

    local tmpcount
    tmpcount=$(find "$HOME/.cs-secrets" -maxdepth 1 -name '.??????' -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_eq 0 "$tmpcount" "success path must leave no temp file" || return 1
}

# ============================================================================
# Session isolation
# ============================================================================

test_sessions_are_isolated() {
    create_test_session session-a >/dev/null
    create_test_session session-b >/dev/null
    export CLAUDE_SESSION_NAME="session-a"
    "$CS_SECRETS_BIN" set shared_key "value_a" 2>&1

    export CLAUDE_SESSION_NAME="session-b"
    "$CS_SECRETS_BIN" set shared_key "value_b" 2>&1

    export CLAUDE_SESSION_NAME="session-a"
    local value_a
    value_a=$("$CS_SECRETS_BIN" get shared_key 2>&1)
    assert_eq "value_a" "$value_a" "Session A should have its own value" || return 1

    export CLAUDE_SESSION_NAME="session-b"
    local value_b
    value_b=$("$CS_SECRETS_BIN" get shared_key 2>&1)
    assert_eq "value_b" "$value_b" "Session B should have its own value" || return 1
}

# ============================================================================
# CLI dispatch
# ============================================================================

test_store_alias_works() {
    "$CS_SECRETS_BIN" store api_key "abc" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get api_key 2>&1)
    assert_eq "abc" "$value" "store alias should work" || return 1
}

test_ls_alias_works() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" ls 2>&1)
    assert_output_contains "$output" "api_key" "ls alias should work" || return 1
}

test_rm_alias_works() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    "$CS_SECRETS_BIN" rm api_key 2>&1
    if "$CS_SECRETS_BIN" get api_key 2>/dev/null; then
        echo "  FAIL: rm alias should delete secret"
        return 1
    fi
}

test_session_flag_overrides_env() {
    create_test_session other-session >/dev/null
    export CLAUDE_SESSION_NAME="default-session"
    "$CS_SECRETS_BIN" --session other-session set api_key "abc" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" --session other-session get api_key 2>&1)
    assert_eq "abc" "$value" "--session flag should override env" || return 1

    # Default session should not have it
    if "$CS_SECRETS_BIN" get api_key 2>/dev/null; then
        echo "  FAIL: Default session should not have the secret"
        return 1
    fi
}

test_no_session_errors() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    local output
    if output=$("$CS_SECRETS_BIN" set api_key "abc" </dev/null 2>&1); then
        echo "  FAIL: Should fail without session name"
        return 1
    fi
    assert_output_contains "$output" "No session specified. Set CLAUDE_SESSION_NAME or use --session" || return 1
}

test_picker_selects_numbered_session() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs" "$CS_SESSIONS_ROOT/beta/.cs"
    local out
    out=$(printf '2\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>/dev/null) || return 1
    assert_output_contains "$out" "No secrets stored for session: beta" || return 1
}

test_picker_prompt_stays_off_stdout() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs" "$CS_SESSIONS_ROOT/beta/.cs"
    local out err
    out=$(printf '1\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>"$TEST_TMPDIR/picker-err") || return 1
    err=$(cat "$TEST_TMPDIR/picker-err")
    assert_output_contains "$err" "No session specified. Pick one:" || return 1
    assert_output_contains "$err" "1) alpha" || return 1
    assert_output_not_contains "$out" "Pick one" || return 1
    assert_output_contains "$out" "No secrets stored for session: alpha" || return 1
}

test_picker_enter_takes_cwd_default() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs" "$CS_SESSIONS_ROOT/beta/.cs"
    (
        cd "$CS_SESSIONS_ROOT/beta" || exit 1
        local out err
        out=$(printf '\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>"$TEST_TMPDIR/picker-err") || exit 1
        err=$(cat "$TEST_TMPDIR/picker-err")
        assert_output_contains "$err" "Session number \[beta\]" || exit 1
        assert_output_contains "$out" "No secrets stored for session: beta" || exit 1
    ) || return 1
}

test_picker_worktree_dir_defaults_to_base() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs" "$CS_SESSIONS_ROOT/alpha@task1/.cs"
    (
        cd "$CS_SESSIONS_ROOT/alpha@task1" || exit 1
        local out err
        out=$(printf '\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>"$TEST_TMPDIR/picker-err") || exit 1
        err=$(cat "$TEST_TMPDIR/picker-err")
        assert_output_not_contains "$err" "alpha@task1" || exit 1
        assert_output_contains "$out" "No secrets stored for session: alpha" || exit 1
    ) || return 1
}

test_picker_hides_archived_but_cwd_defaults() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs" "$CS_SESSIONS_ROOT/beta/.cs"
    touch "$CS_SESSIONS_ROOT/alpha/.cs/archived"
    local err
    printf '1\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list >/dev/null 2>"$TEST_TMPDIR/picker-err" || return 1
    err=$(cat "$TEST_TMPDIR/picker-err")
    assert_output_not_contains "$err" "alpha" || return 1
    (
        cd "$CS_SESSIONS_ROOT/alpha" || exit 1
        local out
        out=$(printf '\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>/dev/null) || exit 1
        assert_output_contains "$out" "No secrets stored for session: alpha" || exit 1
    ) || return 1
}

test_picker_eof_aborts_despite_default() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs"
    (
        cd "$CS_SESSIONS_ROOT/alpha" || exit 1
        local out
        if out=$(CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list </dev/null 2>&1); then
            echo "  FAIL: EOF should abort even with a CWD default"
            exit 1
        fi
        assert_output_contains "$out" "No session specified. Set CLAUDE_SESSION_NAME or use --session" || exit 1
    ) || return 1
}

test_picker_all_archived_cwd_still_defaults() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs"
    touch "$CS_SESSIONS_ROOT/alpha/.cs/archived"
    (
        cd "$CS_SESSIONS_ROOT/alpha" || exit 1
        local out
        out=$(printf '\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>/dev/null) || exit 1
        assert_output_contains "$out" "No secrets stored for session: alpha" || exit 1
    ) || return 1
}

test_picker_rejects_invalid_choice() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs"
    local out
    if out=$(printf '99\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>&1); then
        echo "  FAIL: out-of-range choice should error"
        return 1
    fi
    assert_output_contains "$out" "No session specified. Set CLAUDE_SESSION_NAME or use --session" || return 1
    if out=$(printf '\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>&1); then
        echo "  FAIL: empty input with no default should error"
        return 1
    fi
    assert_output_contains "$out" "No session specified. Set CLAUDE_SESSION_NAME or use --session" || return 1
}

test_picker_empty_root_errors() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    # setup stages test-session; this test is about a root with no session.
    rm -rf "$CS_SESSIONS_ROOT/test-session"
    local out
    if out=$(printf '1\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>&1); then
        echo "  FAIL: empty sessions root should error"
        return 1
    fi
    assert_output_contains "$out" "No session specified. Set CLAUDE_SESSION_NAME or use --session" || return 1
    assert_output_not_contains "$out" "Pick one" || return 1
}

test_explicit_session_arg_outranks_ambient_namespace() {
    # A launched worktree session carries CS_SECRETS_SESSION=<base> in its
    # environment; `cs <name> -secrets ...` names its target explicitly and
    # must resolve <name>, not the ambient base namespace.
    local output
    output=$(CS_SECRETS_SESSION="ambient-base" "$CS_BIN" "plainsession" -secrets list 2>&1)
    assert_output_contains "$output" "session: plainsession" \
        "explicit -secrets target must outrank ambient CS_SECRETS_SESSION" || return 1
    assert_output_not_contains "$output" "ambient-base" \
        "ambient worktree namespace must not leak into an explicit -secrets call" || return 1
}

test_help_shows_usage() {
    local output
    output=$("$CS_SECRETS_BIN" --help 2>&1) || true
    assert_output_contains "$output" "Usage" "Should show usage" || return 1
}

# ============================================================================
# Per-machine sync files (export-file / import-file)
# ============================================================================

test_export_file_writes_per_machine_enc() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1
    local _exp_out _exp_rc=0
    _exp_out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file 2>&1) || _exp_rc=$?
    local mid
    mid=$(_machine_id)
    assert_file_exists "$meta/secrets.${mid}.enc" "export-file must write a per-machine sync file" \
        || { echo "  export rc=$_exp_rc output: $_exp_out"
             echo "  backend(sandbox): $(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" backend 2>&1 | tr '\n' ' ')"
             # Report only whether the read worked — never the value itself.
             echo "  get(sandbox) rc: $(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" get api_key >/dev/null 2>&1; echo $?)"
             echo "  meta: $(ls -a "$meta" 2>&1 | tr '\n' ' ')"
             echo "  store: $(ls -a "$HOME/.cs-secrets" 2>&1 | tr '\n' ' ')"
             return 1; }
    assert_file_not_exists "$meta/secrets.enc" "export-file must NOT write the shared/unsuffixed name" || return 1
}

# A session named with --session gets the same link check as the current one:
# its .cs linked out of the session must not receive the sync file.
test_export_file_refuses_a_session_whose_cs_links_out() {
    local t o s="$CS_SESSIONS_ROOT/other" out rc=0
    t=$(cd "$TEST_TMPDIR" && pwd -P); o="$t/outside"
    mkdir -p "$o" "$s"
    ln -s "$o" "$s/.cs"
    "$CS_SECRETS_BIN" --session other set api_key "sk_123" >/dev/null 2>&1
    out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" --session other export-file 2>&1) || rc=$?
    assert_eq "1" "$rc" "the export must fail" || return 1
    assert_eq "cs_mkdir_inside: $s/.cs leads to $o, outside the session $s" "$out" "the refusal names the link" || return 1
    assert_eq "" "$(ls -A "$o")" "nothing is written outside the session" || return 1
}

# A path named inside a session is checked like the default one: a committed
# link above it (.cs/backup -> elsewhere) must not carry the sync file out.
test_export_file_refuses_a_named_path_a_link_carries_out() {
    local t o s="$CS_SESSIONS_ROOT/other" out rc=0
    t=$(cd "$TEST_TMPDIR" && pwd -P); o="$t/outside"
    mkdir -p "$o" "$s/.cs"
    printf 'USER-OWNED\n' > "$o/result.enc"
    ln -s "$o" "$s/.cs/backup"
    "$CS_SECRETS_BIN" --session other set api_key "sk_123" >/dev/null 2>&1
    out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" --session other export-file "$s/.cs/backup/result.enc" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the export must fail" || return 1
    assert_eq "cs-secrets export-file: $s/.cs/backup/result.enc leads to $o/result.enc, outside the session $s" "$out" "the refusal names the link" || return 1
    assert_eq "USER-OWNED" "$(cat "$o/result.enc")" "the file outside is untouched" || return 1
}

# The default sync file is checked too: one committed as a link to a
# directory outside the session would take the ciphertext into it.
test_export_file_refuses_a_default_file_linked_to_a_directory_outside() {
    local t o s="$CS_SESSIONS_ROOT/other" out rc=0 f
    t=$(cd "$TEST_TMPDIR" && pwd -P); o="$t/outside"
    mkdir -p "$o" "$s/.cs"
    "$CS_SECRETS_BIN" --session other set api_key "sk_123" >/dev/null 2>&1
    PATH="$(_ageless_path)" "$CS_SECRETS_BIN" --session other export-file >/dev/null 2>&1
    f=$(ls "$s/.cs"/secrets.*.enc 2>/dev/null)
    [ -f "$f" ] || { echo "  FAIL: no default sync file to replace"; return 1; }
    rm "$f"; ln -s "$o" "$f"
    "$CS_SECRETS_BIN" --session other set api_key "sk_456" >/dev/null 2>&1
    out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" --session other export-file 2>&1) || rc=$?
    assert_eq "1" "$rc" "the export must fail" || return 1
    assert_eq "cs-secrets export-file: $f leads to $o, outside the session $s" "$out" "the refusal names the link" || return 1
    assert_eq "" "$(ls -A "$o")" "nothing is written outside the session" || return 1
}

# A context that leaves USER unset (cron, a systemd unit) must still derive a
# machine id: under `set -u` a bare ${USER} aborts the derivation, the sync file
# collapses to the empty-id name "secrets..enc", and every machine then writes
# the same file.
test_export_file_machine_id_survives_unset_user() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1
    local _exp_out
    _exp_out=$( unset USER
                PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file 2>&1 ) || true
    assert_file_not_exists "$meta/secrets..enc" \
        "an unset USER must not collapse the machine id to empty" || return 1
    ls "$meta"/secrets.*.enc >/dev/null 2>&1 \
        || { echo "  FAIL: no per-machine sync file written with USER unset"
             echo "  export output: $_exp_out"; return 1; }
}

test_export_file_skips_rewrite_when_unchanged() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid
    mid=$(_machine_id)
    local f="$meta/secrets.${mid}.enc"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1
    PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1
    assert_file_exists "$f" "first export should create the file" || return 1
    cp "$f" "$TEST_TMPDIR/before.enc"
    # Re-export with an unchanged store: bytes must be identical (no random-salt churn).
    PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1
    if ! cmp -s "$f" "$TEST_TMPDIR/before.enc"; then
        echo "  FAIL: unchanged re-export rewrote the sync file (byte churn)"
        return 1
    fi
}

test_export_file_rewrites_when_changed() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid
    mid=$(_machine_id)
    local f="$meta/secrets.${mid}.enc"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1
    PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1
    cp "$f" "$TEST_TMPDIR/before.enc"
    "$CS_SECRETS_BIN" set api_key "sk_changed" >/dev/null 2>&1
    PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1
    if cmp -s "$f" "$TEST_TMPDIR/before.enc"; then
        echo "  FAIL: changed store did not rewrite the sync file"
        return 1
    fi
    local dec
    dec=$(openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$f" -pass "pass:$CS_SECRETS_PASSWORD" 2>/dev/null)
    assert_output_contains "$dec" "sk_changed" "re-export should contain the updated value" || return 1
}

# --- age recipient tests (real age; skipped where age is not installed) ---

# Point cs-secrets at the real age binary, overriding the "no age" seam setup
# exports. Returns 77 (skipped) where age or age-keygen is not installed.
_use_real_age() {
    local age_bin keygen_bin
    age_bin=$(command -v age 2>/dev/null) || age_bin=""
    keygen_bin=$(command -v age-keygen 2>/dev/null) || keygen_bin=""
    if [ -z "$age_bin" ] || [ -z "$keygen_bin" ]; then
        echo "    SKIP (age and age-keygen are not installed)"
        return 77
    fi
    export CS_AGE_BIN="$age_bin"
}

# Generate a throwaway age identity in the test dir: <name>.key and <name>.pub.
_make_age_identity() {
    local name="$1"
    age-keygen -o "$TEST_TMPDIR/$name.key" 2>/dev/null || return 1
    age-keygen -y "$TEST_TMPDIR/$name.key" > "$TEST_TMPDIR/$name.pub" || return 1
}

# True when the identity file decrypts the sync file to a payload holding the
# expected value. The plaintext never reaches the test output.
_age_decrypts_to() {
    local key="$1" file="$2" expected="$3" plain
    plain=$(age -d -i "$key" < "$file" 2>/dev/null) || return 1
    grep -qF -- "$expected" <<< "$plain"
}

# Codex (batch 1, round 2): the pin list lived at .cs/local/age-trusted, inside
# the checkout. .cs/local is gitignored, but `git add -f` is not, so a push
# carrying attacker.pub plus a pin list naming its fingerprint made a fresh
# clone trust the pusher with no local age add. The machine-local age state
# lives outside the checkout, under ~/.cs-secrets, where nothing git can
# carry reaches it: a planted pin list in the session is never read.
test_export_ignores_a_pin_list_planted_in_the_checkout() {
    _use_real_age || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f out rc=0 attacker_fp
    f="$meta/secrets.$(_machine_id).age"
    _make_age_identity attacker || { echo "  FAIL: could not create a test identity"; return 1; }
    "$CS_SECRETS_BIN" age init >/dev/null 2>&1 || { echo "  FAIL: age init failed"; return 1; }
    mkdir -p "$meta/age-recipients" "$meta/local"
    cp "$TEST_TMPDIR/attacker.pub" "$meta/age-recipients/attacker.pub"
    attacker_fp=$(printf '%s' "$(head -1 "$TEST_TMPDIR/attacker.pub")" | shasum -a 256 | cut -d' ' -f1)
    printf '%s\n' "$attacker_fp" > "$meta/local/age-trusted"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  FAIL: a pin list planted in the checkout was trusted: $out"
        return 1
    fi
    assert_output_contains "$out" "age add .*age-recipients/attacker\\.pub" "the refusal names attacker.pub with its pin command" || return 1
    if [ -s "$f" ]; then
        echo "  FAIL: the refused export wrote the sync file"
        return 1
    fi
}

# Codex (batch 1, round 2): the recipients lock lived in the session's .cs/local
# too, so a password export of a nonempty store to an external path needed a
# writable checkout even though it writes nothing into the session. The lock
# lives beside the other machine-local age state, under ~/.cs-secrets.
test_password_export_to_an_external_path_needs_no_writable_checkout() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local out rc=0
    mkdir -p "$meta"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    chmod 500 "$meta"
    out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file "$TEST_TMPDIR/external.enc" 2>&1) || rc=$?
    chmod 700 "$meta"
    [ "$rc" -eq 0 ] || { echo "  FAIL: a password export to an external path failed on a read-only checkout (rc=$rc): $out"; return 1; }
    assert_file_exists "$TEST_TMPDIR/external.enc" "the external sync file is written" || return 1
    local restored
    restored=$(openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
        -in "$TEST_TMPDIR/external.enc" -pass "pass:$CS_SECRETS_PASSWORD" 2>/dev/null)
    assert_output_contains "$restored" "sk_123" "the external file holds the store" || return 1
}

test_age_export_skips_rewrite_when_nothing_changed() {
    _use_real_age || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f
    f="$meta/secrets.$(_machine_id).age"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: first export failed"; return 1; }
    cp "$f" "$TEST_TMPDIR/before.age"
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: second export failed"; return 1; }
    if ! cmp -s "$f" "$TEST_TMPDIR/before.age"; then
        echo "  FAIL: an export with the same secrets and recipients rewrote the age sync file"
        return 1
    fi
}

# The recipient set's digest sorts the keys with the C locale handed to sort
# through env, so the digest is the same under every bash and locale and the
# shell never changes its own locale for it, which can crash a bash linked
# against libintl in the forked copy the sort runs in.
test_age_recipient_digest_leaves_the_shells_own_locale_alone() {
    _use_real_age || return $?
    local b utf8 out own
    utf8="$(utf8_locale)"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: first export failed"; return 1; }
    for b in $(every_bash); do
        out=$(env ${utf8:+"LC_ALL=$utf8"} "$b" -x "$CS_SECRETS_BIN" export-file 2>"$TEST_TMPDIR/trace") \
            || { echo "  FAIL: $b: export failed"; return 1; }
        assert_eq "No secret changes to export for session: test-session (secrets.$(_machine_id).age is up to date)" \
            "$out" "$b: the recipient set reads as unchanged" || return 1
        own="$(shell_locale_assignments "$TEST_TMPDIR/trace")"
        assert_eq "" "$own" "$b must not assign its own locale during export-file" || return 1
    done
}

test_age_add_reencrypts_an_unchanged_store() {
    _use_real_age || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f
    f="$meta/secrets.$(_machine_id).age"
    _make_age_identity colleague || { echo "  FAIL: could not create a test identity"; return 1; }
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: first export failed"; return 1; }
    assert_file_exists "$f" "first export should write the age sync file" || return 1
    if _age_decrypts_to "$TEST_TMPDIR/colleague.key" "$f" "sk_123"; then
        echo "  FAIL: the colleague decrypted the file before being added (fixture is wrong)"
        return 1
    fi
    "$CS_SECRETS_BIN" age add "$TEST_TMPDIR/colleague.pub" >/dev/null 2>&1 || { echo "  FAIL: age add failed"; return 1; }
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: export after age add failed"; return 1; }
    if ! _age_decrypts_to "$TEST_TMPDIR/colleague.key" "$f" "sk_123"; then
        echo "  FAIL: after age add, the unchanged store was not re-encrypted to the new recipient"
        return 1
    fi
}

test_age_remove_reencrypts_an_unchanged_store() {
    _use_real_age || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f
    f="$meta/secrets.$(_machine_id).age"
    _make_age_identity colleague || { echo "  FAIL: could not create a test identity"; return 1; }
    "$CS_SECRETS_BIN" age init >/dev/null 2>&1 || { echo "  FAIL: age init failed"; return 1; }
    "$CS_SECRETS_BIN" age add "$HOME/.cs-secrets/id_ed25519.pub" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" age add "$TEST_TMPDIR/colleague.pub" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: first export failed"; return 1; }
    # Positive control: the colleague can read the file before the revocation.
    if ! _age_decrypts_to "$TEST_TMPDIR/colleague.key" "$f" "sk_123"; then
        echo "  FAIL: the colleague could not decrypt before removal (fixture is wrong)"
        return 1
    fi
    cp "$f" "$TEST_TMPDIR/before.age"
    "$CS_SECRETS_BIN" age remove colleague >/dev/null 2>&1 || { echo "  FAIL: age remove failed"; return 1; }
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: export after age remove failed"; return 1; }
    if cmp -s "$f" "$TEST_TMPDIR/before.age"; then
        echo "  FAIL: after age remove, the unchanged store was not re-encrypted"
        return 1
    fi
    if _age_decrypts_to "$TEST_TMPDIR/colleague.key" "$f" "sk_123"; then
        echo "  FAIL: the removed recipient still decrypts the re-exported file"
        return 1
    fi
    if ! _age_decrypts_to "$HOME/.cs-secrets/id_ed25519" "$f" "sk_123"; then
        echo "  FAIL: this machine's own key no longer decrypts the re-exported file"
        return 1
    fi
}

# A .pub that lands in .cs/age-recipients/ without a local `age add` (a git
# pull of someone else's push) must not receive the secrets.
test_export_refuses_an_unpinned_pushed_recipient() {
    _use_real_age || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f out rc=0
    f="$meta/secrets.$(_machine_id).age"
    _make_age_identity intruder || { echo "  FAIL: could not create a test identity"; return 1; }
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: first export failed"; return 1; }
    cp "$f" "$TEST_TMPDIR/before.age"
    cp "$TEST_TMPDIR/intruder.pub" "$meta/age-recipients/intruder.pub"
    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  FAIL: export succeeded with an unpinned recipient present: $out"
        return 1
    fi
    assert_output_contains "$out" "intruder\.pub" "the refusal names the unpinned file" || return 1
    assert_output_contains "$out" "age add .*age-recipients/intruder\.pub" "the refusal prints the command that pins it" || return 1
    if ! cmp -s "$f" "$TEST_TMPDIR/before.age"; then
        echo "  FAIL: the refused export rewrote the age sync file"
        return 1
    fi
    if _age_decrypts_to "$TEST_TMPDIR/intruder.key" "$f" "sk_123"; then
        echo "  FAIL: the unpinned recipient decrypts the sync file"
        return 1
    fi
    assert_file_not_exists "$meta/secrets.$(_machine_id).enc" "the refusal must not fall back to a password export" || return 1
}

test_export_encrypts_to_a_recipient_pinned_by_age_add() {
    _use_real_age || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f
    f="$meta/secrets.$(_machine_id).age"
    _make_age_identity colleague || { echo "  FAIL: could not create a test identity"; return 1; }
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: first export failed"; return 1; }
    cp "$TEST_TMPDIR/colleague.pub" "$meta/age-recipients/colleague.pub"
    "$CS_SECRETS_BIN" age add "$meta/age-recipients/colleague.pub" >/dev/null 2>&1 \
        || { echo "  FAIL: age add on the pulled file failed"; return 1; }
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: export after pinning failed"; return 1; }
    if ! _age_decrypts_to "$TEST_TMPDIR/colleague.key" "$f" "sk_123"; then
        echo "  FAIL: the pinned recipient cannot decrypt the export"
        return 1
    fi
}

# A machine that exported before pinning existed (its own sync file is there,
# no pin list): the first export pins the recipients present, says so once,
# and pins nothing that arrives afterwards.
# Codex (batch 1, round 1): the one-time migration keyed trust on the
# existence of this machine's own sync file, a TRACKED file with a predictable
# name. A push adding attacker.pub beside an empty secrets.<user>@<host>.age
# made a fresh clone's first export pin everyone. No automatic pin from
# anything git can carry: only this machine's own public key is pinned by
# content (encrypting to a key whose private half is here trusts nobody new);
# every other recipient needs an `age add` on this machine.
test_export_never_pins_from_a_forged_sync_file() {
    _use_real_age || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f out rc=0
    f="$meta/secrets.$(_machine_id).age"
    _make_age_identity attacker || { echo "  FAIL: could not create a test identity"; return 1; }
    "$CS_SECRETS_BIN" age init >/dev/null 2>&1 || { echo "  FAIL: age init failed"; return 1; }
    mkdir -p "$meta/age-recipients"
    cp "$HOME/.cs-secrets/id_ed25519.pub" "$meta/age-recipients/self.pub"
    cp "$TEST_TMPDIR/attacker.pub" "$meta/age-recipients/attacker.pub"
    # The forged sync file a push can plant: tracked, predictable name, empty.
    : > "$f"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  FAIL: a forged sync file made the first export pin a pushed key: $out"
        return 1
    fi
    assert_output_contains "$out" "age add .*age-recipients/attacker\.pub" "the refusal names attacker.pub with its pin command" || return 1
    assert_output_not_contains "$out" "self\.pub" "this machine's own key is pinned by content, not listed" || return 1
    assert_output_not_contains "$out" "Pinned" "nothing is pinned automatically" || return 1
    if [ -s "$f" ]; then
        echo "  FAIL: the refused export wrote the sync file"
        return 1
    fi
    local attacker_fp
    attacker_fp=$(printf '%s' "$(head -1 "$TEST_TMPDIR/attacker.pub")" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$HOME/.cs-secrets/sessions/test-session/age-trusted" ] && grep -qxF "$attacker_fp" "$HOME/.cs-secrets/sessions/test-session/age-trusted"; then
        echo "  FAIL: attacker.pub is in the pin list"
        return 1
    fi
    # Only an explicit age add on this machine admits the key.
    "$CS_SECRETS_BIN" age add "$meta/age-recipients/attacker.pub" >/dev/null 2>&1 || { echo "  FAIL: age add failed"; return 1; }
    out=$("$CS_SECRETS_BIN" export-file 2>&1) || { echo "  FAIL: export after the explicit pin failed: $out"; return 1; }
    if ! _age_decrypts_to "$TEST_TMPDIR/attacker.key" "$f" "sk_123"; then
        echo "  FAIL: an explicitly pinned recipient cannot decrypt the export"
        return 1
    fi
}

# A fresh clone (or a wiped .cs/local) has recipients but no sync file of this
# machine's own: nothing is pinned for it, the export lists every unpinned file,
# and an `age add` pins only the file it names.
test_export_on_a_fresh_clone_pins_nothing() {
    _use_real_age || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f out rc=0
    f="$meta/secrets.$(_machine_id).age"
    _make_age_identity alice || { echo "  FAIL: could not create a test identity"; return 1; }
    _make_age_identity bob || { echo "  FAIL: could not create a test identity"; return 1; }
    mkdir -p "$meta/age-recipients"
    cp "$TEST_TMPDIR/alice.pub" "$meta/age-recipients/alice.pub"
    cp "$TEST_TMPDIR/bob.pub" "$meta/age-recipients/bob.pub"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  FAIL: a fresh clone exported to recipients it never pinned: $out"
        return 1
    fi
    assert_output_contains "$out" "age add .*age-recipients/alice\.pub" "the refusal names alice.pub with its pin command" || return 1
    assert_output_contains "$out" "age add .*age-recipients/bob\.pub" "the refusal names bob.pub with its pin command" || return 1
    assert_output_not_contains "$out" "Pinned" "a fresh clone pins nothing by itself" || return 1
    assert_file_not_exists "$f" "the refused export writes no age sync file" || return 1
    assert_file_not_exists "$meta/secrets.$(_machine_id).enc" "the refusal must not fall back to a password export" || return 1
    "$CS_SECRETS_BIN" age add "$meta/age-recipients/alice.pub" >/dev/null 2>&1 || { echo "  FAIL: age add failed"; return 1; }
    rc=0
    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  FAIL: age add on one file pinned the other as well: $out"
        return 1
    fi
    assert_output_contains "$out" "bob\.pub" "the refusal still names bob.pub" || return 1
    assert_output_not_contains "$out" "alice\.pub" "alice.pub is pinned now" || return 1
}

# Removing a recipient also drops its pin, so a copy of the same key pushed back
# into the directory is refused rather than silently trusted again.
test_age_remove_drops_the_pin() {
    _use_real_age || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local out rc=0
    _make_age_identity colleague || { echo "  FAIL: could not create a test identity"; return 1; }
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: first export failed"; return 1; }
    "$CS_SECRETS_BIN" age add "$TEST_TMPDIR/colleague.pub" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" age remove colleague >/dev/null 2>&1 || return 1
    cp "$TEST_TMPDIR/colleague.pub" "$meta/age-recipients/colleague.pub"
    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  FAIL: a removed recipient's key pushed back was trusted again: $out"
        return 1
    fi
    assert_output_contains "$out" "colleague\.pub" "the refusal names the re-pushed file" || return 1
}

_use_real_ssh_keygen() {
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        echo "    SKIP (ssh-keygen is not installed)"
        return 77
    fi
}
_make_ssh_identity() {  # name -> $TEST_TMPDIR/<name>.ssh (+ .pub)
    ssh-keygen -q -t ed25519 -N '' -C "$1@example.com" -f "$TEST_TMPDIR/$1.ssh" </dev/null || return 1
}

# A recipient may be an ssh-ed25519 key: age encrypts to it, and it is the key
# a peer signs its sync file with.
test_age_add_takes_an_ssh_ed25519_key_file() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f; f="$meta/secrets.$(_machine_id).age"
    local out rc=0 key_type key_body key_comment
    _make_ssh_identity colleague || { echo "  FAIL: could not create a test ssh identity"; return 1; }
    read -r key_type key_body key_comment < "$TEST_TMPDIR/colleague.ssh.pub"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: first export failed"; return 1; }

    out=$("$CS_SECRETS_BIN" age add "$TEST_TMPDIR/colleague.ssh.pub" 2>&1) || rc=$?
    assert_eq "0" "$rc" "age add accepts the key file: $out" || return 1
    assert_eq "$key_type $key_body" "$(cat "$meta/age-recipients/colleague.ssh.pub")" \
        "the recipient file holds the key without its comment" || return 1
    rc=0
    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the export encrypts to it: $out" || return 1
    _age_decrypts_to "$TEST_TMPDIR/colleague.ssh" "$f" "sk_123" \
        || { echo "  FAIL: the ssh identity cannot decrypt the sync file"; return 1; }
}

test_age_add_takes_a_raw_ssh_ed25519_key() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f; f="$meta/secrets.$(_machine_id).age"
    local out rc=0 key_type key_body key_comment added
    _make_ssh_identity colleague || { echo "  FAIL: could not create a test ssh identity"; return 1; }
    read -r key_type key_body key_comment < "$TEST_TMPDIR/colleague.ssh.pub"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1

    out=$("$CS_SECRETS_BIN" age add "$key_type $key_body $key_comment" 2>&1) || rc=$?
    assert_eq "0" "$rc" "age add accepts the quoted key: $out" || return 1
    added=$(cat "$meta"/age-recipients/recipient-*.pub)
    assert_eq "$key_type $key_body" "$added" "the recipient file holds the key without its comment" || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: export failed"; return 1; }
    _age_decrypts_to "$TEST_TMPDIR/colleague.ssh" "$f" "sk_123" \
        || { echo "  FAIL: the ssh identity cannot decrypt the sync file"; return 1; }
}

# Only the two key forms are recipients. Anything else is refused before a
# file or a pin is written.
test_age_add_refuses_what_is_not_a_key() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local refusal="Error: Invalid public key. Must be a file, an age1... key or a quoted \"ssh-ed25519 <key>\""
    local candidate out rc
    printf 'not a key\n' > "$TEST_TMPDIR/junk.pub"
    for candidate in "hello" "ssh-ed25519" "ssh-ed25519 " "ssh-ed25519 not*base64" "ssh-rsa AAAAB3NzaC1yc2E" "$TEST_TMPDIR/junk.pub"; do
        rc=0
        out=$("$CS_SECRETS_BIN" age add "$candidate" 2>&1) || rc=$?
        assert_eq "1" "$rc" "age add exits 1 for '$candidate'" || return 1
        assert_eq "$refusal" "$out" "the refusal names the accepted forms for '$candidate'" || return 1
        assert_eq "" "$(ls "$meta/age-recipients" 2>/dev/null)" "no recipient file is written for '$candidate'" || return 1
        assert_not_exists "$HOME/.cs-secrets/sessions/test-session/age-trusted" "nothing is pinned for '$candidate'" || return 1
    done
}

# A recipient is named after its key file, so two collaborators' keys can both
# arrive as laptop.pub. The second `age add` refuses to replace the first
# recipient, naming the file and both keys: replacing it would leave the first
# collaborator unable to decrypt. Adding the same key again changes nothing.
test_age_add_refuses_a_different_key_under_a_recipient_name_in_use() {
    _use_real_age || return $?
    local dir="$CS_SESSIONS_ROOT/test-session/.cs/age-recipients" out rc=0 k1 k2 fp2
    mkdir -p "$TEST_TMPDIR/first" "$TEST_TMPDIR/second"
    age-keygen 2>/dev/null | age-keygen -y > "$TEST_TMPDIR/first/laptop.pub" || { echo "  FAIL: fixture: age-keygen"; return 1; }
    age-keygen 2>/dev/null | age-keygen -y > "$TEST_TMPDIR/second/laptop.pub" || { echo "  FAIL: fixture: age-keygen"; return 1; }
    k1=$(cat "$TEST_TMPDIR/first/laptop.pub"); k2=$(cat "$TEST_TMPDIR/second/laptop.pub")
    fp2=$(printf '%s' "$k2" | shasum -a 256 | cut -d' ' -f1)
    "$CS_SECRETS_BIN" age add "$TEST_TMPDIR/first/laptop.pub" >/dev/null 2>&1 || { echo "  FAIL: fixture: the first age add failed"; return 1; }

    out=$("$CS_SECRETS_BIN" age add "$TEST_TMPDIR/second/laptop.pub" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a second key under the name laptop is refused" || return 1
    assert_eq "Error: refusing to replace recipient laptop: $dir/laptop.pub holds $k1, not the key given, $k2. Give the key file another name, or run 'cs -secrets age remove laptop' first." \
        "$out" "the refusal names the file and both keys" || return 1
    assert_eq "$k1" "$(cat "$dir/laptop.pub")" "laptop.pub still holds the first key" || return 1
    if grep -qxF "$fp2" "$HOME/.cs-secrets/sessions/test-session/age-trusted"; then
        echo "  FAIL: the refused key was pinned"
        return 1
    fi

    rc=0
    out=$("$CS_SECRETS_BIN" age add "$TEST_TMPDIR/first/laptop.pub" 2>&1) || rc=$?
    assert_eq "0" "$rc" "adding the same key again succeeds" || return 1
    assert_eq "Added recipient: laptop
Public key: $k1" "$out" "adding the same key again says what it holds" || return 1
    assert_eq "laptop.pub" "$(ls "$dir")" "no second recipient file is written" || return 1
}

# `age add` never offers to download age: with no age binary it fails at once,
# pointing at `age init`, which is where the download is offered. It prompts
# for nothing, reaches for no network, and writes no recipient, no pin and no
# machine key. The curl on PATH logs a call and fails.
test_age_add_without_age_points_at_age_init() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs" netbin="$TEST_TMPDIR/net-bin" out rc=0
    mkdir -p "$netbin"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$TEST_TMPDIR/curl-argv" > "$netbin/curl"
    chmod +x "$netbin/curl"
    out=$(PATH="$netbin:$PATH" "$CS_SECRETS_BIN" age add age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq 2>&1) || rc=$?
    assert_eq "1" "$rc" "age add exits 1 with no age binary" || return 1
    assert_eq "Error: age binary not found. Run: cs -secrets age init" "$out" "the refusal points at age init and offers no download" || return 1
    assert_not_exists "$TEST_TMPDIR/curl-argv" "age add reaches for no network" || return 1
    assert_eq "" "$(ls "$meta/age-recipients" 2>/dev/null)" "no recipient file is written" || return 1
    assert_not_exists "$HOME/.cs-secrets/sessions/test-session/age-trusted" "nothing is pinned" || return 1
    assert_not_exists "$HOME/.cs-secrets/id_ed25519" "no machine key is made" || return 1
}

_stage_machine_ssh_key() {  # this machine's ssh key under the test HOME
    mkdir -p "$HOME/.cs-secrets" && chmod 700 "$HOME/.cs-secrets" || return 1
    ssh-keygen -q -t ed25519 -N '' -C "test@example.com" -f "$HOME/.cs-secrets/id_ed25519" </dev/null || return 1
}

# A peer encrypts to whichever of this machine's keys it has pinned: the ssh
# key, or the age key from before the ssh key existed. Both stay readable.
test_import_file_reads_a_file_encrypted_to_this_machines_ssh_key() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _stage_machine_ssh_key || { echo "  FAIL: could not stage the machine ssh key"; return 1; }
    printf '%s\n' '{"from_peer":"vp"}' \
        | age -r "$(cat "$HOME/.cs-secrets/id_ed25519.pub")" -o "$meta/secrets.peer@example.age" \
        || { echo "  FAIL: fixture: age could not encrypt to the ssh key"; return 1; }

    # Made by hand, so unsigned: this test is about which key decrypts.
    local out rc=0
    out=$("$CS_SECRETS_BIN" import-file --allow-unsigned 2>&1) || rc=$?
    assert_eq "vp" "$("$CS_SECRETS_BIN" get from_peer 2>&1)" "the secret is imported (import said: $rc $out)" || return 1
}

test_import_file_still_reads_a_file_encrypted_to_the_earlier_age_key() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _stage_machine_ssh_key || { echo "  FAIL: could not stage the machine ssh key"; return 1; }
    age-keygen -o "$HOME/.cs-secrets/age.key" 2>/dev/null || { echo "  FAIL: fixture: age-keygen failed"; return 1; }
    printf '%s\n' '{"from_before":"vb"}' \
        | age -r "$(age-keygen -y "$HOME/.cs-secrets/age.key")" -o "$meta/secrets.peer@example.age" \
        || { echo "  FAIL: fixture: age could not encrypt to the age key"; return 1; }

    local out rc=0
    out=$("$CS_SECRETS_BIN" import-file --allow-unsigned 2>&1) || rc=$?
    assert_eq "vb" "$("$CS_SECRETS_BIN" get from_before 2>&1)" "the secret is imported (import said: $rc $out)" || return 1
}

# This machine has one key, an ssh-ed25519 pair cs keeps under ~/.cs-secrets:
# never the user's own ~/.ssh keys, and no passphrase, since exports run
# unattended.
test_age_init_creates_this_machines_ssh_key() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local out rc=0 key_type key_body key_comment
    out=$("$CS_SECRETS_BIN" age init 2>&1) || rc=$?
    assert_eq "0" "$rc" "age init exits 0: $out" || return 1
    assert_file_exists "$HOME/.cs-secrets/id_ed25519" "the private key exists" || return 1
    assert_eq "600" "$(_file_mode "$HOME/.cs-secrets/id_ed25519")" "the private key is owner-only" || return 1
    assert_not_exists "$HOME/.cs-secrets/age.key" "no age key is created" || return 1
    assert_not_exists "$HOME/.ssh" "the user's own ssh directory is untouched" || return 1
    assert_file_exists "$HOME/.cs-secrets/id_ed25519.pub" "the public key exists" || return 1
    read -r key_type key_body key_comment < "$HOME/.cs-secrets/id_ed25519.pub"
    assert_eq "ssh-ed25519" "$key_type" "the key is an ed25519 key" || return 1
    assert_eq "$key_type $key_body" "$("$CS_SECRETS_BIN" age pubkey 2>&1)" "age pubkey prints the key without its comment" || return 1
    printf 'x' > "$TEST_TMPDIR/payload"
    ssh-keygen -q -Y sign -f "$HOME/.cs-secrets/id_ed25519" -n probe "$TEST_TMPDIR/payload" </dev/null 2>/dev/null \
        || { echo "  FAIL: the key signs without asking for a passphrase"; return 1; }
}

test_age_init_names_a_missing_ssh_keygen() {
    _use_real_age || return $?
    local bindir="$TEST_TMPDIR/no-ssh-keygen" out rc=0
    link_path_without "$bindir" 'ssh-keygen'
    out=$(PATH="$bindir" "$CS_SECRETS_BIN" age init 2>&1) || rc=$?
    assert_eq "1" "$rc" "age init exits 1" || return 1
    assert_eq "Error: ssh-keygen not found. cs keeps this machine's key as an ssh-ed25519 pair and needs OpenSSH 8.0 or later to create it and to sign with it." \
        "$out" "the refusal names ssh-keygen" || return 1
    assert_not_exists "$HOME/.cs-secrets/id_ed25519" "no key is created" || return 1
    assert_not_exists "$HOME/.cs-secrets/age.key" "no age key is created instead" || return 1
}

test_first_export_makes_this_machines_ssh_key_the_recipient() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f; f="$meta/secrets.$(_machine_id).age"
    local out rc=0 key_type key_body key_comment
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the first export exits 0: $out" || return 1
    assert_file_exists "$HOME/.cs-secrets/id_ed25519.pub" "this machine's public key exists" || return 1
    read -r key_type key_body key_comment < "$HOME/.cs-secrets/id_ed25519.pub"
    assert_eq "$key_type $key_body" "$(cat "$meta/age-recipients/$(_machine_id).pub")" \
        "this machine's recipient file holds its ssh key" || return 1
    _age_decrypts_to "$HOME/.cs-secrets/id_ed25519" "$f" "sk_123" \
        || { echo "  FAIL: this machine's ssh key cannot decrypt its own sync file"; return 1; }
    assert_not_exists "$HOME/.cs-secrets/age.key" "no age key is created" || return 1
}

# Machines upgrade one at a time, so one sync file is encrypted to age keys
# and ssh keys together.
test_export_encrypts_to_age_and_ssh_recipients_together() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f; f="$meta/secrets.$(_machine_id).age"
    _make_age_identity older || { echo "  FAIL: could not create a test age identity"; return 1; }
    _make_ssh_identity newer || { echo "  FAIL: could not create a test ssh identity"; return 1; }
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: first export failed"; return 1; }
    "$CS_SECRETS_BIN" age add "$TEST_TMPDIR/older.pub" >/dev/null 2>&1 || { echo "  FAIL: age add of the age key failed"; return 1; }
    "$CS_SECRETS_BIN" age add "$TEST_TMPDIR/newer.ssh.pub" >/dev/null 2>&1 || { echo "  FAIL: age add of the ssh key failed"; return 1; }
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: export to both failed"; return 1; }
    _age_decrypts_to "$TEST_TMPDIR/older.key" "$f" "sk_123" || { echo "  FAIL: the age recipient cannot decrypt"; return 1; }
    _age_decrypts_to "$TEST_TMPDIR/newer.ssh" "$f" "sk_123" || { echo "  FAIL: the ssh recipient cannot decrypt"; return 1; }
    _age_decrypts_to "$HOME/.cs-secrets/id_ed25519" "$f" "sk_123" || { echo "  FAIL: this machine cannot decrypt its own file"; return 1; }
}

# A session the way a cs from before the ssh key left it on this machine: an
# age key pair, this machine's recipient file holding the age key, that key
# pinned, a secret in the store.
_stage_session_from_before_the_ssh_key() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs" age_pub
    mkdir -p "$HOME/.cs-secrets/sessions/test-session" "$meta/age-recipients" || return 1
    chmod 700 "$HOME/.cs-secrets"
    age-keygen -o "$HOME/.cs-secrets/age.key" 2>/dev/null || return 1
    age_pub=$(age-keygen -y "$HOME/.cs-secrets/age.key") || return 1
    printf '%s\n' "$age_pub" > "$HOME/.cs-secrets/age.pub"
    printf '%s\n' "$age_pub" > "$meta/age-recipients/$(_machine_id).pub"
    printf '%s' "$age_pub" | shasum -a 256 | cut -d' ' -f1 > "$HOME/.cs-secrets/sessions/test-session/age-trusted"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
}

# The first export after the upgrade moves this machine to its ssh key: its
# recipient file changes, the sync file is encrypted to the new key, and a
# peer that pinned the old key is told to pin the new one before it exports
# again.
test_export_switches_this_machine_to_its_ssh_key() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid; mid=$(_machine_id)
    local f="$meta/secrets.$mid.age" peer_home="$TEST_TMPDIR/peer-home"
    local out rc=0 key_type key_body key_comment
    _stage_session_from_before_the_ssh_key || { echo "  FAIL: could not stage the earlier session"; return 1; }
    # The peer is another machine (its own user name, so its own recipient
    # file). It pinned this machine's age key while that was the recipient,
    # and this machine pinned the peer's key in turn.
    mkdir -p "$peer_home"
    USER=peer HOME="$peer_home" "$CS_SECRETS_BIN" age add "$meta/age-recipients/$mid.pub" >/dev/null 2>&1 \
        || { echo "  FAIL: fixture: the peer could not pin the age key"; return 1; }
    USER=peer HOME="$peer_home" "$CS_SECRETS_BIN" set peer_key "pv" >/dev/null 2>&1 || return 1
    USER=peer HOME="$peer_home" "$CS_SECRETS_BIN" export-file "$TEST_TMPDIR/peer-before.age" >/dev/null 2>&1 \
        || { echo "  FAIL: fixture: the peer cannot export before the switch"; return 1; }
    printf '%s' "$(cat "$meta"/age-recipients/peer@*.pub)" | shasum -a 256 | cut -d' ' -f1 \
        >> "$HOME/.cs-secrets/sessions/test-session/age-trusted"

    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the export exits 0: $out" || return 1
    assert_file_exists "$HOME/.cs-secrets/id_ed25519.pub" "this machine has an ssh key" || return 1
    read -r key_type key_body key_comment < "$HOME/.cs-secrets/id_ed25519.pub"
    assert_eq "$key_type $key_body" "$(cat "$meta/age-recipients/$mid.pub")" \
        "this machine's recipient file holds its ssh key" || return 1
    _age_decrypts_to "$HOME/.cs-secrets/id_ed25519" "$f" "sk_123" \
        || { echo "  FAIL: the ssh key cannot decrypt the sync file"; return 1; }
    if _age_decrypts_to "$HOME/.cs-secrets/age.key" "$f" "sk_123"; then
        echo "  FAIL: the sync file is still encrypted to the earlier age key"
        return 1
    fi
    assert_file_exists "$HOME/.cs-secrets/age.key" "the earlier age key is kept" || return 1

    rc=0
    out=$(USER=peer HOME="$peer_home" "$CS_SECRETS_BIN" export-file "$TEST_TMPDIR/peer-after.age" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the peer's next export is refused" || return 1
    assert_output_contains "$out" "age add .*age-recipients/$mid\.pub" "the refusal gives the peer the pin command" || return 1
    assert_file_not_exists "$TEST_TMPDIR/peer-after.age" "the refused export writes nothing" || return 1
}

# With age on the machine an export encrypts to keys, and it needs ssh-keygen
# for this machine's key. Without it the export stops and says so; it does not
# fall back to a password file.
test_first_export_without_ssh_keygen_refuses() {
    _use_real_age || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local bindir="$TEST_TMPDIR/no-ssh-keygen" out rc=0
    link_path_without "$bindir" 'ssh-keygen'
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    out=$(PATH="$bindir" "$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    assert_eq "1" "$rc" "the export exits 1" || return 1
    assert_eq "Error: ssh-keygen not found. cs keeps this machine's key as an ssh-ed25519 pair and needs OpenSSH 8.0 or later to create it and to sign with it." \
        "$out" "the refusal names ssh-keygen" || return 1
    assert_eq "" "$(find "$meta" -name 'secrets.*')" "no sync file of either kind is written" || return 1
    assert_eq "" "$(find "$meta" -name '*.pub')" "no recipient file is written" || return 1
}

# True when <file>.sig is this key's signature over the file in the session's
# namespace. Checked with ssh-keygen directly, not through cs.
_sync_file_is_signed_by() {  # public key file, sync file, session
    local allowed="$TEST_TMPDIR/allowed.$$" key_type key_body key_comment
    read -r key_type key_body key_comment < "$1"
    printf 'cs %s %s\n' "$key_type" "$key_body" > "$allowed"
    ssh-keygen -Y verify -f "$allowed" -I cs -n "cs-secrets@$3" -s "$2.sig" < "$2" >/dev/null 2>&1
}

# age says who may read a sync file, not who wrote it: anyone who can push can
# encrypt to a tracked public key. The export signs the ciphertext with this
# machine's key, in a namespace that names the session.
test_export_signs_the_sync_file() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f; f="$meta/secrets.$(_machine_id).age"
    local out rc=0
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the export exits 0: $out" || return 1
    assert_file_exists "$f.sig" "the signature sits beside the sync file" || return 1
    _sync_file_is_signed_by "$HOME/.cs-secrets/id_ed25519.pub" "$f" test-session \
        || { echo "  FAIL: the signature does not verify with this machine's key"; return 1; }
    if _sync_file_is_signed_by "$HOME/.cs-secrets/id_ed25519.pub" "$f" other-session; then
        echo "  FAIL: the signature verifies for another session"
        return 1
    fi
}

# A stop between the two renames leaves a new sync file beside an old
# signature, or none. The next export puts a current signature back although
# no secret changed.
test_export_replaces_a_signature_that_does_not_verify() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f; f="$meta/secrets.$(_machine_id).age"
    local out rc
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: first export failed"; return 1; }

    rm "$f.sig"
    rc=0
    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the export after a lost signature exits 0: $out" || return 1
    _sync_file_is_signed_by "$HOME/.cs-secrets/id_ed25519.pub" "$f" test-session \
        || { echo "  FAIL: a lost signature was not written again: $out"; return 1; }

    printf 'an earlier ciphertext' \
        | ssh-keygen -Y sign -f "$HOME/.cs-secrets/id_ed25519" -n "cs-secrets@test-session" > "$f.sig" 2>/dev/null \
        || { echo "  FAIL: fixture: could not make a stale signature"; return 1; }
    rc=0
    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the export after a stale signature exits 0: $out" || return 1
    _sync_file_is_signed_by "$HOME/.cs-secrets/id_ed25519.pub" "$f" test-session \
        || { echo "  FAIL: a stale signature was not replaced: $out"; return 1; }
    assert_eq "sk_123" "$(age -d -i "$HOME/.cs-secrets/id_ed25519" < "$f" | jq -r .api_key)" "the secret is still the same" || return 1
}

# A peer checks a sync file's signature against the public keys in
# .cs/age-recipients, so the machine that signs has to be in there. Joining a
# session that already has recipients adds this machine's key on its first
# export.
test_export_adds_this_machine_to_a_session_that_has_recipients() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid; mid=$(_machine_id)
    local f="$meta/secrets.$mid.age" out rc=0 key_type key_body key_comment
    _make_age_identity colleague || { echo "  FAIL: could not create a test identity"; return 1; }
    "$CS_SECRETS_BIN" age add "$TEST_TMPDIR/colleague.pub" >/dev/null 2>&1 || { echo "  FAIL: fixture: age add failed"; return 1; }
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1

    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the export exits 0: $out" || return 1
    assert_file_exists "$HOME/.cs-secrets/id_ed25519.pub" "this machine has a key" || return 1
    read -r key_type key_body key_comment < "$HOME/.cs-secrets/id_ed25519.pub"
    assert_file_exists "$meta/age-recipients/$mid.pub" "this machine has a recipient file" || return 1
    assert_eq "$key_type $key_body" "$(cat "$meta/age-recipients/$mid.pub")" "it holds this machine's key" || return 1
    _age_decrypts_to "$HOME/.cs-secrets/id_ed25519" "$f" "sk_123" || { echo "  FAIL: this machine cannot decrypt its own file"; return 1; }
    _age_decrypts_to "$TEST_TMPDIR/colleague.key" "$f" "sk_123" || { echo "  FAIL: the colleague cannot decrypt"; return 1; }
    _sync_file_is_signed_by "$meta/age-recipients/$mid.pub" "$f" test-session \
        || { echo "  FAIL: the signature does not verify with the published key"; return 1; }
}

# The file name this machine would publish under can already hold someone
# else's key: two machines with one user and host name, or a key pair made
# anew. cs does not replace a key it cannot account for.
test_export_refuses_when_this_machines_recipient_file_holds_another_key() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid; mid=$(_machine_id)
    local out rc=0 before
    _make_ssh_identity other || { echo "  FAIL: could not create a test ssh identity"; return 1; }
    cp "$TEST_TMPDIR/other.ssh.pub" "$TEST_TMPDIR/$mid.pub"
    "$CS_SECRETS_BIN" age add "$TEST_TMPDIR/$mid.pub" >/dev/null 2>&1 || { echo "  FAIL: fixture: age add failed"; return 1; }
    before=$(cat "$meta/age-recipients/$mid.pub")
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1

    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    assert_eq "1" "$rc" "the export exits 1" || return 1
    assert_eq "Error: $meta/age-recipients/$mid.pub holds a key that is not this machine's. Remove it with 'cs -secrets age remove $mid', or publish this machine's key under another name with 'cs -secrets age add <a copy of $HOME/.cs-secrets/id_ed25519.pub>'." \
        "$out" "the refusal names the file and both ways out" || return 1
    assert_eq "$before" "$(cat "$meta/age-recipients/$mid.pub")" "the file is left as it was" || return 1
    assert_eq "" "$(find "$meta" -name 'secrets.*')" "no sync file is written" || return 1
}

# An export that has nothing new to say leaves the file and its signature
# byte for byte as they were.
test_export_leaves_a_current_signed_file_alone() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f; f="$meta/secrets.$(_machine_id).age"
    local out rc=0
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: first export failed"; return 1; }
    cp "$f" "$TEST_TMPDIR/before.age"
    cp "$f.sig" "$TEST_TMPDIR/before.sig"
    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the second export exits 0" || return 1
    assert_eq "No secret changes to export for session: test-session (secrets.$(_machine_id).age is up to date)" "$out" \
        "it reports nothing to export" || return 1
    cmp -s "$f" "$TEST_TMPDIR/before.age" || { echo "  FAIL: the sync file was rewritten"; return 1; }
    cmp -s "$f.sig" "$TEST_TMPDIR/before.sig" || { echo "  FAIL: the signature was rewritten"; return 1; }
}

# Signing needs ssh-keygen on every export, not only the first.
test_later_export_without_ssh_keygen_refuses_and_keeps_the_signed_file() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f; f="$meta/secrets.$(_machine_id).age"
    local bindir="$TEST_TMPDIR/no-ssh-keygen" out rc=0
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: first export failed"; return 1; }
    cp "$f" "$TEST_TMPDIR/before.age"
    cp "$f.sig" "$TEST_TMPDIR/before.sig"
    "$CS_SECRETS_BIN" set api_key "sk_456" >/dev/null 2>&1 || return 1
    link_path_without "$bindir" 'ssh-keygen'
    out=$(PATH="$bindir" "$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    assert_eq "1" "$rc" "the export exits 1" || return 1
    assert_eq "Error: ssh-keygen not found. cs keeps this machine's key as an ssh-ed25519 pair and needs OpenSSH 8.0 or later to create it and to sign with it." \
        "$out" "the refusal names ssh-keygen" || return 1
    cmp -s "$f" "$TEST_TMPDIR/before.age" || { echo "  FAIL: the sync file was changed"; return 1; }
    cmp -s "$f.sig" "$TEST_TMPDIR/before.sig" || { echo "  FAIL: the signature was changed"; return 1; }
    assert_eq "" "$(find "$meta" -name '.secrets.*')" "no temp file is left" || return 1
    assert_eq "" "$(find "$meta" -name '*.enc')" "no password file is written instead" || return 1
}

test_export_to_a_named_file_signs_beside_it() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local named="$TEST_TMPDIR/out/named.age"
    mkdir -p "$TEST_TMPDIR/out"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file "$named" >/dev/null 2>&1 || { echo "  FAIL: export to a named file failed"; return 1; }
    _sync_file_is_signed_by "$HOME/.cs-secrets/id_ed25519.pub" "$named" test-session \
        || { echo "  FAIL: the named file has no verifying signature beside it"; return 1; }
    assert_eq "" "$(find "$meta" -name 'secrets.*')" "nothing is written at the default place" || return 1
}

# A password file's trust is the password: whoever holds it can write one. It
# carries no signature.
test_password_export_writes_no_signature() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: password export failed"; return 1; }
    assert_file_exists "$meta/secrets.$(_machine_id).enc" "the password file is written" || return 1
    assert_eq "" "$(find "$meta" -name '*.sig')" "no signature is written" || return 1
    assert_not_exists "$HOME/.cs-secrets/id_ed25519" "no machine key is made for a password export" || return 1
}

# A directory where the signature goes would take the new signature inside it
# and leave the sync file with none: the export stops before it writes.
test_export_refuses_a_directory_where_the_signature_goes() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f; f="$meta/secrets.$(_machine_id).age"
    local out rc=0
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: first export failed"; return 1; }
    cp "$f" "$TEST_TMPDIR/before.age"
    rm "$f.sig"
    mkdir "$f.sig"
    "$CS_SECRETS_BIN" set api_key "sk_456" >/dev/null 2>&1 || return 1
    out=$("$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    assert_eq "1" "$rc" "the export exits 1" || return 1
    assert_eq "Error: Aborting export for session 'test-session': $f.sig is a directory" "$out" "the refusal names the path" || return 1
    cmp -s "$f" "$TEST_TMPDIR/before.age" || { echo "  FAIL: the sync file was changed"; return 1; }
    assert_eq "" "$(find "$meta" -name '.secrets.*')" "no temp file is left" || return 1
    assert_eq "" "$(find "$f.sig" -mindepth 1)" "nothing is written into the directory" || return 1
}

# ---------------------------------------------------------------------------
# Signed sync files on import. age only says who may read a file: anyone who
# can push to the session's repository can encrypt one to a tracked public
# key. An import takes an age file only when its signature was made by a key
# a recipient file holds and this machine has pinned.
# ---------------------------------------------------------------------------

# Another machine in the session, with its own HOME and user name. It pins
# this machine's key, stores one secret and exports: the session then holds
# secrets.peer@<host>.age, its signature and the peer's recipient file.
_peer_exports() {  # secret name, value
    local peer_home="$TEST_TMPDIR/peer-home" own_pubkey="$HOME/.cs-secrets/id_ed25519.pub"
    mkdir -p "$peer_home"
    "$CS_SECRETS_BIN" age init >/dev/null 2>&1 || return 1
    USER=peer HOME="$peer_home" "$CS_SECRETS_BIN" age add "$own_pubkey" >/dev/null 2>&1 || return 1
    USER=peer HOME="$peer_home" "$CS_SECRETS_BIN" set "$1" "$2" >/dev/null 2>&1 || return 1
    USER=peer HOME="$peer_home" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || return 1
}
_peer_sync_file() {
    printf '%s' "$CS_SESSIONS_ROOT"/test-session/.cs/secrets.peer@*.age
}
_peer_recipient_file() {
    printf '%s' "$CS_SESSIONS_ROOT"/test-session/.cs/age-recipients/peer@*.pub
}
# A sync file someone who can push made by hand: encrypted to this machine's
# key under the given file name, with no signature.
_plant_unsigned_sync_file() {  # file name, json
    "$CS_SECRETS_BIN" age init >/dev/null 2>&1 || return 1
    printf '%s\n' "$2" | age -r "$(cat "$HOME/.cs-secrets/id_ed25519.pub")" \
        -o "$CS_SESSIONS_ROOT/test-session/.cs/$1" || return 1
}

test_import_file_takes_a_file_signed_by_a_pinned_peer() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local out rc=0
    _peer_exports from_peer "vp" || { echo "  FAIL: fixture: the peer could not export"; return 1; }
    "$CS_SECRETS_BIN" age add "$(_peer_recipient_file)" >/dev/null 2>&1 || { echo "  FAIL: fixture: could not pin the peer"; return 1; }
    out=$("$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the import exits 0: $out" || return 1
    assert_eq "Imported 1 secret(s) from 1 sync file(s)." "$out" "it reports the one file" || return 1
    assert_eq "vp" "$("$CS_SECRETS_BIN" get from_peer 2>&1)" "the peer's secret is imported" || return 1
}

test_import_file_skips_an_unsigned_age_file() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local mode out rc
    _plant_unsigned_sync_file "secrets.aaa@example.age" '{"planted":"vx"}' || { echo "  FAIL: fixture: could not plant the file"; return 1; }
    for mode in "" --replace; do
        rc=0
        # shellcheck disable=SC2086  # an empty mode is no argument
        out=$("$CS_SECRETS_BIN" import-file $mode 2>&1) || rc=$?
        assert_eq "0" "$rc" "the import exits 0 (mode '$mode')" || return 1
        assert_output_contains "$out" "^Skipped secrets\.aaa@example\.age: it has no signature\. Sync files written before cs signed them have none; import one you trust with --allow-unsigned\.$" \
            "the skip names the file and the flag (mode '$mode')" || return 1
        _assert_secret_absent planted "nothing from the file is stored (mode '$mode')" || return 1
    done
}

# A file under this machine's own name is no more trusted than any other: the
# name is a string anyone can write.
test_import_file_skips_an_unsigned_file_under_this_machines_name() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local out rc=0
    "$CS_SECRETS_BIN" set api_key "vlocal" >/dev/null 2>&1 || return 1
    _plant_unsigned_sync_file "secrets.$(_machine_id).age" '{"api_key":"vswapped"}' || { echo "  FAIL: fixture: could not plant the file"; return 1; }
    out=$("$CS_SECRETS_BIN" import-file --replace 2>&1) || rc=$?
    assert_eq "0" "$rc" "the import exits 0" || return 1
    assert_output_contains "$out" "^Skipped secrets\.$(_machine_id)\.age: it has no signature" "the skip names the file" || return 1
    assert_eq "vlocal" "$("$CS_SECRETS_BIN" get api_key 2>&1)" "the stored secret is not replaced" || return 1
}

test_import_file_skips_a_file_signed_by_an_unpinned_key() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local out rc=0 peer_pub peer_file
    _peer_exports from_peer "vp" || { echo "  FAIL: fixture: the peer could not export"; return 1; }
    peer_pub=$(_peer_recipient_file)
    peer_file=$(_peer_sync_file)
    out=$("$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the import exits 0" || return 1
    assert_output_contains "$out" "^Skipped $(basename "$peer_file"): it is signed by $(basename "$peer_pub"), a key this machine has not pinned\. If you trust it: cs -secrets --session test-session age add " \
        "the skip names the signer's file and the pin command" || return 1
    _assert_secret_absent from_peer "nothing from the file is stored" || return 1
}

# A signature by a key no recipient file holds says nothing about who wrote
# the file, however valid it is.
test_import_file_skips_a_file_signed_by_a_key_outside_the_session() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f="$meta/secrets.aaa@example.age" out rc=0
    _make_ssh_identity stranger || return 1
    # This machine has exported, so the session holds a pinned key to check
    # signatures against: the stranger's must fail that check, not find it empty.
    "$CS_SECRETS_BIN" set local_key "vlocal" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 || { echo "  FAIL: fixture: export failed"; return 1; }
    _plant_unsigned_sync_file "secrets.aaa@example.age" '{"planted":"vx"}' || return 1
    ssh-keygen -Y sign -f "$TEST_TMPDIR/stranger.ssh" -n "cs-secrets@test-session" < "$f" > "$f.sig" 2>/dev/null \
        || { echo "  FAIL: fixture: could not sign"; return 1; }
    out=$("$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the import exits 0" || return 1
    assert_output_contains "$out" "^Skipped secrets\.aaa@example\.age: its signature does not match\." "the skip names the file" || return 1
    _assert_secret_absent planted "nothing from the file is stored" || return 1
}

test_import_file_skips_a_signed_file_changed_after_signing() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local out rc=0 peer_file
    _peer_exports from_peer "vp" || { echo "  FAIL: fixture: the peer could not export"; return 1; }
    "$CS_SECRETS_BIN" age add "$(_peer_recipient_file)" >/dev/null 2>&1 || return 1
    peer_file=$(_peer_sync_file)
    # One byte added to the ciphertext. (Overwriting a byte with a fixed value
    # leaves the file as it was once in 256 runs.)
    printf 'X' >> "$peer_file"
    out=$("$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the import exits 0" || return 1
    assert_output_contains "$out" "^Skipped $(basename "$peer_file"): its signature does not match\." "the skip names the file" || return 1
    _assert_secret_absent from_peer "nothing from the file is stored" || return 1
}

# The bytes that are decrypted are the bytes whose signature was checked. A
# checkout can replace a sync file while an import runs; here ssh-keygen
# itself replaces the session's file, just before or just after it verifies.
_ssh_keygen_that_swaps() {  # bin dir, before|after, replacement, sync file
    local real_keygen
    real_keygen=$(command -v ssh-keygen)
    mkdir -p "$1"
    cat > "$1/ssh-keygen" <<SHIM
#!/bin/bash
case " \$* " in
    *" -Y verify "*)
        if [ "$2" = before ]; then
            cp "$3" "$4"
            : > "$TEST_TMPDIR/swapped"
            exec "$real_keygen" "\$@"
        fi
        "$real_keygen" "\$@" || exit \$?
        cp "$3" "$4"
        : > "$TEST_TMPDIR/swapped"
        exit 0
        ;;
esac
exec "$real_keygen" "\$@"
SHIM
    chmod +x "$1/ssh-keygen"
}
_plant_unsigned_replacement() {  # output file, json
    printf '%s\n' "$2" | age -r "$(cat "$HOME/.cs-secrets/id_ed25519.pub")" -o "$1"
}

test_import_file_decrypts_the_bytes_it_verified() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local bindir="$TEST_TMPDIR/swapping-ssh-keygen" unsigned="$TEST_TMPDIR/unsigned.age"
    local peer_file out rc=0
    _peer_exports from_peer "vp" || { echo "  FAIL: fixture: the peer could not export"; return 1; }
    "$CS_SECRETS_BIN" age add "$(_peer_recipient_file)" >/dev/null 2>&1 || { echo "  FAIL: fixture: could not pin the peer"; return 1; }
    peer_file=$(_peer_sync_file)
    _plant_unsigned_replacement "$unsigned" '{"from_peer":"vswapped"}' || { echo "  FAIL: fixture: could not encrypt the replacement"; return 1; }
    _ssh_keygen_that_swaps "$bindir" after "$unsigned" "$peer_file"
    out=$(PATH="$bindir:$PATH" "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_file_exists "$TEST_TMPDIR/swapped" "fixture: the file was replaced after a passing check" || return 1
    cmp -s "$peer_file" "$unsigned" || { echo "  FAIL: fixture: the session does not hold the replacement"; return 1; }
    assert_eq "0" "$rc" "the import exits 0: $out" || return 1
    assert_eq "vp" "$("$CS_SECRETS_BIN" get from_peer 2>&1)" "the signed value is imported, not the replacement" || return 1
}

# The other order: the session holds an unsigned file when the import reads
# it, and the signed one is back in place by the time the signature is checked.
test_import_file_verifies_the_bytes_it_will_decrypt() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local bindir="$TEST_TMPDIR/swapping-ssh-keygen" signed="$TEST_TMPDIR/signed.age"
    local peer_file out rc=0
    _peer_exports from_peer "vp" || { echo "  FAIL: fixture: the peer could not export"; return 1; }
    "$CS_SECRETS_BIN" age add "$(_peer_recipient_file)" >/dev/null 2>&1 || { echo "  FAIL: fixture: could not pin the peer"; return 1; }
    peer_file=$(_peer_sync_file)
    cp "$peer_file" "$signed"
    _plant_unsigned_replacement "$peer_file" '{"from_peer":"vswapped"}' || { echo "  FAIL: fixture: could not encrypt the replacement"; return 1; }
    _ssh_keygen_that_swaps "$bindir" before "$signed" "$peer_file"
    out=$(PATH="$bindir:$PATH" "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_file_exists "$TEST_TMPDIR/swapped" "fixture: the signed file was put back before the check" || return 1
    cmp -s "$peer_file" "$signed" || { echo "  FAIL: fixture: the session does not hold the signed file"; return 1; }
    assert_eq "0" "$rc" "the import exits 0: $out" || return 1
    assert_output_contains "$out" "^Skipped $(basename "$peer_file"): its signature does not match\." "the skip names the file" || return 1
    _assert_secret_absent from_peer "nothing from the unsigned file is stored" || return 1
}

# A symbolic link is the one thing a push can put at either path that names
# something outside the repository: a device, a pipe, a file of any size. An
# import copies the link, never what it names, and takes neither.
test_import_file_skips_a_signature_that_is_a_symbolic_link() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local peer_file mode out rc
    _peer_exports from_peer "vp" || { echo "  FAIL: fixture: the peer could not export"; return 1; }
    "$CS_SECRETS_BIN" age add "$(_peer_recipient_file)" >/dev/null 2>&1 || { echo "  FAIL: fixture: could not pin the peer"; return 1; }
    peer_file=$(_peer_sync_file)
    mv "$peer_file.sig" "$TEST_TMPDIR/elsewhere.sig"
    ln -s "$TEST_TMPDIR/elsewhere.sig" "$peer_file.sig"
    for mode in "" --allow-unsigned; do
        rc=0
        # shellcheck disable=SC2086  # an empty mode is no argument
        out=$("$CS_SECRETS_BIN" import-file $mode 2>&1) || rc=$?
        assert_eq "0" "$rc" "the import exits 0 (mode '$mode')" || return 1
        assert_output_contains "$out" "^Skipped $(basename "$peer_file"): its signature is a symbolic link\.$" "the skip says why (mode '$mode')" || return 1
        _assert_secret_absent from_peer "nothing from the file is stored (mode '$mode')" || return 1
    done
}

test_import_file_skips_a_sync_file_that_is_a_symbolic_link() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local peer_file out rc=0
    _peer_exports from_peer "vp" || { echo "  FAIL: fixture: the peer could not export"; return 1; }
    "$CS_SECRETS_BIN" age add "$(_peer_recipient_file)" >/dev/null 2>&1 || { echo "  FAIL: fixture: could not pin the peer"; return 1; }
    peer_file=$(_peer_sync_file)
    mv "$peer_file" "$TEST_TMPDIR/elsewhere.age"
    ln -s "$TEST_TMPDIR/elsewhere.age" "$peer_file"
    out=$("$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the import exits 0" || return 1
    assert_output_contains "$out" "^Skipped $(basename "$peer_file"): it is a symbolic link\.$" "the skip says why" || return 1
    _assert_secret_absent from_peer "nothing from the file is stored" || return 1
}

# A password file carries no signature, so the link is the whole attack: a
# pushed .enc link to another session's local store, which the shared password
# opens, would import that session's secrets and the next export would publish
# them in this session's tracked sync file.
test_import_file_skips_a_password_sync_file_that_is_a_symbolic_link() {
    local out rc=0 link="$CS_SESSIONS_ROOT/test-session/.cs/secrets.zz.enc"
    create_test_session other-session >/dev/null
    printf 'value-of-other\n' | "$CS_SECRETS_BIN" --session other-session set other_token >/dev/null 2>&1 \
        || { echo "  FAIL: fixture: set in the other session failed"; return 1; }
    assert_file_exists "$HOME/.cs-secrets/other-session.enc" "fixture: the other session's local store" || return 1
    ln -s "$HOME/.cs-secrets/other-session.enc" "$link"
    out=$("$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the import exits 0" || return 1
    assert_output_contains "$out" "^Skipped secrets\.zz\.enc: it is a symbolic link\.$" "the skip says why" || return 1
    _assert_secret_absent other_token "nothing from the linked store is imported" || return 1
    rc=0
    out=$("$CS_SECRETS_BIN" import-file "$link" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a named link is refused" || return 1
    assert_eq "Error: Refusing to import $link: it is a symbolic link." "$out" "the refusal names the file and why" || return 1
    _assert_secret_absent other_token "nothing is imported through the named link" || return 1
}

# One value larger than the kernel lets a process carry in its environment
# (1 MiB on macOS, 128 KiB per string on Linux) used to make the store's jq
# fail to start; the empty result was written over the store, every secret
# was lost, and the import still reported success.
test_import_file_keeps_the_store_when_a_value_exceeds_the_exec_limit() {
    local out rc=0 len
    printf 'kept\n' | "$CS_SECRETS_BIN" set keep_one >/dev/null 2>&1 \
        || { echo "  FAIL: fixture: set failed"; return 1; }
    {
        printf '{"big_blob":"'
        head -c 1200000 /dev/zero | tr '\0' 'A'
        printf '","zzz_small":"s2"}\n'
    } > "$TEST_TMPDIR/payload.json"
    openssl enc -aes-256-cbc -e -pbkdf2 -iter 100000 -in "$TEST_TMPDIR/payload.json" \
        -out "$CS_SESSIONS_ROOT/test-session/.cs/secrets.peer@example.enc" -pass env:CS_SECRETS_PASSWORD \
        || { echo "  FAIL: fixture: could not encrypt the sync file"; return 1; }
    out=$("$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_eq "0 Imported 2 secret(s) from 1 sync file(s)." "$rc $out" "the import stores both values" || return 1
    assert_eq "kept" "$("$CS_SECRETS_BIN" get keep_one 2>&1)" "the stored secret survives" || return 1
    assert_eq "s2" "$("$CS_SECRETS_BIN" get zzz_small 2>&1)" "the small value is stored" || return 1
    len=$("$CS_SECRETS_BIN" get big_blob 2>/dev/null | tr -d '\n' | wc -c | tr -d ' ')
    assert_eq "1200000" "$len" "the large value is stored whole" || return 1
}

# A .cs pushed as a link to ~/.cs-secrets holds no link a file check sees, yet
# the legacy secrets.enc it finds there is the local store of a session named
# secrets, which the shared password opens.
test_import_file_refuses_a_session_whose_cs_is_a_link() {
    local out rc=0 session_dir="$CS_SESSIONS_ROOT/linked-session" real
    create_test_session secrets >/dev/null
    printf 'value-of-victim\n' | "$CS_SECRETS_BIN" --session secrets set victim_token >/dev/null 2>&1 \
        || { echo "  FAIL: fixture: set in the session named secrets failed"; return 1; }
    assert_file_exists "$HOME/.cs-secrets/secrets.enc" "fixture: the victim's local store" || return 1
    mkdir -p "$session_dir"
    ln -s "$HOME/.cs-secrets" "$session_dir/.cs"
    real=$(cd "$HOME/.cs-secrets" && pwd -P)
    out=$("$CS_SECRETS_BIN" --session linked-session import-file 2>&1) || rc=$?
    assert_eq "1" "$rc" "the import is refused" || return 1
    assert_eq "Error: Refusing to import for session 'linked-session': $session_dir/.cs leads to $real, outside the session" \
        "$out" "the refusal names the link and where it leads" || return 1
    rc=0
    out=$("$CS_SECRETS_BIN" --session linked-session import-file "$session_dir/.cs/secrets.enc" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a file named through the link is refused" || return 1
    rc=0
    out=$("$CS_SECRETS_BIN" --session linked-session get victim_token 2>&1) || rc=$?
    assert_eq "3 Error: secret not found: victim_token" "$rc $out" "nothing from the victim's store is imported" || return 1
}

# A file named outright is read from where its path leads, so a directory link
# pushed inside the session (.cs/inbox -> ~/.cs-secrets) would hand over
# another session's local store under a name that is itself no link.
test_import_file_refuses_a_named_file_behind_a_linked_directory() {
    local out rc=0 inbox="$CS_SESSIONS_ROOT/test-session/.cs/inbox" real
    create_test_session other-session >/dev/null
    printf 'value-of-other\n' | "$CS_SECRETS_BIN" --session other-session set other_token >/dev/null 2>&1 \
        || { echo "  FAIL: fixture: set in the other session failed"; return 1; }
    ln -s "$HOME/.cs-secrets" "$inbox"
    real=$(cd "$HOME/.cs-secrets" && /bin/pwd -P)
    out=$("$CS_SECRETS_BIN" import-file "$inbox/other-session.enc" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the import is refused" || return 1
    assert_eq "Error: Refusing to import $inbox/other-session.enc: its directory leads to $real, outside the session" \
        "$out" "the refusal names the file and where its directory leads" || return 1
    _assert_secret_absent other_token "nothing from the other session's store is imported" || return 1
}

# Writes a stand-in for <tool> at the front of PATH that, on the first call
# whose arguments mention <word>, swaps the session's .cs for a link to
# ~/.cs-secrets (keeping the real one as .cs.saved), then runs the real tool.
_make_cs_swapper() {  # tool, word
    local bindir="$TEST_TMPDIR/swap-bin" real
    real=$(command -v "$1") || return 1
    mkdir -p "$bindir"
    cat > "$bindir/$1" <<EOF
#!/bin/bash
case "\$*" in *"$2"*)
    if [ ! -e "$TEST_TMPDIR/swapped" ]; then
        : > "$TEST_TMPDIR/swapped"
        mv "$CS_SESSIONS_ROOT/test-session/.cs" "$CS_SESSIONS_ROOT/test-session/.cs.saved"
        ln -s "$HOME/.cs-secrets" "$CS_SESSIONS_ROOT/test-session/.cs"
    fi ;;
esac
exec "$real" "\$@"
EOF
    chmod +x "$bindir/$1"
    printf '%s\n' "$bindir"
}

# The session's own legacy secrets.enc, and a session named secrets whose
# local store ~/.cs-secrets/secrets.enc a swapped-in .cs link would expose.
_seed_swap_fixture() {
    create_test_session secrets >/dev/null
    printf 'value-of-victim\n' | "$CS_SECRETS_BIN" --session secrets set victim_token >/dev/null 2>&1 \
        || { echo "  FAIL: fixture: set in the session named secrets failed"; return 1; }
    printf '{"own_token":"mine"}\n' | openssl enc -aes-256-cbc -e -pbkdf2 -iter 100000 \
        -out "$CS_SESSIONS_ROOT/test-session/.cs/secrets.enc" -pass env:CS_SECRETS_PASSWORD \
        || { echo "  FAIL: fixture: could not encrypt the sync file"; return 1; }
}

# The .cs is checked once, then each file is copied: a checkout that swaps .cs
# for a link before a copy starts must not lead that copy out of the session.
test_import_file_refuses_a_cs_swapped_for_a_link_before_the_copy() {
    local out rc=0 bindir
    _seed_swap_fixture || return 1
    bindir=$(_make_cs_swapper mktemp cs-import) || { echo "  FAIL: fixture: no mktemp"; return 1; }
    out=$(PATH="$bindir:$PATH" "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_file_exists "$TEST_TMPDIR/swapped" "positive control: the swap happened during the import" || return 1
    assert_output_contains "$out" "^Skipped secrets\.enc: its directory changed while it was read\.$" \
        "the skip says why" || return 1
    _assert_secret_absent victim_token "nothing from the victim's store is imported" || return 1
}

# A swap that lands while the copy itself runs must not lead it out either.
test_import_file_reads_the_cs_it_checked_when_swapped_during_the_copy() {
    local out rc=0 bindir
    _seed_swap_fixture || return 1
    bindir=$(_make_cs_swapper cp secrets.enc) || { echo "  FAIL: fixture: no cp"; return 1; }
    out=$(PATH="$bindir:$PATH" "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_file_exists "$TEST_TMPDIR/swapped" "positive control: the swap happened during the import" || return 1
    assert_eq "0 Imported 1 secret(s) from 1 sync file(s)." "$rc $out" "the session's own file is imported" || return 1
    assert_eq "mine" "$("$CS_SECRETS_BIN" get own_token 2>&1)" "the value is the session's own" || return 1
    _assert_secret_absent victim_token "nothing from the victim's store is imported" || return 1
}

# A directory outside the session and outside the local store, holding a sync
# file the shared password opens; the session's .cs/inbox is linked to it.
_link_inbox_outside_the_session() {
    mkdir -p "$TEST_TMPDIR/outside"
    printf '{"other_token":"value-of-other"}\n' | openssl enc -aes-256-cbc -e -pbkdf2 -iter 100000 \
        -out "$TEST_TMPDIR/outside/other-session.enc" -pass env:CS_SECRETS_PASSWORD \
        || { echo "  FAIL: fixture: could not encrypt the sync file"; return 1; }
    ln -s "$TEST_TMPDIR/outside" "$CS_SESSIONS_ROOT/test-session/.cs/inbox"
}

# The session can be spelled many ways: a doubled slash, a dot segment, a link
# to the sessions root, or a relative name from a directory reached through
# one. Each is the same session, so each must meet the same refusal.
test_import_file_refuses_a_named_file_behind_a_linked_directory_however_spelled() {
    local out rc spelling alias="$TEST_TMPDIR/root-alias"
    _link_inbox_outside_the_session || return 1
    ln -s "$CS_SESSIONS_ROOT" "$alias"
    for spelling in \
        "$CS_SESSIONS_ROOT//test-session/.cs/inbox/other-session.enc" \
        "$CS_SESSIONS_ROOT/./test-session/.cs/inbox/other-session.enc" \
        "$alias/test-session/.cs/inbox/other-session.enc"; do
        rc=0
        out=$("$CS_SECRETS_BIN" import-file "$spelling" 2>&1) || rc=$?
        assert_eq "1" "$rc" "the import of $spelling is refused: $out" || return 1
    done
    rc=0
    out=$(cd "$alias/test-session" && "$CS_SECRETS_BIN" import-file .cs/inbox/other-session.enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "a relative name from the session reached through a link is refused: $out" || return 1
    _assert_secret_absent other_token "nothing from the other session's store is imported" || return 1
}

# On a filesystem that ignores case, a session spelled in another case is the
# same session.
test_import_file_refuses_a_named_file_behind_a_linked_directory_in_another_case() {
    local out rc=0 upper
    mkdir "$TEST_TMPDIR/case-probe"
    if [[ ! -d "$TEST_TMPDIR/CASE-PROBE" ]]; then
        echo "    SKIP (this filesystem tells case apart)"
        return 77
    fi
    upper=$(printf '%s' "$CS_SESSIONS_ROOT/test-session" | tr '[:lower:]' '[:upper:]')
    _link_inbox_outside_the_session || return 1
    out=$("$CS_SECRETS_BIN" import-file "$upper/.cs/inbox/other-session.enc" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the import is refused: $out" || return 1
    _assert_secret_absent other_token "nothing from the other session's store is imported" || return 1
}

# Whatever path names it, a file in the local secrets store is another
# session's store, never a sync file: a link outside every session reaches it
# just as well.
test_import_file_refuses_a_named_file_in_the_local_secrets_store() {
    local out rc=0 link="$TEST_TMPDIR/elsewhere" real
    create_test_session other-session >/dev/null
    printf 'value-of-other\n' | "$CS_SECRETS_BIN" --session other-session set other_token >/dev/null 2>&1 \
        || { echo "  FAIL: fixture: set in the other session failed"; return 1; }
    ln -s "$HOME/.cs-secrets" "$link"
    real=$(cd "$HOME/.cs-secrets" && /bin/pwd -P)
    out=$("$CS_SECRETS_BIN" import-file "$link/other-session.enc" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the import is refused" || return 1
    assert_eq "Error: Refusing to import $link/other-session.enc: its directory leads to $real, the local secrets store" \
        "$out" "the refusal names the file and the store" || return 1
    _assert_secret_absent other_token "nothing from the other session's store is imported" || return 1
}

# Another session's checkout is no more trusted than this one's: a file named
# through its .cs/inbox, a link pushed to a directory outside it, must not be
# read. A file that really is in the other session still imports.
test_import_file_refuses_a_named_file_behind_another_sessions_linked_directory() {
    local out rc=0 other="$CS_SESSIONS_ROOT/b-session"
    mkdir -p "$TEST_TMPDIR/outside" "$other/.cs"
    printf '{"other_token":"value-of-other"}\n' | openssl enc -aes-256-cbc -e -pbkdf2 -iter 100000 \
        -out "$TEST_TMPDIR/outside/other-session.enc" -pass env:CS_SECRETS_PASSWORD \
        || { echo "  FAIL: fixture: could not encrypt the outside file"; return 1; }
    ln -s "$TEST_TMPDIR/outside" "$other/.cs/inbox"
    out=$("$CS_SECRETS_BIN" import-file "$other/.cs/inbox/other-session.enc" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the import is refused: $out" || return 1
    _assert_secret_absent other_token "nothing behind the other session's link is imported" || return 1
    printf '{"b_token":"from-b"}\n' | openssl enc -aes-256-cbc -e -pbkdf2 -iter 100000 \
        -out "$other/.cs/secrets.b.enc" -pass env:CS_SECRETS_PASSWORD \
        || { echo "  FAIL: fixture: could not encrypt the other session's file"; return 1; }
    # A link in this session into the other one leaves this session too.
    ln -s "$other/.cs" "$CS_SESSIONS_ROOT/test-session/.cs/inbox"
    rc=0
    out=$("$CS_SECRETS_BIN" import-file "$CS_SESSIONS_ROOT/test-session/.cs/inbox/secrets.b.enc" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a file reached through a link into the other session is refused: $out" || return 1
    _assert_secret_absent b_token "nothing from the other session is imported through the link" || return 1
    rc=0
    out=$("$CS_SECRETS_BIN" import-file "$other/.cs/secrets.b.enc" 2>&1) || rc=$?
    assert_eq "0 Imported 1 secret(s) from 1 sync file(s)." "$rc $out" "a file inside the other session imports" || return 1
}

# A named file cs cannot read is not a file it could not decrypt.
test_import_file_names_a_file_it_cannot_read() {
    local out rc=0 work="$TEST_TMPDIR/work"
    mkdir -p "$work"
    printf '{"own_token":"mine"}\n' | openssl enc -aes-256-cbc -e -pbkdf2 -iter 100000 \
        -out "$work/backup.enc" -pass env:CS_SECRETS_PASSWORD \
        || { echo "  FAIL: fixture: could not encrypt the sync file"; return 1; }
    chmod 000 "$work/backup.enc"
    out=$("$CS_SECRETS_BIN" import-file "$work/backup.enc" 2>&1) || rc=$?
    chmod 600 "$work/backup.enc"
    assert_eq "1 Error: Could not read $work/backup.enc" "$rc $out" "the refusal says the file could not be read" || return 1
}

# An exported CDPATH must not change where a relative name leads, nor what the
# directory check reads back.
test_import_file_reads_a_relative_name_under_an_exported_cdpath() {
    local out rc=0 work="$TEST_TMPDIR/work"
    mkdir -p "$work/sub"
    printf '{"cdpath_token":"v"}\n' | openssl enc -aes-256-cbc -e -pbkdf2 -iter 100000 \
        -out "$work/sub/backup.enc" -pass env:CS_SECRETS_PASSWORD \
        || { echo "  FAIL: fixture: could not encrypt the sync file"; return 1; }
    out=$(cd "$work" && CDPATH=".:$TEST_TMPDIR" "$CS_SECRETS_BIN" import-file sub/backup.enc 2>&1) || rc=$?
    assert_eq "0 Imported 1 secret(s) from 1 sync file(s)." "$rc $out" "the file is imported" || return 1
    assert_eq "v" "$("$CS_SECRETS_BIN" get cdpath_token 2>&1)" "the value is stored" || return 1
}

# A relative TMPDIR names a directory from where cs-secrets started, not from
# the directory a copy runs in.
test_import_file_reads_the_session_under_a_relative_tmpdir() {
    local out rc=0
    printf '{"own_token":"mine"}\n' | openssl enc -aes-256-cbc -e -pbkdf2 -iter 100000 \
        -out "$CS_SESSIONS_ROOT/test-session/.cs/secrets.enc" -pass env:CS_SECRETS_PASSWORD \
        || { echo "  FAIL: fixture: could not encrypt the sync file"; return 1; }
    mkdir "$TEST_TMPDIR/rt"
    out=$(cd "$TEST_TMPDIR" && TMPDIR=rt "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_eq "0 Imported 1 secret(s) from 1 sync file(s)." "$rc $out" "the session's file is imported" || return 1
    assert_eq "mine" "$("$CS_SECRETS_BIN" get own_token 2>&1)" "the value is stored" || return 1
}

# A .cs that cannot be entered by the time its file is copied has not changed:
# the file is unreadable, and the import says so.
test_import_file_counts_a_cs_it_cannot_enter_as_unreadable() {
    local out rc=0 bindir="$TEST_TMPDIR/lock-bin" real meta="$CS_SESSIONS_ROOT/test-session/.cs"
    printf '{"own_token":"mine"}\n' | openssl enc -aes-256-cbc -e -pbkdf2 -iter 100000 \
        -out "$meta/secrets.enc" -pass env:CS_SECRETS_PASSWORD \
        || { echo "  FAIL: fixture: could not encrypt the sync file"; return 1; }
    real=$(command -v mktemp) || { echo "  FAIL: fixture: no mktemp"; return 1; }
    mkdir -p "$bindir"
    cat > "$bindir/mktemp" <<EOF
#!/bin/bash
case "\$*" in *cs-import*) chmod 000 "$meta" ;; esac
exec "$real" "\$@"
EOF
    chmod +x "$bindir/mktemp"
    out=$(PATH="$bindir:$PATH" "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    chmod 755 "$meta"
    assert_eq "0" "$rc" "the import finishes: $out" || return 1
    assert_output_contains "$out" "^Skipped 1 sync file(s) that could not be read\.$" "the file is counted as unreadable" || return 1
    if [[ "$out" == *"changed while it was read"* ]]; then
        echo "  FAIL: an unenterable .cs is reported as changed: $out"
        return 1
    fi
}

# A Keychain value larger than the kernel lets a process carry in its
# environment (1 MiB on macOS) must still reach the backup: export-file builds
# the backup through jq, which never starts if the value rides in env.
test_keychain_export_file_carries_a_value_past_the_exec_limit() {
    local bindir; bindir=$(_make_fake_security)
    local kcstore="$TEST_TMPDIR/kc-store" mid; mid=$(_machine_id)
    local f="$CS_SESSIONS_ROOT/test-session/.cs/secrets.${mid}.enc" len rc=0 out
    mkdir -p "$kcstore"
    {
        printf 'cs:test-session:big_blob\n'
        head -c 1200000 /dev/zero | tr '\0' 'A'
        printf '\n'
    } > "$kcstore/cs_test-session_big_blob"
    out=$(PATH="$bindir:$(_ageless_path)" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kcstore" \
        "$CS_SECRETS_BIN" export-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "export-file succeeds: $out" || return 1
    openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$f" -pass env:CS_SECRETS_PASSWORD \
        > "$TEST_TMPDIR/backup.json" 2>/dev/null \
        || { echo "  FAIL: the sync file does not decrypt with the test password"; return 1; }
    len=$(jq -r '.big_blob | length' "$TEST_TMPDIR/backup.json")
    assert_eq "1200000" "$len" "the backup carries the whole value" || return 1
}

# A store that already holds two JSON documents (a corrupt or hand-edited
# file) comes back from jq as two documents; writing them would keep a store
# that every reader takes as missing secrets.
test_set_refuses_to_write_a_store_of_more_than_one_document() {
    local out rc=0 store="$HOME/.cs-secrets/test-session.enc"
    mkdir -p "$HOME/.cs-secrets"
    printf '{"a":"1"}\n{"b":"2"}\n' | openssl enc -aes-256-cbc -e -pbkdf2 -iter 100000 \
        -out "$store" -pass env:CS_SECRETS_PASSWORD \
        || { echo "  FAIL: fixture: could not encrypt the store"; return 1; }
    cp "$store" "$TEST_TMPDIR/store.before"
    out=$(printf 'v\n' | "$CS_SECRETS_BIN" set c 2>&1) || rc=$?
    assert_eq "1" "$rc" "the write is refused" || return 1
    assert_output_contains "$out" "^Error: refusing to write a secrets store for session 'test-session' that is not one JSON object$" \
        "the refusal says why" || return 1
    cmp -s "$store" "$TEST_TMPDIR/store.before" || { echo "  FAIL: the store on disk changed"; return 1; }
}

# A directory at the signature path is not a missing signature.
test_import_file_skips_a_file_whose_signature_cannot_be_read() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local out rc=0
    _plant_unsigned_sync_file "secrets.aaa@example.age" '{"planted":"vx"}' || { echo "  FAIL: fixture: could not plant the file"; return 1; }
    mkdir "$CS_SESSIONS_ROOT/test-session/.cs/secrets.aaa@example.age.sig"
    out=$("$CS_SECRETS_BIN" import-file --allow-unsigned 2>&1) || rc=$?
    assert_eq "0" "$rc" "the import exits 0" || return 1
    assert_output_contains "$out" "^Skipped secrets\.aaa@example\.age: its signature could not be read\.$" "the skip says why" || return 1
    _assert_secret_absent planted "nothing from the file is stored" || return 1
}

# The same peer, pinned in two sessions: a file it signed for one is not
# accepted in the other.
test_import_file_skips_a_file_signed_for_another_session() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs" other="$CS_SESSIONS_ROOT/other-session/.cs"
    local out rc=0 peer_file peer_pub
    _peer_exports from_peer "vp" || { echo "  FAIL: fixture: the peer could not export"; return 1; }
    peer_file=$(_peer_sync_file)
    peer_pub=$(_peer_recipient_file)
    mkdir -p "$other/age-recipients"
    cp "$peer_pub" "$other/age-recipients/"
    cp "$peer_file" "$peer_file.sig" "$other/"
    "$CS_SECRETS_BIN" --session other-session age add "$other/age-recipients/$(basename "$peer_pub")" >/dev/null 2>&1 \
        || { echo "  FAIL: fixture: could not pin the peer in the other session"; return 1; }
    out=$("$CS_SECRETS_BIN" --session other-session import-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the import exits 0" || return 1
    assert_output_contains "$out" "^Skipped $(basename "$peer_file"): its signature does not match\." "the skip names the file" || return 1
    out=$("$CS_SECRETS_BIN" --session other-session get from_peer 2>&1) || true
    assert_eq "Error: secret not found: from_peer" "$out" "nothing is stored in the other session" || return 1
}

test_import_file_allow_unsigned_takes_a_file_with_no_signature() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local out rc=0
    _plant_unsigned_sync_file "secrets.older@example.age" '{"from_before":"vb"}' || return 1
    out=$("$CS_SECRETS_BIN" import-file --allow-unsigned 2>&1) || rc=$?
    assert_eq "0" "$rc" "the import exits 0: $out" || return 1
    assert_eq "vb" "$("$CS_SECRETS_BIN" get from_before 2>&1)" "the unsigned file is imported" || return 1
}

# The flag is for files that predate signatures, not for files whose
# signature is wrong.
test_import_file_allow_unsigned_still_skips_a_bad_signature() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local out rc=0 peer_file
    _peer_exports from_peer "vp" || { echo "  FAIL: fixture: the peer could not export"; return 1; }
    "$CS_SECRETS_BIN" age add "$(_peer_recipient_file)" >/dev/null 2>&1 || return 1
    peer_file=$(_peer_sync_file)
    printf 'X' >> "$peer_file"
    out=$("$CS_SECRETS_BIN" import-file --allow-unsigned 2>&1) || rc=$?
    assert_eq "0" "$rc" "the import exits 0" || return 1
    assert_output_contains "$out" "^Skipped $(basename "$peer_file"): its signature does not match\." "the skip names the file" || return 1
    _assert_secret_absent from_peer "nothing from the file is stored" || return 1
}

test_import_file_refuses_a_named_file_that_is_not_trusted() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local f="$meta/secrets.aaa@example.age" out rc=0
    _plant_unsigned_sync_file "secrets.aaa@example.age" '{"planted":"vx"}' || return 1
    out=$("$CS_SECRETS_BIN" import-file "$f" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the import of the named file exits 1" || return 1
    assert_eq "Error: Refusing to import $f: it has no signature. Sync files written before cs signed them have none; import one you trust with --allow-unsigned." \
        "$out" "the refusal names the file and the flag" || return 1
    _assert_secret_absent planted "nothing from the file is stored" || return 1
    rc=0
    out=$("$CS_SECRETS_BIN" import-file "$f" --allow-unsigned 2>&1) || rc=$?
    assert_eq "0" "$rc" "with the flag the named file is imported: $out" || return 1
    assert_eq "vx" "$("$CS_SECRETS_BIN" get planted 2>&1)" "its secret is stored" || return 1
}

# Checking a signature needs ssh-keygen. Without it an age file is skipped by
# name, and a password file beside it is still imported.
test_import_file_without_ssh_keygen_skips_signed_files_by_name() {
    _use_real_age || return $?
    _use_real_ssh_keygen || return $?
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local bindir="$TEST_TMPDIR/no-ssh-keygen" out rc=0 peer_file
    _peer_exports from_peer "vp" || { echo "  FAIL: fixture: the peer could not export"; return 1; }
    "$CS_SECRETS_BIN" age add "$(_peer_recipient_file)" >/dev/null 2>&1 || return 1
    peer_file=$(_peer_sync_file)
    _seed_enc_sync_file "$meta/secrets.machine-b.enc" '{"from_password_file":"ve"}' || return 1
    link_path_without "$bindir" 'ssh-keygen'
    out=$(PATH="$bindir" "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_eq "0" "$rc" "the import exits 0: $out" || return 1
    assert_output_contains "$out" "^Skipped $(basename "$peer_file"): ssh-keygen not found, so its signature cannot be checked\.$" "the skip names the file and the tool" || return 1
    _assert_secret_absent from_peer "the age file is not imported" || return 1
    assert_eq "ve" "$("$CS_SECRETS_BIN" get from_password_file 2>&1)" "the password file is imported" || return 1
}

test_import_file_merges_all_machines_and_legacy() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _seed_enc_sync_file "$meta/secrets.machine-b.enc" '{"from_machine_b":"vb"}' || return 1
    _seed_enc_sync_file "$meta/secrets.enc" '{"from_legacy":"vl"}' || return 1
    # A locally pre-existing secret must survive a merge import.
    "$CS_SECRETS_BIN" set local_key "vlocal" >/dev/null 2>&1

    # Keep the import's own report: its "Imported N secret(s) from M sync
    # file(s)" / "Skipped X undecryptable file(s)" summary names which candidate
    # files it accepted, which is the only way to tell a missed file apart from
    # a rejected one when an assertion below fails.
    local out rc=0
    out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?

    assert_eq "vb" "$("$CS_SECRETS_BIN" get from_machine_b 2>&1)" "should import per-machine sync file" \
        || { _report_import "$rc" "$out" "$meta"; return 1; }
    assert_eq "vl" "$("$CS_SECRETS_BIN" get from_legacy 2>&1)" "should import legacy unsuffixed sync file" \
        || { _report_import "$rc" "$out" "$meta"; return 1; }
    assert_eq "vlocal" "$("$CS_SECRETS_BIN" get local_key 2>&1)" "merge import should preserve local secrets" \
        || { _report_import "$rc" "$out" "$meta"; return 1; }
}

# A write failure while importing must ABORT and must never be reported as a
# successful import: `import-file` calls backend_store under `|| error`, which
# suppresses errexit for the whole call, so a store that ignores its write's
# return value would report "Imported N secret(s)" having stored nothing.
# A secret NAME becomes a shell variable name in the eval'd `export` output.
# An unvalidated name breaks out of the assignment and executes -- and sync
# files are designed to be committed and shared, so the name is attacker-
# controlled in the worst case. Reject at the door.
test_set_rejects_a_name_that_breaks_out_of_export() {
    local out rc=0
    out=$(printf 'v' | "$CS_SECRETS_BIN" set 'a;touch /tmp/cs_pwned_set;b' 2>&1) || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: set accepted a secret name that injects into export"
        echo "    output: $out"
        return 1
    fi
    assert_output_contains "$out" "name" "the refusal must name the problem" || return 1
    assert_output_not_contains "$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" list 2>&1)" "touch" \
        "a rejected name must not reach the store" || return 1
}

# The realistic vector: another machine commits a sync file whose KEY is hostile.
# A name can be a valid identifier and still be dangerous: `path` upper-cases
# to PATH, `ld_preload` to LD_PRELOAD. Eval'ing such an export hijacks the
# caller's command resolution and process loading without a single shell
# metacharacter.
# Exported names are namespaced so a secret can never land on a variable the
# shell or the dynamic loader acts on. This closes the hijack class structurally
# rather than by enumerating dangerous names, which leaked repeatedly.
# Two distinct stored names can collapse onto ONE exported variable, because
# export upper-cases and maps hyphens to underscores: `api_key` and `api-key`
# both become CS_SECRET_API_KEY. Eval takes the last, so a sync file can shadow
# a real secret with an attacker's value. Refuse rather than emit both.
test_export_refuses_colliding_exported_names() {
    # Staged with two `set` calls: an import refuses the pair.
    "$CS_SECRETS_BIN" set api_key "REAL" >/dev/null 2>&1 || { echo "  FAIL: fixture: set api_key failed"; return 1; }
    "$CS_SECRETS_BIN" set api-key "SHADOW" >/dev/null 2>&1 || { echo "  FAIL: fixture: set api-key failed"; return 1; }

    local out rc=0
    out=$("$CS_SECRETS_BIN" export 2>&1) || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: export emitted two secrets under one variable name"
        echo "    output: $out"
        return 1
    fi
    assert_output_contains "$out" "CS_SECRET_API_KEY" "the refusal must name the collided variable" || return 1

    # A refused export must emit NOTHING on stdout: `eval "$(cs -secrets
    # export)"` evaluates whatever was printed regardless of exit status, so a
    # partial emission would still set the shadowing value it just refused.
    local emitted
    emitted=$("$CS_SECRETS_BIN" export 2>/dev/null)
    assert_eq "" "$emitted" "a refused export must emit no assignments at all" || return 1
}

# migrate writes to a backend without passing through the entry validation that
# guards set and import-file, so it must validate too.
test_migrate_refuses_an_invalid_name() {
    local bindir; bindir=$(_make_fake_security)
    local rc=0 out
    out=$(PATH="$bindir:$PATH" FAKE_SECURITY_STORE="$TEST_TMPDIR/kc-store" \
          "$CS_SECRETS_BIN" migrate-backend "not a backend" --from encrypted 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "  FAIL: an invalid target backend must exit nonzero"; return 1; }
    assert_output_contains "$out" "Invalid target backend" "must name the invalid backend" || return 1
}

test_export_namespaces_every_variable() {
    printf 'v' | "$CS_SECRETS_BIN" set api_key >/dev/null 2>&1
    local output; output=$("$CS_SECRETS_BIN" export 2>&1)
    assert_output_contains "$output" "export CS_SECRET_API_KEY=" \
        "an exported secret must carry the CS_SECRET_ namespace" || return 1
    assert_output_not_contains "$output" "export API_KEY=" \
        "the bare, collidable name must not be emitted" || return 1
}

# The point of the namespace: a name that would otherwise land on a shell or
# loader variable is now inert, so storing it is safe again.
test_export_namespace_neutralises_dangerous_names() {
    local n
    for n in path ifs prompt_command editor ld_preload; do
        printf 'v' | "$CS_SECRETS_BIN" set "$n" >/dev/null 2>&1 \
            || { echo "  FAIL: set rejected '$n', which the namespace makes safe"; return 1; }
    done
    local output; output=$("$CS_SECRETS_BIN" export 2>&1)
    for n in PATH IFS PROMPT_COMMAND EDITOR LD_PRELOAD; do
        assert_output_not_contains "$output" "export $n=" \
            "export must never assign the bare $n" || return 1
        assert_output_contains "$output" "export CS_SECRET_$n=" \
            "$n must be namespaced, not dropped" || return 1
    done
}

test_import_file_refuses_a_hostile_key_name() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _seed_enc_sync_file "$meta/secrets.machine-x.enc" \
        '{"a;touch /tmp/cs_pwned_import;b":"v"}' || return 1

    local out rc=0
    out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: import accepted a hostile key name from a sync file"
        echo "    output: $out"
        return 1
    fi
    assert_output_contains "$out" "name" "the refusal must name the problem" || return 1
}

_assert_secret_absent() {  # name, message
    local out rc=0
    out=$("$CS_SECRETS_BIN" get "$1" 2>&1) || rc=$?
    assert_eq "3 Error: secret not found: $1" "$rc $out" "$2" || return 1
}

# Two names that differ only in hyphen against underscore become one variable
# in `cs -secrets export`, which then refuses the whole store. An import that
# would create such a pair stores nothing and names both.
test_import_file_refuses_two_names_that_export_as_one_variable() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _seed_enc_sync_file "$meta/secrets.machine-a.enc" '{"api-key":"va","other":"vo"}' || return 1
    _seed_enc_sync_file "$meta/secrets.machine-b.enc" '{"api_key":"vb"}' || return 1

    local out rc=0
    out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_eq "1" "$rc" "the import exits 1" || return 1
    assert_eq "Error: Aborting import for session 'test-session': secrets 'api-key' and 'api_key' both export as CS_SECRET_API_KEY. Nothing was imported. Remove one of them where it is stored, then export and import again." \
        "$out" "the refusal names both secrets and the variable" || return 1
    _assert_secret_absent api-key "the hyphenated name is not stored" || return 1
    _assert_secret_absent api_key "the underscored name is not stored" || return 1
    _assert_secret_absent other "a name beside the pair is not stored either" || return 1
}

# The same pair with one half already stored: the local secret stays, the
# incoming one is refused, and export keeps working.
test_import_file_refuses_a_name_that_shares_a_variable_with_a_stored_secret() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    "$CS_SECRETS_BIN" set api_key "vlocal" >/dev/null 2>&1 || { echo "  FAIL: fixture: set failed"; return 1; }
    _seed_enc_sync_file "$meta/secrets.machine-a.enc" '{"api-key":"va","other":"vo"}' || return 1

    local mode out rc
    for mode in "" --replace; do
        rc=0
        # shellcheck disable=SC2086  # an empty mode is no argument
        out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" import-file $mode 2>&1) || rc=$?
        assert_eq "1" "$rc" "the import exits 1 (mode '$mode')" || return 1
        assert_eq "Error: Aborting import for session 'test-session': secrets 'api-key' and 'api_key' both export as CS_SECRET_API_KEY. Nothing was imported. Remove one of them where it is stored, then export and import again." \
            "$out" "the refusal names the incoming and the stored secret (mode '$mode')" || return 1
        _assert_secret_absent api-key "the incoming name is not stored (mode '$mode')" || return 1
        _assert_secret_absent other "a name beside it is not stored either (mode '$mode')" || return 1
        assert_eq "vlocal" "$("$CS_SECRETS_BIN" get api_key 2>&1)" "the stored secret is untouched (mode '$mode')" || return 1
    done
    assert_eq "export CS_SECRET_API_KEY=vlocal" "$("$CS_SECRETS_BIN" export 2>&1)" "export still works" || return 1
}

# An invalid name stops the import before any name is stored, however the
# names sort.
test_import_file_stores_nothing_when_one_name_is_invalid() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _seed_enc_sync_file "$meta/secrets.machine-a.enc" '{"aaa_new":"v1","zz;rm":"v2"}' || return 1

    local out rc=0
    out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_eq "1" "$rc" "the import exits 1" || return 1
    assert_output_contains "$out" "invalid secret name 'zz;rm'" "the refusal names the invalid name" || return 1
    _assert_secret_absent aaa_new "a valid name sorted before the invalid one is not stored" || return 1
    assert_file_not_exists "$HOME/.cs-secrets/test-session.enc" "no store is created" || return 1
}

# A name carrying a carriage return is not the name without it. The import
# refuses it instead of storing an empty value under the shorter name.
test_import_file_refuses_a_name_ending_in_a_carriage_return() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _seed_enc_sync_file "$meta/secrets.machine-a.enc" '{"cr_key\r":"crval"}' || return 1

    local out rc=0
    out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?
    assert_eq "1" "$rc" "the import exits 1" || return 1
    assert_output_contains "$out" "invalid secret name 'cr_key\\\\r'" "the refusal shows the carriage return" || return 1
    assert_output_not_contains "$out" "Imported" "nothing is reported as imported" || return 1
    assert_file_not_exists "$HOME/.cs-secrets/test-session.enc" "no store is created" || return 1
}

# Defense in depth: a store written before the check existed must still not be
# able to execute. Poison the encrypted store directly, bypassing `set`.
test_export_refuses_a_hostile_name_already_in_the_store() {
    printf 'ok' | "$CS_SECRETS_BIN" set good_key >/dev/null 2>&1
    local store="$HOME/.cs-secrets/test-session.enc"
    printf '%s\n' '{"good_key":"ok","a;touch /tmp/cs_pwned_store;b":"v"}' \
        | openssl enc -aes-256-cbc -e -pbkdf2 -iter 100000 \
            -out "$store" -pass "pass:$CS_SECRETS_PASSWORD" || return 1

    local out rc=0
    out=$("$CS_SECRETS_BIN" export 2>&1) || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: export emitted a store containing an injectable name"
        echo "    output: $out"
        return 1
    fi
    assert_output_not_contains "$out" ";TOUCH " "must not emit the injectable line" || return 1
    assert_output_contains "$out" "a;touch" "the refusal must name the offending key" || return 1
}


test_import_file_aborts_when_the_store_write_fails() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _seed_enc_sync_file "$meta/secrets.machine-b.enc" '{"from_machine_b":"vb"}' || return 1

    local bindir; bindir=$(_make_openssl_writefail_bin)
    local out rc=0
    out=$(PATH="$bindir:$(_ageless_path)" "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: import must abort nonzero when a store write fails"
        echo "    output: $out"
        return 1
    fi
    assert_output_not_contains "$out" "Imported 1 secret" \
        "a failed write must not be counted as an imported secret" || return 1
}

test_import_file_skips_undecryptable_files() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _seed_enc_sync_file "$meta/secrets.machine-a.enc" '{"good_key":"vg"}' || return 1
    # An .age file we cannot decrypt (no age binary under the sandbox, bogus bytes).
    mkdir -p "$meta"
    printf 'not-a-valid-age-file' > "$meta/secrets.machine-a.age"

    PATH="$(_ageless_path)" "$CS_SECRETS_BIN" import-file >/dev/null 2>&1

    assert_eq "vg" "$("$CS_SECRETS_BIN" get good_key 2>&1)" "should import the decryptable file despite an undecryptable one" || return 1
}

# A transient backend read failure during the merge-import existence probe must
# ABORT the import nonzero and NOT overwrite the (unreadable) existing secret.
# readfail makes the per-key `find-generic-password` probe fail with a
# non-not-found error; the addlog proves no store was attempted.
test_import_file_aborts_on_backend_read_failure_no_overwrite() {
    local bindir; bindir=$(_make_fake_security)
    local addlog="$TEST_TMPDIR/kc-addlog"
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _seed_enc_sync_file "$meta/secrets.machine-a.enc" '{"K1":"synced_value"}' || return 1

    local out rc=0
    out=$(PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=readfail \
        FAKE_SECURITY_ADDLOG="$addlog" CS_SECRETS_PASSWORD="$CS_SECRETS_PASSWORD" \
        "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: import must abort nonzero when the existence probe read fails"
        echo "    output: $out"
        return 1
    fi
    assert_output_contains "$out" "refusing to overwrite" \
        "the abort must name the refusal, not just exit nonzero" || return 1
    assert_file_not_exists "$addlog" "must NOT store/overwrite when the existence probe read fails" || return 1
}

# The genuine-not-found path must still store: when the probe reports the secret
# is truly absent (errSecItemNotFound), the merge import proceeds to store it.
test_import_file_stores_when_secret_genuinely_absent() {
    local bindir; bindir=$(_make_fake_security)
    local addlog="$TEST_TMPDIR/kc-addlog"
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _seed_enc_sync_file "$meta/secrets.machine-a.enc" '{"K1":"synced_value"}' || return 1

    local out rc=0
    out=$(PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=empty \
        FAKE_SECURITY_ADDLOG="$addlog" CS_SECRETS_PASSWORD="$CS_SECRETS_PASSWORD" \
        "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?

    assert_eq 0 "$rc" "import must succeed when the secret is genuinely absent" || return 1
    assert_file_exists "$addlog" "a genuinely-absent secret must be stored" || return 1
}

# With USER unset, a bare "$USER" in the keychain functions aborts the command
# substitution under `set -u` before `security` ever runs. The merge-import probe
# then reads that as a backend READ FAILURE rather than not-found and refuses to
# import.
test_import_file_stores_when_secret_absent_and_user_unset() {
    local bindir; bindir=$(_make_fake_security)
    local addlog="$TEST_TMPDIR/kc-addlog"
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _seed_enc_sync_file "$meta/secrets.machine-a.enc" '{"K1":"synced_value"}' || return 1

    local out rc=0
    out=$(PATH="$bindir:$PATH" env -u USER \
        CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=empty \
        FAKE_SECURITY_ADDLOG="$addlog" CS_SECRETS_PASSWORD="$CS_SECRETS_PASSWORD" \
        "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: import must succeed with USER unset (rc=$rc)"
        echo "    output: $out"
        return 1
    fi
    assert_file_exists "$addlog" "a genuinely-absent secret must be stored with USER unset" || return 1
}

# A jq failure while building the backup JSON must abort the export nonzero and
# write no sync file -- never a partial/empty backup that silently loses secrets.
# readok makes enumeration+read succeed so collection reaches the jq assignment;
# a fake jq fails only on that assignment, leaving other jq calls intact.
test_keychain_export_file_aborts_on_jq_failure() {
    local bindir; bindir=$(_make_fake_security)
    local real_jq; real_jq=$(command -v jq)
    # A fake jq in the sandbox dir shadows the real one, which it delegates to
    # for every call except the one it simulates failing.
    cat > "$bindir/jq" <<JQFAKE
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in *'.[\$name] = \$value'*) echo "jq: simulated failure" >&2; exit 5 ;; esac
done
exec "$real_jq" "\$@"
JQFAKE
    chmod +x "$bindir/jq"
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid; mid=$(_machine_id)

    local out rc=0
    out=$(PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=readok \
        "$CS_SECRETS_BIN" export-file 2>&1) || rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: export-file must abort when json construction (jq) fails"
        echo "    output: $out"
        return 1
    fi
    assert_output_contains "$out" "jq: simulated failure" \
        "the abort must show jq actually ran and failed, not that cs-secrets never started" || return 1
    assert_file_not_exists "$meta/secrets.${mid}.enc" "no sync file on jq construction failure" || return 1
    assert_file_not_exists "$meta/secrets.${mid}.age" "no age sync file on jq construction failure" || return 1
}

# An awk execution failure in keychain enumeration must fail loud, not read
# as an empty store. A fake awk fails only on the extraction script, which
# reads the session's prefix from CS_KEYCHAIN_PREFIX.
test_keychain_list_loud_on_extraction_failure() {
    local bindir; bindir=$(_make_fake_security)
    local real_awk; real_awk=$(command -v awk)
    # A fake awk in the sandbox dir shadows the real one, which it delegates to
    # for every call except the one it simulates failing.
    cat > "$bindir/awk" <<AWKFAKE
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in *CS_KEYCHAIN_PREFIX*) echo "awk: simulated failure" >&2; exit 2 ;; esac
done
exec "$real_awk" "\$@"
AWKFAKE
    chmod +x "$bindir/awk"

    local out rc=0
    out=$(PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=readfail \
        "$CS_SECRETS_BIN" list 2>&1) || rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: list must be nonzero when enumeration extraction (awk) fails"
        echo "    output: $out"
        return 1
    fi
    assert_output_contains "$out" "awk: simulated failure" \
        "the abort must show awk actually ran and failed, not that cs-secrets never started" || return 1
    assert_output_not_contains "$out" "No secrets stored" "an extraction failure must not read as an empty store" || return 1
}

# An unknown/unimplemented backend must fail loudly, never silently no-op.
test_unknown_backend_guard() {
    local out
    if out=$(CS_SECRETS_BACKEND=bogus "$CS_SECRETS_BIN" get API_KEY 2>&1); then
        echo "  FAIL: unknown backend should exit nonzero"
        return 1
    fi
    assert_output_contains "$out" "Unknown backend" "unknown backend must error loudly" || return 1
}

# The `backend` display command must also reject an unknown backend loudly.
test_unknown_backend_display_is_loud() {
    local out
    if out=$(CS_SECRETS_BACKEND=bogus "$CS_SECRETS_BIN" backend 2>&1); then
        echo "  FAIL: backend display should exit nonzero for an unknown backend"
        return 1
    fi
    assert_output_contains "$out" "Unknown backend" "backend display must error loudly" || return 1
}

# ============================================================================
# Backup/migrate data integrity: a backend failure must FAIL LOUD, never
# produce a partial/empty secret set (which silently loses secrets on restore).
# ============================================================================

# --- encrypted: a decrypt failure must not masquerade as an empty store ---

test_encrypted_get_loud_on_decrypt_failure() {
    "$CS_SECRETS_BIN" set api_key "sk_ok" >/dev/null 2>&1
    printf 'corrupt-not-openssl-ciphertext' > "$HOME/.cs-secrets/test-session.enc"
    local out
    if out=$("$CS_SECRETS_BIN" get api_key 2>&1); then
        echo "  FAIL: get on a corrupt store must be nonzero"
        return 1
    fi
    assert_output_not_contains "$out" "not found" "decrypt failure must not read as 'not found'" || return 1
    assert_output_contains "$out" "decrypt" "should explain the decrypt failure" || return 1
}

test_encrypted_list_loud_on_decrypt_failure() {
    "$CS_SECRETS_BIN" set api_key "sk_ok" >/dev/null 2>&1
    printf 'corrupt' > "$HOME/.cs-secrets/test-session.enc"
    local out
    if out=$("$CS_SECRETS_BIN" list 2>&1); then
        echo "  FAIL: list on a corrupt store must be nonzero"
        return 1
    fi
    assert_output_not_contains "$out" "No secrets" "decrypt failure must not read as an empty store" || return 1
}

test_encrypted_export_file_aborts_on_decrypt_failure() {
    "$CS_SECRETS_BIN" set api_key "sk_ok" >/dev/null 2>&1
    printf 'corrupt' > "$HOME/.cs-secrets/test-session.enc"
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid; mid=$(_machine_id)
    local out
    if out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file 2>&1); then
        echo "  FAIL: export-file must abort on a decrypt failure"
        return 1
    fi
    assert_output_not_contains "$out" "No secrets to export" "must not claim empty on failure" || return 1
    assert_file_not_exists "$meta/secrets.${mid}.enc" "no sync file may be written on a decrypt failure" || return 1
}

test_encrypted_migrate_aborts_on_decrypt_failure() {
    "$CS_SECRETS_BIN" set api_key "sk_ok" >/dev/null 2>&1
    printf 'corrupt' > "$HOME/.cs-secrets/test-session.enc"
    local out
    if out=$("$CS_SECRETS_BIN" migrate-backend keychain --from encrypted 2>&1); then
        echo "  FAIL: migrate must abort on a decrypt failure"
        return 1
    fi
    assert_output_not_contains "$out" "Migrated" "must not report a migration on a source failure" || return 1
}

test_encrypted_export_file_empty_store_is_clean() {
    local out
    out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file 2>&1) || return 1
    assert_output_contains "$out" "No secrets to export" "a genuinely-empty store must export cleanly" || return 1
}

# --- keychain: an enumeration failure must abort the backup ---

test_keychain_export_file_aborts_on_enumeration_failure() {
    local bindir; bindir=$(_make_fake_security)
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid; mid=$(_machine_id)
    local out
    if out=$(PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=fail \
        "$CS_SECRETS_BIN" export-file 2>&1); then
        echo "  FAIL: export-file must abort when keychain enumeration fails"
        return 1
    fi
    assert_output_contains "$out" "enumerate Keychain for session" \
        "the abort must name the enumeration failure, not just exit nonzero" || return 1
    assert_output_not_contains "$out" "No secrets to export" "must not claim empty on enumeration failure" || return 1
    assert_file_not_exists "$meta/secrets.${mid}.enc" "no sync file on keychain enumeration failure" || return 1
    assert_file_not_exists "$meta/secrets.${mid}.age" "no age sync file on keychain enumeration failure" || return 1
}

test_keychain_export_file_empty_store_is_clean() {
    local bindir; bindir=$(_make_fake_security)
    local out
    out=$(PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=empty \
        "$CS_SECRETS_BIN" export-file 2>&1) || return 1
    assert_output_contains "$out" "No secrets to export" "an empty keychain must export cleanly" || return 1
}

# --- keychain: list/purge/export must fail loud on a backend command failure ---

test_keychain_list_loud_on_enumeration_failure() {
    local bindir; bindir=$(_make_fake_security)
    local out
    if out=$(PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=fail \
        "$CS_SECRETS_BIN" list 2>&1); then
        echo "  FAIL: list must be nonzero when keychain enumeration fails"
        return 1
    fi
    assert_output_contains "$out" "enumerate Keychain for session" \
        "the abort must name the enumeration failure, not just exit nonzero" || return 1
    assert_output_not_contains "$out" "No secrets" "enumeration failure must not read as an empty store" || return 1
}

test_keychain_list_empty_is_clean() {
    local bindir; bindir=$(_make_fake_security)
    local out
    out=$(PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=empty \
        "$CS_SECRETS_BIN" list 2>&1) || return 1
    assert_output_contains "$out" "No secrets stored for session" "an empty keychain must list cleanly" || return 1
}

test_keychain_purge_loud_on_enumeration_failure() {
    local bindir; bindir=$(_make_fake_security)
    local out
    if out=$(PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=fail \
        "$CS_SECRETS_BIN" purge 2>&1); then
        echo "  FAIL: purge must be nonzero when keychain enumeration fails"
        return 1
    fi
    assert_output_contains "$out" "enumerate Keychain for session" \
        "the abort must name the enumeration failure, not just exit nonzero" || return 1
    assert_output_not_contains "$out" "Purged" "enumeration failure must not report a purge" || return 1
}

test_keychain_export_loud_on_enumeration_failure() {
    local bindir; bindir=$(_make_fake_security)
    local out
    if out=$(PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=fail \
        "$CS_SECRETS_BIN" export 2>&1); then
        echo "  FAIL: export must be nonzero when keychain enumeration fails"
        return 1
    fi
    assert_output_contains "$out" "enumerate Keychain for session" \
        "the abort must name the enumeration failure, not just exit nonzero" || return 1
}

test_keychain_export_loud_on_read_failure() {
    local bindir; bindir=$(_make_fake_security)
    local out
    # Enumeration lists one credential but the per-item read fails.
    local errfile="$TEST_TMPDIR/kc-export-err"
    if out=$(PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=readfail \
        FAKE_SECURITY_SESSION=test-session "$CS_SECRETS_BIN" export 2>"$errfile"); then
        echo "  FAIL: export must be nonzero when a keychain read fails"
        return 1
    fi
    assert_eq "" "$out" "export must emit nothing on a read failure" || return 1
    assert_file_contains "$errfile" "failed to read Keychain secret" \
        "the abort must name the read failure, not just exit nonzero" || return 1
}

# --- migrate: a partial migration fails loud ---

test_migrate_partial_write_fails_loud() {
    local bindir; bindir=$(_make_fake_security)
    "$CS_SECRETS_BIN" set k1 "v1" >/dev/null 2>&1
    "$CS_SECRETS_BIN" set k2 "v2" >/dev/null 2>&1
    local out
    # Every write to the target store fails -> migrated 0 of 2 -> nonzero.
    if out=$(PATH="$bindir:$PATH" FAKE_SECURITY_MODE=storefail \
             "$CS_SECRETS_BIN" migrate-backend keychain --from encrypted 2>&1); then
        echo "  FAIL: a partial/failed migration must exit nonzero"
        return 1
    fi
    assert_output_contains "$out" "incomplete" "must report the migration as incomplete" || return 1
}

# ============================================================================
# Concurrency & durability (encrypted backend)
# ============================================================================

# D1: concurrent read-modify-write must not lose updates. Each writer reads the
# store, adds its own key, and writes back. The per-write commit is atomic, but
# the read-modify-write sequence is not: without a mutex, two writers read the
# same base and the second rename clobbers the first writer's key, so keys
# silently vanish. Every key must survive.
test_encrypted_concurrent_stores_no_lost_update() {
    local sess="d1-concurrent"
    create_test_session "$sess" >/dev/null
    local n=15 i
    for i in $(seq 1 "$n"); do
        CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set "key$i" "val$i" >/dev/null 2>&1 &
    done
    wait
    local out
    out=$(CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" list 2>&1)
    for i in $(seq 1 "$n"); do
        assert_output_contains "$out" "key$i" \
            "key$i must survive $n concurrent stores (lost-update race)" || return 1
    done
}


# D2: a failed sync export must not destroy the previous good backup. The old
# code encrypted straight to `-out "$enc_output"`, which opens the live sync
# file with O_TRUNC before openssl finishes; a failed/interrupted encrypt then
# leaves the prior backup truncated (pipefail surfaces the failure, but too
# late). A fake openssl truncates the output then fails only on encrypt (-e);
# decrypt (-d), used to read the store and compare the existing file, passes
# through to real openssl. The fix encrypts into a temp and renames on success,
# so a failed export leaves the existing sync file untouched.
test_export_file_atomic_preserves_prior_on_encrypt_failure() {
    local sess="d2-atomic"
    create_test_session "$sess" >/dev/null
    CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set k1 v1 >/dev/null 2>&1

    # Seed an existing, valid per-machine sync file (a prior successful export).
    local mid meta sync
    mid=$(_machine_id)
    meta="$CS_SESSIONS_ROOT/$sess/.cs"
    sync="$meta/secrets.${mid}.enc"
    _seed_enc_sync_file "$sync" '{"prior":"good"}' || return 1

    # Fake openssl: truncate the -out target then fail on encrypt; pass decrypt
    # and everything else through to the real binary.
    local real_ssl ageless fakedir
    real_ssl=$(command -v openssl)
    ageless=$(_ageless_path)
    fakedir="$TEST_TMPDIR/d2-fakebin"
    mkdir -p "$fakedir"
    cat > "$fakedir/openssl" <<SHIM
#!/usr/bin/env bash
orig=("\$@"); is_enc=0; out=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -e) is_enc=1 ;;
        -out) shift; out="\$1" ;;
    esac
    shift
done
if [ "\$is_enc" = 1 ]; then
    : > "\$out"                              # simulate openssl's O_TRUNC open...
    echo "fake openssl: forced encrypt failure" >&2
    exit 1                                   # ...then fail before writing bytes
fi
exec "$real_ssl" "\${orig[@]}"
SHIM
    chmod +x "$fakedir/openssl"

    local out
    if out=$(PATH="$fakedir:$ageless" CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" export-file 2>&1); then
        echo "  FAIL: export must fail loud when encryption fails"
        echo "    output: $out"
        return 1
    fi

    # The prior sync file must still decrypt to its original content.
    local restored
    restored=$(openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
        -in "$sync" -pass "pass:$CS_SECRETS_PASSWORD" 2>/dev/null)
    assert_output_contains "$restored" '"prior":"good"' \
        "prior sync file must survive a failed export (non-atomic truncate)" || return 1
}

# codex finding 1: a lock left by a dead process must NOT be silently reaped.
# The earlier reap read the holder PID, classified it dead, then renamed the
# lock away without re-checking that the file still held that PID — a two-waiter
# TOCTOU that could hand two writers the lock at once (the lost update this mutex
# prevents). Acquisition now fails loud after the timeout instead, naming the
# lock to remove. Deterministic: seed the lock with a definitely-dead PID.
test_encrypted_stale_lock_fails_loud_not_reaped() {
    local sess="stale-lock"
    create_test_session "$sess" >/dev/null
    mkdir -p "$HOME/.cs-secrets"
    chmod 700 "$HOME/.cs-secrets"
    # A definitely-dead PID: spawn a child, reap it, reuse its now-free PID.
    local dead
    sh -c 'exit 0' & dead=$!
    wait "$dead" 2>/dev/null
    echo "$dead" > "$HOME/.cs-secrets/.lock.$sess"

    local out rc=0
    out=$(CS_SECRETS_LOCK_TIMEOUT=1 CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set k v 2>&1) || rc=$?
    assert_eq "1" "$rc" "store must fail when the lock is held" || return 1
    assert_output_contains "$out" "timed out" "must fail loud, not silently reap the stale lock" || return 1
    assert_output_contains "$out" "remove:" "must name the lock file to remove" || return 1
    assert_file_not_exists "$HOME/.cs-secrets/$sess.enc" \
        "no store may be written when the lock was never acquired" || return 1
}




# codex F1 review: the export mutex must not couple non-encrypted backends to the
# encrypted backend's ~/.cs-secrets. A keychain store is atomic per credential
# and never needed the store lock. Narrowed by batch 1 (Codex round 2): the age
# recipients lock and pin list live under ~/.cs-secrets on every backend, taken
# once there is something to export, so the guarantee that remains is that an
# export with nothing to export touches nothing. Block the path with a plain
# file where the dir would go and confirm an empty-store keychain export still
# works.
test_keychain_export_does_not_require_cs_secrets_dir() {
    local bindir; bindir=$(_make_fake_security)
    rm -rf "$HOME/.cs-secrets"
    : > "$HOME/.cs-secrets"   # a file, so mkdir -p "$HOME/.cs-secrets" cannot succeed
    local out
    out=$(PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=empty \
        CS_SECRETS_LOCK_TIMEOUT=1 "$CS_SECRETS_BIN" export-file 2>&1) || {
        echo "  FAIL: keychain export must not require a writable ~/.cs-secrets"
        echo "    output: $out"
        return 1
    }
    assert_output_contains "$out" "No secrets to export" \
        "keychain export must work without the encrypted backend's ~/.cs-secrets" || return 1
}



# ----------------------------------------------------------------------------
# No secret on a child's argv (audit H3). Every local user can read any
# process's argv through `ps`, and EDR tools log it, so a value taken on stdin
# must not be handed on to security, openssl or jq as an argument. Each fake
# below records the argv it was started with (what `ps` shows) and then runs the
# real tool, so the operation still has to work end to end.
# ----------------------------------------------------------------------------

# A random fixture value held in a file; tests feed it on stdin and grep for it
# with -f, so the value itself never reaches an argv in the test either. Echoes
# the file path.
_argv_canary() {
    local f="$TEST_TMPDIR/canary"
    printf 'canary-%s-%s-%s' "$RANDOM" "$RANDOM" "$$" > "$f"
    printf '%s' "$f"
}

# The canary's hex form, which is just as secret: a `-X <hex>` on argv would
# leak the value as surely as `-w <value>`. Echoes the file path.
_argv_canary_hex() {
    local f="$TEST_TMPDIR/canary.hex"
    od -An -v -tx1 < "$1" | tr -d ' \n' > "$f"
    printf '%s' "$f"
}

# The fixture password, held in a file for the same reason.
_argv_password_file() {
    local f="$TEST_TMPDIR/password"
    printf '%s' "$CS_SECRETS_PASSWORD" > "$f"
    printf '%s' "$f"
}

# Put an argv-recording wrapper for tool $1 into bin dir $2, appending one line
# per call to log $3, then exec the real tool found on the current PATH.
_make_argv_logger() {
    local tool="$1" bindir="$2" log="$3" real
    real=$(command -v "$tool") || { echo "  FAIL: no real $tool on PATH"; return 1; }
    mkdir -p "$bindir"
    cat > "$bindir/$tool" <<LOGGER
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exec "$real" "\$@"
LOGGER
    chmod +x "$bindir/$tool"
}

# Fail when argv log $1 holds the text in file $2. The message names the tool
# and what leaked but never prints the value.
_refute_argv_holds() {
    local log="$1" needle="$2" what="$3"
    if grep -qF -f "$needle" "$log" 2>/dev/null; then
        echo "  FAIL: $what reached a child's argv (visible to ps): $(basename "$log")"
        return 1
    fi
}

# True when file $1 holds exactly the bytes of file $2 plus the one trailing
# newline `get` prints. Compares without putting either value on output.
_get_matches() {
    [ "$(cat "$1")" = "$(cat "$2")" ]
}

test_keychain_set_keeps_the_value_off_argv() {
    local bindir; bindir=$(_make_fake_security)
    local canary; canary=$(_argv_canary)
    local hex; hex=$(_argv_canary_hex "$canary")
    local argvlog="$TEST_TMPDIR/security-argv" kcstore="$TEST_TMPDIR/kc-store"

    PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kcstore" \
        FAKE_SECURITY_ARGVLOG="$argvlog" "$CS_SECRETS_BIN" set K1 < "$canary" >/dev/null 2>&1 \
        || { echo "  FAIL: keychain set exited nonzero"; return 1; }

    # Positive control: the fake ran, and what it stored reads back byte-exact.
    [ -s "$argvlog" ] || { echo "  FAIL: the fake security was never called"; return 1; }
    PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kcstore" \
        "$CS_SECRETS_BIN" get K1 > "$TEST_TMPDIR/got" 2>/dev/null \
        || { echo "  FAIL: keychain get exited nonzero"; return 1; }
    _get_matches "$TEST_TMPDIR/got" "$canary" \
        || { echo "  FAIL: the stored value did not read back byte-exact"; return 1; }

    _refute_argv_holds "$argvlog" "$canary" "the secret value" || return 1
    _refute_argv_holds "$argvlog" "$hex" "the secret value (hex-encoded)" || return 1
}

# A value the user typed or piped in must reach security byte-exact, interior
# newline and quotes included, now that it travels as a command line on stdin.
test_keychain_set_round_trips_a_multiline_quoted_value() {
    local bindir; bindir=$(_make_fake_security)
    local kcstore="$TEST_TMPDIR/kc-store"
    printf 'line one "q" \\ end\nline two' > "$TEST_TMPDIR/value"

    PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kcstore" \
        "$CS_SECRETS_BIN" set K1 < "$TEST_TMPDIR/value" >/dev/null 2>&1 \
        || { echo "  FAIL: keychain set exited nonzero"; return 1; }
    PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kcstore" \
        "$CS_SECRETS_BIN" get K1 > "$TEST_TMPDIR/got" 2>/dev/null \
        || { echo "  FAIL: keychain get exited nonzero"; return 1; }
    _get_matches "$TEST_TMPDIR/got" "$TEST_TMPDIR/value" \
        || { echo "  FAIL: a multi-line value with quotes and a backslash did not read back byte-exact"; return 1; }
}

# `security -i` reads one command per line into a 4096-byte buffer, so a line
# runs whole only up to 4095 bytes; the rest of a longer line is read as the
# next command. The store line for account "tester" and secret BIG of
# test-session is 37 fixed bytes, the quoted account (8) and service
# "cs:test-session:BIG" (21), and two hex digits per value byte:
# 66 + 2 * 2014 = 4094 fits, 66 + 2 * 2015 = 4096 does not. A value over the
# limit is refused before `security` runs at all; one at the limit is stored.
test_keychain_set_refuses_a_value_too_long_for_one_security_line() {
    local bindir; bindir=$(_make_fake_security)
    local argvlog="$TEST_TMPDIR/security-argv" kcstore="$TEST_TMPDIR/kc-store" out rc=0
    head -c 2015 /dev/zero | tr '\0' 'v' > "$TEST_TMPDIR/over"
    head -c 2014 /dev/zero | tr '\0' 'v' > "$TEST_TMPDIR/at"

    out=$(PATH="$bindir:$PATH" USER=tester CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kcstore" \
        FAKE_SECURITY_ARGVLOG="$argvlog" "$CS_SECRETS_BIN" set BIG < "$TEST_TMPDIR/over" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a value one byte over the limit is refused" || return 1
    assert_eq "Error: refusing to store BIG in the Keychain: its value is 2015 bytes, over the 2014 bytes a Keychain value can hold under this session and name. Store larger values with the encrypted backend (CS_SECRETS_BACKEND=encrypted)." \
        "$out" "the refusal names the limit and the encrypted backend" || return 1
    assert_not_exists "$argvlog" "security is never called for a value over the limit" || return 1

    rc=0
    out=$(PATH="$bindir:$PATH" USER=tester CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kcstore" \
        FAKE_SECURITY_ARGVLOG="$argvlog" "$CS_SECRETS_BIN" set BIG < "$TEST_TMPDIR/at" 2>&1) || rc=$?
    assert_eq "0" "$rc" "a value at the limit is stored: $out" || return 1
    PATH="$bindir:$PATH" USER=tester CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kcstore" \
        "$CS_SECRETS_BIN" get BIG > "$TEST_TMPDIR/got" 2>/dev/null \
        || { echo "  FAIL: keychain get exited nonzero"; return 1; }
    _get_matches "$TEST_TMPDIR/got" "$TEST_TMPDIR/at" \
        || { echo "  FAIL: the value at the limit did not read back byte-exact"; return 1; }
}

test_encrypted_set_keeps_value_and_password_off_argv() {
    local bindir="$TEST_TMPDIR/argv-bin"
    local olog="$TEST_TMPDIR/openssl-argv" jlog="$TEST_TMPDIR/jq-argv"
    _make_argv_logger openssl "$bindir" "$olog" || return 1
    _make_argv_logger jq "$bindir" "$jlog" || return 1
    local canary; canary=$(_argv_canary)
    local pw; pw=$(_argv_password_file)

    PATH="$bindir:$PATH" "$CS_SECRETS_BIN" set K1 < "$canary" >/dev/null 2>&1 \
        || { echo "  FAIL: encrypted set exited nonzero"; return 1; }
    PATH="$bindir:$PATH" "$CS_SECRETS_BIN" get K1 > "$TEST_TMPDIR/got" 2>/dev/null \
        || { echo "  FAIL: encrypted get exited nonzero"; return 1; }

    # Positive control: both wrappers ran, and the round trip held.
    assert_file_contains "$olog" "aes-256-cbc" "the openssl wrapper must have seen the encrypt/decrypt" || return 1
    [ -s "$jlog" ] || { echo "  FAIL: the jq wrapper was never called"; return 1; }
    _get_matches "$TEST_TMPDIR/got" "$canary" \
        || { echo "  FAIL: the stored value did not read back byte-exact"; return 1; }

    _refute_argv_holds "$olog" "$canary" "the secret value" || return 1
    _refute_argv_holds "$jlog" "$canary" "the secret value" || return 1
    _refute_argv_holds "$olog" "$pw" "CS_SECRETS_PASSWORD" || return 1
    _refute_argv_holds "$jlog" "$pw" "CS_SECRETS_PASSWORD" || return 1
}

# Without CS_SECRETS_PASSWORD the store key is derived: a SHA-256 printed as 64
# hex characters. That key must not reach openssl's argv either.
test_encrypted_derived_key_stays_off_argv() {
    local bindir="$TEST_TMPDIR/argv-bin" olog="$TEST_TMPDIR/openssl-argv"
    _make_argv_logger openssl "$bindir" "$olog" || return 1
    local canary; canary=$(_argv_canary)

    ( unset CS_SECRETS_PASSWORD
      PATH="$bindir:$PATH" "$CS_SECRETS_BIN" set K1 < "$canary" >/dev/null 2>&1 \
          || { echo "  FAIL: encrypted set with a derived key exited nonzero"; exit 1; }
      PATH="$bindir:$PATH" "$CS_SECRETS_BIN" get K1 > "$TEST_TMPDIR/got" 2>/dev/null \
          || { echo "  FAIL: encrypted get with a derived key exited nonzero"; exit 1; }
    ) || return 1

    assert_file_contains "$olog" "aes-256-cbc" "the openssl wrapper must have seen the encrypt/decrypt" || return 1
    _get_matches "$TEST_TMPDIR/got" "$canary" \
        || { echo "  FAIL: the stored value did not read back byte-exact"; return 1; }
    if grep -qE '[0-9a-f]{64}' "$olog"; then
        echo "  FAIL: a derived 256-bit key (64 hex characters) reached openssl's argv"
        return 1
    fi
}

# export-file encrypts the whole store, import-file decrypts and merges every
# sync file; neither may put a value or the sync password on argv.
test_sync_export_import_keep_values_off_argv() {
    local bindir="$TEST_TMPDIR/argv-bin"
    local olog="$TEST_TMPDIR/openssl-argv" jlog="$TEST_TMPDIR/jq-argv"
    _make_argv_logger openssl "$bindir" "$olog" || return 1
    _make_argv_logger jq "$bindir" "$jlog" || return 1
    local canary; canary=$(_argv_canary)
    local pw; pw=$(_argv_password_file)

    "$CS_SECRETS_BIN" set K1 < "$canary" >/dev/null 2>&1 \
        || { echo "  FAIL: seeding set exited nonzero"; return 1; }
    PATH="$bindir:$(_ageless_path)" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 \
        || { echo "  FAIL: export-file exited nonzero"; return 1; }
    "$CS_SECRETS_BIN" delete K1 >/dev/null 2>&1 \
        || { echo "  FAIL: delete exited nonzero"; return 1; }
    PATH="$bindir:$(_ageless_path)" "$CS_SECRETS_BIN" import-file >/dev/null 2>&1 \
        || { echo "  FAIL: import-file exited nonzero"; return 1; }

    # Positive control: the import really restored the value from the sync file.
    "$CS_SECRETS_BIN" get K1 > "$TEST_TMPDIR/got" 2>/dev/null \
        || { echo "  FAIL: get after import exited nonzero"; return 1; }
    _get_matches "$TEST_TMPDIR/got" "$canary" \
        || { echo "  FAIL: import-file did not restore the exported value byte-exact"; return 1; }
    assert_file_contains "$olog" "aes-256-cbc" "the openssl wrapper must have seen the sync encrypt/decrypt" || return 1
    [ -s "$jlog" ] || { echo "  FAIL: the jq wrapper was never called"; return 1; }

    _refute_argv_holds "$olog" "$canary" "the secret value" || return 1
    _refute_argv_holds "$jlog" "$canary" "the secret value" || return 1
    _refute_argv_holds "$olog" "$pw" "CS_SECRETS_PASSWORD" || return 1
    _refute_argv_holds "$jlog" "$pw" "CS_SECRETS_PASSWORD" || return 1
}

# Collecting a keychain store into a backup builds its JSON one value at a time;
# that construction must not put a value on jq's argv.
test_keychain_export_file_keeps_values_off_argv() {
    local bindir; bindir=$(_make_fake_security)
    local jlog="$TEST_TMPDIR/jq-argv" olog="$TEST_TMPDIR/openssl-argv"
    _make_argv_logger jq "$bindir" "$jlog" || return 1
    _make_argv_logger openssl "$bindir" "$olog" || return 1
    local canary; canary=$(_argv_canary)
    local pw; pw=$(_argv_password_file)
    local kcstore="$TEST_TMPDIR/kc-store"
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid; mid=$(_machine_id)

    PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kcstore" \
        "$CS_SECRETS_BIN" set K1 < "$canary" >/dev/null 2>&1 \
        || { echo "  FAIL: keychain set exited nonzero"; return 1; }
    : > "$jlog"; : > "$olog"
    PATH="$bindir:$(_ageless_path)" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kcstore" \
        "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 \
        || { echo "  FAIL: keychain export-file exited nonzero"; return 1; }

    # Positive control: the backup really carries the value.
    local f="$meta/secrets.${mid}.enc"
    assert_file_exists "$f" "export-file must write the per-machine sync file" || return 1
    openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$f" -pass env:CS_SECRETS_PASSWORD \
        > "$TEST_TMPDIR/backup.json" 2>/dev/null \
        || { echo "  FAIL: the sync file does not decrypt with the test password"; return 1; }
    grep -qF -f "$canary" "$TEST_TMPDIR/backup.json" \
        || { echo "  FAIL: the sync file does not carry the stored value"; return 1; }
    [ -s "$jlog" ] || { echo "  FAIL: the jq wrapper was never called"; return 1; }

    _refute_argv_holds "$jlog" "$canary" "the secret value" || return 1
    _refute_argv_holds "$olog" "$canary" "the secret value" || return 1
    _refute_argv_holds "$olog" "$pw" "CS_SECRETS_PASSWORD" || return 1
}

# ----------------------------------------------------------------------------
# rename: a session's secrets follow it to a new name. The picker renames the
# session directory, then runs `rename`; every store keyed by the name moves:
# the Keychain entries cs:<old>:*, ~/.cs-secrets/<old>.enc and the age state
# ~/.cs-secrets/sessions/<old>/.
# ----------------------------------------------------------------------------

# Run cs-secrets on the Keychain backend against the fake security's store.
_kc_secrets() {
    PATH="$_RN_BIN:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$TEST_TMPDIR/kc-store" \
        "$CS_SECRETS_BIN" "$@"
}

# Session alpha with a value in all three stores, Keychain K1 (the argv
# canary) and K2, encrypted-store E1, and a pin list, and its directory then
# renamed to bravo as the picker does before it runs `rename`. Leaves the
# fake security's bin dir in _RN_BIN.
_seed_renamed_session() {
    _RN_BIN=$(_make_fake_security)
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs"
    _RN_CANARY=$(_argv_canary)
    printf 'value-two' > "$TEST_TMPDIR/v2"
    printf 'value-enc' > "$TEST_TMPDIR/ve"
    _kc_secrets --session alpha set K1 < "$_RN_CANARY" >/dev/null 2>&1 || return 1
    _kc_secrets --session alpha set K2 < "$TEST_TMPDIR/v2" >/dev/null 2>&1 || return 1
    "$CS_SECRETS_BIN" --session alpha set E1 < "$TEST_TMPDIR/ve" >/dev/null 2>&1 || return 1
    mkdir -p "$HOME/.cs-secrets/sessions/alpha"
    printf 'pin-fingerprint\n' > "$HOME/.cs-secrets/sessions/alpha/age-trusted"
    mv "$CS_SESSIONS_ROOT/alpha" "$CS_SESSIONS_ROOT/bravo"
}

# The names a fake Keychain holds, one service per line, sorted.
_kc_services() {
    local f
    for f in "$TEST_TMPDIR/kc-store"/*; do
        [ -f "$f" ] && head -1 "$f"
    done | sort
}

test_rename_moves_every_store_to_the_new_name() {
    _seed_renamed_session || { echo "  FAIL: fixture: could not seed alpha's stores"; return 1; }
    local out rc=0 argvlog="$TEST_TMPDIR/security-argv"
    out=$(FAKE_SECURITY_ARGVLOG="$argvlog" _kc_secrets --session alpha rename bravo 2>&1) || rc=$?
    assert_eq "0" "$rc" "rename exits 0: $out" || return 1
    assert_output_contains "$out" "^Moved the secrets of session 'alpha' to 'bravo'$" "rename says what it did" || return 1

    assert_eq "cs:bravo:K1
cs:bravo:K2" "$(_kc_services)" "the Keychain holds bravo's entries and none of alpha's" || return 1
    _kc_secrets --session bravo get K1 > "$TEST_TMPDIR/got" 2>/dev/null \
        || { echo "  FAIL: bravo's K1 does not read"; return 1; }
    _get_matches "$TEST_TMPDIR/got" "$_RN_CANARY" || { echo "  FAIL: K1 did not move byte-exact"; return 1; }
    assert_eq "value-two" "$(_kc_secrets --session bravo get K2 2>&1)" "K2 moved" || return 1
    _refute_argv_holds "$argvlog" "$_RN_CANARY" "the moved Keychain value" || return 1

    assert_eq "value-enc" "$("$CS_SECRETS_BIN" --session bravo get E1 2>&1)" "the encrypted store moved" || return 1
    [ ! -e "$HOME/.cs-secrets/alpha.enc" ] || { echo "  FAIL: alpha.enc is still there"; return 1; }

    assert_eq "pin-fingerprint" "$(cat "$HOME/.cs-secrets/sessions/bravo/age-trusted" 2>&1)" "the pin list moved" || return 1
    [ ! -e "$HOME/.cs-secrets/sessions/alpha" ] || { echo "  FAIL: alpha's age state is still there"; return 1; }
    local entry left=""
    for entry in "$HOME/.cs-secrets"/* "$HOME/.cs-secrets"/.[!.]*; do
        [ -e "$entry" ] || continue
        case "$(basename "$entry")" in bravo.enc|sessions|.salt) ;; *) left="$left $(basename "$entry")" ;; esac
    done
    assert_eq "" "$left" "nothing but bravo's store is left in ~/.cs-secrets (no lock, no marker)" || return 1
    assert_eq "age-trusted" "$(ls -A "$HOME/.cs-secrets/sessions/bravo")" "bravo's age state holds the pin list only" || return 1
}

test_rename_refuses_a_new_name_that_has_secrets_or_age_state() {
    _seed_renamed_session || { echo "  FAIL: fixture: could not seed alpha's stores"; return 1; }
    local out rc kind
    for kind in keychain enc age; do
        rm -rf "$TEST_TMPDIR/kc-store/cs_bravo_"* "$HOME/.cs-secrets/bravo.enc" "$HOME/.cs-secrets/sessions/bravo"
        case "$kind" in
            keychain) _kc_secrets --session bravo set B1 < "$TEST_TMPDIR/v2" >/dev/null 2>&1 || return 1 ;;
            enc) "$CS_SECRETS_BIN" --session bravo set B1 < "$TEST_TMPDIR/v2" >/dev/null 2>&1 || return 1 ;;
            age) mkdir -p "$HOME/.cs-secrets/sessions/bravo" && printf 'other\n' > "$HOME/.cs-secrets/sessions/bravo/age-trusted" ;;
        esac
        rc=0
        out=$(_kc_secrets --session alpha rename bravo 2>&1) || rc=$?
        assert_eq "1" "$rc" "rename refuses when bravo has $kind state: $out" || return 1
        case "$kind" in
            keychain) assert_eq "Error: Refusing to move the secrets of session 'alpha' to 'bravo': 'bravo' already has Keychain secrets" "$out" "the refusal names the Keychain" || return 1 ;;
            enc) assert_eq "Error: Refusing to move the secrets of session 'alpha' to 'bravo': $HOME/.cs-secrets/bravo.enc already exists" "$out" "the refusal names the store" || return 1 ;;
            age) assert_eq "Error: Refusing to move the secrets of session 'alpha' to 'bravo': $HOME/.cs-secrets/sessions/bravo already exists" "$out" "the refusal names the age state" || return 1 ;;
        esac
        assert_eq "value-two" "$(_kc_secrets --session alpha get K2 2>&1)" "alpha's Keychain entry stays ($kind)" || return 1
        assert_eq "value-enc" "$("$CS_SECRETS_BIN" --session alpha get E1 2>&1)" "alpha's encrypted store stays ($kind)" || return 1
        assert_eq "pin-fingerprint" "$(cat "$HOME/.cs-secrets/sessions/alpha/age-trusted" 2>&1)" "alpha's pins stay ($kind)" || return 1
        [ ! -e "$HOME/.cs-secrets/.rename.alpha" ] || { echo "  FAIL: a refused rename left a marker ($kind)"; return 1; }
    done
    assert_eq "other" "$(cat "$HOME/.cs-secrets/sessions/bravo/age-trusted")" "bravo's own pins are untouched" || return 1
}

# A session with no secrets of its own takes none from the new name either:
# what an earlier session left under bravo would become the renamed session's
# secrets and trust.
test_rename_of_a_session_without_secrets_refuses_a_new_name_that_has_any() {
    _RN_BIN=$(_make_fake_security)
    mkdir -p "$CS_SESSIONS_ROOT/bravo/.cs"
    printf 'value-two' > "$TEST_TMPDIR/v2"
    local out rc kind
    for kind in keychain enc age; do
        rm -rf "$TEST_TMPDIR/kc-store/cs_bravo_"* "$HOME/.cs-secrets/bravo.enc" "$HOME/.cs-secrets/sessions/bravo"
        case "$kind" in
            keychain) _kc_secrets --session bravo set B1 < "$TEST_TMPDIR/v2" >/dev/null 2>&1 || return 1 ;;
            enc) "$CS_SECRETS_BIN" --session bravo set B1 < "$TEST_TMPDIR/v2" >/dev/null 2>&1 || return 1 ;;
            age) mkdir -p "$HOME/.cs-secrets/sessions/bravo" && printf 'other\n' > "$HOME/.cs-secrets/sessions/bravo/age-trusted" ;;
        esac
        rc=0
        out=$(_kc_secrets --session alpha rename bravo 2>&1) || rc=$?
        assert_eq "1" "$rc" "rename refuses when bravo has $kind state: $out" || return 1
        case "$kind" in
            keychain) assert_eq "Error: Refusing to move the secrets of session 'alpha' to 'bravo': 'bravo' already has Keychain secrets" "$out" "the refusal names the Keychain" || return 1
                      assert_eq "value-two" "$(_kc_secrets --session bravo get B1 2>&1)" "bravo's Keychain entry stays" || return 1 ;;
            enc) assert_eq "Error: Refusing to move the secrets of session 'alpha' to 'bravo': $HOME/.cs-secrets/bravo.enc already exists" "$out" "the refusal names the store" || return 1
                 assert_eq "value-two" "$("$CS_SECRETS_BIN" --session bravo get B1 2>&1)" "bravo's encrypted store stays" || return 1 ;;
            age) assert_eq "Error: Refusing to move the secrets of session 'alpha' to 'bravo': $HOME/.cs-secrets/sessions/bravo already exists" "$out" "the refusal names the age state" || return 1
                 assert_eq "other" "$(cat "$HOME/.cs-secrets/sessions/bravo/age-trusted")" "bravo's pins stay" || return 1 ;;
        esac
        [ ! -e "$HOME/.cs-secrets/.rename.alpha" ] || { echo "  FAIL: a refused rename left a marker ($kind)"; return 1; }
    done
}

# An empty age-state directory under the new name holds no pins and no
# digest; a refused move leaves one behind when its lock was the only entry.
# It is not state the new name has, so it does not block the move.
test_rename_moves_into_an_empty_age_state_directory() {
    _seed_renamed_session || { echo "  FAIL: fixture: could not seed alpha's stores"; return 1; }
    local out rc=0
    mkdir -p "$HOME/.cs-secrets/sessions/bravo"
    out=$(_kc_secrets --session alpha rename bravo 2>&1) || rc=$?
    assert_eq "0" "$rc" "rename exits 0: $out" || return 1
    assert_eq "Moved the secrets of session 'alpha' to 'bravo'" "$out" "rename moves the secrets" || return 1
    assert_eq "pin-fingerprint" "$(cat "$HOME/.cs-secrets/sessions/bravo/age-trusted" 2>&1)" "the pin list is bravo's" || return 1
}

# The new name is a session name, never a command or an option: a session
# may be called purge, and renaming to it moves the secrets there.
test_rename_takes_the_new_name_literally() {
    _seed_renamed_session || { echo "  FAIL: fixture: could not seed alpha's stores"; return 1; }
    local out rc=0
    mv "$CS_SESSIONS_ROOT/bravo" "$CS_SESSIONS_ROOT/purge"
    out=$(_kc_secrets --session alpha rename purge 2>&1) || rc=$?
    assert_eq "0" "$rc" "rename to purge exits 0: $out" || return 1
    assert_eq "Moved the secrets of session 'alpha' to 'purge'" "$out" "rename moves the secrets to purge" || return 1
    assert_eq "cs:purge:K1
cs:purge:K2" "$(_kc_services)" "the Keychain entries are purge's" || return 1
    assert_eq "value-enc" "$("$CS_SECRETS_BIN" --session purge get E1 2>&1)" "the encrypted store is purge's" || return 1
    assert_eq "pin-fingerprint" "$(cat "$HOME/.cs-secrets/sessions/purge/age-trusted" 2>&1)" "the pin list is purge's" || return 1
}

# A word after the new name is refused, not read as a command: every store
# stays alpha's.
test_rename_refuses_a_second_name() {
    _seed_renamed_session || { echo "  FAIL: fixture: could not seed alpha's stores"; return 1; }
    local out rc=0
    out=$(_kc_secrets --session alpha rename bravo purge 2>&1) || rc=$?
    assert_eq "1" "$rc" "rename with a second word exits 1: $out" || return 1
    assert_eq "Error: rename takes one session name; unexpected: purge" "$out" "the refusal names the extra word" || return 1
    assert_eq "cs:alpha:K1
cs:alpha:K2" "$(_kc_services)" "alpha's Keychain entries stay" || return 1
    assert_eq "value-enc" "$("$CS_SECRETS_BIN" --session alpha get E1 2>&1)" "alpha's encrypted store stays" || return 1
    assert_eq "pin-fingerprint" "$(cat "$HOME/.cs-secrets/sessions/alpha/age-trusted" 2>&1)" "alpha's pins stay" || return 1
}

# The secrets follow the session directory, never lead it: while the sessions
# root still has alpha, its secrets stay alpha's. bravo must be a session too,
# so nothing is created under a name the root lacks.
test_rename_refuses_while_the_old_session_directory_exists() {
    _seed_renamed_session || { echo "  FAIL: fixture: could not seed alpha's stores"; return 1; }
    local out rc=0
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs"
    out=$(_kc_secrets --session alpha rename bravo 2>&1) || rc=$?
    assert_eq "1" "$rc" "rename refuses while alpha is a session: $out" || return 1
    assert_eq "Error: Refusing to move the secrets of session 'alpha' to 'bravo': $CS_SESSIONS_ROOT/alpha still exists; rename the session directory first" "$out" \
        "the refusal says the directory moves first" || return 1
    rm -rf "$CS_SESSIONS_ROOT/alpha" "$CS_SESSIONS_ROOT/bravo"
    rc=0
    out=$(_kc_secrets --session alpha rename bravo 2>&1) || rc=$?
    assert_eq "1" "$rc" "rename refuses a target the sessions root lacks: $out" || return 1
    assert_eq "Error: No session named 'bravo' in $CS_SESSIONS_ROOT" "$out" "the refusal names the missing session" || return 1
    assert_eq "cs:alpha:K1
cs:alpha:K2" "$(_kc_services)" "alpha's Keychain entries stay" || return 1
    [ -e "$HOME/.cs-secrets/alpha.enc" ] || { echo "  FAIL: alpha.enc moved"; return 1; }
    [ -e "$HOME/.cs-secrets/sessions/alpha/age-trusted" ] || { echo "  FAIL: alpha's pins moved"; return 1; }
    [ ! -e "$HOME/.cs-secrets/sessions/bravo" ] || { echo "  FAIL: a refused rename created bravo's age state"; return 1; }
}

# A move interrupted after its marker: K1 copied but alpha's copy not yet
# deleted, K2 not copied, the encrypted store moved, one age file moved and
# one not. The rerun finishes it and leaves nothing under alpha.
test_rename_rerun_finishes_an_interrupted_move() {
    _seed_renamed_session || { echo "  FAIL: fixture: could not seed alpha's stores"; return 1; }
    local out rc=0 sec="$HOME/.cs-secrets"
    _kc_secrets --session bravo set K1 < "$_RN_CANARY" >/dev/null 2>&1 || return 1
    mv "$sec/alpha.enc" "$sec/bravo.enc"
    mkdir -p "$sec/sessions/bravo"
    mv "$sec/sessions/alpha/age-trusted" "$sec/sessions/bravo/age-trusted"
    printf 'digest\n' > "$sec/sessions/alpha/age-exported-to"
    printf 'bravo\n' > "$sec/.rename.alpha"
    out=$(_kc_secrets --session alpha rename bravo 2>&1) || rc=$?
    assert_eq "0" "$rc" "the rerun exits 0: $out" || return 1
    assert_output_contains "$out" "^Moved the secrets of session 'alpha' to 'bravo'$" "the rerun finishes" || return 1
    assert_eq "cs:bravo:K1
cs:bravo:K2" "$(_kc_services)" "every Keychain entry is bravo's" || return 1
    assert_eq "value-two" "$(_kc_secrets --session bravo get K2 2>&1)" "K2 moved" || return 1
    assert_eq "value-enc" "$("$CS_SECRETS_BIN" --session bravo get E1 2>&1)" "the encrypted store is bravo's" || return 1
    assert_eq "age-exported-to
age-trusted" "$(ls -A "$sec/sessions/bravo")" "both age files are bravo's" || return 1
    [ ! -e "$sec/sessions/alpha" ] || { echo "  FAIL: alpha's age state is still there"; return 1; }
    [ ! -e "$sec/.rename.alpha" ] || { echo "  FAIL: the marker outlived the finished move"; return 1; }
}

# On a rerun a value present under both names counts as moved only when it is
# the same value; a different one is never overwritten.
test_rename_rerun_refuses_a_value_that_differs_under_both_names() {
    _seed_renamed_session || { echo "  FAIL: fixture: could not seed alpha's stores"; return 1; }
    local out rc=0
    printf 'not-the-same' > "$TEST_TMPDIR/vx"
    _kc_secrets --session bravo set K2 < "$TEST_TMPDIR/vx" >/dev/null 2>&1 || return 1
    printf 'bravo\n' > "$HOME/.cs-secrets/.rename.alpha"
    out=$(_kc_secrets --session alpha rename bravo 2>&1) || rc=$?
    assert_eq "1" "$rc" "the rerun refuses: $out" || return 1
    assert_eq "Error: Refusing to move the secrets of session 'alpha' to 'bravo': Keychain secret K2 differs under the two names; nothing was overwritten" "$out" \
        "the refusal names the secret" || return 1
    assert_eq "value-two" "$(_kc_secrets --session alpha get K2 2>&1)" "alpha's K2 stays" || return 1
    assert_eq "not-the-same" "$(_kc_secrets --session bravo get K2 2>&1)" "bravo's K2 stays" || return 1
    _kc_secrets --session alpha get K1 > "$TEST_TMPDIR/got" 2>/dev/null \
        || { echo "  FAIL: alpha's K1 was deleted by a refused move"; return 1; }
}

# An ln stand-in that refuses every link whose target matches the pattern in
# its first line and hands the rest to the real ln. Echoes its bin dir.
_make_failing_ln() {  # target pattern (a case pattern)
    local bindir="$TEST_TMPDIR/ln-bin" real_ln
    real_ln=$(command -v ln)
    mkdir -p "$bindir"
    cat > "$bindir/ln" <<SHIM
#!/usr/bin/env bash
case "\$2" in
    $1) exit 1 ;;
esac
exec "$real_ln" "\$@"
SHIM
    chmod +x "$bindir/ln"
    echo "$bindir"
}

# A move that fails partway puts back what it moved before it exits: the
# Keychain entries were moved and the encrypted store too when linking the
# pin list fails, and every value is alpha's again, with no marker, so the
# picker can move the session directory back.
test_rename_that_fails_partway_puts_every_value_back_under_the_old_name() {
    _seed_renamed_session || { echo "  FAIL: fixture: could not seed alpha's stores"; return 1; }
    local lnbin out rc=0 sec="$HOME/.cs-secrets"
    lnbin=$(_make_failing_ln "*/sessions/bravo/*")
    out=$(PATH="$lnbin:$PATH" _kc_secrets --session alpha rename bravo 2>&1) || rc=$?
    assert_eq "1" "$rc" "rename exits 1: $out" || return 1
    assert_eq "Error: Refusing to move the secrets of session 'alpha' to 'bravo': could not move $sec/sessions/alpha/age-trusted to $sec/sessions/bravo/age-trusted" "$out" \
        "rename names the step that failed" || return 1
    assert_eq "cs:alpha:K1
cs:alpha:K2" "$(_kc_services)" "the Keychain holds alpha's entries and none of bravo's" || return 1
    _kc_secrets --session alpha get K1 > "$TEST_TMPDIR/got" 2>/dev/null \
        || { echo "  FAIL: alpha's K1 does not read"; return 1; }
    _get_matches "$TEST_TMPDIR/got" "$_RN_CANARY" || { echo "  FAIL: K1 did not come back byte-exact"; return 1; }
    assert_eq "value-two" "$(_kc_secrets --session alpha get K2 2>&1)" "K2 is alpha's" || return 1
    assert_eq "value-enc" "$("$CS_SECRETS_BIN" --session alpha get E1 2>&1)" "the encrypted store is alpha's" || return 1
    assert_not_exists "$sec/bravo.enc" "no encrypted store under bravo" || return 1
    assert_eq "pin-fingerprint" "$(cat "$sec/sessions/alpha/age-trusted" 2>&1)" "the pin list is alpha's" || return 1
    assert_not_exists "$sec/sessions/bravo" "no age state under bravo" || return 1
    assert_not_exists "$sec/.rename.alpha" "no marker is left" || return 1
    assert_eq "bravo
test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root" || return 1
}

# A move that cannot put back what it moved keeps its marker and says so: the
# values are split across the names, and the rerun it names finishes the move.
test_rename_that_cannot_put_a_failed_move_back_keeps_the_marker() {
    _seed_renamed_session || { echo "  FAIL: fixture: could not seed alpha's stores"; return 1; }
    local lnbin out rc=0 sec="$HOME/.cs-secrets"
    lnbin=$(_make_failing_ln "*/sessions/bravo/*|*/alpha.enc")
    out=$(PATH="$lnbin:$PATH" _kc_secrets --session alpha rename bravo 2>&1) || rc=$?
    assert_eq "1" "$rc" "rename exits 1: $out" || return 1
    assert_eq "Error: Refusing to move the secrets of session 'alpha' to 'bravo': could not move $sec/sessions/alpha/age-trusted to $sec/sessions/bravo/age-trusted
Error: could not move the secrets of session 'alpha' back from 'bravo': could not move $sec/bravo.enc back to $sec/alpha.enc; rerun: cs -secrets --session alpha rename bravo" "$out" \
        "rename names the step that failed and the one it could not put back" || return 1
    assert_eq "bravo" "$(cat "$sec/.rename.alpha" 2>&1)" "the marker names the move to finish" || return 1
    out=$(_kc_secrets --session alpha rename bravo 2>&1) || { echo "  FAIL: the rerun failed: $out"; return 1; }
    assert_eq "Moved the secrets of session 'alpha' to 'bravo'" "$out" "the rerun finishes the move" || return 1
    assert_eq "cs:bravo:K1
cs:bravo:K2" "$(_kc_services)" "every Keychain entry is bravo's" || return 1
    assert_eq "value-enc" "$("$CS_SECRETS_BIN" --session bravo get E1 2>&1)" "the encrypted store is bravo's" || return 1
    assert_eq "pin-fingerprint" "$(cat "$sec/sessions/bravo/age-trusted" 2>&1)" "the pin list is bravo's" || return 1
}

# A signal that lands the moment rename has written its marker, before it
# moves anything, puts back nothing and removes the marker: a marker is left
# only by a move it could not put back. BASH_ENV hands cs-secrets a DEBUG
# trap that sends it one TERM before its first command after the marker
# exists.
test_a_signal_right_after_the_marker_is_written_leaves_no_marker() {
    _seed_renamed_session || { echo "  FAIL: fixture: could not seed alpha's stores"; return 1; }
    local env="$TEST_TMPDIR/term-after-marker.sh" out rc=0 sec="$HOME/.cs-secrets"
    cat > "$env" <<HOOK
set -T
trap '[ -e "$sec/.rename.alpha" ] && [ ! -e "$TEST_TMPDIR/term.sent" ] && : > "$TEST_TMPDIR/term.sent" && kill -TERM \$\$' DEBUG
HOOK
    out=$(BASH_ENV="$env" _kc_secrets --session alpha rename bravo 2>&1) || rc=$?
    [ -e "$TEST_TMPDIR/term.sent" ] || { echo "  FAIL: fixture: the hook never saw the marker"; return 1; }
    assert_eq "143" "$rc" "rename exits 143: $out" || return 1
    assert_eq "" "$out" "rename prints nothing" || return 1
    assert_not_exists "$sec/.rename.alpha" "no marker is left" || return 1
    assert_eq "cs:alpha:K1
cs:alpha:K2" "$(_kc_services)" "the Keychain holds alpha's entries and none of bravo's" || return 1
    assert_eq "value-enc" "$("$CS_SECRETS_BIN" --session alpha get E1 2>&1)" "the encrypted store is alpha's" || return 1
    assert_eq "pin-fingerprint" "$(cat "$sec/sessions/alpha/age-trusted" 2>&1)" "the pin list is alpha's" || return 1
}

# A session name is matched literally in the Keychain: a dot in a.b matches
# a dot, never the dash of a-b, so list, export, purge and rename of a.b see
# none of a-b's entries.
test_keychain_commands_match_the_session_name_literally() {
    _RN_BIN=$(_make_fake_security)
    mkdir -p "$CS_SESSIONS_ROOT/a-b/.cs" "$CS_SESSIONS_ROOT/a.b/.cs"
    printf 'value-ab' > "$TEST_TMPDIR/vab"
    _kc_secrets --session a-b set K1 < "$TEST_TMPDIR/vab" >/dev/null 2>&1 || { echo "  FAIL: fixture: set a-b K1 failed"; return 1; }
    local out rc=0
    out=$(_kc_secrets --session a.b list 2>&1) || rc=$?
    assert_eq "0 No secrets stored for session: a.b" "$rc $out" "list a.b shows none of a-b's names" || return 1
    rc=0
    out=$(_kc_secrets --session a.b export 2>&1) || rc=$?
    assert_eq "0 " "$rc $out" "export a.b exports nothing" || return 1
    rc=0
    out=$(_kc_secrets --session a.b purge 2>&1) || rc=$?
    assert_eq "0 No secrets to purge for session: a.b" "$rc $out" "purge a.b finds nothing to purge" || return 1
    rm -rf "$CS_SESSIONS_ROOT/a.b"
    rc=0
    out=$(_kc_secrets --session a.b rename x 2>&1) || rc=$?
    assert_eq "1 Error: No session named 'x' in $CS_SESSIONS_ROOT" "$rc $out" "rename a.b refuses only for the missing target" || return 1
    mkdir -p "$CS_SESSIONS_ROOT/a.b/.cs"
    rc=0
    out=$(_kc_secrets --session x rename a.b 2>&1) || rc=$?
    assert_eq "0 No secrets to move for session: x" "$rc $out" "rename to a.b finds no secrets under a.b" || return 1
    assert_eq "cs:a-b:K1" "$(_kc_services)" "a-b's entry is untouched" || return 1
    assert_eq "value-ab" "$(_kc_secrets --session a-b get K1 2>&1)" "a-b's K1 keeps its value" || return 1
}

# A rename refused before it made the new name's age directory leaves that
# directory alone: an export or age add for the new name may have just made it.
test_a_refused_rename_leaves_the_new_names_age_directory() {
    _seed_renamed_session || { echo "  FAIL: fixture: could not seed alpha's stores"; return 1; }
    local out rc=0
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs" "$HOME/.cs-secrets/sessions/bravo"
    out=$(_kc_secrets --session alpha rename bravo 2>&1) || rc=$?
    assert_eq "1" "$rc" "rename refuses while alpha is a session: $out" || return 1
    [ -d "$HOME/.cs-secrets/sessions/bravo" ] || { echo "  FAIL: the refused rename removed bravo's age directory"; return 1; }
}

# A rename that has moved every value exits 0 even when it cannot release a
# lock it took: the picker reads a nonzero exit as "still under the old name"
# and moves the session directory back away from its secrets. The lock it
# could not remove is named on stderr and left for the user to remove. A
# stand-in rm fails on alpha's write lock.
test_a_rename_that_cannot_release_a_lock_after_the_move_exits_0() {
    _seed_renamed_session || { echo "  FAIL: fixture: could not seed alpha's stores"; return 1; }
    local rmbin="$TEST_TMPDIR/rm-bin" real_rm out rc=0 sec="$HOME/.cs-secrets" lock="$CS_SESSIONS_ROOT/.secrets-lock.alpha"
    real_rm=$(command -v rm)
    mkdir -p "$rmbin"
    cat > "$rmbin/rm" <<SHIM
#!/usr/bin/env bash
case "\$*" in
    "-f $lock") echo "rm: simulated failure on \$2" >&2; exit 1 ;;
esac
exec "$real_rm" "\$@"
SHIM
    chmod +x "$rmbin/rm"
    out=$(PATH="$rmbin:$PATH" _kc_secrets --session alpha rename bravo 2>"$TEST_TMPDIR/err") || rc=$?
    assert_eq "0" "$rc" "rename exits 0: $out $(cat "$TEST_TMPDIR/err")" || return 1
    assert_eq "Moved the secrets of session 'alpha' to 'bravo'" "$out" "rename says what it did" || return 1
    assert_eq "rm: simulated failure on $lock
Warning: could not remove the lock $lock; remove it by hand" "$(cat "$TEST_TMPDIR/err")" \
        "rename names the lock it could not release" || return 1
    assert_eq "cs:bravo:K1
cs:bravo:K2" "$(_kc_services)" "the Keychain holds bravo's entries and none of alpha's" || return 1
    assert_eq "value-enc" "$("$CS_SECRETS_BIN" --session bravo get E1 2>&1)" "the encrypted store is bravo's" || return 1
    assert_eq "pin-fingerprint" "$(cat "$sec/sessions/bravo/age-trusted" 2>&1)" "the pin list is bravo's" || return 1
    assert_not_exists "$sec/sessions/alpha" "no age state is left under alpha" || return 1
    assert_not_exists "$sec/.rename.alpha" "no marker is left" || return 1
    assert_eq ".secrets-lock.alpha
bravo
test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "only the lock rm could not remove is left in the sessions root" || return 1
}

# On a Mac the Keychain holds what a session stored there whatever backend a
# later run uses, so rename on the encrypted backend reads it too. Run against
# the fake security's store, as macOS.
_mac_encrypted_secrets() {
    PATH="$_RN_BIN:$PATH" CS_PLATFORM_OVERRIDE=macos CS_SECRETS_BACKEND=encrypted FAKE_SECURITY_STORE="$TEST_TMPDIR/kc-store" \
        "$CS_SECRETS_BIN" "$@"
}

test_rename_on_the_encrypted_backend_moves_the_keychain_entries() {
    _seed_renamed_session || { echo "  FAIL: fixture: could not seed alpha's stores"; return 1; }
    local out rc=0
    out=$(_mac_encrypted_secrets --session alpha rename bravo 2>&1) || rc=$?
    assert_eq "0" "$rc" "rename exits 0: $out" || return 1
    assert_eq "Moved the secrets of session 'alpha' to 'bravo'" "$out" "rename says what it did" || return 1
    assert_eq "cs:bravo:K1
cs:bravo:K2" "$(_kc_services)" "the Keychain holds bravo's entries and none of alpha's" || return 1
    assert_eq "value-two" "$(_kc_secrets --session bravo get K2 2>&1)" "K2 moved" || return 1
    assert_eq "value-enc" "$("$CS_SECRETS_BIN" --session bravo get E1 2>&1)" "the encrypted store moved" || return 1
}

# What a removed session left in the Keychain under the new name would become
# the renamed session's, and a Keychain that cannot be read may hold such a
# value: either is refused before anything changes.
test_rename_on_the_encrypted_backend_refuses_what_the_keychain_holds_or_hides() {
    _RN_BIN=$(_make_fake_security)
    mkdir -p "$CS_SESSIONS_ROOT/bravo/.cs"
    printf 'stale' > "$TEST_TMPDIR/stale"
    _kc_secrets --session bravo set K1 < "$TEST_TMPDIR/stale" >/dev/null 2>&1 || return 1
    local out rc=0
    out=$(_mac_encrypted_secrets --session alpha rename bravo 2>&1) || rc=$?
    assert_eq "1" "$rc" "rename refuses: $out" || return 1
    assert_eq "Error: Refusing to move the secrets of session 'alpha' to 'bravo': 'bravo' already has Keychain secrets" "$out" \
        "the refusal names the Keychain" || return 1
    assert_eq "stale" "$(_kc_secrets --session bravo get K1 2>&1)" "bravo's Keychain entry stays" || return 1

    rm -rf "$TEST_TMPDIR/kc-store"
    rc=0
    out=$(FAKE_SECURITY_MODE=fail _mac_encrypted_secrets --session alpha rename bravo 2>&1) || rc=$?
    assert_eq "1" "$rc" "rename refuses an unreadable Keychain: $out" || return 1
    assert_eq "Error: Refusing to move the secrets of session 'alpha' to 'bravo': failed to enumerate the Keychain" "$out" \
        "the refusal says the Keychain could not be read" || return 1
    [ ! -e "$HOME/.cs-secrets/.rename.alpha" ] || { echo "  FAIL: a refused rename left a marker"; return 1; }
}

# The picker runs rename on every rename, mostly for sessions with no secrets:
# those must not gain a ~/.cs-secrets.
test_rename_with_nothing_to_move_creates_no_cs_secrets() {
    local bindir; bindir=$(_make_fake_security)
    local out rc=0
    mkdir -p "$CS_SESSIONS_ROOT/bravo/.cs"
    out=$(PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$TEST_TMPDIR/kc-store" \
        "$CS_SECRETS_BIN" --session alpha rename bravo 2>&1) || rc=$?
    assert_eq "0" "$rc" "rename exits 0: $out" || return 1
    assert_eq "No secrets to move for session: alpha" "$out" "rename says there was nothing" || return 1
    [ ! -e "$HOME/.cs-secrets" ] || { echo "  FAIL: rename created ~/.cs-secrets"; return 1; }
    assert_eq "bravo
test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root" || return 1
}

# ----------------------------------------------------------------------------
# The session write lock: set, delete, purge and rename serialise on one lock
# per session name, <sessions root>/.secrets-lock.<name>, and set and delete
# refuse a name the sessions root does not have. Without both, a write that
# lands while rename moves the session is deleted or left under the old name
# after it said it was stored.
# ----------------------------------------------------------------------------

# Run cs-secrets on the named backend; the Keychain is the fake security's
# store. Needs _RN_BIN.
_backend_secrets() {  # backend, args...
    PATH="$_RN_BIN:$PATH" CS_SECRETS_BACKEND="$1" FAKE_SECURITY_STORE="$TEST_TMPDIR/kc-store" \
        "$CS_SECRETS_BIN" "${@:2}"
}

# Session ghost with K1 on both backends and a pin list, then removed from
# the sessions root: what `cs -rm`, or a rename away from the name, leaves.
_seed_removed_session() {
    _RN_BIN=$(_make_fake_security)
    mkdir -p "$CS_SESSIONS_ROOT/ghost/.cs"
    printf 'kept' > "$TEST_TMPDIR/kept"
    printf 'late' > "$TEST_TMPDIR/late"
    local backend
    for backend in keychain encrypted; do
        _backend_secrets "$backend" --session ghost set K1 < "$TEST_TMPDIR/kept" >/dev/null 2>&1 || return 1
    done
    mkdir -p "$HOME/.cs-secrets/sessions/ghost"
    printf 'pin-fingerprint\n' > "$HOME/.cs-secrets/sessions/ghost/age-trusted"
    rm -rf "$CS_SESSIONS_ROOT/ghost"
}

# A value stored under a name the sessions root does not have is one no
# session reads, and one the rename that moved the session away never moves.
test_set_and_delete_refuse_a_session_the_root_does_not_have() {
    _seed_removed_session || { echo "  FAIL: fixture: could not seed ghost's stores"; return 1; }
    local backend out rc
    for backend in keychain encrypted; do
        rc=0
        out=$(_backend_secrets "$backend" --session ghost set K2 < "$TEST_TMPDIR/late" 2>&1) || rc=$?
        assert_eq "1" "$rc" "$backend set exits 1: $out" || return 1
        assert_eq "Error: No session named 'ghost' in $CS_SESSIONS_ROOT" "$out" "$backend set names the session and the root" || return 1
        rc=0
        out=$(_backend_secrets "$backend" --session ghost delete K1 2>&1) || rc=$?
        assert_eq "1" "$rc" "$backend delete exits 1: $out" || return 1
        assert_eq "Error: No session named 'ghost' in $CS_SESSIONS_ROOT" "$out" "$backend delete names the session and the root" || return 1
        assert_eq "Secrets for session: ghost
  - K1" "$(_backend_secrets "$backend" --session ghost list 2>&1)" "$backend holds K1 and no K2" || return 1
        assert_eq "kept" "$(_backend_secrets "$backend" --session ghost get K1 2>&1)" "$backend K1 keeps its value" || return 1
    done
    assert_not_exists "$CS_SESSIONS_ROOT/ghost" "no directory is created for the session" || return 1
    assert_eq "test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root" || return 1
}

# migrate-backend stores every key it moves, so a session the sessions root
# does not have is refused before it starts, by name, not key by key.
test_migrate_backend_refuses_a_session_the_root_does_not_have() {
    _seed_removed_session || { echo "  FAIL: fixture: could not seed ghost's stores"; return 1; }
    local out rc=0 backend
    out=$(_backend_secrets keychain --session ghost migrate-backend keychain --from encrypted --delete-source 2>&1) || rc=$?
    assert_eq "1" "$rc" "migrate-backend exits 1: $out" || return 1
    assert_eq "Error: No session named 'ghost' in $CS_SESSIONS_ROOT" "$out" "migrate-backend names the session and the root" || return 1
    for backend in keychain encrypted; do
        assert_eq "kept" "$(_backend_secrets "$backend" --session ghost get K1 2>&1)" "$backend K1 keeps its value" || return 1
    done
}

# Stored secrets outlive `cs -rm`, and purge is how they are removed
# afterwards, so purge does not need the session directory.
test_purge_removes_what_a_removed_session_left() {
    _seed_removed_session || { echo "  FAIL: fixture: could not seed ghost's stores"; return 1; }
    local backend out rc
    for backend in keychain encrypted; do
        rc=0
        out=$(_backend_secrets "$backend" --session ghost purge 2>&1) || rc=$?
        assert_eq "0" "$rc" "$backend purge exits 0: $out" || return 1
        assert_eq "Purged 1 secret(s) for session: ghost" "$out" "$backend purge counts what it removed" || return 1
        assert_eq "No secrets stored for session: ghost" "$(_backend_secrets "$backend" --session ghost list 2>&1)" \
            "$backend holds nothing of ghost's" || return 1
    done
    assert_not_exists "$HOME/.cs-secrets/sessions/ghost" "the age state went with the secrets" || return 1
    assert_eq "test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root" || return 1
}

# The write lock lives in the sessions root, so a Keychain write on a machine
# with no ~/.cs-secrets does not create one.
test_keychain_writes_create_no_cs_secrets_dir() {
    _RN_BIN=$(_make_fake_security)
    printf 'value-one' > "$TEST_TMPDIR/v1"
    assert_eq "Stored secret: K1" "$(_backend_secrets keychain set K1 < "$TEST_TMPDIR/v1" 2>&1)" "set stores K1" || return 1
    assert_eq "Deleted secret: K1" "$(_backend_secrets keychain delete K1 2>&1)" "delete removes K1" || return 1
    assert_eq "Stored secret: K1" "$(_backend_secrets keychain set K1 < "$TEST_TMPDIR/v1" 2>&1)" "set stores K1 again" || return 1
    assert_eq "Purged 1 secret(s) for session: test-session" "$(_backend_secrets keychain purge 2>&1)" "purge removes K1" || return 1
    assert_not_exists "$HOME/.cs-secrets" "no ~/.cs-secrets is created" || return 1
    assert_eq "test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root" || return 1
}

# A write that cannot take the lock changes nothing and names the lock file.
# PID 1 stands for another process holding it.
test_set_delete_and_purge_take_the_session_write_lock() {
    _RN_BIN=$(_make_fake_security)
    local lock="$CS_SESSIONS_ROOT/.secrets-lock.test-session" backend verb out rc
    printf 'value-one' > "$TEST_TMPDIR/v1"
    for backend in keychain encrypted; do
        _backend_secrets "$backend" set K1 < "$TEST_TMPDIR/v1" >/dev/null 2>&1 \
            || { echo "  FAIL: fixture: $backend set failed"; return 1; }
    done
    printf '1\n' > "$lock"
    for backend in keychain encrypted; do
        for verb in "set K2" "delete K1" "purge"; do
            rc=0
            # shellcheck disable=SC2086  # $verb is a verb and its argument
            out=$(CS_SECRETS_LOCK_TIMEOUT=0 _backend_secrets "$backend" $verb < "$TEST_TMPDIR/v1" 2>&1) || rc=$?
            assert_eq "1" "$rc" "$backend $verb exits 1: $out" || return 1
            assert_eq "Error: timed out after 0s acquiring the secrets write lock for session 'test-session' (held by PID 1). If no such process is running, remove: $lock
Error: Refusing to change the secrets of session 'test-session': could not acquire the secrets write lock" "$out" \
                "$backend $verb names the lock" || return 1
        done
        assert_eq "Secrets for session: test-session
  - K1" "$(_backend_secrets "$backend" list 2>&1)" "$backend holds K1 and no K2" || return 1
    done
    assert_eq "1" "$(cat "$lock")" "the other holder's lock is left alone" || return 1
}

# rename takes the write lock of both names before it looks at any store,
# even to say there is nothing to move: a set that passed its session check
# before the directory moved may still be writing under the old name.
test_rename_takes_the_write_lock_of_both_names() {
    _RN_BIN=$(_make_fake_security)
    mkdir -p "$CS_SESSIONS_ROOT/bravo/.cs"
    local name lock out rc
    for name in alpha bravo; do
        lock="$CS_SESSIONS_ROOT/.secrets-lock.$name"
        printf '1\n' > "$lock"
        rc=0
        out=$(CS_SECRETS_LOCK_TIMEOUT=0 _kc_secrets --session alpha rename bravo 2>&1) || rc=$?
        assert_eq "1" "$rc" "rename exits 1 while $name's write lock is held: $out" || return 1
        assert_eq "Error: timed out after 0s acquiring the secrets write lock for session '$name' (held by PID 1). If no such process is running, remove: $lock
Error: Refusing to move the secrets of session 'alpha' to 'bravo': could not acquire the secrets write locks" "$out" \
            "rename names $name's lock" || return 1
        rm -f "$lock"
        assert_eq "bravo
test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "rename released the lock it did take" || return 1
    done
    assert_not_exists "$HOME/.cs-secrets" "a refused rename creates no ~/.cs-secrets" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs-secrets tests"
echo "================"
echo ""

# Backend
run_test test_backend_shows_encrypted
run_test test_backend_override_via_env
run_test test_backend_wsl_defaults_encrypted_not_keychain

# Store and retrieve
run_test test_store_and_get
run_test test_set_warns_about_a_value_on_argv
run_test test_set_reads_value_from_stdin
run_test test_set_reads_value_from_file_redirect
run_test test_set_refuses_placeholder_values
run_test test_set_on_a_tty_does_not_echo_the_value
run_test test_store_with_spaces_in_value
run_test test_store_with_special_chars
run_test test_store_overwrites_existing
run_test test_get_nonexistent_fails

# List
run_test test_list_empty
run_test test_list_shows_stored_secrets
run_test test_list_does_not_show_values

# Delete
run_test test_delete_removes_secret
run_test test_delete_nonexistent_fails
run_test test_delete_preserves_other_secrets

# Purge
run_test test_purge_removes_all
run_test test_purge_drops_the_sessions_age_state
run_test test_age_add_refuses_a_session_the_root_does_not_have
run_test test_age_add_refuses_a_directory_that_is_not_a_session
run_test test_age_add_refuses_a_name_that_is_a_path
run_test test_session_verbs_refuse_a_name_that_is_a_path
run_test test_age_remove_refuses_a_session_the_root_does_not_have
run_test test_export_file_refuses_a_session_the_root_does_not_have
run_test test_import_file_refuses_a_session_the_root_does_not_have
run_test test_purge_empty_session

# Export
run_test test_export_produces_eval_format
run_test test_multi_line_secrets_survive_get_and_export
run_test test_export_is_eval_safe

# Encrypted file internals
run_test test_encrypted_file_created
run_test test_encrypted_file_not_plaintext
run_test test_encrypted_file_permissions
run_test test_secrets_dir_permissions
run_test test_encrypted_write_failure_preserves_prior_store
run_test test_encrypted_write_success_updates_and_leaves_no_temp

# Session isolation
run_test test_sessions_are_isolated

# CLI dispatch
run_test test_store_alias_works
run_test test_ls_alias_works
run_test test_rm_alias_works
run_test test_session_flag_overrides_env
run_test test_export_file_refuses_a_session_whose_cs_links_out
run_test test_export_file_refuses_a_named_path_a_link_carries_out
run_test test_export_file_refuses_a_default_file_linked_to_a_directory_outside
run_test test_no_session_errors
run_test test_picker_selects_numbered_session
run_test test_picker_prompt_stays_off_stdout
run_test test_picker_enter_takes_cwd_default
run_test test_picker_worktree_dir_defaults_to_base
run_test test_picker_hides_archived_but_cwd_defaults
run_test test_picker_eof_aborts_despite_default
run_test test_picker_all_archived_cwd_still_defaults
run_test test_picker_rejects_invalid_choice
run_test test_picker_empty_root_errors
run_test test_explicit_session_arg_outranks_ambient_namespace
run_test test_help_shows_usage

# Per-machine sync files
run_test test_export_file_writes_per_machine_enc
run_test test_export_file_machine_id_survives_unset_user
run_test test_export_file_skips_rewrite_when_unchanged
run_test test_export_file_rewrites_when_changed
run_test test_import_file_merges_all_machines_and_legacy
run_test test_set_rejects_a_name_that_breaks_out_of_export
run_test test_export_refuses_colliding_exported_names
run_test test_migrate_refuses_an_invalid_name
run_test test_export_namespaces_every_variable
run_test test_export_namespace_neutralises_dangerous_names
run_test test_import_file_refuses_a_hostile_key_name
run_test test_import_file_refuses_two_names_that_export_as_one_variable
run_test test_import_file_refuses_a_name_that_shares_a_variable_with_a_stored_secret
run_test test_import_file_stores_nothing_when_one_name_is_invalid
run_test test_import_file_refuses_a_name_ending_in_a_carriage_return
run_test test_export_refuses_a_hostile_name_already_in_the_store
run_test test_import_file_aborts_when_the_store_write_fails
run_test test_import_file_skips_undecryptable_files
run_test test_import_file_aborts_on_backend_read_failure_no_overwrite
run_test test_import_file_stores_when_secret_genuinely_absent
run_test test_import_file_stores_when_secret_absent_and_user_unset
run_test test_keychain_export_file_aborts_on_jq_failure
run_test test_keychain_list_loud_on_extraction_failure

# Unknown backend guard
run_test test_unknown_backend_guard
run_test test_unknown_backend_display_is_loud

# Backup/migrate data integrity (fail loud, never partial/empty)
run_test test_encrypted_get_loud_on_decrypt_failure
run_test test_encrypted_list_loud_on_decrypt_failure
run_test test_encrypted_export_file_aborts_on_decrypt_failure
run_test test_encrypted_migrate_aborts_on_decrypt_failure
run_test test_encrypted_export_file_empty_store_is_clean
run_test test_keychain_export_file_aborts_on_enumeration_failure
run_test test_keychain_export_file_empty_store_is_clean

# Comprehensive sweep: keychain list/purge/export, migrate
run_test test_keychain_list_loud_on_enumeration_failure
run_test test_keychain_list_empty_is_clean
run_test test_keychain_purge_loud_on_enumeration_failure
run_test test_keychain_export_loud_on_enumeration_failure
run_test test_keychain_export_loud_on_read_failure
run_test test_migrate_partial_write_fails_loud

# Concurrency & durability
run_test test_encrypted_concurrent_stores_no_lost_update
run_test test_export_file_atomic_preserves_prior_on_encrypt_failure
run_test test_encrypted_stale_lock_fails_loud_not_reaped
run_test test_keychain_export_does_not_require_cs_secrets_dir

# No secret on a child's argv (audit H3)
run_test test_keychain_set_keeps_the_value_off_argv
run_test test_keychain_set_round_trips_a_multiline_quoted_value
run_test test_keychain_set_refuses_a_value_too_long_for_one_security_line
run_test test_encrypted_set_keeps_value_and_password_off_argv
run_test test_encrypted_derived_key_stays_off_argv
run_test test_sync_export_import_keep_values_off_argv
run_test test_keychain_export_file_keeps_values_off_argv

# age recipients
run_test test_age_export_skips_rewrite_when_nothing_changed
run_test test_age_recipient_digest_leaves_the_shells_own_locale_alone
run_test test_age_add_reencrypts_an_unchanged_store
run_test test_age_remove_reencrypts_an_unchanged_store
run_test test_export_refuses_an_unpinned_pushed_recipient
run_test test_export_encrypts_to_a_recipient_pinned_by_age_add
run_test test_export_never_pins_from_a_forged_sync_file
run_test test_export_ignores_a_pin_list_planted_in_the_checkout
run_test test_password_export_to_an_external_path_needs_no_writable_checkout
run_test test_export_on_a_fresh_clone_pins_nothing
run_test test_age_remove_drops_the_pin
run_test test_age_add_takes_an_ssh_ed25519_key_file
run_test test_age_add_takes_a_raw_ssh_ed25519_key
run_test test_age_add_refuses_a_different_key_under_a_recipient_name_in_use
run_test test_age_add_without_age_points_at_age_init
run_test test_age_add_refuses_what_is_not_a_key
run_test test_import_file_reads_a_file_encrypted_to_this_machines_ssh_key
run_test test_import_file_still_reads_a_file_encrypted_to_the_earlier_age_key
run_test test_age_init_creates_this_machines_ssh_key
run_test test_age_init_names_a_missing_ssh_keygen
run_test test_first_export_makes_this_machines_ssh_key_the_recipient
run_test test_export_encrypts_to_age_and_ssh_recipients_together
run_test test_export_switches_this_machine_to_its_ssh_key
run_test test_first_export_without_ssh_keygen_refuses
run_test test_export_signs_the_sync_file
run_test test_export_replaces_a_signature_that_does_not_verify
run_test test_export_adds_this_machine_to_a_session_that_has_recipients
run_test test_rename_moves_every_store_to_the_new_name
run_test test_rename_refuses_a_new_name_that_has_secrets_or_age_state
run_test test_rename_of_a_session_without_secrets_refuses_a_new_name_that_has_any
run_test test_rename_moves_into_an_empty_age_state_directory
run_test test_rename_takes_the_new_name_literally
run_test test_rename_refuses_a_second_name
run_test test_rename_refuses_while_the_old_session_directory_exists
run_test test_rename_on_the_encrypted_backend_moves_the_keychain_entries
run_test test_rename_on_the_encrypted_backend_refuses_what_the_keychain_holds_or_hides
run_test test_rename_that_fails_partway_puts_every_value_back_under_the_old_name
run_test test_rename_that_cannot_put_a_failed_move_back_keeps_the_marker
run_test test_a_signal_right_after_the_marker_is_written_leaves_no_marker
run_test test_keychain_commands_match_the_session_name_literally
run_test test_a_refused_rename_leaves_the_new_names_age_directory
run_test test_a_rename_that_cannot_release_a_lock_after_the_move_exits_0
run_test test_rename_rerun_finishes_an_interrupted_move
run_test test_rename_rerun_refuses_a_value_that_differs_under_both_names
run_test test_rename_with_nothing_to_move_creates_no_cs_secrets
run_test test_set_and_delete_refuse_a_session_the_root_does_not_have
run_test test_migrate_backend_refuses_a_session_the_root_does_not_have
run_test test_purge_removes_what_a_removed_session_left
run_test test_keychain_writes_create_no_cs_secrets_dir
run_test test_set_delete_and_purge_take_the_session_write_lock
run_test test_rename_takes_the_write_lock_of_both_names
run_test test_export_refuses_when_this_machines_recipient_file_holds_another_key
run_test test_export_leaves_a_current_signed_file_alone
run_test test_later_export_without_ssh_keygen_refuses_and_keeps_the_signed_file
run_test test_export_to_a_named_file_signs_beside_it
run_test test_export_refuses_a_directory_where_the_signature_goes
run_test test_password_export_writes_no_signature
run_test test_import_file_takes_a_file_signed_by_a_pinned_peer
run_test test_import_file_skips_an_unsigned_age_file
run_test test_import_file_skips_an_unsigned_file_under_this_machines_name
run_test test_import_file_skips_a_file_signed_by_an_unpinned_key
run_test test_import_file_skips_a_file_signed_by_a_key_outside_the_session
run_test test_import_file_skips_a_signed_file_changed_after_signing
run_test test_import_file_decrypts_the_bytes_it_verified
run_test test_import_file_verifies_the_bytes_it_will_decrypt
run_test test_import_file_skips_a_signature_that_is_a_symbolic_link
run_test test_import_file_skips_a_sync_file_that_is_a_symbolic_link
run_test test_import_file_skips_a_password_sync_file_that_is_a_symbolic_link
run_test test_import_file_keeps_the_store_when_a_value_exceeds_the_exec_limit
run_test test_import_file_refuses_a_session_whose_cs_is_a_link
run_test test_import_file_refuses_a_named_file_behind_a_linked_directory
run_test test_import_file_refuses_a_cs_swapped_for_a_link_before_the_copy
run_test test_import_file_reads_the_cs_it_checked_when_swapped_during_the_copy
run_test test_import_file_refuses_a_named_file_behind_a_linked_directory_however_spelled
run_test test_import_file_refuses_a_named_file_behind_a_linked_directory_in_another_case
run_test test_import_file_refuses_a_named_file_in_the_local_secrets_store
run_test test_import_file_refuses_a_named_file_behind_another_sessions_linked_directory
run_test test_import_file_names_a_file_it_cannot_read
run_test test_import_file_reads_a_relative_name_under_an_exported_cdpath
run_test test_import_file_reads_the_session_under_a_relative_tmpdir
run_test test_import_file_counts_a_cs_it_cannot_enter_as_unreadable
run_test test_keychain_export_file_carries_a_value_past_the_exec_limit
run_test test_set_refuses_to_write_a_store_of_more_than_one_document
run_test test_import_file_skips_a_file_whose_signature_cannot_be_read
run_test test_import_file_skips_a_file_signed_for_another_session
run_test test_import_file_allow_unsigned_takes_a_file_with_no_signature
run_test test_import_file_allow_unsigned_still_skips_a_bad_signature
run_test test_import_file_refuses_a_named_file_that_is_not_trusted
run_test test_import_file_without_ssh_keygen_skips_signed_files_by_name

report_results
