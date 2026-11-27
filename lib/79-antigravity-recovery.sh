# ABOUTME: Retains Antigravity snapshots from interrupted managed runs and offers them on an exact reopen.

# The caller holds the session guard. A stale lease with a registered native
# child that has no recorded clean exit can still have interrupted autosaves.
# Old autosave refs have no run trailer and cannot prove it.
_antigravity_recovery_record_interruption() {  # meta_dir
    local meta="$1" dir="${1%/.cs}" lease="$1/local/run-lease.json" owner run oid type ref target saved_run id status=0
    local GIT_NO_REPLACE_OBJECTS=1
    export GIT_NO_REPLACE_OBJECTS
    [ -f "$meta/session.lock" ] && [ ! -L "$meta/session.lock" ] && [ -f "$lease" ] && [ ! -L "$lease" ] || return 0
    IFS= read -r owner < "$meta/session.lock" || return 0
    run=$(jq -er --arg owner "$owner" 'select(.engine == "antigravity" and (.owner_pid | tostring) == $owner
        and (.native_pid | type == "number" and . > 1) and .native_exit != 0) | .run_id | strings' "$lease" 2>/dev/null) || return 0
    _is_uuid "$run" || return 0
    _cs_git_at "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0

    local snapshots
    snapshots=$(_cs_git_at "$dir" for-each-ref \
        --format='%(objectname) %(objecttype) %(refname) target:%(symref) %(trailers:key=cs-run,valueonly,unfold,separator=%x20)' \
        refs/worktree/cs/session/ 2>/dev/null) || return 1
    while IFS=' ' read -r oid type ref target saved_run; do
        id="${ref##*/}"
        [ "$saved_run" = "$run" ] && [ "$type" = commit ] && [ "$target" = target: ] \
            && [ "$ref" = "refs/worktree/cs/session/$id" ] && _is_uuid "$id" || continue
        _cs_git_at "$dir" update-ref --no-deref "refs/worktree/cs/antigravity-recovery/$id" "$oid" || status=1
    done < <(printf '%s\n' "$snapshots")
    return "$status"
}

_antigravity_recovery_tip() {  # directory, ref
    local refs oid type ref target
    refs=$(_cs_git_at "$1" for-each-ref --format='%(objectname) %(objecttype) %(refname) %(symref)' "$2") || return 1
    while IFS=' ' read -r oid type ref target; do
        [ "$ref" = "$2" ] && [ "$type" = commit ] && [ -z "$target" ] || continue
        printf '%s\n' "$oid"
        return 0
    done < <(printf '%s\n' "$refs")
    return 1
}

_antigravity_recovery_commit() {  # directory, revision
    _cs_git_at "$1" rev-parse --verify --quiet "$2^{commit}"
}

_antigravity_recovery_base() {  # directory, snapshot commit
    _cs_git_at "$1" show -s --format='%(trailers:key=cs-base,valueonly,unfold)' "$2"
}

_CS_ANTIGRAVITY_RECOVERY_PATCH_ARGS=(
    --literal-pathspecs diff --binary --no-renames --no-ext-diff --no-textconv --no-color
    --ignore-submodules=none --submodule=short --src-prefix=a/ --dst-prefix=b/
)

_antigravity_recovery_patch() {  # directory, base, snapshot commit
    local dir="$1" base="$2" oid="$3"
    shift 3
    _cs_git_at "$dir" "${_CS_ANTIGRAVITY_RECOVERY_PATCH_ARGS[@]}" "$base" "$oid" -- "$@"
}

_antigravity_recovery_git() {
    git -c core.hooksPath=/dev/null -c core.fsmonitor= -c core.splitIndex=false -c core.sparseCheckout=false \
        -c core.fileMode=true -c core.symlinks=true -c apply.ignoreWhitespace=no -c apply.whitespace=nowarn "$@"
}

_antigravity_recovery_clear_git_env() {
    local var
    while IFS= read -r var; do unset "$var"; done < <(git rev-parse --local-env-vars)
    export GIT_NO_REPLACE_OBJECTS=1
}

