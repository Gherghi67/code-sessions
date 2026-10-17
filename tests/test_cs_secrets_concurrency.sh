#!/usr/bin/env bash
# ABOUTME: Concurrency tests for cs-secrets: locking, atomic writes, signals
# ABOUTME: Split from test_cs_secrets.sh because these sleeps are the gate's long pole

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
        # A store that touches <hold>.began and then waits for <hold>.release,
        # two seconds at most, stays in flight until a test lets it go.
        if [ -n "${FAKE_SECURITY_HOLD_STORE:-}" ]; then
            : > "$FAKE_SECURITY_HOLD_STORE.began"
            held=0
            until [ -e "$FAKE_SECURITY_HOLD_STORE.release" ] || [ "$held" -ge 40 ]; do
                sleep 0.05
                held=$((held + 1))
            done
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
        # A delete that touches a marker tells a test the caller has begun
        # deleting.
        [ -n "${FAKE_SECURITY_DELETE_MARKER:-}" ] && : > "$FAKE_SECURITY_DELETE_MARKER"
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

# Why these live apart from test_cs_secrets.sh.
#
# Every test here proves something about two cs-secrets processes racing, and
# the only way to hold a writer inside its critical section is to slow it down
# on purpose — an openssl shim that sleeps on encrypt, then a sleep long enough
# for the peer to reach the contended read. Those sleeps are the assertion, not
# padding: remove them and the test passes against a store with no locking at
# all.
#
# That made the combined suite the parallel gate's long pole (89s against a few
# seconds for most suites), and a long pole bounds the whole run no matter how
# many lanes run_all.sh opens — one file cannot be split across lanes. Splitting
# them out lets the fast majority rejoin the pack while these run beside it.
#
# Keep the split on that basis: a test belongs here when it is slow BECAUSE it
# synchronises two processes, not merely because it is slow.

# D3: first-use salt creation must be atomic. get_encryption_password derives
# the key from a machine id plus a random salt persisted on first use. The
# original `openssl rand -hex 32 > SALT_FILE` opens the file EMPTY before
# openssl fills it; a second process reading the salt in that window derives its
# key from an empty salt and its store becomes permanently undecryptable. With
# real openssl the window is microseconds and never observed, so a slow-`rand`
# openssl shim widens it deterministically (real openssl still does the actual
# encrypt/decrypt). The fix publishes a fully-written salt in one atomic step,
# so the second writer either sees no salt (and creates its own, losing the
# exclusive-create race) or reads the winner's COMPLETE salt — never an empty one.
test_encrypted_salt_write_is_atomic_under_concurrency() {
    unset CS_SECRETS_PASSWORD   # force the machine-id + salt derivation path
    local real_ssl shim
    real_ssl=$(command -v openssl)
    shim="$TEST_TMPDIR/ssl-shim"
    mkdir -p "$shim"
    cat > "$shim/openssl" <<SHIM
#!/usr/bin/env bash
# Delay only the salt generation so SALT_FILE stays mid-write for a beat;
# everything else (encrypt/decrypt) passes straight through to real openssl.
if [ "\$1" = "rand" ]; then sleep 0.4; fi
exec "$real_ssl" "\$@"
SHIM
    chmod +x "$shim/openssl"
    create_test_session salt-A >/dev/null
    create_test_session salt-B >/dev/null

    PATH="$shim:$PATH" CLAUDE_SESSION_NAME="salt-A" "$CS_SECRETS_BIN" set k "vA" >/dev/null 2>&1 &
    sleep 0.15   # B reaches the salt read while A's file is still mid-write
    PATH="$shim:$PATH" CLAUDE_SESSION_NAME="salt-B" "$CS_SECRETS_BIN" set k "vB" >/dev/null 2>&1 &
    wait

    # Read back with the real (fast) openssl. Both stores must decrypt: neither
    # may have been written under an empty or transient salt.
    local got_a got_b
    got_a=$(CLAUDE_SESSION_NAME="salt-A" "$CS_SECRETS_BIN" get k 2>&1)
    got_b=$(CLAUDE_SESSION_NAME="salt-B" "$CS_SECRETS_BIN" get k 2>&1)
    assert_eq "vA" "$got_a" "salt-A must decrypt after concurrent first-use salt write" || return 1
    assert_eq "vB" "$got_b" "salt-B must decrypt (must not read a half-written salt)" || return 1
}

# codex finding 2: a signal during the critical section must TERMINATE the
# writer. Bash does not auto-exit after an INT/TERM/HUP trap handler returns; a
# handler that only released the lock would let execution continue lock-less
# through the write, so another process could interleave (the lost update this
# mutex prevents). A slow-encrypt openssl shim holds the writer in the critical
# section; we TERM it there and assert it did not go on to report success and
# left no lock behind.
test_encrypted_signal_terminates_writer_mid_critical_section() {
    local sess="sig-term"
    create_test_session "$sess" >/dev/null
    local real_ssl shim
    real_ssl=$(command -v openssl)
    shim="$TEST_TMPDIR/sig-shim"
    mkdir -p "$shim"
    cat > "$shim/openssl" <<SHIM
#!/usr/bin/env bash
# Slow only the encrypt so the writer sits in the critical section; decrypt and
# everything else pass through to the real binary.
orig=("\$@"); is_enc=0
for a in "\$@"; do [ "\$a" = "-e" ] && is_enc=1; done
[ "\$is_enc" = 1 ] && sleep 2
exec "$real_ssl" "\${orig[@]}"
SHIM
    chmod +x "$shim/openssl"

    local logf="$TEST_TMPDIR/sig-out.log"
    PATH="$shim:$PATH" CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set k v >"$logf" 2>&1 &
    local pid=$!
    sleep 0.6            # let it acquire and enter the slow encrypt
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    local rc=$?

    assert_output_not_contains "$(cat "$logf")" "Stored secret" \
        "a TERM in the critical section must terminate the writer, not complete the store" || return 1
    [ "$rc" -ne 0 ] || { echo "  FAIL: writer must exit non-zero when TERMed mid-store (got $rc)"; return 1; }
    assert_file_not_exists "$HOME/.cs-secrets/.lock.$sess" \
        "the lock must be released after the signal" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/.secrets-lock.$sess" \
        "the write lock must be released after the signal" || return 1
}

