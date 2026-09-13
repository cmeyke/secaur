#!/usr/bin/env bash
#
# aur-diff.sh — check for pending AUR updates; save their diffs to a file
#
# Checks whether any installed foreign (AUR) packages have updates pending,
# and writes a unified diff of the build files (PKGBUILD / .SRCINFO) that each
# pending update would introduce into ./aur.diff. The output file is always
# overwritten, so it always reflects the most recent check.
#
# Usage:
#   ./aur-diff.sh [OPTIONS]
#
#   -o, --output FILE      write the diffs to FILE (default: ./aur.diff)
#       --include-ignored  also audit updates held back via IgnorePkg
#   -h, --help             show this help and exit
#
# Exit status:
#   0   done — no actionable AUR updates are pending (none at all, or all
#       held back via IgnorePkg; the output file contains a note)
#   3   done — auditable AUR updates are pending, their diffs were written
#   1   error — output may be incomplete; see stderr and notes in the file
#
# How it works:
#   1. `pacman -Qm` lists the installed foreign packages with their versions.
#   2. The current AUR versions are fetched with the official AUR RPC v5 API
#      (batched HTTPS queries).
#   3. A package counts as pending when `vercmp <installed> <remote>` < 0 —
#      the same notion of "pending" as `auracle outdated` / `yay -Qua`.
#   4. The pending packages are grouped by AUR base (split packages share one
#      build). For every base its AUR git repository is cloned into a
#      temporary directory, the commit matching the installed version is
#      located in the git history, and everything from that commit up to HEAD
#      is saved: the upstream commit log, a --stat overview of all changed
#      files, and a full unified diff of PKGBUILD and .SRCINFO.
#   5. If the installed version is not found in the history (typical for
#      -git packages whose pkgver comes from a pkgver() function, or when the
#      installed version is older than the last SCAN_LIMIT build commits), the
#      complete current PKGBUILD is written instead, with an explanatory note.
#   6. Updates held back via IgnorePkg (pacman.conf — preferably read with
#      pacman-conf —, paru.conf, or yay's config.json; glob patterns are
#      supported) would be "pending" forever. They are summarized in the
#      output header but not audited; if they are the only pending updates,
#      exit 0 is returned. Use --include-ignored to audit them anyway (their
#      sections are marked as held back).
#
# Requirements: bash, pacman (provides vercmp), curl, diff, plus jq or
#   python3 for JSON parsing (an awk fallback exists). git is required for
#   real diffs; without it only full PKGBUILDs can be saved. pacman-conf is
#   used when available to resolve IgnorePkg including Include= files.
#   The AUR is only read — nothing is installed, built or modified.
#
# The JSON parser can be forced with AUR_DIFF_PARSER=auto|jq|python3|awk;
# AUR_DIFF_IGNORE_CONF overrides the ignore-list config files (a
# colon-separated list).

set -euo pipefail

readonly PROGNAME=$(basename "$0")
readonly AUR_RPC_URL='https://aur.archlinux.org/rpc/v5/info'
readonly AUR_GIT_URL='https://aur.archlinux.org'
readonly RPC_CHUNK_SIZE=50   # package names per RPC query
readonly SCAN_LIMIT=200      # commits inspected when locating the installed version

readonly CURL_OPTS=(--silent --show-error --fail --location
                    --connect-timeout 15 --retry 2)

OUT='aur.diff'
tmp=''
JSON_PARSER="${AUR_DIFF_PARSER:-auto}"
INCLUDE_IGNORED=0
declare -A IGNORE_SEEN=()   # IgnorePkg entries: exact names or glob patterns

# ----------------------------------------------------------------- helpers ---

usage() {
    cat <<EOF
aur-diff.sh — check for pending AUR updates; save their diffs to a file

Usage: $PROGNAME [OPTIONS]

  -o, --output FILE      write the diffs to FILE (default: ./aur.diff)
      --include-ignored  also audit updates held back via IgnorePkg
  -h, --help             show this help and exit

Exit status:  0 no actionable pending AUR updates (none, or all ignored)
              3 auditable pending updates (diffs written)
              1 error — output may be incomplete (see notes in the file)
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    printf "Try '%s --help'\n" "$PROGNAME" >&2
    exit 2
}

die() {
    printf '%s: error: %s\n' "$PROGNAME" "$*" >&2
    # Never leave a stale diff behind: replace the output with an error note.
    { printf '# %s: ERROR: %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')" "$*"
      printf '# No diff data — this file was written because the check FAILED.\n'
    } >"$OUT" 2>/dev/null || true
    exit 1
}

