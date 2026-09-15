#!/usr/bin/env bash
#
# repo-diff.sh — check for pending repository (non-AUR) updates; save diffs
#
# Companion to aur-diff.sh: audits the repository side of a system upgrade
# (`pacman -Syu` / the first half of `paru`). Reports which installed
# packages have updates pending in the configured binary repositories and
# writes a review corpus to ./repo.diff: per pending package a metadata
# diff (dependencies, provides, install-script presence, packager, groups,
# sizes) plus a unified diff of the upstream PKGBUILD between the old and
# the new version, fetched from the official Arch packaging repositories
# (gitlab.archlinux.org/archlinux/packaging/packages/<pkgbase>).
# The output file is always overwritten, so it always reflects the most
# recent check.
#
# Usage:
#   ./repo-diff.sh [OPTIONS]
#
#   -o, --output FILE      write the diffs to FILE (default: ./repo.diff)
#       --include-ignored  also audit updates held back via IgnorePkg
#   -h, --help             show this help and exit
#
# Exit status:
#   0   done — no actionable repo updates are pending (none at all, or all
#       held back via IgnorePkg; the output file contains a note)
#   3   done — auditable repo updates are pending, their diffs were written
#   1   error — output may be incomplete; see stderr and notes in the file
#
# How it works — everything runs unprivileged; nothing is installed:
#   1. Fresh sync databases are fetched into a temporary dbpath with the
#      local database symlinked in (the checkupdates technique). Methods
#      are tried in order (force with REPO_DIFF_SYNC=fakeroot|download|
#      existing|auto):
#        fakeroot   pacman -Sy under fakeroot — signature-verified dbs,
#                   exactly what checkupdates does; needs fakeroot, and
#                   fails in some sandboxed environments
#        download   fetch each <repo>.db straight from the configured
#                   mirrors with curl — works everywhere, but the dbs are
#                   NOT signature-verified (audit-only; pacman verifies
#                   again at real install time)
#        existing   reuse /var/lib/pacman/sync as-is (staleness is noted)
#   2. `pacman -Qu` against that dbpath lists the pending updates. Packages
#      that are locally NEWER than the repos (e.g. local rebuilds) are not
#      pending and are not listed — matching what pacman/paru would do.
#   3. Updates held back via IgnorePkg are summarized in the header but not
#      audited (same rules and config sources as aur-diff.sh).
#   4. Per pending package, metadata from the local db (pacman -Qi) is
#      compared with metadata from the sync db (pacman -Si); every changed
#      field is written as a diff block. Gained install scripts, new
#      dependencies, changed packagers and sizes stand out.
#   5. The upstream PKGBUILDs for the old and new versions are fetched from
#      the Arch packaging repository tags. Epoch prefixes are stripped and
#      rebuild pkgrel suffixes like "8.22.0-1.2" are normalized to "8.22.0-1";
#      the fetched PKGBUILD's own pkgver/pkgrel must match before it is
#      diffed (a wrong tag is never silently diffed). Split packages share
#      one PKGBUILD diff per pkgbase. Packages without an upstream repo
#      (e.g. CachyOS-specific ones) get a note instead.
#
# Requirements: bash, pacman, pacman-conf, curl, diff, bsdtar (libarchive).
#   IgnorePkg handling mirrors aur-diff.sh: /etc/pacman.conf via pacman-conf,
#   paru.conf, yay's config.json; glob patterns are supported;
#   AUR_DIFF_IGNORE_CONF overrides the config file list (colon-separated).
#   REPO_DIFF_LOCAL_DB overrides the local database path (default
#   /var/lib/pacman/local) — advanced/testing.

set -euo pipefail

readonly PROGNAME=$(basename "$0")
readonly LOCAL_DB_DEFAULT='/var/lib/pacman/local'
readonly SYNC_DB_SYSTEM='/var/lib/pacman/sync'
readonly GL_API='https://gitlab.archlinux.org/api/v4/projects'
readonly GL_PREFIX='archlinux%2Fpackaging%2Fpackages%2F'
readonly SLEEP_GITLAB=0.3      # politeness delay between GitLab fetches

readonly CURL_OPTS=(--silent --show-error --fail --location
                    --connect-timeout 15 --max-time 30 --retry 1)

readonly -a META_FIELDS=(
    'Depends On' 'Optional Deps' 'Provides' 'Conflicts With' 'Replaces'
    'Groups' 'Packager' 'Architecture' 'Installed Size'
)
# NOTE: install-script presence cannot be compared from the sync db —
# pacman >= 6.1 dropped scriptlets from sync databases. The upstream
# PKGBUILD's install= line is summarized in each section instead (and any
# change to it appears in the PKGBUILD diff itself).

