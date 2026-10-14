#!/usr/bin/env bash
# ABOUTME: Guards that every cd or pushd in cs's shipped shell puts -- before an operand
# ABOUTME: taken from a variable, so a name starting with a dash is a path and not an option

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

REPO_ROOT="$SCRIPT_DIR/.."

# A cd or pushd, past any options of its own, whose operand starts with $ (a
# variable or a command substitution) with no -- before it. cd -P "$d" reads
# a directory named -L as an option and lands in $HOME; cd -- "$d" does not.
CD_OPERAND_RE='(^|[^[:alnum:]_.-])(cd|pushd)([[:space:]]+-[LPe@]+)*[[:space:]]+"?\$'

# Print file:line:text for each such cd in the files, skipping lines that
# start with a comment. A file that does not exist is named too, so a path
# list that stops matching cannot pass by scanning nothing.
_cd_without_end_of_options() {  # file...
    local f line
    for f in "$@"; do
        if [ ! -f "$f" ]; then
            printf '%s: no such file\n' "$f"
            continue
        fi
        while IFS= read -r line; do
            printf '%s:%s\n' "$f" "$line"
        done < <(grep -nE "$CD_OPERAND_RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    done
}

# The shell cs ships: the lib/ fragments bin/cs is built from, the hooks, the
# skills' scripts and the standalone binaries.
test_shipped_shell_puts_end_of_options_before_a_variable_cd_operand() {
    local out
    out=$(cd "$REPO_ROOT" && _cd_without_end_of_options lib/*.sh hooks/*.sh skills/*/scripts/*.sh \
        bin/cs-secrets bin/cs-statusline bin/cs-subagent-statusline)
    assert_eq "" "$out" "every cd or pushd with a variable operand passes -- first" || return 1
}

# The scan finds each unguarded form and passes the guarded ones, literal
# operands and comments.
test_the_scan_names_each_cd_with_a_variable_operand_and_no_end_of_options() {
    local f="$TEST_TMPDIR/sample.sh" out
    mkdir -p "$TEST_TMPDIR"
    cat > "$f" <<'EOF'
cd "$a"
x=$(cd -P "$b" && pwd -P)
(cd "${c}/d" && ls)
pushd "$e"
cd $f
y=$(cd "$(dirname "$g")" && pwd)
cd -- "$h"
z=$(cd -P -- "$i" && pwd -P)
cd ./"$j"
cd .cs/local
    # cd "$k" in a comment
echo "the cd goes to $l"
EOF
    out=$(_cd_without_end_of_options "$f" "$TEST_TMPDIR/missing.sh")
    assert_eq "$f:1:cd \"\$a\"
$f:2:x=\$(cd -P \"\$b\" && pwd -P)
$f:3:(cd \"\${c}/d\" && ls)
$f:4:pushd \"\$e\"
$f:5:cd \$f
$f:6:y=\$(cd \"\$(dirname \"\$g\")\" && pwd)
$TEST_TMPDIR/missing.sh: no such file" "$out" "the scan names lines 1 to 6 and the missing file" || return 1
}

run_test test_shipped_shell_puts_end_of_options_before_a_variable_cd_operand
run_test test_the_scan_names_each_cd_with_a_variable_operand_and_no_end_of_options

report_results