# codex round 3 finding: encrypted_purge deleted the store without holding the
# per-session mutex, so it raced concurrent store/delete. A store that read the
# store under lock could rename its update into place AFTER purge deleted the
# file, resurrecting purged secrets (or purge could drop a just-committed
# update). Purge must hold the same lock across the whole operation. A slow-
# encrypt store holds the lock while a purge is launched; serialized, the purge
# runs after the store commits and leaves the store empty, not resurrected.
test_encrypted_purge_serialized_with_concurrent_store() {
    local sess="purge-race"
    create_test_session "$sess" >/dev/null
    CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set A vA >/dev/null 2>&1

    local real_ssl shim
    real_ssl=$(command -v openssl)
    shim="$TEST_TMPDIR/purge-shim"
    mkdir -p "$shim"
    cat > "$shim/openssl" <<SHIM
#!/usr/bin/env bash
orig=("\$@"); is_enc=0
for a in "\$@"; do [ "\$a" = "-e" ] && is_enc=1; done
[ "\$is_enc" = 1 ] && sleep 2
exec "$real_ssl" "\${orig[@]}"
SHIM
    chmod +x "$shim/openssl"

    # Store B holds the lock through a slow encrypt; purge is launched during it.
    PATH="$shim:$PATH" CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set B vB >/dev/null 2>&1 &
    sleep 0.6
    CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" purge >/dev/null 2>&1
    wait

    # Serialized, purge runs after the store commits -> the store is empty. The
    # bug lets store's rename resurrect the secrets after purge "succeeded".
    local out
    out=$(CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" list 2>&1)
    assert_output_contains "$out" "No secrets" \
        "a purge serialized with a concurrent store must leave the store empty, not resurrected" || return 1
    assert_file_not_exists "$HOME/.cs-secrets/$sess.enc" \
        "purge must remove the store file even against a concurrent store" || return 1
}

# F1: export must serialize against store on the same session, or an older
# export can rename a stale snapshot over a newer sync backup. Export A reads the
# store, then a store adds a secret, then a second export commits the newer set;
# without the mutex A resumes and overwrites the newer backup with its stale
# snapshot, silently losing the secret. A slow-encrypt shim holds export A in its
# encrypt while B is added and re-exported; serialized, the last export wins and
# the backup keeps every secret.
test_export_serialized_against_concurrent_store_no_stale_overwrite() {
    local sess="export-race"
    mkdir -p "$CS_SESSIONS_ROOT/$sess/.cs"
    CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set A vA >/dev/null 2>&1

    # Force the .enc path (no age) and slow ONLY the export's encrypt. The shim
    # uses ABSOLUTE openssl/sleep paths: it runs under the ageless sandbox PATH,
    # which deliberately omits both, so a bare `sleep`/`openssl` would silently
    # no-op the injection (and the race would never open).
    local real_ssl real_sleep ageless slowdir
    real_ssl=$(command -v openssl)
    real_sleep=$(command -v sleep)
    ageless=$(_ageless_path)
    slowdir="$TEST_TMPDIR/export-slow"
    mkdir -p "$slowdir"
    cat > "$slowdir/openssl" <<SHIM
#!/usr/bin/env bash
orig=("\$@"); is_enc=0
for a in "\$@"; do [ "\$a" = "-e" ] && is_enc=1; done
[ "\$is_enc" = 1 ] && "$real_sleep" 2
exec "$real_ssl" "\${orig[@]}"
SHIM
    chmod +x "$slowdir/openssl"

    local mid meta sync
    mid=$(_machine_id)
    meta="$CS_SESSIONS_ROOT/$sess/.cs"
    sync="$meta/secrets.${mid}.enc"

    # Export A reads {A} and slow-encrypts (holds the lock ~2s with the fix).
    PATH="$slowdir:$ageless" CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 &
    sleep 0.5
    # Add B and re-export (fast). Serialized behind A's lock with the fix.
    PATH="$ageless" CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set B vB >/dev/null 2>&1
    PATH="$ageless" CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1
    wait

    # The backup must still contain B: A's stale snapshot must not overwrite it.
    local restored
    restored=$(openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
        -in "$sync" -pass "pass:$CS_SECRETS_PASSWORD" 2>/dev/null)
    assert_output_contains "$restored" "vB" \
        "export must not rename a stale snapshot over a newer sync backup (F1)" || return 1
}

# F2: migrate-backend --delete-source must not blanket-purge the source. collect
# reads the source unlocked; a secret stored AFTER that snapshot is not in the
# migrated set, so a blanket purge would delete it without ever migrating it
# (lost). Deleting only the migrated keys leaves the concurrently-added secret
# intact. A slow source-decrypt holds migrate in its collect while B is stored;
# after migrate, B must still be in the encrypted source.
test_migrate_delete_source_preserves_concurrent_store() {
    local bindir; bindir=$(_make_fake_security)
    local kcstore="$TEST_TMPDIR/kc-store-1"
    "$CS_SECRETS_BIN" set A vA >/dev/null 2>&1

    # A store that stalls mid-write lets a concurrent `set` land in the source
    # between the migration reading it and deleting it.
    local marker="$TEST_TMPDIR/target-store-began-1"
    PATH="$bindir:$PATH" FAKE_SECURITY_STORE="$kcstore" FAKE_SECURITY_SLOW_STORE="$marker" \
        "$CS_SECRETS_BIN" migrate-backend keychain --from encrypted --delete-source >/dev/null 2>&1 &
    local mpid=$!
    local waited=0
    until [ -f "$marker" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 200 ] && break; done
    "$CS_SECRETS_BIN" set B vB >/dev/null 2>&1
    wait "$mpid" || true

    assert_eq "vB" "$("$CS_SECRETS_BIN" get B 2>/dev/null)" \
        "a secret stored during the migration must survive --delete-source" || return 1
}

# F2 (codex): a migrated key concurrently deleted from the source before the
# delete-source cleanup runs must NOT abort the migration. backend_delete calls
# error()/exit on a not-found key, and a bare `|| true` cannot catch a function's
# exit — only a subshell boundary can. The migration copy already fully
# succeeded, so a source key that vanished is fine; migrate must still exit 0.
test_migrate_delete_source_tolerates_concurrently_deleted_key() {
    local bindir; bindir=$(_make_fake_security)
    local kcstore="$TEST_TMPDIR/kc-store-2"
    "$CS_SECRETS_BIN" set A vA >/dev/null 2>&1

    local marker="$TEST_TMPDIR/target-store-began-2"
    PATH="$bindir:$PATH" FAKE_SECURITY_STORE="$kcstore" FAKE_SECURITY_SLOW_STORE="$marker" \
        "$CS_SECRETS_BIN" migrate-backend keychain --from encrypted --delete-source >/dev/null 2>&1 &
    local mpid=$!
    local waited=0
    until [ -f "$marker" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 200 ] && break; done
    # Concurrently delete the migrated key A from the source before delete-source.
    "$CS_SECRETS_BIN" delete A >/dev/null 2>&1
    local rc=0
    wait "$mpid" || rc=$?

    assert_eq "0" "$rc" \
        "migrate --delete-source must not abort when a migrated key was concurrently deleted from the source" || return 1
    # The suite pins CS_SECRETS_BACKEND=encrypted; read the TARGET back explicitly
    # or this asserts against the source the migration just deleted from.
    assert_eq "vA" "$(PATH="$bindir:$PATH" FAKE_SECURITY_STORE="$kcstore" \
        CS_SECRETS_BACKEND=keychain "$CS_SECRETS_BIN" get A 2>/dev/null)" \
        "migrated secret A must have reached the target" || return 1
}

# Codex (batch 1, round 1): on the keychain backend nothing serialises an
# export against `age remove` and a second export. Export A snapshots the
# recipient set {self, R} and is slow inside age; meanwhile R is removed and
# export B writes a ciphertext for {self} and records that digest; A then
# renames its {self, R} ciphertext over B's. The sync file still admits the
# revoked key. Every export, `age add` and `age remove` must hold the one
# per-session lock across recipient snapshot, encryption, rename and digest
# record, on every backend. The slow age shim is bound to export A only
# (CS_AGE_BIN); the removal and export B run the real binary.
test_export_holds_the_lock_across_encrypt_and_digest_on_every_backend() {
    local age_bin keygen_bin
    age_bin=$(command -v age 2>/dev/null) || age_bin=""
    keygen_bin=$(command -v age-keygen 2>/dev/null) || keygen_bin=""
    if [ -z "$age_bin" ] || [ -z "$keygen_bin" ]; then
        echo "    SKIP (age and age-keygen are not installed)"
        return 77
    fi
    local bindir; bindir=$(_make_fake_security)
    local kcstore="$TEST_TMPDIR/kc-store-age"
    local sess="export-revoke-race"
    local meta="$CS_SESSIONS_ROOT/$sess/.cs"
    mkdir -p "$meta"
    local sync
    sync="$meta/secrets.$(_machine_id).age"
    # Every cs-secrets call below runs on the (fake) keychain backend with the
    # real age; `kc` keeps the three overrides in one place.
    kc() {
        PATH="$bindir:$PATH" FAKE_SECURITY_STORE="$kcstore" FAKE_SECURITY_SESSION="$sess" \
            CS_SECRETS_BACKEND=keychain CLAUDE_SESSION_NAME="$sess" CS_AGE_BIN="${KC_AGE:-$age_bin}" \
            "$CS_SECRETS_BIN" "$@"
    }
    "$keygen_bin" -o "$TEST_TMPDIR/r.key" 2>/dev/null || { echo "  FAIL: age-keygen"; return 1; }
    "$keygen_bin" -y "$TEST_TMPDIR/r.key" > "$TEST_TMPDIR/r.pub" || return 1
    kc age init >/dev/null 2>&1 || { echo "  FAIL: age init"; return 1; }
    kc set api_key sk_123 >/dev/null 2>&1 || { echo "  FAIL: set"; return 1; }
    # First export auto-adds and pins this machine's own key.
    kc export-file >/dev/null 2>&1 || { echo "  FAIL: first export"; return 1; }
    kc age add "$TEST_TMPDIR/r.pub" >/dev/null 2>&1 || { echo "  FAIL: age add"; return 1; }
    kc export-file >/dev/null 2>&1 || { echo "  FAIL: export to self+R"; return 1; }
    if ! "$age_bin" -d -i "$TEST_TMPDIR/r.key" < "$sync" 2>/dev/null | grep -qF sk_123; then
        echo "  FAIL: fixture: R must decrypt the export made while it was a recipient"
        return 1
    fi

    # An age that sleeps on encrypt (-o) only: decrypts for the unchanged check
    # stay fast, so A's pause sits exactly between recipient snapshot and rename.
    local slow="$TEST_TMPDIR/slow-age"
    cat > "$slow" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "-o" ] && sleep 2 && break; done
exec "$age_bin" "\$@"
SHIM
    chmod +x "$slow"

    kc set api_key sk_456 >/dev/null 2>&1 || { echo "  FAIL: set 2"; return 1; }
    KC_AGE="$slow" kc export-file >"$TEST_TMPDIR/export-a.out" 2>&1 &
    local apid=$!
    sleep 0.5
    kc age remove r >"$TEST_TMPDIR/remove.out" 2>&1 \
        || { echo "  FAIL: age remove: $(cat "$TEST_TMPDIR/remove.out")"; kill "$apid" 2>/dev/null; return 1; }
    kc export-file >"$TEST_TMPDIR/export-b.out" 2>&1 \
        || { echo "  FAIL: export B: $(cat "$TEST_TMPDIR/export-b.out")"; kill "$apid" 2>/dev/null; return 1; }
    wait "$apid" || { echo "  FAIL: export A: $(cat "$TEST_TMPDIR/export-a.out")"; return 1; }

    if "$age_bin" -d -i "$TEST_TMPDIR/r.key" < "$sync" >/dev/null 2>&1; then
        echo "  FAIL: the sync file left behind by the race still decrypts with the revoked key"
        return 1
    fi
    if ! "$age_bin" -d -i "$HOME/.cs-secrets/id_ed25519" < "$sync" 2>/dev/null | grep -qF sk_456; then
        echo "  FAIL: this machine's own key must decrypt the final export to the latest value"
        return 1
    fi
    assert_file_contains "$HOME/.cs-secrets/sessions/$sess/age-exported-to" " $sync\$" "the recipient digest is recorded for the sync file" || return 1
}

