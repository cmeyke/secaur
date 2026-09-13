# aur-diff.sh

Check for pending AUR updates — and save their diffs for review, by humans
or by an LLM.

`aur-diff.sh` reports which installed foreign (AUR) packages have updates
pending and writes a unified diff of the build files (`PKGBUILD` and
`.SRCINFO`) that each pending update would introduce into `./aur.diff`.
The output file is always overwritten, so it always reflects the most recent
check — ideal for reviewing what an AUR upgrade would *actually change*
before you run it.

`aur.diff` is also a ready-made corpus for a model-assisted security audit:
the bundled [`aur-security-audit`](skills/aur-security-audit/SKILL.md) agent
skill teaches an LLM the complete workflow — regenerate the corpus, audit
every pending update against its red-flag catalog, verify findings against
the AUR and upstream, and deliver a per-package SAFE / REVIEW / BLOCK
verdict report. Copy `skills/aur-security-audit/` into your agent's skill
directory (e.g. `~/.claude/skills/` or `~/.agents/skills/`), then simply ask
your model to *audit the pending AUR updates* — see
[Agent skill](#agent-skill) below.

## Usage

```sh
./aur-diff.sh [OPTIONS]
```

| Option                   | Description                                        |
|--------------------------|----------------------------------------------------|
| `-o, --output FILE`      | Write the diffs to `FILE` (default: `./aur.diff`)  |
| `--include-ignored`      | Also audit updates held back via `IgnorePkg`       |
| `-h, --help`             | Show help and exit                                 |

### Exit status

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| `0`  | No actionable AUR updates are pending (none at all, or all held back via `IgnorePkg`) |
| `3`  | Auditable AUR updates are pending; their diffs were written        |
| `1`  | Error — output may be incomplete; see stderr and notes in the file |
| `2`  | Usage error                                                         |

The distinct exit code for "updates pending" makes the script easy to use
from cron or other scripts:

```sh
./aur-diff.sh || rc=$?
case ${rc:-0} in
    0) echo "AUR is up to date (or every pending update is held back)." ;;
    3) echo "AUR updates pending — review aur.diff." ;;
    *) echo "aur-diff.sh failed ($rc)." ;;
esac
```

## How it works

1. `pacman -Qm` lists the installed foreign packages with their versions.
2. Current AUR versions are fetched from the official AUR RPC v5 API in
   batched queries (50 names per request).
3. A package is **pending** when `vercmp <installed> <remote>` is negative —
   the same notion of "pending" as `yay -Qua` / `auracle outdated`. No AUR
   helper is required.
4. Pending packages are grouped by AUR base (split packages share one
   build). For every base its AUR git repository is cloned into a temporary
   directory, the commit matching the *installed* version is located in the
   git history, and everything from that commit up to `HEAD` is saved: the
   upstream commit log, a `--stat` overview of all changed files, and a full
   unified diff of `PKGBUILD` and `.SRCINFO`.
5. If the installed version is not found in the history (typical for `-git`
   packages whose `pkgver` comes from a `pkgver()` function, or versions
   older than the last 200 build-file commits), the complete current
   `PKGBUILD` is written instead, with an explanatory note.
6. Updates held back via `IgnorePkg` (from `pacman.conf` — read with
   `pacman-conf` when available so `Include=` files are resolved —,
   `paru.conf`, or yay's `config.json`; glob patterns supported) would be
   "pending" forever: they are summarized in the header but not audited, and
   exit `0` is returned when they are the only pending updates.
   `--include-ignored` audits them anyway, marking their sections.

The result is a review document: everything you are about to accept when you
build the update.

## Example output

Trimmed from a real run — the eight pending updates below are held back via
`IgnorePkg`, so they are summarized instead of re-audited on every run:

```
# aur.diff — diffs of pending AUR package updates
# generated 2026-09-13 08:26 UTC by aur-diff.sh
# foreign packages: 63 checked, 62 found in the AUR, 1 local-only (skipped)
# pending AUR updates: 8 (0 actionable, 8 held back via IgnorePkg)
# held back via IgnorePkg — intentionally not updated, NOT audited
# (rerun with --include-ignored to audit them anyway):
#   ttf-ms-win11                             10.0.26200.7462-1 -> 10.0.26200.9168-3
#   ttf-ms-win11-japanese                    10.0.26200.7462-1 -> 10.0.26200.9168-3
#   ...

# No actionable AUR updates — nothing to review.
```

When updates are audited (actionable, or with `--include-ignored`), one
section per AUR base follows:

```
# ------------------------------------------------------------------------
# ttf-ms-win11 — AUR base with 8 pending package(s):
#   ttf-ms-win11          10.0.26200.7462-1 -> 10.0.26200.9168-3
#   ...
# Changes from the installed version (10.0.26200.7462-1 at 27ab873) to the pending version (10.0.26200.9168-3 at 730194d):

# upstream commits:
#   730194d 2026-08-26 bump pkgrel
#   88596ec 2026-08-26 Revert "Include missing Windows 11 fonts"
#   ...

# all files changed (sources, install scripts, patches, ...):
#    .SRCINFO | 94 ++++++++++++++++++++++++++++++++--------------------------------
#    PKGBUILD | 94 ++++++++++++++++++++++++++++++++--------------------------------
#    2 files changed, 94 insertions(+), 94 deletions(-)

diff --git a/PKGBUILD b/PKGBUILD
--- a/PKGBUILD
+++ b/PKGBUILD
@@ -43,8 +43,8 @@
 pkgbase=ttf-ms-win11
-pkgver=10.0.26200.7462
-pkgrel=1
+pkgver=10.0.26200.9168
+pkgrel=3
```

## Notes & limitations

- **Read-only.** The AUR is only queried; nothing is installed, built or
  modified on this system.
- **Overwrite semantics.** `aur.diff` is always overwritten. On a failed run
  the file is replaced with an `# ERROR` note, so a stale diff is never
  mistaken for fresh results.
- **Devel packages.** Like any version-based checker, `-git`/`-hg`-style
  packages with a `pkgver()` function can appear perpetually pending; their
  sections then contain the full current `PKGBUILD` for a full review.
- **Ignore-aware.** Updates held back via `IgnorePkg` (`/etc/pacman.conf`,
  `paru.conf`, or yay's `config.json`; glob patterns supported; `pacman-conf`
  resolves `Include=` files) are summarized in the header but not audited —
  they would be "pending" forever otherwise. `--include-ignored` audits them
  anyway and marks their sections as held back.
- **Epochs and split packages** are handled: `epoch:pkgver-pkgrel` versions
  match their commits, and split packages share one section per AUR base.
- **JSON parsing** uses `jq` or `python3` (an `awk` fallback exists). Force a
  specific parser with `AUR_DIFF_PARSER=jq|python3|awk`.
- `aur.diff` is generated output and therefore listed in `.gitignore`.

## Requirements

`bash`, `pacman` (provides `vercmp`), `curl`, `diff`, `git` (needed for real
diffs; without it only full `PKGBUILD`s are saved), plus `jq` or `python3`.

## Installation

Copy the script anywhere on your `PATH`, e.g.:

```sh
install -m 755 aur-diff.sh ~/.local/bin/aur-diff.sh
```

## Agent skill

`skills/aur-security-audit/` is a model skill that walks an agent through a
read-only security audit of all pending AUR updates: it regenerates
`aur.diff`, audits every section against
`skills/aur-security-audit/references/red-flags.md`, verifies findings
against the AUR and upstream, and produces a SAFE/REVIEW/BLOCK verdict
report per pending package.

## License

[MIT](LICENSE) © Carsten Meyke