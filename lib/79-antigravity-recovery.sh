# ABOUTME: Retains Antigravity snapshots from interrupted managed runs and offers them on an exact reopen.

# The caller holds the session guard. A stale lease with a registered native
# child, or a managed run whose child was interrupted, is evidence a run did
# not finish cleanly. Old autosave refs have no run trailer and cannot prove it.
_antigravity_recovery_record_interruption() {  # meta_dir
    local meta="$1" dir="${1%/.cs}" lease="$1/local/run-lease.json" owner run oid ref saved_run
    local GIT_NO_REPLACE_OBJECTS=1
    export GIT_NO_REPLACE_OBJECTS
    [ -f "$meta/session.lock" ] && [ ! -L "$meta/session.lock" ] && [ -f "$lease" ] && [ ! -L "$lease" ] || return 0
    IFS= read -r owner < "$meta/session.lock" || return 0
    run=$(jq -er --arg owner "$owner" 'select(.engine == "antigravity" and (.owner_pid | tostring) == $owner
        and (.native_pid | type == "number" and . > 1)) | .run_id | strings' "$lease" 2>/dev/null) || return 0
    _is_uuid "$run" || return 0

    local snapshots
    snapshots=$(_cs_git_at "$dir" for-each-ref \
        --format='%(objectname) %(refname) %(trailers:key=cs-run,valueonly,unfold)' refs/worktree/cs/session/ 2>/dev/null) || return 0
    while IFS=' ' read -r oid ref saved_run; do
        [ "$saved_run" = "$run" ] && _is_uuid "${ref##*/}" || continue
        _cs_git_at "$dir" update-ref "refs/worktree/cs/antigravity-recovery/${ref##*/}" "$oid" || return 1
    done < <(printf '%s\n' "$snapshots")
}

_antigravity_recovery_tip() {  # directory, ref
    _cs_git_at "$1" rev-parse --verify --quiet "$2^{commit}"
}

_antigravity_recovery_base() {  # directory, snapshot commit
    _cs_git_at "$1" show -s --format='%(trailers:key=cs-base,valueonly,unfold)' "$2"
}

_antigravity_recovery_patch() {  # directory, base, snapshot commit
    local dir="$1" base="$2" oid="$3"
    shift 3
    _cs_git_at "$dir" --literal-pathspecs diff --binary --no-renames --no-ext-diff --no-textconv --no-color \
        --ignore-submodules=none --submodule=short --src-prefix=a/ --dst-prefix=b/ "$base" "$oid" -- "$@"
}

# Skip files already on disk as saved. For the rest, check staged changes
# and working-tree changes against the base. Apply only to the worktree:
# apply --index can check out a locally deleted file even with --check.
_antigravity_recovery_restore() (  # directory, ref, snapshot commit, base
    local dir="$1" ref="$2" oid="$3" base="$4" temp var change file
    local -a saved=() deleted=() paths=()
    local -a git_options=(-c core.hooksPath=/dev/null -c core.fsmonitor= -c core.splitIndex=false \
        -c core.sparseCheckout=false -c core.fileMode=true -c apply.ignoreWhitespace=no -c apply.whitespace=nowarn)
    [ "$(_antigravity_recovery_base "$dir" "$oid")" = "$base" ] \
        && [ "$(_antigravity_recovery_tip "$dir" "$ref")" = "$oid" ] \
        && [ "$(_antigravity_recovery_tip "$dir" HEAD)" = "$base" ] || return 1
    temp=$(mktemp -d "${TMPDIR:-/tmp}/cs-agy-recovery.XXXXXX") || return 1
    trap 'rm -rf -- "$temp"' EXIT
    _cs_git_at "$dir" diff --raw -z --no-renames --ignore-submodules=none "$base" "$oid" -- > "$temp/paths" || return 1
    while IFS= read -r -d '' change && IFS= read -r -d '' file; do
        # Git can apply a gitlink to an index without restoring its checkout.
        case "$change" in ':160000 '*|:??????' 160000 '*) return 1 ;; esac
        case "$change" in :??????' 000000 '*) deleted+=("$file") ;; *) saved+=("$file") ;; esac
    done < "$temp/paths"

    # The normal Git wrappers clear inherited repository settings. Here we
    # need to supply our own index after clearing them.
    while IFS= read -r var; do unset "$var"; done < <(git rev-parse --local-env-vars)
    export GIT_NO_REPLACE_OBJECTS=1
    cd -- "$dir" || return 1
    if [ "${#saved[@]}" -gt 0 ]; then
        export GIT_INDEX_FILE="$temp/saved-index"
        git "${git_options[@]}" read-tree "$oid" || return 1
        git "${git_options[@]}" update-index -q --refresh >/dev/null || return 1
        git "${git_options[@]}" --literal-pathspecs diff-files --name-only -z -- "${saved[@]}" > "$temp/pending" || return 1
        while IFS= read -r -d '' file; do paths+=("$file"); done < "$temp/pending"
    fi
    for file in ${deleted[@]+"${deleted[@]}"}; do
        if [ -L "$file" ] || { [ -e "$file" ] && [ ! -d "$file" ]; }; then paths+=("$file"); fi
    done
    [ "${#paths[@]}" -gt 0 ] || return 1
    _cs_git_at "$dir" --literal-pathspecs diff --cached --quiet --ignore-submodules=none \
        "$base" -- "${paths[@]}" || return 1
    _antigravity_recovery_patch "$dir" "$base" "$oid" "${paths[@]}" > "$temp/patch" || return 1
    export GIT_INDEX_FILE="$temp/base-index"
    git "${git_options[@]}" read-tree "$base" || return 1
    git "${git_options[@]}" update-index -q --refresh >/dev/null || return 1
    git "${git_options[@]}" --literal-pathspecs diff-files --quiet -- "${paths[@]}" || return 1
    git "${git_options[@]}" apply --check "$temp/patch" || return 1
    [ "$(_antigravity_recovery_tip "$dir" HEAD)" = "$base" ] \
        && [ "$(_antigravity_recovery_tip "$dir" "$ref")" = "$oid" ] \
        && _cs_git_at "$dir" --literal-pathspecs diff --cached --quiet --ignore-submodules=none \
            "$base" -- "${paths[@]}" || return 1
    git "${git_options[@]}" apply "$temp/patch" || return 1
    _cs_git_at "$dir" update-ref -d "$ref" "$oid" \
        || warn 'The files were restored. The recovery copy is still available.'
)