OUT='repo.diff'
tmp=''
tmpdb=''
SYNC_MODE="${REPO_DIFF_SYNC:-auto}"
LOCAL_DB="${REPO_DIFF_LOCAL_DB:-$LOCAL_DB_DEFAULT}"
INCLUDE_IGNORED=0
SYNC_MODE_USED=''
SYNC_NOTE=''
declare -A IGNORE_SEEN=()      # IgnorePkg entries: exact names or glob patterns

# ----------------------------------------------------------------- helpers ---

usage() {
    cat <<EOF
repo-diff.sh — check for pending repository updates; save their diffs to a file

Usage: $PROGNAME [OPTIONS]

  -o, --output FILE      write the diffs to FILE (default: ./repo.diff)
      --include-ignored  also audit updates held back via IgnorePkg
  -h, --help             show this help and exit

Exit status:  0 no actionable pending repo updates (none, or all ignored)
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

# ------------------------------------------------------------ ignore lists ---
# Same rules as aur-diff.sh: updates for IgnorePkg packages are intentionally
# not applied, so they are summarized but not audited.

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

# --------------------------------------------------------------- sync dbs ----

sync_dbs_fakeroot() {
    if ! have fakeroot; then
        return 1
    fi
    fakeroot -- pacman -Sy --disable-sandbox-filesystem \
        --dbpath "$tmpdb" --logfile /dev/null >/dev/null 2>&1
}

sync_dbs_download() {
    local arch r srv url ok failed=0
    local -a repos servers
    mkdir -p "$tmpdb/sync"
    arch=$(pacman-conf Architecture 2>/dev/null | head -1)
    if [[ -z $arch || $arch == auto ]]; then
        arch=$(uname -m)
    fi
    mapfile -t repos < <(pacman-conf --repo-list 2>/dev/null)
    ((${#repos[@]} > 0)) || return 1
    for r in "${repos[@]}"; do
        ok=0
        mapfile -t servers < <(pacman-conf --repo "$r" Server 2>/dev/null)
        for srv in "${servers[@]}"; do
            [[ -n $srv ]] || continue
            url=${srv//\$repo/$r}
            url=${url//\$arch/$arch}
            if curl "${CURL_OPTS[@]}" -o "$tmpdb/sync/$r.db" "$url/$r.db" 2>/dev/null; then
                ok=1
                break
            fi
        done
        if (( ! ok )); then
            printf '%s: warning: could not download the %s sync db from any mirror\n' \
                "$PROGNAME" "$r" >&2
            failed=$((failed + 1))
        fi
    done
    ((failed == 0))
}

prepare_dbs() {
    local newest
    mkdir -p "$tmpdb"
    ln -s "$LOCAL_DB" "$tmpdb/local"
    case $SYNC_MODE in
        auto|fakeroot|download|existing) ;;
        *) die 'REPO_DIFF_SYNC must be one of: auto, fakeroot, download, existing' ;;
    esac
    if [[ $SYNC_MODE == auto || $SYNC_MODE == fakeroot ]]; then
        if sync_dbs_fakeroot; then
            SYNC_MODE_USED='fakeroot'
            SYNC_NOTE='sync dbs refreshed via pacman -Sy under fakeroot (signature-verified)'
            return 0
        fi
    fi
    if [[ $SYNC_MODE == auto || $SYNC_MODE == download ]]; then
        if sync_dbs_download; then
            SYNC_MODE_USED='download'
            SYNC_NOTE='sync dbs downloaded from mirrors (not signature-verified; audit-only — pacman verifies at install time)'
            return 0
        fi
    fi
    if [[ $SYNC_MODE == auto || $SYNC_MODE == existing ]]; then
        newest=$(ls -t "$SYNC_DB_SYSTEM"/*.db 2>/dev/null | head -1 || true)
        if [[ -n ${newest:-} ]]; then
            ln -s "$SYNC_DB_SYSTEM" "$tmpdb/sync"
            SYNC_MODE_USED='existing'
            SYNC_NOTE="reusing the existing sync dbs (newest dated $(date -r "$newest" '+%Y-%m-%d %H:%M')) — may be stale"
            return 0
        fi
    fi
    die "could not obtain sync databases (mode: $SYNC_MODE)"
}

# ------------------------------------------------------------ info parsing ---

# Parse `pacman -Qi`/`pacman -Si` output from stdin into "field<TAB>value"
# lines; indented continuation lines (multi-value fields) are joined.
info_tsv() {
    awk '
        function flush() { if (f != "") printf "%s\t%s\n", f, v }
        /^$/ { next }
        /^[[:space:]]/ {
            sub(/^[[:space:]]+/, "")
            if (v != "") v = v "  " $0
            next
        }
        index($0, " : ") > 0 {
            n = index($0, " : ")
            flush()
            f = substr($0, 1, n - 1)
            gsub(/[[:space:]]+$/, "", f)
            v = substr($0, n + 3)
        }
        END { flush() }
    '
}

# "4.9 MiB" -> bytes
size_to_bytes() {
    printf '%s' "$1" | awk '{
        v = $1 + 0
        u = $2
        m["B"] = 1; m["KiB"] = 1024; m["MiB"] = 1048576; m["GiB"] = 1073741824
        printf "%d", v * m[u]
    }'
}

bytes_human() { # bytes -> "12.3 MiB"
    awk -v b="$1" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ")
        for (i = 5; i >= 1; i--) {
            f = b / (1024 ^ (i - 1))
            if (f >= 1 || i == 1) { printf "%.1f %s", f, u[i]; exit }
        }
    }'
}

# A value from a package's sync-db desc (db entries are "<name>-<version>/desc").
# Prints empty when the field is absent.
sync_desc_value() { # $1 = repo, $2 = name, $3 = version, $4 = %TAG%
    local out
    out=$(bsdtar -xOf "$tmpdb/sync/$1.db" "$2-$3/desc" 2>/dev/null |
        awk -v t="$4" '$0 == t {getline; print; exit}')
    printf '%s' "${out:-}"
}

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

urlencode() { # minimal: the characters that appear in pkgbases and tags
    local s=$1
    s=${s//+/%2B}
    s=${s//:/%3A}
    s=${s// /%20}
    printf '%s' "$s"
}

# Fetch the upstream PKGBUILD of pkgbase at the given (epoch-stripped)
# package version. Tags are tried as "<pkgver>-<pkgrel>", then with the
# rebuild pkgrel suffix ("1.2" -> "1") removed. The fetched PKGBUILD's own
# pkgver/pkgrel must match the expectation. rc 0 + file on success.
fetch_pkgbuild() { # $1 = pkgbase, $2 = version, $3 = output file
    local pbase=$1 ver=$2 outfile=$3
    local epoch='' rest pkgver pkgrel cand tag rel fpkgver fpkgrel url
    if [[ $ver == *:* ]]; then
        epoch=${ver%%:*}
        rest=${ver#*:}
    else
        rest=$ver
    fi
    pkgrel=${rest#*-}
    pkgver=${rest%-*}
    [[ -n $pkgver && -n $pkgrel ]] || return 1
    # Tag formats in the Arch packaging repos vary: "<pkgver>-<pkgrel>" and,
    # for some packages with an epoch, "<epoch>-<pkgver>-<pkgrel>". Repo
    # rebuilds renumber the pkgrel (CachyOS uses "1.2" or bumps "1" to "2"),
    # so the parent pkgrel is tried as well. Each candidate is
    # "tag|expected-pkgrel"; the fetched PKGBUILD's own pkgver/pkgrel must
    # match before it is used. Prints the resolved tag on success.
    local -a cands=()
    cands+=("${pkgver}-${pkgrel}|${pkgrel}")
    if [[ $pkgrel == *.* ]]; then
        cands+=("${pkgver}-${pkgrel%%.*}|${pkgrel%%.*}")
    elif (( pkgrel > 1 )); then
        cands+=("${pkgver}-$((pkgrel - 1))|$((pkgrel - 1))")
    fi
    if [[ -n $epoch ]]; then
        cands+=("${epoch}-${pkgver}-${pkgrel}|${pkgrel}")
        if [[ $pkgrel == *.* ]]; then
            cands+=("${epoch}-${pkgver}-${pkgrel%%.*}|${pkgrel%%.*}")
        elif (( pkgrel > 1 )); then
            cands+=("${epoch}-${pkgver}-$((pkgrel - 1))|$((pkgrel - 1))")
        fi
    fi
    for cand in "${cands[@]}"; do
        tag=${cand%%|*}
        rel=${cand#*|}
        url="$GL_API/$GL_PREFIX$(urlencode "$pbase")/repository/files/PKGBUILD/raw?ref=$(urlencode "$tag")"
        if curl --silent --show-error --fail --location --connect-timeout 15 \
                --max-time 30 --retry 3 --retry-all-errors --retry-delay 2 \
                "$url" >"$outfile" 2>/dev/null && [[ -s $outfile ]]; then
            # Verify against .SRCINFO (always literal); some PKGBUILDs compute
            # pkgver (e.g. bash's "pkgver=${_basever}.${_patchlevel}"), so the
            # PKGBUILD fallback accepts a non-literal pkgver when the pkgrel
            # matches and no .SRCINFO is available.
            local srcinfo
            srcinfo=$(curl --silent --show-error --fail --location \
                    --connect-timeout 15 --max-time 30 \
                    "$GL_API/$GL_PREFIX$(urlencode "$pbase")/repository/files/.SRCINFO/raw?ref=$(urlencode "$tag")" \
                    2>/dev/null) || srcinfo=''
            if [[ -n $srcinfo ]]; then
                fpkgver=$(field_at "$srcinfo" pkgver)
                fpkgrel=$(field_at "$srcinfo" pkgrel)
            else
                fpkgver=$(field_at "$(<"$outfile")" pkgver)
                fpkgrel=$(field_at "$(<"$outfile")" pkgrel)
            fi
            if [[ $fpkgrel == "$rel" && ( $fpkgver == "$pkgver" || $fpkgver == *'$'* ) ]]; then
                sleep "$SLEEP_GITLAB"
                printf '%s\n' "$tag"
                return 0
            fi
        fi
        sleep "$SLEEP_GITLAB"
    done
    return 1
}

# ------------------------------------------------------- section emission ---

emit_repo_section() { # $1 = name, $2 = oldver, $3 = newver, $4 = held flag
    local name=$1 over=$2 nver=$3 held=${4:-}
    local old_tsv="$tmp/info/$name.old.tsv" new_tsv="$tmp/info/$name.new.tsv"
    local f o n repo dlsize sha base
    local -A OLD=() NEW=()

    if [[ ! -s $old_tsv || ! -s $new_tsv ]]; then
        printf '# ERROR: metadata for %s could not be read — section skipped\n' "$name"
        return 1
    fi

    while IFS=$'\t' read -r f o; do
        [[ -n ${f:-} ]] || continue
        OLD[$f]=$o
    done <"$old_tsv"
    while IFS=$'\t' read -r f o; do
        [[ -n ${f:-} ]] || continue
        NEW[$f]=$o
    done <"$new_tsv"

    repo=${NEW[Repository]:-unknown}
    dlsize=${NEW[Download Size]:-?}
    if [[ -s $tmp/info/$name.new.sha ]]; then
        sha=$(<"$tmp/info/$name.new.sha")
    else
        sha='not recorded in the sync db'
    fi
    base=$(sync_desc_value "$repo" "$name" "$nver" '%BASE%')
    if [[ -z $base ]]; then
        base=$name
    fi

    printf '\n'
    printf '# ------------------------------------------------------------------------\n'
    if [[ -n $held ]]; then
        printf '# %s : %s  ->  %s   [%s]   [held back: IgnorePkg]\n' "$name" "$over" "$nver" "$repo"
    else
        printf '# %s : %s  ->  %s   [%s]\n' "$name" "$over" "$nver" "$repo"
    fi
    printf '# ------------------------------------------------------------------------\n'

    # metadata diff (only changed fields are shown)
    printf '# metadata changes (installed vs pending sync db):\n'
    local changed=0
    for f in "${META_FIELDS[@]}"; do
        o=${OLD[$f]:-}
        n=${NEW[$f]:-}
        if [[ $f == 'Optional Deps' ]]; then
            o=${o// \[installed\]/}   # drop pacman's "[installed]" annotations
            n=${n// \[installed\]/}
        fi
        if [[ $f == 'Installed Size' ]]; then
            # compare numerically; display the original strings
            if [[ $(size_to_bytes "$o") -eq $(size_to_bytes "$n") ]]; then
                continue
            fi
        else
            if [[ $o == "$n" ]]; then
                continue
            fi
        fi
        changed=$((changed + 1))
        if (( ${#o} <= 60 && ${#n} <= 60 )); then
            printf '#   %s: %s -> %s\n' "$f" "$o" "$n"
        else
            printf '#   %s:\n#     - %s\n#     + %s\n' "$f" "$o" "$n"
        fi
    done
    if (( changed == 0 )); then
        printf '#   (compared: %s — all unchanged)\n' "${META_FIELDS[*]}"
    fi
    printf '# pending package: download %s, sha256 %s\n' "$dlsize" "$sha"

    # upstream PKGBUILD diff — one per pkgbase
    if [[ -n ${BASE_SEEN[$base]:-} ]]; then
        printf '# upstream PKGBUILD diff: see the %s section (same pkgbase %s)\n' \
            "${BASE_SEEN[$base]}" "$base"
        return 0
    fi
    BASE_SEEN[$base]=$name

    printf '# upstream PKGBUILD (archlinux/packaging/packages/%s):\n' "$base"
    local opb="$tmp/pb.old" npb="$tmp/pb.new" rc=0 otag ntag
    if ! otag=$(fetch_pkgbuild "$base" "$over" "$opb"); then
        printf '# NOTE: no upstream PKGBUILD for the installed version %s (repo-specific\n' "$over"
        printf '#       package such as a CachyOS one, a split pkgbase without its own repo,\n'
        printf '#       or no matching tag) — audit the metadata above and the built package.\n'
        return 0
    fi
    if ! ntag=$(fetch_pkgbuild "$base" "$nver" "$npb"); then
        printf '# NOTE: no upstream PKGBUILD for the pending version %s (repo-specific\n' "$nver"
        printf '#       package such as a CachyOS one, or no matching tag) — audit the\n'
        printf '#       metadata above and the built package.\n'
        return 0
    fi
    if [[ $otag != "$over" || $ntag != "$nver" ]]; then
        printf '# (repo rebuilds normalized to the upstream tags: %s -> %s)\n' "$otag" "$ntag"
    fi
    local oinst ninst
    oinst=$(field_at "$(<"$opb")" install)
    [[ -n $oinst ]] || oinst='none'
    ninst=$(field_at "$(<"$npb")" install)
    [[ -n $ninst ]] || ninst='none'
    printf '# install script (upstream PKGBUILD install=): %s -> %s\n' "$oinst" "$ninst"
    diff -u --label "PKGBUILD ($otag)" --label "PKGBUILD ($ntag)" "$opb" "$npb" >"$tmp/pb.diff" || rc=$?
    if ((rc > 1)); then
        printf '# ERROR: diff of the upstream PKGBUILDs failed\n'
        return 1
    fi
    if [[ ! -s $tmp/pb.diff ]]; then
        printf '# PKGBUILD unchanged between the two versions — rebuild/packaging-only update.\n'
    else
        cat "$tmp/pb.diff"
    fi
    return 0
}

# ------------------------------------------------------------------- main ----

main() {
    local n ov arrow nv extra
    local -a names=() oldvers=() newvers=() heldpacman=()
    local -A BASE_SEEN=()
    local body failed=0 i total_bytes=0

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

    local missing=()
    for n in pacman pacman-conf curl diff bsdtar; do
        have "$n" || missing+=("$n")
    done
    if ((${#missing[@]} > 0)); then
        die "missing required command(s): ${missing[*]}"
    fi
    load_ignore_lists
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/repo-diff.XXXXXX") || die 'mktemp failed'
    tmpdb="$tmp/db"
    body="$tmp/body"
    : >"$body"

    printf 'Checking for pending repository updates...\n'

    prepare_dbs
    printf '  sync databases ready (mode: %s)\n' "$SYNC_MODE_USED"

    # 1) pending updates ------------------------------------------------------
    local updates_out
    updates_out=$(LC_ALL=C pacman -Qu --color never --dbpath "$tmpdb" 2>/dev/null || true)
    while read -r n ov arrow nv extra; do
        [[ -n ${n:-} ]] || continue
        names+=("$n"); oldvers+=("$ov"); newvers+=("$nv")
        if [[ ${extra:-} == '[ignored]' ]]; then
            heldpacman+=("$n")
        fi
    done <<<"$updates_out"

    # 2) prefetch metadata, split actionable / held back -----------------------
    local -a actionable=() heldback=() audit_idx=()
    local -A held_map=()
    mkdir -p "$tmp/info"
    for n in "${heldpacman[@]}"; do
        held_map[$n]=1
    done
    for i in "${!names[@]}"; do
        n=${names[$i]}
        local repo
        LC_ALL=C pacman --dbpath "$tmpdb" -Qi "$n" 2>/dev/null | info_tsv >"$tmp/info/$n.old.tsv" || true
        LC_ALL=C pacman -Si --dbpath "$tmpdb" "$n" 2>/dev/null | info_tsv >"$tmp/info/$n.new.tsv" || true
        repo=$(awk -F'\t' '$1=="Repository"{print $2; exit}' "$tmp/info/$n.new.tsv")
        sync_desc_value "$repo" "$n" "${newvers[$i]}" '%SHA256SUM%' >"$tmp/info/$n.new.sha"
        total_bytes=$((total_bytes + $(size_to_bytes "$(awk -F'\t' '$1=="Download Size"{print $2; exit}' "$tmp/info/$n.new.tsv")")))
        if is_ignored "$n" || [[ -n ${held_map[$n]:-} ]]; then
            heldback+=("$i")
            if ((INCLUDE_IGNORED)); then
                audit_idx+=("$i")
            fi
        else
            actionable+=("$i")
            audit_idx+=("$i")
        fi
    done

    printf '  %d pending repo update(s) — %d actionable, %d held back via IgnorePkg\n' \
        "${#names[@]}" "${#actionable[@]}" "${#heldback[@]}"

    # 3) header ----------------------------------------------------------------
    {
        printf '# repo.diff — diffs of pending repository package updates\n'
        printf '# generated %s by %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')" "$PROGNAME"
        printf '# sync mode: %s — %s\n' "$SYNC_MODE_USED" "$SYNC_NOTE"
        printf '# repositories: %s\n' "$(pacman-conf --repo-list 2>/dev/null | tr '\n' ' ')"
        if ((${#names[@]} > 0)); then
            printf '# pending repo updates: %d (%d actionable, %d held back via IgnorePkg), total download %s\n' \
                "${#names[@]}" "${#actionable[@]}" "${#heldback[@]}" "$(bytes_human "$total_bytes")"
        else
            printf '# pending repo updates: 0\n'
        fi
        if ((${#heldback[@]} > 0)); then
            if ((INCLUDE_IGNORED)); then
                printf '# held-back (IgnorePkg) updates are INCLUDED in this audit (--include-ignored)\n'
            else
                printf '# held back via IgnorePkg — intentionally not updated, NOT audited\n'
                printf '# (rerun with --include-ignored to audit them anyway):\n'
                for i in "${heldback[@]}"; do
                    printf '#   %-38s %s -> %s\n' "${names[$i]}" "${oldvers[$i]}" "${newvers[$i]}"
                done
            fi
        fi
        if ((${#audit_idx[@]} == 0)); then
            printf '\n# No actionable repo updates — nothing to review.\n'
        else
            printf '\n# Overview:\n'
            for i in "${audit_idx[@]}"; do
                printf '#   %-38s %s -> %s\n' "${names[$i]}" "${oldvers[$i]}" "${newvers[$i]}"
            done
        fi
    } >>"$body"

    # 4) sections ----------------------------------------------------------------
    for i in "${audit_idx[@]}"; do
        n=${names[$i]}
        printf '  diffing %s (%s -> %s)...\n' "$n" "${oldvers[$i]}" "${newvers[$i]}"
        local heldflag=''
        if is_ignored "$n" || [[ -n ${held_map[$n]:-} ]]; then
            heldflag='held'
        fi
        if ! emit_repo_section "$n" "${oldvers[$i]}" "${newvers[$i]}" "$heldflag" >>"$body"; then
            printf '%s: warning: could not fully process %s\n' "$PROGNAME" "$n" >&2
            failed=$((failed + 1))
        fi
    done

    # 5) publish — the output file is always overwritten ---------------------------
    if ! cat "$body" >"$OUT" 2>/dev/null; then
        die "cannot write to output file: $OUT"
    fi

    if ((failed > 0)); then
        printf '%s: diffs for %d of the pending update(s) could not be produced — %s may be incomplete\n' \
            "$PROGNAME" "$failed" "$OUT" >&2
        exit 1
    elif ((${#audit_idx[@]} > 0)); then
        printf '%d pending repo update(s) audited — diffs written to %s\n' "${#audit_idx[@]}" "$OUT"
        exit 3
    elif ((${#heldback[@]} > 0)); then
        printf 'No actionable repo updates — %d update(s) held back via IgnorePkg (noted in %s).\n' \
            "${#heldback[@]}" "$OUT"
        exit 0
    else
        printf 'No pending repo updates — %s (re)written with a note.\n' "$OUT"
        exit 0
    fi
}

trap 'if [[ -n ${tmp:-} ]]; then rm -rf "$tmp"; fi' EXIT
trap 'exit 130' INT TERM

main "$@"