check_deps() {
    local c missing=()
    for c in pacman vercmp curl diff; do
        have "$c" || missing+=("$c")
    done
    if ((${#missing[@]} > 0)); then
        die "missing required command(s): ${missing[*]}"
    fi
    if ! have git; then
        printf '%s: warning: git not found — only full PKGBUILDs can be saved, no real diffs\n' \
            "$PROGNAME" >&2
    fi
}

choose_parser() {
    case $JSON_PARSER in
        jq)      have jq      || die 'AUR_DIFF_PARSER=jq, but jq is not installed' ;;
        python3) have python3 || die 'AUR_DIFF_PARSER=python3, but python3 is not installed' ;;
        awk)     : ;;
        auto)
            if have jq; then JSON_PARSER=jq
            elif have python3; then JSON_PARSER=python3
            else JSON_PARSER=awk
            fi ;;
        *) die 'AUR_DIFF_PARSER must be one of: auto, jq, python3, awk' ;;
    esac
}

# ------------------------------------------------------------ ignore lists ---
# Updates for packages in an IgnorePkg list are intentionally not applied
# (paru prints "ignoring package upgrade" for them), so their "pending"
# status never resolves — they would be re-audited on every run. aur-diff.sh
# therefore does not audit them by default and only summarizes them in the
# output header. Sources: pacman-conf(1) (preferred: it resolves Include=
# directives), the ini-style pacman.conf/paru.conf files themselves, and
# yay's config.json. Glob patterns are supported.

add_ignore_patterns() { # words as arguments: exact names or glob patterns
    local p
    for p in "$@"; do
        [[ -n $p ]] || continue
        IGNORE_SEEN[$p]=1
    done
}

read_ini_ignores() { # $1 = ini-style config file, $2 = include depth
    local file=$1 depth=${2:-0} line key rest inc f
    local -a pats=()
    if [[ ! -r $file ]] || ((depth > 4)); then
        return 0
    fi
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}
        [[ $line == *=* ]] || continue
        key=${line%%=*}
        key=${key#"${key%%[![:space:]]*}"}   # trim whitespace around the key
        key=${key%"${key##*[![:space:]]}"}
        rest=${line#*=}
        case ${key,,} in
            ignorepkg)
                pats=()
                read -r -a pats <<<"$rest" || true   # no globbing here
                add_ignore_patterns "${pats[@]}"
                ;;
            include)
                for inc in $rest; do                 # globbing intended here
                    for f in $inc; do
                        [[ -f $f ]] || continue
                        read_ini_ignores "$f" $((depth + 1))
                    done
                done
                ;;
        esac
    done <"$file"
}

read_yay_ignores() { # $1 = yay config.json
    local file=$1 out line
    local -a pats=()
    if [[ ! -r $file ]]; then
        return 0
    fi
    if have jq; then
        out=$(jq -r '.ignorepkg[]?' "$file" 2>/dev/null) || out=''
    elif have python3; then
        out=$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
for p in cfg.get("ignorepkg") or []:
    print(p)
' "$file" 2>/dev/null) || out=''
    else
        return 0
    fi
    while IFS= read -r line; do
        pats=()
        read -r -a pats <<<"$line" || true
        add_ignore_patterns "${pats[@]}"
    done <<<"$out"
}

load_ignore_lists() {
    local -a confs=()
    local c out line
    local -a pats=()
    if [[ -n ${AUR_DIFF_IGNORE_CONF:-} ]]; then
        IFS=: read -r -a confs <<<"$AUR_DIFF_IGNORE_CONF"
    else
        confs=('/etc/pacman.conf' '/etc/paru.conf'
               "${XDG_CONFIG_HOME:-$HOME/.config}/paru/paru.conf"
               "$HOME/.config/yay/config.json")
    fi
    for c in "${confs[@]}"; do
        [[ -n $c ]] || continue
        if [[ $c == *.json ]]; then
            read_yay_ignores "$c"
        elif [[ $c == '/etc/pacman.conf' ]] && have pacman-conf; then
            # pacman-conf resolves Include= directives and format quirks
            out=$(pacman-conf IgnorePkg 2>/dev/null) || out=''
            while IFS= read -r line; do
                pats=()
                read -r -a pats <<<"$line" || true
                add_ignore_patterns "${pats[@]}"
            done <<<"$out"
        else
            read_ini_ignores "$c" 0
        fi
    done
}