_antigravity_recovery_review() {  # directory, comparison commit, snapshot commit
    printf 'To inspect the saved patch from another shell, run:\n  git -C %q diff %s %s --\n' "$1" "$2" "$3"
}

_antigravity_recovery_discard() {  # directory, recovery ref, snapshot commit, conversation id
    local dir="$1" ref="$2" oid="$3" autosave="refs/worktree/cs/session/$4"
    if [ "$(_antigravity_recovery_tip "$dir" "$autosave")" = "$oid" ]; then
        printf 'delete %s %s\ndelete %s %s\n' "$ref" "$oid" "$autosave" "$oid" \
            | _cs_git_at "$dir" update-ref --stdin
    else
        _cs_git_at "$dir" update-ref -d "$ref" "$oid"
    fi
}

_antigravity_recovery_offer() {  # directory, conversation id
    local session_dir="$1" id="$2" dir ref oid head base compare summary answer="" restore="" submodule=""
    local GIT_NO_REPLACE_OBJECTS=1
    export GIT_NO_REPLACE_OBJECTS
    _is_uuid "$id" || return 0
    ref="refs/worktree/cs/antigravity-recovery/$id"
    oid=$(_antigravity_recovery_tip "$session_dir" "$ref" 2>/dev/null) || return 0
    dir=$(_cs_git_at "$session_dir" rev-parse --show-toplevel 2>/dev/null) || return 0
    head=$(_antigravity_recovery_tip "$dir" HEAD 2>/dev/null) || head=""
    base=$(_antigravity_recovery_base "$dir" "$oid" 2>/dev/null) || base=""
    compare="$head"
    if [[ "$base" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] && _antigravity_recovery_tip "$dir" "$base" >/dev/null 2>&1; then
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
    # A worktree-only apply check ignores submodule commit IDs.
    if _cs_git_at "$dir" diff --raw --no-renames --ignore-submodules=none "$compare" "$oid" -- 2>/dev/null \
        | grep -E '^:(160000|[0-7]{6} 160000) ' >/dev/null; then
        submodule=1
    elif _antigravity_recovery_patch "$dir" "$compare" "$oid" 2>/dev/null \
        | _cs_git_at "$dir" -c apply.ignoreWhitespace=no apply --check --reverse --whitespace=nowarn 2>/dev/null; then
        return 0
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
            if [ -n "$restore" ] && cs_run_with_lease "$session_dir/.cs" _antigravity_recovery_restore "$dir" "$ref" "$oid" "$base"; then
                printf 'Restored the Antigravity snapshot to the working tree.\n'
            else
                warn 'Could not restore the Antigravity snapshot safely. The recovery copy is still available.'
                _antigravity_recovery_review "$dir" "$compare" "$oid"
            fi
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
}
