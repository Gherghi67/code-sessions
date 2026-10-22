# ABOUTME: SSH-signed release manifests and the self-update mechanism.
# ABOUTME: Backs 'cs -update' and the non-blocking update-available notice.

# --- Release verification ---

# Verifies a release manifest against its signature: manifest, signature,
# release version. The signature is bound to the release through its
# namespace, cs-release-v<version>, so a manifest signed for one tag never
# verifies another.
_verify_manifest() {  # manifest, signature, version
    (
        if ! command -v ssh-keygen >/dev/null 2>&1; then
            printf '%s\n' 'ssh-keygen is required to verify release manifests.' >&2
            exit 1
        fi
        trust_dir=$(mktemp -d "${TMPDIR:-/tmp}/cs-release.XXXXXX") || exit 1
        trap 'rm -rf "$trust_dir"' EXIT
        printf '%s\n' "$CS_RELEASE_SIGNERS" > "$trust_dir/signers" || exit 1
        printf '%s' "$CS_RELEASE_REVOKED" > "$trust_dir/revoked" || exit 1
        local revocation_args=()
        [ ! -s "$trust_dir/revoked" ] || revocation_args=(-r "$trust_dir/revoked")
        if ! ssh-keygen -Y verify -f "$trust_dir/signers" -I release -n "cs-release-v$3" \
            -s "$2" ${revocation_args[@]+"${revocation_args[@]}"} < "$1" > "$trust_dir/verify.log" 2>&1; then
            printf '%s\n' 'Release manifest signature verification failed.' >&2
            exit 1
        fi
    )
}

# Verify SHA-256 checksum (hard gate — always runs)
verify_checksum() {
    local file="$1" checksumfile="$2" asset="${3:-${1##*/}}"
    local expected actual
    expected=$(awk -v asset="$asset" '
        $2 == asset {
            count++
            if (NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/) bad=1
            digest=$1
        }
        END { if (count != 1 || bad) exit 1; print digest }
    ' "$checksumfile") || return 1
    if command -v sha256sum &>/dev/null; then
        actual=$(sha256sum "$file" | awk '{print $1}') || return 1
    elif command -v shasum &>/dev/null; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}') || return 1
    else
        # Fail closed: a verification gate that can't verify must not pass.
        echo "Error: no sha256sum or shasum found — cannot verify download. Install one and retry." >&2
        return 1
    fi
    [ "$expected" = "$actual" ]
}