# Print the NUL-delimited paths whose saved state is absent from the worktree.
# Return 2 when a gitlink changed, since a patch cannot restore its checkout.
_antigravity_recovery_pending() (  # directory, base, snapshot commit, scratch directory
    local dir="$1" base="$2" oid="$3" temp="$4" change file
    local -a saved=() deleted=()
    _cs_git_at "$dir" diff --raw -z --no-renames --ignore-submodules=none "$base" "$oid" -- > "$temp/changes" || return 1
    while IFS= read -r -d '' change && IFS= read -r -d '' file; do
        case "$change" in ':160000 '*|:??????' 160000 '*) return 2 ;; esac
        case "$change" in :??????' 000000 '*) deleted+=("$file") ;; *) saved+=("$file") ;; esac
    done < "$temp/changes"

    _antigravity_recovery_clear_git_env
    cd -- "$dir" || return 1
    if [ "${#saved[@]}" -gt 0 ]; then
        export GIT_INDEX_FILE="$temp/saved-index"
        rm -f -- "$GIT_INDEX_FILE" || return 1
        _antigravity_recovery_git read-tree "$oid" || return 1
        _antigravity_recovery_git update-index -q --refresh >/dev/null || return 1
        _antigravity_recovery_git --literal-pathspecs diff-files --name-only -z -- "${saved[@]}" || return 1
    fi
    for file in ${deleted[@]+"${deleted[@]}"}; do
        if [ -L "$file" ] || { [ -e "$file" ] && [ ! -d "$file" ]; }; then printf '%s\0' "$file"; fi
    done
)

_antigravity_recovery_staged_diff() {  # directory, base, paths...
    local dir="$1" base="$2"
    shift 2
    _cs_git_at "$dir" --literal-pathspecs diff --cached --raw -z --no-abbrev --no-renames \
        --ignore-submodules=none "$base" -- "$@"
}

# Skip files already on disk as saved. For the rest, check staged changes
# and working-tree changes against the base. Apply only to the worktree:
# apply --index can check out a locally deleted file even with --check.
_antigravity_recovery_restore() (  # directory, ref, snapshot commit, base
    local dir="$1" ref="$2" oid="$3" base="$4" temp change file
    local -a paths=() affected=()
    [ "$(_antigravity_recovery_base "$dir" "$oid")" = "$base" ] \
        && [ "$(_antigravity_recovery_tip "$dir" "$ref")" = "$oid" ] \
        && [ "$(_antigravity_recovery_commit "$dir" HEAD)" = "$base" ] || return 1
    temp=$(mktemp -d "${TMPDIR:-/tmp}/cs-agy-recovery.XXXXXX") || return 1
    trap 'rm -rf -- "$temp"' EXIT
    _antigravity_recovery_pending "$dir" "$base" "$oid" "$temp" > "$temp/pending" || return 1
    while IFS= read -r -d '' file; do paths+=("$file"); done < "$temp/pending"
    [ "${#paths[@]}" -gt 0 ] || return 1
    while IFS= read -r -d '' change && IFS= read -r -d '' file; do affected+=("$file"); done < "$temp/changes"
    _cs_git_at "$dir" --literal-pathspecs diff --cached --quiet --ignore-submodules=none \
        "$base" -- "${paths[@]}" || return 1
    _antigravity_recovery_staged_diff "$dir" "$base" "${affected[@]}" > "$temp/staged" || return 1
    _antigravity_recovery_patch "$dir" "$base" "$oid" "${paths[@]}" > "$temp/patch" || return 1
    _antigravity_recovery_clear_git_env
    cd -- "$dir" || return 1
    export GIT_INDEX_FILE="$temp/base-index"
    _antigravity_recovery_git read-tree "$base" || return 1
    _antigravity_recovery_git update-index -q --refresh >/dev/null || return 1
    _antigravity_recovery_git --literal-pathspecs diff-files --quiet -- "${paths[@]}" || return 1
    _antigravity_recovery_git apply --check "$temp/patch" || return 1
    [ "$(_antigravity_recovery_commit "$dir" HEAD)" = "$base" ] \
        && [ "$(_antigravity_recovery_tip "$dir" "$ref")" = "$oid" ] \
        && _antigravity_recovery_git --literal-pathspecs diff-files --quiet -- "${paths[@]}" \
        && _cs_git_at "$dir" --literal-pathspecs diff --cached --quiet --ignore-submodules=none \
            "$base" -- "${paths[@]}" || return 1
    _antigravity_recovery_git apply "$temp/patch" || return 1
    # The lease cannot exclude another Git process or editor. Keep the copy
    # if any affected path, the real index, HEAD, or the ref changed.
    _antigravity_recovery_pending "$dir" "$base" "$oid" "$temp" > "$temp/remaining" \
        && [ ! -s "$temp/remaining" ] \
        && _antigravity_recovery_staged_diff "$dir" "$base" "${affected[@]}" > "$temp/staged-now" \
        && cmp -s "$temp/staged" "$temp/staged-now" \
        && [ "$(_antigravity_recovery_commit "$dir" HEAD)" = "$base" ] \
        && [ "$(_antigravity_recovery_tip "$dir" "$ref")" = "$oid" ] || return 2
    _cs_git_at "$dir" update-ref --no-deref -d "$ref" "$oid" || return 2
)