is_ignored() { # $1 = package name; rc 0 when held back via IgnorePkg
    local name=$1 p
    for p in "${!IGNORE_SEEN[@]}"; do
        if [[ $name == $p ]]; then
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------- AUR RPC (version db) --

# Parse an AUR RPC v5 info response from stdin;
# prints "name<TAB>version<TAB>pkgbase" for every result.
parse_rpc() {
    case $JSON_PARSER in
        jq)
            jq -r '(.results // [])[] | [.Name, .Version, (.PackageBase // .Name)] | @tsv' ;;
        python3)
            python3 -c '
import json, sys
for r in json.load(sys.stdin).get("results", []):
    print("\t".join((r["Name"], r["Version"], r.get("PackageBase") or r["Name"])))
' ;;
        awk)
            # Last-resort fallback: a tiny token scanner. Relies on the RPC
            # serializer emitting Name ... PackageBase ... Version per result
            # (it serializes fields alphabetically).
            awk '{
                s = $0
                while (match(s, /"(Name|PackageBase|Version)"[ \t]*:[ \t]*"[^"]*"/)) {
                    tok = substr(s, RSTART, RLENGTH)
                    s  = substr(s, RSTART + RLENGTH)
                    key = tok; sub(/^"/, "", key); sub(/"[ \t]*:.*/, "", key)
                    val = tok; sub(/^[^:]*:[ \t]*"/, "", val); sub(/"$/, "", val)
                    if (key == "Name")             { name = val; pbase = "" }
                    else if (key == "PackageBase") pbase = val
                    else if (key == "Version") {
                        if (name != "")
                            printf "%s\t%s\t%s\n", name, val, (pbase != "" ? pbase : name)
                        name = ""
                    }
                }
            }' ;;
    esac
}

rpc_query_batch() {
    local -a args=()
    local name resp
    for name in "$@"; do
        args+=(--data-urlencode "arg[]=$name")
    done
    resp=$(curl "${CURL_OPTS[@]}" -G "$AUR_RPC_URL" "${args[@]}") ||
        die "AUR RPC query failed for '${1}' (+$(($# - 1)) more) — network problem?"
    [[ $resp == *'"results"'* ]] ||
        die "unexpected AUR RPC response for '${1}' (got ${#resp} bytes, is it JSON?)"
    parse_rpc <<<"$resp"
}