_check_revocation_carry_forward() {
    local installer="$1" key installed
    # Parse the literal declaration as data, without executing the installer.
    awk -v quote="'" '
        function keyline(line, parts, n) {
            if (line == "") return
            n=split(line, parts, /[ \t]+/)
            if (n < 2 || parts[1] != "ssh-ed25519" || parts[2] ~ /[^A-Za-z0-9+\/=]/) {
                bad=1
                return
            }
            print parts[1] " " parts[2]
        }
        /^[[:space:]]*(export[[:space:]]+)?CS_RELEASE_REVOKED[[:space:]]*=/ {
            count++
            if (active || index($0, "CS_RELEASE_REVOKED=" quote) != 1) { bad=1; next }
            active=1
            $0=substr($0, length("CS_RELEASE_REVOKED=" quote)+1)
        }
        active {
            end=index($0, quote)
            if (end) {
                if (end != length($0)) bad=1
                keyline(substr($0, 1, end-1))
                active=0
            } else keyline($0)
        }
        END { if (count != 1 || active || bad) exit 1 }
    ' "$installer" > "$installer.revoked" || error "Malformed CS_RELEASE_REVOKED in downloaded installer."
    installed=$(printf '%s\n' "$CS_RELEASE_REVOKED" | awk '
        NF {
            if (NF < 2 || $1 != "ssh-ed25519" || $2 ~ /[^A-Za-z0-9+\/=]/) exit 1
            print $1 " " $2
        }
    ') || error "Malformed installed CS_RELEASE_REVOKED."
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        grep -qxF "$key" "$installer.revoked" || error "Release dropped revoked key: $key"
    done <<< "$installed"
}

# --- Update mechanism ---

# Fetch latest version from GitHub Releases
get_remote_version() {
    curl -fsSL --connect-timeout 2 --max-time 4 \
        "${RELEASES_BASE}/latest" -o /dev/null -w '%{url_effective}' 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//'
}

# Compare versions (YYYY.MM.N format). Returns 0 if v1 > v2, 1 otherwise
version_greater() {
    local v1="$1" v2="$2"

    # Split into components
    local y1 m1 n1 y2 m2 n2
    IFS='.' read -r y1 m1 n1 <<< "$v1"
    IFS='.' read -r y2 m2 n2 <<< "$v2"

    # Compare year
    if [ "$y1" -gt "$y2" ] 2>/dev/null; then return 0; fi
    if [ "$y1" -lt "$y2" ] 2>/dev/null; then return 1; fi

    # Compare month
    if [ "$m1" -gt "$m2" ] 2>/dev/null; then return 0; fi
    if [ "$m1" -lt "$m2" ] 2>/dev/null; then return 1; fi

    # Compare patch
    if [ "$n1" -gt "$n2" ] 2>/dev/null; then return 0; fi

    return 1
}

# Strip bold markers and links (keeping the link text); backticks survive
# for the renderer's code-span tinting.
_md_strip_links_bold() {
    printf '%s' "$1" | sed -e 's/\*\*//g' \
        -e 's/\[\([^]]*\)\]([^)]*)/\1/g'
}

# Strip inline markdown to plain text: bold markers, backticks, and links
# (keeping the link text).
_md_strip_inline() {
    _md_strip_links_bold "$1" | sed -e 's/`//g'
}

# Emit the changelog sections for every version newer than $2 from file $1,
# newest first (file order). Sections are delimited by '## X.Y.Z' headings;
# emission stops at the first heading that is not newer.
changelog_span() {
    local file="$1" installed="$2"
    local line ver keep=""
    while IFS= read -r line; do
        case "$line" in
            "## "*)
                ver="${line#\#\# }"
                if version_greater "$ver" "$installed"; then
                    keep=1
                else
                    break
                fi
                ;;
        esac
        if [ -n "$keep" ]; then
            printf '%s\n' "$line"
        fi
    done < "$file"
    return 0
}

# Emit up to $3 'version<TAB>summary' lines for versions newer than $2 in
# file $1, plus a '+<TAB>… and N earlier versions' line when capped. The
# summary is a section's first non-empty prose line (headings, comments,
# and subsection labels don't qualify), markdown-stripped.
changelog_summaries() {
    local file="$1" installed="$2" cap="$3"
    local line ver="" want="" total=0
    while IFS= read -r line; do
        case "$line" in
            "## "*)
                ver="${line#\#\# }"
                if version_greater "$ver" "$installed"; then
                    total=$((total + 1))
                    want=""
                    if [ "$total" -le "$cap" ]; then
                        want="$ver"
                    fi
                else
                    break
                fi
                ;;
            ""|"### "*|"<!--"*)
                :
                ;;
            *)
                if [ -n "$want" ]; then
                    printf '%s\t%s\n' "$want" "$(_md_strip_inline "$line")"
                    want=""
                fi
                ;;
        esac
    done < "$file"
    if [ "$total" -gt "$cap" ]; then
        printf '+\t… and %d earlier versions\n' $((total - cap))
    fi
    return 0
}