_antigravity_recovery_review() {  # directory, comparison commit, snapshot commit
    printf 'To inspect the saved patch from another shell, run:\n  GIT_NO_REPLACE_OBJECTS=1 git -C %q' "$1"
    printf ' %q' "${_CS_ANTIGRAVITY_RECOVERY_PATCH_ARGS[@]}" "$2" "$3" --
    printf '\n'
}

_antigravity_recovery_discard() {  # directory, recovery ref, snapshot commit, conversation id
    local dir="$1" ref="$2" oid="$3" autosave="refs/worktree/cs/session/$4"
    [ "$(_antigravity_recovery_tip "$dir" "$ref")" = "$oid" ] || return 1
    if [ "$(_antigravity_recovery_tip "$dir" "$autosave")" = "$oid" ]; then
        printf 'delete %s %s\ndelete %s %s\n' "$ref" "$oid" "$autosave" "$oid" \
            | _cs_git_at "$dir" update-ref --no-deref --stdin
    else
        _cs_git_at "$dir" update-ref --no-deref -d "$ref" "$oid"
    fi
}

_antigravity_recovery_offer() (  # directory, conversation id
    local session_dir="$1" id="$2" dir ref oid head base compare summary answer="" restore="" submodule=""
    local temp result=0
    local GIT_NO_REPLACE_OBJECTS=1
    export GIT_NO_REPLACE_OBJECTS
    _is_uuid "$id" || return 0
    ref="refs/worktree/cs/antigravity-recovery/$id"
    oid=$(_antigravity_recovery_tip "$session_dir" "$ref" 2>/dev/null) || return 0
    dir=$(_cs_git_at "$session_dir" rev-parse --show-toplevel 2>/dev/null) || return 0
    head=$(_antigravity_recovery_commit "$dir" HEAD 2>/dev/null) || head=""
    base=$(_antigravity_recovery_base "$dir" "$oid" 2>/dev/null) || base=""
    compare="$head"
    if [[ "$base" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] && _antigravity_recovery_commit "$dir" "$base" >/dev/null 2>&1; then
        compare="$base"
    else
        base=""
    fi
    if [ -z "$compare" ]; then
        compare=$(_cs_git_at "$dir" hash-object -t tree /dev/null 2>/dev/null) || return 0
    fi
    summary=$(_cs_git_at "$dir" -c core.quotePath=true diff --stat=80,48,12 --no-renames --no-ext-diff \
        --no-textconv --no-color --ignore-submodules=none "$compare" "$oid" -- 2>/dev/null) || return 0
    [ -n "$summary" ] || return 0
    temp=$(mktemp -d "${TMPDIR:-/tmp}/cs-agy-recovery.XXXXXX") || return 0
    trap 'rm -rf -- "$temp"' EXIT
    if _antigravity_recovery_pending "$dir" "$compare" "$oid" "$temp" > "$temp/pending" 2>/dev/null; then
        [ -s "$temp/pending" ] || return 0
    elif [ "$?" -eq 2 ]; then
        submodule=1
    fi

    printf '\nAntigravity crash recovery for %s\n%s\n' "$id" "$summary"
    if [ -z "$base" ]; then
        printf 'The saved snapshot has no verifiable base. Review it before recovering individual files.\n'
    elif [ "$base" != "$head" ]; then
        printf 'HEAD changed since the snapshot. Review it before recovering individual files.\n'
    elif [ -n "$submodule" ]; then
        printf 'The snapshot includes a submodule change. Review it before recovering individual files.\n'
    else
        restore='r=restore / '
    fi
    printf 'Recovery [%sv=review / d=discard saved copy / Enter=keep for later] ' "$restore"
    IFS= read -rsn1 answer || answer=""
    printf '\n'
    case "$answer" in
        [rR])
            [ -n "$restore" ] && cs_run_with_lease "$session_dir/.cs" \
                _antigravity_recovery_restore "$dir" "$ref" "$oid" "$base" || result=$?
            case "$result" in
                0) printf 'Restored the Antigravity snapshot to the working tree.\n' ;;
                2) warn 'The patch was applied, but recovery could not be verified.'
                    _antigravity_recovery_review "$dir" "$compare" "$oid" ;;
                *) warn 'Could not restore the Antigravity snapshot safely. The recovery copy is still available.'
                    _antigravity_recovery_review "$dir" "$compare" "$oid" ;;
            esac
            ;;
        [vV]) _antigravity_recovery_review "$dir" "$compare" "$oid" ;;
        [dD])
            if cs_run_with_lease "$session_dir/.cs" _antigravity_recovery_discard "$dir" "$ref" "$oid" "$id"; then
                printf 'Discarded the Antigravity recovery copy.\n'
            else
                warn 'Could not discard the displayed Antigravity recovery copy.'
            fi
            ;;
    esac
)