# Two cs processes that both find no machine key each generate one. The first
# to place its private key wins and the second adopts that pair: a key some
# sync file is already encrypted to is never replaced. The ssh-keygen shim
# delays each generation by a different amount, so both are under way before
# either lands and the first has reported its key before the second places.
test_two_first_runs_keep_one_machine_key() {
    local age_bin real_keygen
    age_bin=$(command -v age 2>/dev/null) || age_bin=""
    real_keygen=$(command -v ssh-keygen 2>/dev/null) || real_keygen=""
    if [ -z "$age_bin" ] || [ -z "$real_keygen" ]; then
        echo "    SKIP (age and ssh-keygen are not installed)"
        return 77
    fi
    local shim="$TEST_TMPDIR/keygen-shim" log="$TEST_TMPDIR/keygen.log"
    mkdir -p "$shim"
    cat > "$shim/ssh-keygen" <<SHIM
#!/bin/bash
case " \$* " in
    *" -t "*) echo generate >> "$log"; sleep "\${SHIM_SLEEP:-0}" ;;
esac
exec "$real_keygen" "\$@"
SHIM
    chmod +x "$shim/ssh-keygen"

    PATH="$shim:$PATH" SHIM_SLEEP=2 CS_AGE_BIN="$age_bin" "$CS_SECRETS_BIN" age init > "$TEST_TMPDIR/first.out" 2>&1 &
    local first_pid=$!
    PATH="$shim:$PATH" SHIM_SLEEP=5 CS_AGE_BIN="$age_bin" "$CS_SECRETS_BIN" age init > "$TEST_TMPDIR/second.out" 2>&1 &
    local second_pid=$!
    wait "$first_pid" || { echo "  FAIL: the first age init failed: $(cat "$TEST_TMPDIR/first.out")"; wait "$second_pid"; return 1; }
    wait "$second_pid" || { echo "  FAIL: the second age init failed: $(cat "$TEST_TMPDIR/second.out")"; return 1; }

    assert_eq "2" "$(grep -c generate "$log")" "both processes generated a key (the race ran)" || return 1
    local kept key_type key_body
    kept=$(CS_AGE_BIN="$age_bin" "$CS_SECRETS_BIN" age pubkey 2>&1)
    read -r key_type key_body _ <<< "$("$real_keygen" -y -f "$HOME/.cs-secrets/id_ed25519")"
    assert_eq "$key_type $key_body" "$kept" "the public key belongs to the private key that was kept" || return 1
    assert_eq "Public key: $kept" "$(grep '^Public key:' "$TEST_TMPDIR/first.out" | tail -1)" \
        "the key the first process reported is the one kept" || return 1
    assert_eq "Public key: $kept" "$(grep '^Public key:' "$TEST_TMPDIR/second.out" | tail -1)" \
        "the second process reports the same key" || return 1
    assert_eq "" "$(find "$HOME/.cs-secrets" -name '.keygen.*')" "no staging directory is left" || return 1
}