# Render one bullet: '**Title.** body' becomes a bold title line with the
# dimmed body wrapped and indented beneath it; anything else wraps plain.
_render_bullet() {
    local text="$1" width="$2"
    local title="" body=""
    case "$text" in
        "**"*"**"*)
            title="${text#\*\*}"
            title="${title%%\*\**}"
            body="${text#*\*\*"$title"\*\*}"
            body="${body# }"
            ;;
        *)
            body="$text"
            ;;
    esac
    body="$(_md_strip_links_bold "$body")"
    if [ -n "$title" ]; then
        printf '  %b•%b %b%s%b\n' "$YELLOW" "$NC" "$BOLD" "$(_md_strip_inline "$title")" "$NC"
        if [ -n "$body" ]; then
            local gold_esc nc_esc dim_esc
            gold_esc=$(printf '%b' "$GOLD")
            nc_esc=$(printf '%b' "$NC")
            dim_esc=$(printf '%b' "$DIM")
            printf '%b' "$DIM"
            printf '%s\n' "$body" | fold -s -w $((width - 4)) | sed 's/^/    /' \
                | sed "s/\`\([^\`]*\)\`/${gold_esc}\1${nc_esc}${dim_esc}/g" | sed 's/`//g'
            printf '%b' "$NC"
        fi
    else
        printf '%s\n' "$body" | sed 's/`//g' | fold -s -w $((width - 4)) | sed 's/^/  /'
    fi
    return 0
}

# Print the pending version header (with an optional summary joined on the
# line) and its dim rule, then clear it. Called from render_changelog.
_flush_version_header() {
    printf '\n%b▌%b %b%s%b' "$YELLOW" "$NC" "${GREEN}${BOLD}" "$pending_ver" "$NC"
    if [ -n "$1" ]; then
        printf ' %s' "$1"
    fi
    printf '\n'
    printf '%b%s%b\n' "$DIM" "────────────────────────────────────────────────────────" "$NC"
    pending_ver=""
}

# Render a changelog markdown stream (stdin) in house style: version + its
# summary on one line under a colored bar, subsection labels tinted,
# bold-title bullets with dimmed wrapped bodies.
render_changelog() {
    local width
    width=$(tput cols 2>/dev/null) || width=80
    case "$width" in ''|*[!0-9]*) width=80 ;; esac
    if [ "$width" -gt 100 ]; then
        width=100
    fi
    if [ "$width" -lt 20 ]; then
        width=20
    fi
    local line pending_ver=""
    while IFS= read -r line; do
        case "$line" in
            "## "*)
                pending_ver="${line#\#\# }"
                ;;
            "### "*)
                if [ -n "$pending_ver" ]; then
                    _flush_version_header ""
                fi
                printf '  %b%s%b\n' "$YELLOW" "${line#\#\#\# }" "$NC"
                ;;
            "<!--"*|"")
                :
                ;;
            "- "*)
                if [ -n "$pending_ver" ]; then
                    _flush_version_header ""
                fi
                _render_bullet "${line#- }" "$width"
                ;;
            *)
                if [ -n "$pending_ver" ]; then
                    _flush_version_header "$(_md_strip_inline "$line")"
                else
                    printf '  %s\n' "$(_md_strip_inline "$line")"
                fi
                ;;
        esac
    done
    if [ -n "$pending_ver" ]; then
        _flush_version_header ""
    fi
    return 0
}