# Query the AUR for the given package names (in chunks);
# prints "name<TAB>version<TAB>pkgbase" lines.
rpc_query() {
    local -a batch=()
    local name
    for name in "$@"; do
        batch+=("$name")
        if ((${#batch[@]} >= RPC_CHUNK_SIZE)); then
            rpc_query_batch "${batch[@]}"
            batch=()
        fi
    done
    if ((${#batch[@]} > 0)); then
        rpc_query_batch "${batch[@]}"
    fi
}

# ------------------------------------------------- AUR git history digging ---

# First value of a "key = value" (SRCINFO) / "key=value" (PKGBUILD) assignment.
field_at() {
    local src=$1 key=$2 raw=''
    raw=$(awk -v k="$key" '
        $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*", "")
            print
            exit
        }' <<<"$src")
    raw=${raw%%#*}           # strip a trailing comment
    raw=${raw%%[[:space:]]*} # cut at the first whitespace
    raw=${raw#\'}; raw=${raw%\'}
    raw=${raw#\"}; raw=${raw%\"}
    printf '%s' "$raw"
}

# Full version ("epoch:pkgver-pkgrel") of a package at a given commit, or ''.
version_at() {
    local repo=$1 commit=$2 src v r e
    src=$(git -C "$repo" show "$commit:.SRCINFO" 2>/dev/null) || src=''
    if [[ -z $src ]]; then
        src=$(git -C "$repo" show "$commit:PKGBUILD" 2>/dev/null) || src=''
        [[ -n $src ]] || return 0
    fi
    v=$(field_at "$src" pkgver)
    r=$(field_at "$src" pkgrel)
    e=$(field_at "$src" epoch)
    if [[ -z $v || -z $r ]]; then
        return 0
    fi
    if [[ $e == '0' ]]; then
        e=''
    fi
    if [[ -n $e ]]; then
        printf '%s:%s-%s' "$e" "$v" "$r"
    else
        printf '%s-%s' "$v" "$r"
    fi
    return 0
}

# Newest commit whose version equals the installed one; not found -> rc 1.
scan_baseline() {
    local repo=$1 installed=$2 commit i=0 v
    local -a commits=()
    mapfile -t commits < <(git -C "$repo" rev-list HEAD -- PKGBUILD .SRCINFO 2>/dev/null)
    for commit in "${commits[@]}"; do
        i=$((i + 1))
        if ((i > SCAN_LIMIT)); then
            return 1
        fi
        v=$(version_at "$repo" "$commit")
        if [[ $v == "$installed" ]]; then
            printf '%s\n' "$commit"
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------ diff section output --

# Full current PKGBUILD from an existing clone, as a /dev/null diff.
emit_full_pkgbuild_from_repo() {
    local repo=$1 rver=$2 f rc=0
    f="$tmp/PKGBUILD.current"
    if ! git -C "$repo" show 'HEAD:PKGBUILD' >"$f" 2>/dev/null; then
        printf '# ERROR: could not read the current PKGBUILD from the AUR repo\n'
        return 1
    fi
    printf '# Full current PKGBUILD (%s):\n\n' "$rver"
    diff -u --label /dev/null --label "PKGBUILD (pending $rver)" /dev/null "$f" || rc=$?
    if ((rc > 1)); then
        printf '# ERROR: diff of the full PKGBUILD failed\n'
        return 1
    fi
    return 0
}

# Full current PKGBUILD via cgit (used when git is unavailable).
emit_full_pkgbuild_via_cgit() {
    local pbase=$1 rver=$2 f rc=0
    f="$tmp/PKGBUILD.current"
    if ! curl "${CURL_OPTS[@]}" -o "$f" "$AUR_GIT_URL/cgit/aur.git/plain/PKGBUILD?h=$pbase"; then
        printf '# ERROR: could not download the current PKGBUILD for %s\n' "$pbase"
        return 1
    fi
    printf '# Full current PKGBUILD (%s):\n\n' "$rver"
    diff -u --label /dev/null --label "PKGBUILD (pending $rver)" /dev/null "$f" || rc=$?
    if ((rc > 1)); then
        printf '# ERROR: diff of the full PKGBUILD failed\n'
        return 1
    fi
    return 0
}

# One AUR base's review section, covering every pending split package of it.
# $1 = pkgbase, $2 = group lines: "name<TAB>installed<TAB>remote<TAB>held"
# where <held> is "held" for packages held back via IgnorePkg, else empty.
# rc != 0 on hard failure.
emit_base_section() {
    local pbase=$1 group=$2
    local repo="$tmp/repos/$pbase"
    local n iv rv ig n0 iv0 rv0 ig0 count baseline anchor='' sha1 sha2
    local held held0=''
    local -A tried=()
    local -a tryvers=()

    IFS=$'\t' read -r n0 iv0 rv0 ig0 <<<"$group"
    if [[ ${ig0:-} == 'held' ]]; then
        held0='   [held back: IgnorePkg]'
    fi
    count=$(grep -c . <<<"$group")

    printf '\n'
    printf '# ------------------------------------------------------------------------\n'
    if ((count == 1)) && [[ $n0 == "$pbase" ]]; then
        printf '# %s : %s  ->  %s%s\n' "$n0" "$iv0" "$rv0" "$held0"
    else
        printf '# %s — AUR base with %d pending package(s):\n' "$pbase" "$count"
        while IFS=$'\t' read -r n iv rv ig; do
            [[ -n ${n:-} ]] || continue
            if [[ ${ig:-} == 'held' ]]; then
                held='   [held back]'
            else
                held=''
            fi
            printf '#   %-38s %s -> %s%s\n' "$n" "$iv" "$rv" "$held"
        done <<<"$group"
    fi
    printf '# ------------------------------------------------------------------------\n'

    if ! have git; then
        printf '# NOTE: git is not available — a real diff cannot be produced.\n'
        printf '#       The complete current PKGBUILD is written for review instead.\n\n'
        emit_full_pkgbuild_via_cgit "$pbase" "$rv0" || return 1
        return 0
    fi

    if [[ ! -d $repo ]]; then
        if ! GIT_TERMINAL_PROMPT=0 git clone -q --single-branch --no-checkout \
                "$AUR_GIT_URL/$pbase.git" "$repo" 2>/dev/null; then
            printf '# ERROR: could not clone %s from the AUR (removed or renamed?)\n' "$pbase"
            return 1
        fi
    fi

    # distinct installed versions of the group (split packages are usually equal)
    while IFS=$'\t' read -r n iv rv ig; do
        [[ -n ${n:-} ]] || continue
        if [[ -z ${tried[$iv]:-} ]]; then
            tried[$iv]=1
            tryvers+=("$iv")
        fi
    done <<<"$group"

    for iv in "${tryvers[@]}"; do
        if baseline=$(scan_baseline "$repo" "$iv"); then
            anchor=$iv
            break
        fi
    done

    if [[ -n $baseline ]]; then
        sha1=$(git -C "$repo" rev-parse --short "$baseline")
        sha2=$(git -C "$repo" rev-parse --short HEAD)
        printf '# Changes from the installed version (%s at %s) to the pending version (%s at %s):\n\n' \
            "$anchor" "$sha1" "$rv0" "$sha2"
        printf '# upstream commits:\n'
        git -C "$repo" log --pretty=format:'#   %h %ad %s' --date=short "$baseline..HEAD"
        printf '\n\n'
        printf '# all files changed (sources, install scripts, patches, ...):\n'
        git -C "$repo" diff --stat "$baseline" HEAD | sed 's/^/#   /'
        printf '\n'
        if git -C "$repo" diff --quiet "$baseline" HEAD -- PKGBUILD .SRCINFO; then
            printf '# PKGBUILD and .SRCINFO are unchanged — nothing to review here.\n'
        else
            printf '# build-file diff (PKGBUILD + .SRCINFO):\n\n'
            git -C "$repo" diff "$baseline" HEAD -- PKGBUILD .SRCINFO
        fi
    else
        printf '# NOTE: none of the installed version(s) [%s] appear in the AUR history\n' \
            "${tryvers[*]}"
        printf '#       (typical for -git/-hg/... packages whose pkgver is computed by\n'
        printf '#        a pkgver() function, for locally-modified packages, or when the\n'
        printf '#        version is older than the %d most recent build-file commits).\n' "$SCAN_LIMIT"
        printf '#        The complete current PKGBUILD is written below for a full review.\n\n'
        emit_full_pkgbuild_from_repo "$repo" "$rv0" || return 1
    fi
    return 0
}

# ------------------------------------------------------------------- main ----

main() {
    local name ver n rpc_out failed=0
    local -a names=() pending=() local_only=()
    local -A installed=() remote=() base=()
    local body

    while (($# > 0)); do
        case $1 in
            -o|--output)
                [[ $# -ge 2 ]] || usage_error 'option -o/--output needs a file argument'
                OUT=$2
                shift 2 ;;
            --output=*)
                OUT=${1#*=}
                shift ;;
            --include-ignored)
                INCLUDE_IGNORED=1
                shift ;;
            -h|--help)
                usage
                exit 0 ;;
            --)
                shift
                break ;;
            *)
                usage_error "unknown option: $1" ;;
        esac
    done
    if (($# > 0)); then
        usage_error 'this script takes no positional arguments'
    fi
    [[ -n $OUT ]] || usage_error 'output file name must not be empty'

    check_deps
    choose_parser
    load_ignore_lists
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/aur-diff.XXXXXX") || die 'mktemp failed'
    body="$tmp/body"
    : >"$body"

    printf 'Checking for pending AUR updates...\n'

    # 1) installed foreign packages ------------------------------------------
    while read -r name ver; do
        [[ -n ${name:-} ]] || continue
        installed[$name]=$ver
        names+=("$name")
    done < <(pacman -Qm 2>/dev/null || true)

    # 2) current AUR versions -------------------------------------------------
    if ((${#names[@]} > 0)); then
        printf '  querying the AUR for %d foreign package(s)...\n' "${#names[@]}"
        rpc_out=$(rpc_query "${names[@]}") || die 'AUR RPC query failed'
        while IFS=$'\t' read -r n ver pb; do
            [[ -n ${n:-} ]] || continue
            remote[$n]=$ver
            base[$n]=$pb
        done <<<"$rpc_out"
    fi

    # 3) which ones are pending? ----------------------------------------------
    for n in "${names[@]}"; do
        if [[ -z ${remote[$n]:-} ]]; then
            local_only+=("$n")
        elif (( $(vercmp "${installed[$n]}" "${remote[$n]}") < 0 )); then
            pending+=("$n")
        fi
    done

    # split pending updates into actionable ones and held-back (IgnorePkg) ones
    local -a actionable=() heldback=() audit=()
    for n in "${pending[@]}"; do
        if is_ignored "$n"; then
            heldback+=("$n")
        else
            actionable+=("$n")
        fi
    done
    if ((INCLUDE_IGNORED)); then
        audit=("${pending[@]}")
    else
        audit=("${actionable[@]}")
    fi

    if ((${#pending[@]} > 0)); then
        printf '  %d pending AUR update(s) — %d actionable, %d held back via IgnorePkg\n' \
            "${#pending[@]}" "${#actionable[@]}" "${#heldback[@]}"
        for n in "${audit[@]}"; do
            printf '    %s %s -> %s\n' "$n" "${installed[$n]}" "${remote[$n]}"
        done
    fi

    # 4) assemble the output ---------------------------------------------------
    {
        printf '# aur.diff — diffs of pending AUR package updates\n'
        printf '# generated %s by %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')" "$PROGNAME"
        printf '# foreign packages: %d checked, %d found in the AUR, %d local-only (skipped)\n' \
            "${#names[@]}" "${#remote[@]}" "${#local_only[@]}"
        if ((${#local_only[@]} > 0)); then
            printf '# local-only (not in the AUR): %s\n' "${local_only[*]}"
        fi
        printf '# pending AUR updates: %d (%d actionable, %d held back via IgnorePkg)\n' \
            "${#pending[@]}" "${#actionable[@]}" "${#heldback[@]}"
        if ((${#heldback[@]} > 0)); then
            if ((INCLUDE_IGNORED)); then
                printf '# held-back (IgnorePkg) updates are INCLUDED in this audit (--include-ignored)\n'
            else
                printf '# held back via IgnorePkg — intentionally not updated, NOT audited\n'
                printf '# (rerun with --include-ignored to audit them anyway):\n'
                for n in "${heldback[@]}"; do
                    printf '#   %-38s %s -> %s\n' "$n" "${installed[$n]}" "${remote[$n]}"
                done
            fi
        fi
        if ((${#audit[@]} == 0)); then
            printf '\n# No actionable AUR updates — nothing to review.\n'
        else
            printf '\n# Overview:\n'
            for n in "${audit[@]}"; do
                if is_ignored "$n"; then
                    printf '#   %-40s %s -> %s   [held back]\n' \
                        "$n" "${installed[$n]}" "${remote[$n]}"
                else
                    printf '#   %-40s %s -> %s\n' "$n" "${installed[$n]}" "${remote[$n]}"
                fi
            done
        fi
    } >>"$body"

    # group the audited packages by AUR base (split packages share one build)
    local b groups_count=0 igflag
    local -A seen_base=() base_groups=()
    local -a bases=()
    for n in "${audit[@]}"; do
        b=${base[$n]}
        if [[ -z ${seen_base[$b]:-} ]]; then
            seen_base[$b]=1
            bases+=("$b")
        fi
        if [[ -n ${base_groups[$b]:-} ]]; then
            base_groups[$b]+=$'\n'
        fi
        if is_ignored "$n"; then
            igflag='held'
        else
            igflag=''
        fi
        base_groups[$b]+="$n"$'\t'"${installed[$n]}"$'\t'"${remote[$n]}"$'\t'"$igflag"
    done

    for b in "${bases[@]}"; do
        groups_count=$(grep -c . <<<"${base_groups[$b]}")
        printf '  diffing %s (%d pending package(s))...\n' "$b" "$groups_count"
        if ! emit_base_section "$b" "${base_groups[$b]}" >>"$body"; then
            printf '%s: warning: could not fully process the AUR base %s\n' "$PROGNAME" "$b" >&2
            failed=$((failed + 1))
        fi
    done

    # 5) publish — the output file is always overwritten -------------------------
    if ! cat "$body" >"$OUT" 2>/dev/null; then
        die "cannot write to output file: $OUT"
    fi

    if ((failed > 0)); then
        printf '%s: diffs for %d of the pending update(s) could not be produced — %s may be incomplete\n' \
            "$PROGNAME" "$failed" "$OUT" >&2
        exit 1
    elif ((${#audit[@]} > 0)); then
        printf '%d pending AUR update(s) audited — diffs written to %s\n' "${#audit[@]}" "$OUT"
        exit 3
    elif ((${#heldback[@]} > 0)); then
        printf 'No actionable AUR updates — %d update(s) held back via IgnorePkg (noted in %s).\n' \
            "${#heldback[@]}" "$OUT"
        exit 0
    else
        printf 'No pending AUR updates — %s (re)written with a note.\n' "$OUT"
        exit 0
    fi
}

trap 'if [[ -n ${tmp:-} ]]; then rm -rf "$tmp"; fi' EXIT
trap 'exit 130' INT TERM

main "$@"