# A Keychain set that passed its session check before the picker moved the
# session directory, and writes while rename moves the session's entries: the
# set says it stored the value, so the value must end up under the new name.
# The set's write is held in flight; it is let go when rename begins deleting
# the old entries, which is after rename copied the earlier value. With no
# lock shared by the two, rename reaches that point and the held value lands
# under the old name or is deleted. With the lock rename waits, the held write
# times out of its wait, and rename then moves what the set stored.
test_keychain_set_during_a_rename_is_moved_with_the_session() {
    local bindir; bindir=$(_make_fake_security)
    local kc="$TEST_TMPDIR/kc-store" hold="$TEST_TMPDIR/hold"
    _kcs() {
        PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kc" "$CS_SECRETS_BIN" "$@"
    }
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs"
    printf 'value-one' > "$TEST_TMPDIR/v1"
    printf 'value-two' > "$TEST_TMPDIR/v2"
    printf 'v2-concurrent' > "$TEST_TMPDIR/v2c"
    _kcs --session alpha set K1 < "$TEST_TMPDIR/v1" >/dev/null 2>&1 || { echo "  FAIL: fixture: set K1 failed"; return 1; }
    _kcs --session alpha set K2 < "$TEST_TMPDIR/v2" >/dev/null 2>&1 || { echo "  FAIL: fixture: set K2 failed"; return 1; }

    FAKE_SECURITY_HOLD_STORE="$hold" _kcs --session alpha set K2 < "$TEST_TMPDIR/v2c" > "$TEST_TMPDIR/set.out" 2>&1 &
    # The wait ends on the held write or on the set exiting; the deadline only
    # stops a hang.
    local spid=$! deadline=$((SECONDS + 300)) rc=0
    while [ ! -f "$hold.began" ] && kill -0 "$spid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.05; done
    if [ ! -f "$hold.began" ]; then
        if kill -0 "$spid" 2>/dev/null; then
            kill -KILL "$spid" 2>/dev/null
            echo "  FAIL: fixture: the held set never reached its write: not there after 300 s"
        else
            wait "$spid" || rc=$?
            echo "  FAIL: fixture: the held set never reached its write: it exited first, status $rc: $(cat "$TEST_TMPDIR/set.out")"
        fi
        return 1
    fi

    # The picker moves the directory, then runs rename.
    mv "$CS_SESSIONS_ROOT/alpha" "$CS_SESSIONS_ROOT/bravo"
    FAKE_SECURITY_DELETE_MARKER="$hold.release" _kcs --session alpha rename bravo > "$TEST_TMPDIR/rename.out" 2>&1 &
    local rpid=$! src=0 rrc=0
    wait "$spid" || src=$?
    wait "$rpid" || rrc=$?

    assert_eq "0" "$src" "the set exits 0: $(cat "$TEST_TMPDIR/set.out")" || return 1
    assert_eq "Stored secret: K2" "$(cat "$TEST_TMPDIR/set.out")" "the set says it stored K2" || return 1
    assert_eq "0" "$rrc" "rename exits 0: $(cat "$TEST_TMPDIR/rename.out")" || return 1
    assert_eq "Moved the secrets of session 'alpha' to 'bravo'" "$(cat "$TEST_TMPDIR/rename.out")" "rename says what it did" || return 1
    assert_eq "v2-concurrent" "$(_kcs --session bravo get K2 2>&1)" "the value the set stored is bravo's" || return 1
    assert_eq "value-one" "$(_kcs --session bravo get K1 2>&1)" "K1 moved" || return 1
    local f services=""
    for f in "$kc"/*; do
        [ -f "$f" ] && services="$services$(head -1 "$f") "
    done
    assert_eq "cs:bravo:K1 cs:bravo:K2 " "$services" "nothing is left under alpha" || return 1
    assert_eq "bravo
test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root" || return 1
}

# A set that waits on the write lock while the picker moves its session away
# checks the session once it holds the lock: a value stored under the old name
# is one no session reads. The lock wait's sleep is the only one cs-secrets
# runs, so a sleep that leaves a marker shows the set is waiting; PID 1 stands
# for the rename holding the lock.
test_a_set_that_waited_on_the_write_lock_refuses_a_session_moved_away() {
    local bindir; bindir=$(_make_fake_security)
    local kc="$TEST_TMPDIR/kc-store" shim="$TEST_TMPDIR/sleep-shim" lock="$CS_SESSIONS_ROOT/.secrets-lock.alpha"
    local real_sleep; real_sleep=$(command -v sleep)
    _kcs() {
        PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kc" "$CS_SECRETS_BIN" "$@"
    }
    mkdir -p "$shim"
    cat > "$shim/sleep" <<SHIM
#!/usr/bin/env bash
: > "$TEST_TMPDIR/waiting"
exec "$real_sleep" "\$@"
SHIM
    chmod +x "$shim/sleep"
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs"
    printf 'late' > "$TEST_TMPDIR/late"
    printf '1\n' > "$lock"

    PATH="$shim:$PATH" CS_SECRETS_LOCK_TIMEOUT=30 _kcs --session alpha set K1 < "$TEST_TMPDIR/late" > "$TEST_TMPDIR/set.out" 2>&1 &
    local spid=$! waited=0 rc=0
    until [ -f "$TEST_TMPDIR/waiting" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 400 ] && break; done
    [ -f "$TEST_TMPDIR/waiting" ] || { echo "  FAIL: fixture: the set never waited on the write lock"; kill "$spid"; wait "$spid"; return 1; }

    # The picker moves the directory; rename finds nothing and lets the lock go.
    mv "$CS_SESSIONS_ROOT/alpha" "$CS_SESSIONS_ROOT/bravo"
    rm -f "$lock"
    wait "$spid" || rc=$?

    assert_eq "1" "$rc" "the set exits 1: $(cat "$TEST_TMPDIR/set.out")" || return 1
    assert_eq "Error: No session named 'alpha' in $CS_SESSIONS_ROOT" "$(cat "$TEST_TMPDIR/set.out")" \
        "the set names the session it no longer finds" || return 1
    assert_eq "No secrets stored for session: alpha" "$(_kcs --session alpha list 2>&1)" "nothing is stored under alpha" || return 1
    assert_eq "bravo
test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root" || return 1
}

# A TERM to a Keychain set while `security` writes keeps the write lock until
# that write is done: a rename that took the lock the moment it went would
# move the session's entries while the value still lands under the old name.
# The store is held in flight for two seconds at most; the set exits after it,
# so the stored value is there the moment the set has exited.
test_a_term_keeps_the_write_lock_until_the_keychain_write_finishes() {
    local bindir; bindir=$(_make_fake_security)
    local kc="$TEST_TMPDIR/kc-store" hold="$TEST_TMPDIR/hold" slot="$TEST_TMPDIR/kc-store/cs_alpha_K1"
    _kcs() {
        PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kc" "$CS_SECRETS_BIN" "$@"
    }
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs"
    printf 'value-one' > "$TEST_TMPDIR/v1"

    # Started directly, not through _kcs: the TERM must reach cs-secrets, not
    # a subshell running the function.
    PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kc" FAKE_SECURITY_HOLD_STORE="$hold" \
        "$CS_SECRETS_BIN" --session alpha set K1 < "$TEST_TMPDIR/v1" > "$TEST_TMPDIR/set.out" 2>&1 &
    # The wait ends on the held write or on the set exiting; the deadline only
    # stops a hang.
    local spid=$! deadline=$((SECONDS + 300)) waited=0 rc=0 written_first=0
    while [ ! -f "$hold.began" ] && kill -0 "$spid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.05; done
    if [ ! -f "$hold.began" ]; then
        if kill -0 "$spid" 2>/dev/null; then
            kill -KILL "$spid" 2>/dev/null
            echo "  FAIL: fixture: the set never reached its write: not there after 300 s"
        else
            wait "$spid" || rc=$?
            echo "  FAIL: fixture: the set never reached its write: it exited first, status $rc: $(cat "$TEST_TMPDIR/set.out")"
        fi
        return 1
    fi
    kill -TERM "$spid"
    wait "$spid" || rc=$?
    [ -f "$slot" ] && written_first=1
    # A store left running writes on its own; let it finish before teardown.
    waited=0
    until [ -f "$slot" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 100 ] && break; done

    assert_eq "1" "$written_first" "the Keychain write finished before the set exited" || return 1
    assert_eq "143" "$rc" "the set exits 143: $(cat "$TEST_TMPDIR/set.out")" || return 1
    assert_eq "" "$(cat "$TEST_TMPDIR/set.out")" "the set does not say it stored the value" || return 1
    assert_eq "value-one" "$(_kcs --session alpha get K1 2>&1)" "the write in flight stored its value" || return 1
    assert_eq "alpha
test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root" || return 1
}

# Two renames of alpha to different names: the second waits on alpha's write
# lock while the first writes its marker naming bravo and stops partway, with
# K1 moved and K2 still alpha's. The second reads the marker once it holds the
# lock and refuses, naming the move to finish; it moves nothing to charlie.
# PID 1 stands for the first rename holding the lock, and the sleep shim's
# marker shows the second is waiting on it.
test_a_rename_that_waited_on_the_write_lock_refuses_over_a_move_begun_meanwhile() {
    local bindir; bindir=$(_make_fake_security)
    local kc="$TEST_TMPDIR/kc-store" shim="$TEST_TMPDIR/sleep-shim" lock="$CS_SESSIONS_ROOT/.secrets-lock.alpha"
    local real_sleep; real_sleep=$(command -v sleep)
    _kcs() {
        PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kc" "$CS_SECRETS_BIN" "$@"
    }
    mkdir -p "$shim"
    cat > "$shim/sleep" <<SHIM
#!/usr/bin/env bash
: > "$TEST_TMPDIR/waiting"
exec "$real_sleep" "\$@"
SHIM
    chmod +x "$shim/sleep"
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs"
    printf 'value-one' > "$TEST_TMPDIR/v1"
    printf 'value-two' > "$TEST_TMPDIR/v2"
    _kcs --session alpha set K1 < "$TEST_TMPDIR/v1" >/dev/null 2>&1 || { echo "  FAIL: fixture: set K1 failed"; return 1; }
    _kcs --session alpha set K2 < "$TEST_TMPDIR/v2" >/dev/null 2>&1 || { echo "  FAIL: fixture: set K2 failed"; return 1; }
    rm -rf "$CS_SESSIONS_ROOT/alpha"
    mkdir -p "$CS_SESSIONS_ROOT/bravo/.cs" "$CS_SESSIONS_ROOT/charlie/.cs"
    printf '1\n' > "$lock"

    PATH="$shim:$PATH" CS_SECRETS_LOCK_TIMEOUT=30 _kcs --session alpha rename charlie > "$TEST_TMPDIR/rename.out" 2>&1 &
    local rpid=$! waited=0 rc=0
    until [ -f "$TEST_TMPDIR/waiting" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 400 ] && break; done
    [ -f "$TEST_TMPDIR/waiting" ] || { echo "  FAIL: fixture: the rename never waited on the write lock"; kill "$rpid"; wait "$rpid"; return 1; }

    # The first rename's marker and its first move, K1, then it stops.
    mkdir -p "$HOME/.cs-secrets"
    printf 'bravo\n' > "$HOME/.cs-secrets/.rename.alpha"
    _kcs --session bravo set K1 < "$TEST_TMPDIR/v1" >/dev/null 2>&1 || { echo "  FAIL: fixture: set bravo K1 failed"; wait "$rpid"; return 1; }
    rm -f "$kc/cs_alpha_K1"
    rm -f "$lock"
    wait "$rpid" || rc=$?

    assert_eq "1" "$rc" "the second rename exits 1: $(cat "$TEST_TMPDIR/rename.out")" || return 1
    assert_eq "Error: Refusing to move the secrets of session 'alpha' to 'charlie': an earlier move of 'alpha' to 'bravo' did not finish; rerun: cs -secrets --session alpha rename bravo" \
        "$(cat "$TEST_TMPDIR/rename.out")" "the refusal names the move to finish" || return 1
    local f services=""
    for f in "$kc"/*; do
        [ -f "$f" ] && services="$services$(head -1 "$f") "
    done
    assert_eq "cs:alpha:K2 cs:bravo:K1 " "$services" "nothing moved to charlie" || return 1
    assert_eq "bravo" "$(cat "$HOME/.cs-secrets/.rename.alpha")" "the marker still names bravo" || return 1
    assert_eq "bravo
charlie
test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root" || return 1
}

# A TERM to a rename while it stores a Keychain entry under the new name puts
# the move back once that store is done: the entry is alpha's alone again,
# with no marker and no lock left. The store is held in flight for two
# seconds at most.
test_a_term_to_a_rename_puts_back_what_it_moved() {
    local bindir; bindir=$(_make_fake_security)
    local kc="$TEST_TMPDIR/kc-store" hold="$TEST_TMPDIR/hold"
    _kcs() {
        PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kc" "$CS_SECRETS_BIN" "$@"
    }
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs"
    printf 'value-one' > "$TEST_TMPDIR/v1"
    _kcs --session alpha set K1 < "$TEST_TMPDIR/v1" >/dev/null 2>&1 || { echo "  FAIL: fixture: set K1 failed"; return 1; }
    mv "$CS_SESSIONS_ROOT/alpha" "$CS_SESSIONS_ROOT/bravo"

    # Started directly, not through _kcs: the TERM must reach cs-secrets, not
    # a subshell running the function.
    PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kc" FAKE_SECURITY_HOLD_STORE="$hold" \
        "$CS_SECRETS_BIN" --session alpha rename bravo > "$TEST_TMPDIR/rename.out" 2>&1 &
    local rpid=$! waited=0 rc=0
    until [ -f "$hold.began" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 200 ] && break; done
    [ -f "$hold.began" ] || { echo "  FAIL: fixture: the rename never reached its Keychain store"; wait "$rpid"; return 1; }
    kill -TERM "$rpid"
    wait "$rpid" || rc=$?

    assert_eq "143" "$rc" "the rename exits 143: $(cat "$TEST_TMPDIR/rename.out")" || return 1
    assert_eq "" "$(cat "$TEST_TMPDIR/rename.out")" "the rename prints nothing" || return 1
    local f services=""
    for f in "$kc"/*; do
        [ -f "$f" ] && services="$services$(head -1 "$f") "
    done
    assert_eq "cs:alpha:K1 " "$services" "the Keychain holds alpha's entry and none of bravo's" || return 1
    assert_eq "value-one" "$(_kcs --session alpha get K1 2>&1)" "K1 reads under alpha" || return 1
    assert_not_exists "$HOME/.cs-secrets/.rename.alpha" "no marker is left" || return 1
    assert_not_exists "$HOME/.cs-secrets/sessions/bravo" "no age state is left under bravo" || return 1
    assert_eq "bravo
test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root" || return 1
}

# A signal that reaches rename after every value has moved does not end it
# nonzero: the picker reads a nonzero exit as "still under the old name" and
# moves the directory back over secrets that are all under the new one. Two
# windows: the write-lock release (its `cat` of the lock) and the removal of
# the old name's empty age directory (its `rmdir`). A stand-in pauses there
# until the test lets it go, two seconds at most.
test_a_signal_after_every_value_moved_does_not_end_a_rename_nonzero() {
    local bindir; bindir=$(_make_fake_security)
    local kc="$TEST_TMPDIR/kc-store" shim="$TEST_TMPDIR/tail-shim" tool pattern real out rc waited f services
    _kcs() {
        PATH="$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kc" "$CS_SECRETS_BIN" "$@"
    }
    printf 'value-one' > "$TEST_TMPDIR/v1"
    for tool in cat rmdir; do
        case "$tool" in
            cat) pattern="*/.secrets-lock.alpha" ;;
            rmdir) pattern="*/sessions/alpha" ;;
        esac
        rm -rf "$kc" "$HOME/.cs-secrets" "$shim" "$CS_SESSIONS_ROOT/bravo" "$TEST_TMPDIR/pause."*
        mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs" "$shim"
        _kcs --session alpha set K1 < "$TEST_TMPDIR/v1" >/dev/null 2>&1 || { echo "  FAIL: fixture: set K1 failed ($tool)"; return 1; }
        mkdir -p "$HOME/.cs-secrets/sessions/alpha"
        printf 'pin-fingerprint\n' > "$HOME/.cs-secrets/sessions/alpha/age-trusted"
        mv "$CS_SESSIONS_ROOT/alpha" "$CS_SESSIONS_ROOT/bravo"
        real=$(command -v "$tool")
        cat > "$shim/$tool" <<SHIM