# Fetch the remote changelog to a tmp file; echo the path (caller removes
# it) or return 1.
fetch_remote_changelog() {
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/cs-changelog.XXXXXX") || return 1
    if curl -fsSL --connect-timeout 2 --max-time 4 \
        "$CHANGELOG_RAW_URL" -o "$tmp" 2>/dev/null; then
        echo "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Check for updates
check_update() {
    local remote_version
    remote_version=$(get_remote_version) || {
        error "Failed to check for updates. Check your internet connection."
    }

    echo -e "Current version: ${GREEN}$VERSION${NC}"
    echo -e "Latest version:  ${GREEN}$remote_version${NC}"

    if version_greater "$remote_version" "$VERSION"; then
        echo ""
        info "Update available. Run 'cs -update' to install."
        local notes
        if notes=$(fetch_remote_changelog); then
            changelog_span "$notes" "$VERSION" | render_changelog
            rm -f "$notes"
        else
            echo ""
            echo "  See ${RELEASES_BASE} for what's new."
        fi
        return 0
    else
        echo ""
        info "Already up to date."
        return 0
    fi
}

# Perform update (downloads signed installer from GitHub Releases)
do_update() {
    local remote_version
    local from_version="$VERSION"

    remote_version=$(get_remote_version) || {
        error "Failed to fetch update. Check your internet connection."
    }

    local is_upgrade=false
    if version_greater "$remote_version" "$VERSION"; then
        is_upgrade=true
    elif version_greater "$VERSION" "$remote_version"; then
        error "Release v${remote_version} is older than the installed cs ${VERSION}. Update aborted."
    fi

    echo ""
    if [ "$is_upgrade" = true ]; then
        echo -e "   ${COMMENT}Updating${NC} cs ${COMMENT}from${NC} ${RUST}$VERSION${NC} ${COMMENT}→${NC} ${GREEN}$remote_version${NC}"
    else
        echo -e "   ${COMMENT}Reinstalling${NC} cs ${GREEN}$VERSION${NC}"
    fi
    echo ""

    local releases_url="${RELEASES_BASE}/download/v${remote_version}"
    # A global, not a local: the EXIT trap runs after do_update's frame may be
    # gone, and it removes the dir however the update ends (an error() below,
    # a failing installer under errexit, or the final exit).
    _CS_UPDATE_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/cs-update.XXXXXX") \
        || error "Failed to create a temp dir for the update."
    trap 'rm -rf "$_CS_UPDATE_TMPDIR"' EXIT
    local tmpdir="$_CS_UPDATE_TMPDIR"

    curl -fsSL "$releases_url/install.sh" -o "$tmpdir/install.sh" || {
        error "Failed to download installer."
    }
    curl -fsSL "$releases_url/SHA256SUMS" -o "$tmpdir/SHA256SUMS" || {
        error "Failed to download release manifest."
    }
    curl -fsSL "$releases_url/SHA256SUMS.sig" -o "$tmpdir/SHA256SUMS.sig" || {
        error "Failed to download release manifest signature."
    }

    if ! _verify_manifest "$tmpdir/SHA256SUMS" "$tmpdir/SHA256SUMS.sig" "$remote_version"; then
        error "Release manifest signature verification failed. Update aborted."
    fi
    if ! verify_checksum "$tmpdir/install.sh" "$tmpdir/SHA256SUMS"; then
        error "Checksum verification failed. Update aborted."
    fi
    # The installer fetches its payload from the ref it names; a verified
    # installer pinned to another tag would install another release.
    if ! grep -qx "CS_DEFAULT_REF=v${remote_version}" "$tmpdir/install.sh"; then
        error "Downloaded installer is not pinned to v${remote_version}. Update aborted."
    fi
    _check_revocation_carry_forward "$tmpdir/install.sh"

    info "Verified"

    # Run the verified installer, pinning the payload (cs, cs-secrets, hooks,
    # …) to the same immutable release tag rather than letting it fetch from the
    # mutable main branch. The installer is signature-verified, so it is trusted
    # to fetch its payload from the tag it was published at.
    CS_INSTALL_REF="v${remote_version}" bash "$tmpdir/install.sh"
    rm -rf "$tmpdir"

    # Clear update cache so notification disappears
    rm -f "$HOME/.cache/cs/update-check"

    # Show release notes for the installed version
    local new_version
    new_version=$(grep '^VERSION=' "$HOME/.local/bin/cs" 2>/dev/null | head -1 | cut -d'"' -f2)
    if [ -n "$new_version" ]; then
        local changelog
        local script_dir
        script_dir="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
        changelog="$(dirname "$script_dir")/CHANGELOG.md"
        if [ -f "$changelog" ]; then
            echo ""
            changelog_span "$changelog" "$from_version" | render_changelog
        else
            echo ""
            echo "  See ${RELEASES_BASE} for what's new."
        fi
    fi

    # Exit immediately to prevent bash from reading more of the old script
    # (the file was just overwritten, continuing would cause errors)
    exit 0
}

# Check for updates periodically and notify (non-blocking)
UPDATE_CACHE="$HOME/.cache/cs/update-check"
UPDATE_CHECK_INTERVAL=3600  # 1 hour in seconds
UPDATE_AVAILABLE=""  # Set by check_update_notify if update available

check_update_notify() {
    # Opt out of the network check + cache write (tests set this so a session
    # launch never hits GitHub or touches the real ~/.cache/cs).
    [ -n "${CS_NO_UPDATE_CHECK:-}" ] && return 0

    local cache_dir
    cache_dir="$(dirname "$UPDATE_CACHE")"
    mkdir -p "$cache_dir"

    local now
    now=$(date +%s)

    # Check if cache exists and is fresh. A fresh cache answers the question
    # either way, so a launch that is up to date asks GitHub at most hourly.
    local cache_fresh=""
    if [ -f "$UPDATE_CACHE" ]; then
        local cache_time cached_version
        read -r cache_time cached_version < "$UPDATE_CACHE" 2>/dev/null || true
        # Digits only before the arithmetic below, which would evaluate any
        # other token as an expression; anything else is no cache.
        case "$cache_time" in *[!0-9]*) cache_time="" ;; esac

        # A fresh cache needs both fields: a line torn after the time names
        # no version and answers nothing, so it reads as no cache.
        if [ -n "$cache_time" ] && [ -n "$cached_version" ] \
            && [ $((now - cache_time)) -lt $UPDATE_CHECK_INTERVAL ]; then
            cache_fresh=1
            # Set update available if cached version is newer
            if version_greater "$cached_version" "$VERSION"; then
                UPDATE_AVAILABLE="$cached_version"
            fi
        fi
    fi

    # No fresh cache - do a quick synchronous check
    if [ -z "$cache_fresh" ]; then
        local remote_version
        remote_version=$(get_remote_version 2>/dev/null) || remote_version=""

        if [ -n "$remote_version" ]; then
            cs_write_atomic "$UPDATE_CACHE" printf '%s %s\n' "$now" "$remote_version" || true
            if version_greater "$remote_version" "$VERSION"; then
                UPDATE_AVAILABLE="$remote_version"
            fi
        fi
    fi

    # Build the launch card's notes cache once per pending remote version,
    # and beside it the full changelog span the cs-update mod draws; an
    # empty file records a failed fetch so launches don't retry the network
    # until the version changes (or an explicit --check/-update).
    if [ -n "$UPDATE_AVAILABLE" ]; then
        local notes_cache="$cache_dir/update-notes-$UPDATE_AVAILABLE"
        local full_cache="$cache_dir/update-notes-full-$UPDATE_AVAILABLE"
        if [ ! -f "$notes_cache" ] || [ ! -f "$full_cache" ]; then
            local notes
            if notes=$(fetch_remote_changelog); then
                # A cache that cannot be written is left absent, and the next
                # launch builds it again.
                cs_write_atomic "$notes_cache" changelog_summaries "$notes" "$VERSION" 5 || true
                cs_write_atomic "$full_cache" changelog_span "$notes" "$VERSION" || true
                rm -f "$notes"
            else
                : > "$notes_cache"
                : > "$full_cache"
            fi
            local stale
            for stale in "$cache_dir"/update-notes-*; do
                [ -e "$stale" ] || continue
                if [ "$stale" != "$notes_cache" ] && [ "$stale" != "$full_cache" ]; then
                    rm -f "$stale"
                fi
            done
        fi
    fi
}

# Check dependencies