#!/usr/bin/env bash
case "\$1" in
    $pattern)
        : > "$TEST_TMPDIR/pause.began"
        n=0
        until [ -e "$TEST_TMPDIR/pause.release" ] || [ "\$n" -ge 40 ]; do sleep 0.05; n=\$((n + 1)); done ;;
esac
exec "$real" "\$@"
SHIM
        chmod +x "$shim/$tool"

        PATH="$shim:$bindir:$PATH" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_STORE="$kc" \
            "$CS_SECRETS_BIN" --session alpha rename bravo > "$TEST_TMPDIR/rename.out" 2>&1 &
        local rpid=$!
        waited=0
        until [ -f "$TEST_TMPDIR/pause.began" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 200 ] && break; done
        [ -f "$TEST_TMPDIR/pause.began" ] || { echo "  FAIL: fixture: the rename never reached its $tool"; wait "$rpid"; return 1; }
        kill -TERM "$rpid"
        : > "$TEST_TMPDIR/pause.release"
        rc=0
        wait "$rpid" || rc=$?

        assert_eq "0" "$rc" "the rename exits 0 after a TERM during its $tool: $(cat "$TEST_TMPDIR/rename.out")" || return 1
        assert_eq "Moved the secrets of session 'alpha' to 'bravo'" "$(cat "$TEST_TMPDIR/rename.out")" "the rename says what it did ($tool)" || return 1
        services=""
        for f in "$kc"/*; do
            [ -f "$f" ] && services="$services$(head -1 "$f") "
        done
        assert_eq "cs:bravo:K1 " "$services" "the entry is bravo's ($tool)" || return 1
        assert_eq "pin-fingerprint" "$(cat "$HOME/.cs-secrets/sessions/bravo/age-trusted" 2>&1)" "the pins are bravo's ($tool)" || return 1
        assert_not_exists "$HOME/.cs-secrets/.rename.alpha" "no marker is left ($tool)" || return 1
        assert_eq "bravo
test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root ($tool)" || return 1
    done
}

# A TERM to an encrypted-backend purge while it removes the session's age
# state keeps the write lock until that removal is done: a rename that took
# the lock at once would move the age state while it is being deleted. A
# stand-in rm holds the removal for two seconds at most.
test_a_term_keeps_the_write_lock_until_purge_has_removed_the_age_state() {
    local shim="$TEST_TMPDIR/rm-shim" real_rm age="$HOME/.cs-secrets/sessions/alpha" rc=0 gone_first=0 waited=0
    real_rm=$(command -v rm)
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs" "$shim"
    printf 'value-enc' > "$TEST_TMPDIR/ve"
    CLAUDE_SESSION_NAME=alpha "$CS_SECRETS_BIN" set E1 < "$TEST_TMPDIR/ve" >/dev/null 2>&1 || { echo "  FAIL: fixture: set E1 failed"; return 1; }
    mkdir -p "$age"
    printf 'pin-fingerprint\n' > "$age/age-trusted"
    cat > "$shim/rm" <<SHIM
#!/usr/bin/env bash
case "\$*" in
    "-rf $age")
        : > "$TEST_TMPDIR/pause.began"
        n=0
        until [ -e "$TEST_TMPDIR/pause.release" ] || [ "\$n" -ge 40 ]; do sleep 0.05; n=\$((n + 1)); done ;;
esac
exec "$real_rm" "\$@"
SHIM
    chmod +x "$shim/rm"

    PATH="$shim:$PATH" CLAUDE_SESSION_NAME=alpha "$CS_SECRETS_BIN" purge > "$TEST_TMPDIR/purge.out" 2>&1 &
    local pid=$!
    until [ -f "$TEST_TMPDIR/pause.began" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 200 ] && break; done
    [ -f "$TEST_TMPDIR/pause.began" ] || { echo "  FAIL: fixture: the purge never reached its rm -rf"; wait "$pid"; return 1; }
    kill -TERM "$pid"
    wait "$pid" || rc=$?
    [ -e "$age" ] || gone_first=1
    # A removal left running finishes on its own; let it go before teardown.
    : > "$TEST_TMPDIR/pause.release"
    waited=0
    while [ -e "$age" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 100 ] && break; done

    assert_eq "1" "$gone_first" "the age state was removed before the purge exited" || return 1
    assert_eq "143" "$rc" "the purge exits 143: $(cat "$TEST_TMPDIR/purge.out")" || return 1
    assert_eq "Purged 1 secret(s) for session: alpha" "$(cat "$TEST_TMPDIR/purge.out")" "the purge says what it removed" || return 1
    assert_eq "alpha
test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root" || return 1
}

# An age add or an export that waits on a session's age lock while a rename
# of that session removes the age directory the lock lives in takes the lock
# once the rename is done: the wait makes the directory again before each
# try. The directory goes in one step, lock and all, as the rename's release
# and rmdir leave it; a two-step removal could hand the waiter the lock in
# between. PID 1 stands for the rename holding the lock, and the sleep shim's
# marker shows the command is waiting on it.
test_a_command_waiting_on_the_age_lock_takes_it_once_a_rename_removed_its_directory() {
    local shim="$TEST_TMPDIR/sleep-shim" age="$HOME/.cs-secrets/sessions/bravo" real_sleep cmd pid rc waited expected age_bin
    local key="age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq"
    # age add needs age; the export runs without it, so it takes the password path.
    age_bin=$(command -v age 2>/dev/null) || { echo "    SKIP (age is not installed)"; return 77; }
    real_sleep=$(command -v sleep)
    mkdir -p "$CS_SESSIONS_ROOT/bravo/.cs" "$shim"
    cat > "$shim/sleep" <<SHIM
#!/usr/bin/env bash
: > "$TEST_TMPDIR/waiting"
exec "$real_sleep" "\$@"
SHIM
    chmod +x "$shim/sleep"
    printf '%s\n' "$key" > "$TEST_TMPDIR/laptop.pub"
    printf 'value-one' > "$TEST_TMPDIR/v1"
    CLAUDE_SESSION_NAME=bravo "$CS_SECRETS_BIN" set K1 < "$TEST_TMPDIR/v1" >/dev/null 2>&1 || { echo "  FAIL: fixture: set K1 failed"; return 1; }

    for cmd in age-add export-file; do
        rm -rf "$age" "$TEST_TMPDIR/gone" "$TEST_TMPDIR/waiting"
        mkdir -p "$age"
        printf '1\n' > "$age/.age.lock"
        case "$cmd" in
            age-add)
                PATH="$shim:$PATH" CS_SECRETS_LOCK_TIMEOUT=3 CLAUDE_SESSION_NAME=bravo CS_AGE_BIN="$age_bin" \
                    "$CS_SECRETS_BIN" age add "$TEST_TMPDIR/laptop.pub" > "$TEST_TMPDIR/out" 2>&1 &
                expected="Added recipient: laptop
Public key: $key" ;;
            export-file)
                PATH="$shim:$PATH" CS_SECRETS_LOCK_TIMEOUT=3 CLAUDE_SESSION_NAME=bravo \
                    "$CS_SECRETS_BIN" export-file "$TEST_TMPDIR/sync.enc" > "$TEST_TMPDIR/out" 2>&1 &
                expected="Exported 1 secret(s) to: $TEST_TMPDIR/sync.enc (password encrypted)" ;;
        esac
        pid=$!
        waited=0
        until [ -f "$TEST_TMPDIR/waiting" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 400 ] && break; done
        [ -f "$TEST_TMPDIR/waiting" ] || { echo "  FAIL: fixture: $cmd never waited on the age lock"; kill "$pid"; wait "$pid"; return 1; }

        # The rename releases its lock and removes the directory.
        mv "$age" "$TEST_TMPDIR/gone"
        rc=0
        wait "$pid" || rc=$?

        assert_eq "0" "$rc" "$cmd exits 0: $(cat "$TEST_TMPDIR/out")" || return 1
        assert_eq "$expected" "$(cat "$TEST_TMPDIR/out")" "$cmd says what it did" || return 1
        assert_not_exists "$age/.age.lock" "$cmd releases the age lock" || return 1
    done
    assert_eq "bravo
test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root" || return 1
}

# An age add, age remove or export-file for alpha that waits on alpha's age
# lock while alpha is renamed to bravo refuses once it holds the lock: alpha
# is no session any more. It writes nothing: no recipient, no sync file, no
# pin of this machine's key, and no age directory under alpha. PID 1 stands
# for the rename holding the lock; the picker's move of the session directory
# and the rename's removal of alpha's age directory, lock and all, follow
# once the sleep shim's marker shows the command is waiting.
test_a_command_waiting_on_the_age_lock_through_a_rename_refuses_the_old_name() {
    local shim="$TEST_TMPDIR/sleep-shim" age="$HOME/.cs-secrets/sessions/alpha" real_sleep cmd pid rc waited age_bin
    local key="age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq"
    # age add needs age; remove and the export run without it.
    age_bin=$(command -v age 2>/dev/null) || { echo "    SKIP (age is not installed)"; return 77; }
    real_sleep=$(command -v sleep)
    mkdir -p "$shim" "$HOME/.cs-secrets"
    cat > "$shim/sleep" <<SHIM
#!/usr/bin/env bash
: > "$TEST_TMPDIR/waiting"
exec "$real_sleep" "\$@"
SHIM
    chmod +x "$shim/sleep"
    printf '%s\n' "$key" > "$TEST_TMPDIR/laptop.pub"
    printf 'value-one' > "$TEST_TMPDIR/v1"
    # This machine's key, so a command that runs on under alpha pins it there.
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOwnMachineKeyBodyForTheTestOnly test@example.com\n' \
        > "$HOME/.cs-secrets/id_ed25519.pub"

    for cmd in age-add age-remove export-file; do
        rm -rf "$age" "$TEST_TMPDIR/gone" "$TEST_TMPDIR/waiting" "$TEST_TMPDIR/sync.enc" \
            "$CS_SESSIONS_ROOT/alpha" "$CS_SESSIONS_ROOT/bravo"
        mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs/age-recipients" "$age"
        printf '%s\n' "$key" > "$CS_SESSIONS_ROOT/alpha/.cs/age-recipients/peer.pub"
        CLAUDE_SESSION_NAME=alpha "$CS_SECRETS_BIN" set K1 < "$TEST_TMPDIR/v1" >/dev/null 2>&1 \
            || { echo "  FAIL: fixture: set K1 failed ($cmd)"; return 1; }
        printf '1\n' > "$age/.age.lock"
        case "$cmd" in
            age-add)
                PATH="$shim:$PATH" CS_SECRETS_LOCK_TIMEOUT=3 CLAUDE_SESSION_NAME=alpha CS_AGE_BIN="$age_bin" \
                    "$CS_SECRETS_BIN" age add "$TEST_TMPDIR/laptop.pub" > "$TEST_TMPDIR/out" 2>&1 & ;;
            age-remove)
                PATH="$shim:$PATH" CS_SECRETS_LOCK_TIMEOUT=3 CLAUDE_SESSION_NAME=alpha \
                    "$CS_SECRETS_BIN" age remove peer > "$TEST_TMPDIR/out" 2>&1 & ;;
            export-file)
                PATH="$shim:$PATH" CS_SECRETS_LOCK_TIMEOUT=3 CLAUDE_SESSION_NAME=alpha \
                    "$CS_SECRETS_BIN" export-file "$TEST_TMPDIR/sync.enc" > "$TEST_TMPDIR/out" 2>&1 & ;;
        esac
        pid=$!
        waited=0
        until [ -f "$TEST_TMPDIR/waiting" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 400 ] && break; done
        [ -f "$TEST_TMPDIR/waiting" ] || { echo "  FAIL: fixture: $cmd never waited on the age lock"; kill "$pid"; wait "$pid"; return 1; }

        # The picker moves the session; the rename releases its lock and
        # removes alpha's age directory.
        mv "$CS_SESSIONS_ROOT/alpha" "$CS_SESSIONS_ROOT/bravo"
        mv "$age" "$TEST_TMPDIR/gone"
        rc=0
        wait "$pid" || rc=$?

        assert_eq "1" "$rc" "$cmd for the old name exits 1: $(cat "$TEST_TMPDIR/out")" || return 1
        assert_eq "Error: No session named 'alpha' in $CS_SESSIONS_ROOT" "$(cat "$TEST_TMPDIR/out")" \
            "$cmd refuses the old name" || return 1
        assert_not_exists "$age" "$cmd leaves no age directory, and no pin, under alpha" || return 1
        assert_not_exists "$TEST_TMPDIR/sync.enc" "$cmd writes no sync file" || return 1
        assert_eq "peer.pub" "$(ls -A "$CS_SESSIONS_ROOT/bravo/.cs/age-recipients")" "$cmd changes no recipient" || return 1
    done
    assert_eq "bravo
test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root" || return 1
}

# A command waiting on alpha's age lock makes alpha's age directory and then
# sets its mode before every try. A rename that removes the directory between
# those two steps leaves the mode step nothing to act on; the waiter makes the
# directory again, takes the lock and refuses the old name, as it does when
# the removal lands anywhere else in its wait. The chmod on PATH is the
# rename: on the first mode step after the command has started waiting (the
# sleep shim's marker), it moves the session and removes alpha's age
# directory, lock and all, and then runs the real chmod on what is left.
test_a_rename_between_making_the_age_directory_and_setting_its_mode_is_waited_through() {
    local shim="$TEST_TMPDIR/race-shim" age="$HOME/.cs-secrets/sessions/alpha" real_sleep real_chmod cmd rc age_bin
    local key="age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq"
    # age add needs age; remove and the export run without it.
    age_bin=$(command -v age 2>/dev/null) || { echo "    SKIP (age is not installed)"; return 77; }
    real_sleep=$(command -v sleep)
    real_chmod=$(command -v chmod)
    mkdir -p "$shim" "$HOME/.cs-secrets"
    cat > "$shim/sleep" <<SHIM
#!/usr/bin/env bash
: > "$TEST_TMPDIR/waiting"
exec "$real_sleep" "\$@"
SHIM
    cat > "$shim/chmod" <<SHIM
#!/usr/bin/env bash
if [ -f "$TEST_TMPDIR/waiting" ] && [ ! -e "$TEST_TMPDIR/gone" ]; then
    for a in "\$@"; do
        if [ "\$a" = "$age" ]; then
            mv "$CS_SESSIONS_ROOT/alpha" "$CS_SESSIONS_ROOT/bravo"
            mv "$age" "$TEST_TMPDIR/gone"
            break
        fi
    done
fi
exec "$real_chmod" "\$@"
SHIM
    chmod +x "$shim/sleep" "$shim/chmod"
    printf '%s\n' "$key" > "$TEST_TMPDIR/laptop.pub"
    printf 'value-one' > "$TEST_TMPDIR/v1"
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOwnMachineKeyBodyForTheTestOnly test@example.com\n' \
        > "$HOME/.cs-secrets/id_ed25519.pub"

    for cmd in age-add age-remove export-file; do
        rm -rf "$age" "$TEST_TMPDIR/gone" "$TEST_TMPDIR/waiting" "$TEST_TMPDIR/sync.enc" \
            "$CS_SESSIONS_ROOT/alpha" "$CS_SESSIONS_ROOT/bravo"
        mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs/age-recipients" "$age"
        printf '%s\n' "$key" > "$CS_SESSIONS_ROOT/alpha/.cs/age-recipients/peer.pub"
        CLAUDE_SESSION_NAME=alpha "$CS_SECRETS_BIN" set K1 < "$TEST_TMPDIR/v1" >/dev/null 2>&1 \
            || { echo "  FAIL: fixture: set K1 failed ($cmd)"; return 1; }
        printf '1\n' > "$age/.age.lock"
        rc=0
        case "$cmd" in
            age-add)
                PATH="$shim:$PATH" CS_SECRETS_LOCK_TIMEOUT=3 CLAUDE_SESSION_NAME=alpha CS_AGE_BIN="$age_bin" \
                    "$CS_SECRETS_BIN" age add "$TEST_TMPDIR/laptop.pub" > "$TEST_TMPDIR/out" 2>&1 || rc=$? ;;
            age-remove)
                PATH="$shim:$PATH" CS_SECRETS_LOCK_TIMEOUT=3 CLAUDE_SESSION_NAME=alpha \
                    "$CS_SECRETS_BIN" age remove peer > "$TEST_TMPDIR/out" 2>&1 || rc=$? ;;
            export-file)
                PATH="$shim:$PATH" CS_SECRETS_LOCK_TIMEOUT=3 CLAUDE_SESSION_NAME=alpha \
                    "$CS_SECRETS_BIN" export-file "$TEST_TMPDIR/sync.enc" > "$TEST_TMPDIR/out" 2>&1 || rc=$? ;;
        esac

        [ -d "$TEST_TMPDIR/gone" ] || { echo "  FAIL: fixture: the removal never landed in $cmd's mode step: $(cat "$TEST_TMPDIR/out")"; return 1; }
        assert_eq "1" "$rc" "$cmd for the old name exits 1: $(cat "$TEST_TMPDIR/out")" || return 1
        assert_eq "Error: No session named 'alpha' in $CS_SESSIONS_ROOT" "$(cat "$TEST_TMPDIR/out")" \
            "$cmd refuses the old name" || return 1
        assert_not_exists "$age" "$cmd leaves no age directory, and no pin, under alpha" || return 1
        assert_not_exists "$TEST_TMPDIR/sync.enc" "$cmd writes no sync file" || return 1
        assert_eq "peer.pub" "$(ls -A "$CS_SESSIONS_ROOT/bravo/.cs/age-recipients")" "$cmd changes no recipient" || return 1
    done
    assert_eq "bravo
test-session" "$(ls -A "$CS_SESSIONS_ROOT")" "no lock is left in the sessions root" || return 1
}

# An age directory that cannot be made, or whose mode cannot be set while it
# is there, fails the age lock at once: one try, no wait, the tool's own
# error and the refusal. Only a directory that is gone again by the mode step
# is made again. The command runs in the background so that one that kept
# trying is stopped and reported instead of hanging the suite.
test_an_age_directory_that_cannot_be_made_or_secured_fails_the_age_lock_at_once() {
    local shim="$TEST_TMPDIR/once-shim" age="$HOME/.cs-secrets/sessions/test-session" real_sleep real_chmod how pid waited
    local refusal="Error: Refusing to change the age recipients for session 'test-session': could not acquire the age recipients lock"
    real_sleep=$(command -v sleep)
    real_chmod=$(command -v chmod)
    mkdir -p "$shim" "$CS_SESSIONS_ROOT/test-session/.cs/age-recipients"
    printf 'age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq\n' \
        > "$CS_SESSIONS_ROOT/test-session/.cs/age-recipients/peer.pub"
    cat > "$shim/sleep" <<SHIM
#!/usr/bin/env bash
: > "$TEST_TMPDIR/waiting"
exec "$real_sleep" "\$@"
SHIM
    cat > "$shim/chmod" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
    if [ "\$a" = "$age" ]; then
        printf 'x\n' >> "$TEST_TMPDIR/mode-steps"
        if [ -f "$TEST_TMPDIR/refuse-mode" ]; then
            echo "chmod: $age: Operation not permitted" >&2
            exit 1
        fi
    fi
done
exec "$real_chmod" "\$@"
SHIM
    chmod +x "$shim/sleep" "$shim/chmod"

    for how in unmakeable unsecurable; do
        rm -rf "$HOME/.cs-secrets" "$TEST_TMPDIR/waiting" "$TEST_TMPDIR/mode-steps" "$TEST_TMPDIR/refuse-mode" "$TEST_TMPDIR/rc"
        mkdir -p "$HOME/.cs-secrets"
        case "$how" in
            # A file where the directory of per-session age state belongs.
            unmakeable) : > "$HOME/.cs-secrets/sessions" ;;
            unsecurable) : > "$TEST_TMPDIR/refuse-mode" ;;
        esac
        ( rc=0
          PATH="$shim:$PATH" "$CS_SECRETS_BIN" age remove peer > "$TEST_TMPDIR/out" 2>&1 || rc=$?
          printf '%s\n' "$rc" > "$TEST_TMPDIR/rc" ) &
        pid=$!
        waited=0
        until [ -f "$TEST_TMPDIR/rc" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 200 ] && break; done
        if [ ! -f "$TEST_TMPDIR/rc" ]; then
            pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
            echo "  FAIL: age remove kept trying an age directory it could not make or secure ($how): $(wc -l < "$TEST_TMPDIR/mode-steps" 2>/dev/null) mode steps"
            return 1
        fi
        wait "$pid"
        assert_eq "1" "$(cat "$TEST_TMPDIR/rc")" "age remove exits 1 ($how): $(cat "$TEST_TMPDIR/out")" || return 1
        assert_eq "$refusal" "$(tail -1 "$TEST_TMPDIR/out")" "age remove says it could not take the lock ($how)" || return 1
        assert_eq "2" "$(wc -l < "$TEST_TMPDIR/out" | tr -d ' ')" "one line from the tool that failed, then the refusal ($how)" || return 1
        assert_not_exists "$TEST_TMPDIR/waiting" "age remove does not wait ($how)" || return 1
        case "$how" in
            unmakeable)
                assert_not_exists "$TEST_TMPDIR/mode-steps" "no mode step follows a directory that was not made" || return 1 ;;
            unsecurable)
                assert_eq "chmod: $age: Operation not permitted" "$(head -1 "$TEST_TMPDIR/out")" "the mode step's own error is shown" || return 1 ;;
        esac
        assert_file_exists "$CS_SESSIONS_ROOT/test-session/.cs/age-recipients/peer.pub" "the recipient is left alone ($how)" || return 1
    done
}

# `age add` and `age remove` change the recipient set an export snapshots, so
# each waits while an export holds the session's age lock and runs once the
# export is done. The export's age blocks on encrypt (-o) until the test
# releases it, so the export holds the lock for as long as the test looks;
# the sleep shim's marker shows the add or remove is waiting on that lock.
test_age_add_and_remove_wait_while_an_export_holds_the_age_lock() {
    local age_bin keygen_bin real_sleep cmd pid xpid rc waited expected key
    local shim="$TEST_TMPDIR/sleep-shim" slow="$TEST_TMPDIR/held-age"
    age_bin=$(command -v age 2>/dev/null) || age_bin=""
    keygen_bin=$(command -v age-keygen 2>/dev/null) || keygen_bin=""
    if [ -z "$age_bin" ] || [ -z "$keygen_bin" ]; then
        echo "    SKIP (age and age-keygen are not installed)"
        return 77
    fi
    real_sleep=$(command -v sleep)
    mkdir -p "$shim"
    cat > "$shim/sleep" <<SHIM
#!/usr/bin/env bash
: > "$TEST_TMPDIR/waiting"
exec "$real_sleep" "\$@"
SHIM
    chmod +x "$shim/sleep"
    cat > "$slow" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
    if [ "\$a" = "-o" ]; then
        : > "$TEST_TMPDIR/encrypting"
        n=0
        until [ -f "$TEST_TMPDIR/release" ] || [ "\$n" -ge 200 ]; do "$real_sleep" 0.05; n=\$((n + 1)); done
        break
    fi
done
exec "$age_bin" "\$@"
SHIM
    chmod +x "$slow"
    "$keygen_bin" -o "$TEST_TMPDIR/r.key" 2>/dev/null || { echo "  FAIL: fixture: age-keygen"; return 1; }
    "$keygen_bin" -y "$TEST_TMPDIR/r.key" > "$TEST_TMPDIR/r.pub" || return 1
    key=$(cat "$TEST_TMPDIR/r.pub")
    CS_AGE_BIN="$age_bin" "$CS_SECRETS_BIN" age init >/dev/null 2>&1 || { echo "  FAIL: fixture: age init"; return 1; }

    for cmd in age-add age-remove; do
        rm -f "$TEST_TMPDIR/waiting" "$TEST_TMPDIR/encrypting" "$TEST_TMPDIR/release" "$TEST_TMPDIR/out"
        printf 'value-%s' "$cmd" > "$TEST_TMPDIR/v"
        "$CS_SECRETS_BIN" set api_key < "$TEST_TMPDIR/v" >/dev/null 2>&1 || { echo "  FAIL: fixture: set ($cmd)"; return 1; }
        CS_AGE_BIN="$slow" "$CS_SECRETS_BIN" export-file > "$TEST_TMPDIR/export.out" 2>&1 &
        xpid=$!
        waited=0
        until [ -f "$TEST_TMPDIR/encrypting" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 400 ] && break; done
        [ -f "$TEST_TMPDIR/encrypting" ] || { echo "  FAIL: fixture: the export never reached its encrypt ($cmd): $(cat "$TEST_TMPDIR/export.out")"; kill "$xpid"; wait "$xpid"; return 1; }

        case "$cmd" in
            age-add)
                PATH="$shim:$PATH" CS_AGE_BIN="$age_bin" "$CS_SECRETS_BIN" age add "$TEST_TMPDIR/r.pub" > "$TEST_TMPDIR/out" 2>&1 &
                expected="Added recipient: r
Public key: $key" ;;
            age-remove)
                PATH="$shim:$PATH" CS_AGE_BIN="$age_bin" "$CS_SECRETS_BIN" age remove r > "$TEST_TMPDIR/out" 2>&1 &
                expected="Removed recipient: r

Note: Existing secrets.age files can still be decrypted by this recipient.
Run 'cs -secrets export-file' to re-encrypt without this recipient; each machine
re-encrypts only its own sync file, and copies in git history stay readable to them." ;;
        esac
        pid=$!
        waited=0
        until [ -f "$TEST_TMPDIR/waiting" ] || ! kill -0 "$pid" 2>/dev/null; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 400 ] && break; done
        if ! kill -0 "$pid" 2>/dev/null; then
            : > "$TEST_TMPDIR/release"; wait "$xpid"; wait "$pid"
            echo "  FAIL: $cmd finished while the export held the age lock: $(cat "$TEST_TMPDIR/out")"
            return 1
        fi
        [ -f "$TEST_TMPDIR/waiting" ] || { echo "  FAIL: fixture: $cmd never waited"; : > "$TEST_TMPDIR/release"; kill "$pid"; wait "$xpid"; wait "$pid"; return 1; }
        assert_eq "" "$(cat "$TEST_TMPDIR/out")" "$cmd says nothing while it waits" || { : > "$TEST_TMPDIR/release"; wait "$xpid"; wait "$pid"; return 1; }

        : > "$TEST_TMPDIR/release"
        rc=0
        wait "$xpid" || rc=$?
        assert_eq "0" "$rc" "the export holding the lock exits 0 ($cmd): $(cat "$TEST_TMPDIR/export.out")" || { wait "$pid"; return 1; }
        rc=0
        wait "$pid" || rc=$?
        assert_eq "0" "$rc" "$cmd exits 0 once the export is done" || return 1
        assert_eq "$expected" "$(cat "$TEST_TMPDIR/out")" "$cmd says what it did" || return 1
    done
}

# CS_SECRETS_LOCK_TIMEOUT counts whole seconds. Anything but a positive whole
# number (a word, a fraction, zero) is the default of 10: no arithmetic error,
# and no giving up before the first wait. PID 1 holds the write lock for the
# whole test; the three writers wait on it side by side, so the test takes
# one timeout, not three.
test_a_lock_timeout_that_is_not_a_positive_whole_number_is_the_default() {
    local lock="$CS_SESSIONS_ROOT/.secrets-lock.test-session" value pid rc
    printf '1\n' > "$lock"
    printf 'value-one' > "$TEST_TMPDIR/v1"
    for value in abc 1.5 0; do
        CS_SECRETS_LOCK_TIMEOUT="$value" "$CS_SECRETS_BIN" set K1 < "$TEST_TMPDIR/v1" > "$TEST_TMPDIR/out.$value" 2>&1 &
        printf '%s\n' "$!" > "$TEST_TMPDIR/pid.$value"
    done
    for value in abc 1.5 0; do
        pid=$(cat "$TEST_TMPDIR/pid.$value")
        rc=0
        wait "$pid" || rc=$?
        assert_eq "1" "$rc" "set with CS_SECRETS_LOCK_TIMEOUT=$value exits 1 once it times out" || return 1
        assert_eq "Error: timed out after 10s acquiring the secrets write lock for session 'test-session' (held by PID 1). If no such process is running, remove: $lock
Error: Refusing to change the secrets of session 'test-session': could not acquire the secrets write lock" \
            "$(cat "$TEST_TMPDIR/out.$value")" "CS_SECRETS_LOCK_TIMEOUT=$value waits the default 10 seconds" || return 1
    done
}

# A timeout with a leading zero is read in base 10: 08 is eight seconds, not
# an octal number that does not exist. PID 1 holds the write lock.
test_a_lock_timeout_with_a_leading_zero_is_read_in_base_ten() {
    local lock="$CS_SESSIONS_ROOT/.secrets-lock.test-session" out rc=0
    printf '1\n' > "$lock"
    printf 'value-one' > "$TEST_TMPDIR/v1"
    out=$(CS_SECRETS_LOCK_TIMEOUT=08 "$CS_SECRETS_BIN" set K1 < "$TEST_TMPDIR/v1" 2>&1) || rc=$?
    assert_eq "1" "$rc" "set exits 1 once it times out" || return 1
    assert_eq "Error: timed out after 8s acquiring the secrets write lock for session 'test-session' (held by PID 1). If no such process is running, remove: $lock
Error: Refusing to change the secrets of session 'test-session': could not acquire the secrets write lock" \
        "$out" "CS_SECRETS_LOCK_TIMEOUT=08 waits eight seconds" || return 1
}

run_test test_encrypted_salt_write_is_atomic_under_concurrency
run_test test_encrypted_signal_terminates_writer_mid_critical_section
run_test test_encrypted_purge_serialized_with_concurrent_store
run_test test_export_serialized_against_concurrent_store_no_stale_overwrite
run_test test_migrate_delete_source_preserves_concurrent_store
run_test test_migrate_delete_source_tolerates_concurrently_deleted_key
run_test test_export_holds_the_lock_across_encrypt_and_digest_on_every_backend
run_test test_two_first_runs_keep_one_machine_key
run_test test_keychain_set_during_a_rename_is_moved_with_the_session
run_test test_a_set_that_waited_on_the_write_lock_refuses_a_session_moved_away
run_test test_a_term_keeps_the_write_lock_until_the_keychain_write_finishes
run_test test_a_rename_that_waited_on_the_write_lock_refuses_over_a_move_begun_meanwhile
run_test test_a_term_to_a_rename_puts_back_what_it_moved
run_test test_a_signal_after_every_value_moved_does_not_end_a_rename_nonzero
run_test test_a_term_keeps_the_write_lock_until_purge_has_removed_the_age_state
run_test test_a_command_waiting_on_the_age_lock_takes_it_once_a_rename_removed_its_directory
run_test test_a_command_waiting_on_the_age_lock_through_a_rename_refuses_the_old_name
run_test test_a_rename_between_making_the_age_directory_and_setting_its_mode_is_waited_through
run_test test_an_age_directory_that_cannot_be_made_or_secured_fails_the_age_lock_at_once
run_test test_age_add_and_remove_wait_while_an_export_holds_the_age_lock
run_test test_a_lock_timeout_that_is_not_a_positive_whole_number_is_the_default
run_test test_a_lock_timeout_with_a_leading_zero_is_read_in_base_ten

report_results
