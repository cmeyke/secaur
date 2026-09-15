---
name: aur-security-audit
description: "Security audit of all pending Arch Linux package updates — AUR and repository. Use when: the user asks to audit, review, vet, or safety-check pending AUR or repo updates; before running a pacman -Syu or paru upgrade; when asked to analyze aur.diff or repo.diff or the PKGBUILD diffs of pending updates; or when the user mentions pending updates together with security, safety, malware, or supply-chain concerns. Regenerates both corpora (aur-diff.sh -> aur.diff for AUR packages, repo-diff.sh -> repo.diff for repository packages; manual fallbacks included), audits every pending update against a red-flag catalog, verifies findings against the AUR, the packaging repositories and upstream, and delivers a per-package SAFE/REVIEW/BLOCK verdict report. The audit is read-only: never builds, executes, or installs anything."
---

# Pending-Update Security Audit (AUR + repository)

PKGBUILDs are arbitrary shell code executed at build time, and `-bin`
packages ship prebuilt binaries. A pending update — AUR or repository — is
code the user is about to run; the diff between the installed version and
the pending version is the exact attack surface. This skill audits every
pending update and reports verdicts. Never build, execute, or install
anything during the audit; the report recommends, the human decides. The
final `sudo`/`paru` step stays with the user — this audit is the preparation
for it.

## Inputs and assumptions

- An Arch(-based) machine with `pacman` (provides `vercmp`), `pacman-conf`,
  `curl`, `git`, `diff`, `bsdtar` available.
- `aur-diff.sh` produces the AUR corpus `./aur.diff`; `repo-diff.sh`
  produces the repository corpus `./repo.diff` (both in this repository).
  If a script is not available, use the fallback in Step 1 — the audit
  itself is unchanged.
- Deliver the report as markdown (in chat, or to a file such as
  `aur-audit-report.md` if the user asks for a file).

## Step 1 — Produce fresh corpora

Always generate the corpora yourself; never audit an `aur.diff` or
`repo.diff` whose header (`# generated <timestamp> UTC`) you cannot
attribute to a fresh run.

```sh
./aur-diff.sh          # -> aur.diff  (AUR updates)
./repo-diff.sh         # -> repo.diff (repository updates)
```

For both scripts:

- Exit `0` — nothing to audit from that side: no pending updates at all, or
  every pending update is held back via `IgnorePkg` (the header lists
  them). Report the held-back list as intentionally not updated.
- Exit `3` — auditable updates pending: the corpus was just (over)written;
  audit it.
- Exit `1` — the tool failed; the corpus then contains an `# ERROR` note.
  Do not audit stale data — rerun or fix first.
- `repo.diff`'s header records the sync mode: `fakeroot`
  (signature-verified pacman -Sy under fakeroot — the checkupdates
  technique), `download` (sync dbs fetched straight from the mirrors,
  audit-only), or `existing` (reused system dbs, staleness noted).

Held-back updates: packages in an `IgnorePkg` list (pacman.conf / paru.conf
/ yay config) are intentionally not updated — their "pending" status never
resolves, so neither script audits them by default. Run with
`--include-ignored` only when the user explicitly asks to audit held-back
updates too; such sections are marked `[held back: IgnorePkg]`.

Fallback without `aur-diff.sh` (reproduce its core):
1. Pending list: `pacman -Qm`; query the AUR in chunks of ~50 with
   `curl -G 'https://aur.archlinux.org/rpc/v5/info' --data-urlencode 'arg[]=<name>'`;
   a package is pending when `vercmp <installed> <remote>` is negative.
2. Per pending base: `git clone https://aur.archlinux.org/<PackageBase>.git`,
   find the newest commit whose `epoch:pkgver-pkgrel` (from its `.SRCINFO`)
   equals the installed version, then `git diff <commit>..HEAD --stat` and
   `git diff <commit>..HEAD -- PKGBUILD .SRCINFO`.

Fallback without `repo-diff.sh`: build a temporary dbpath with the local
db symlinked in (`ln -s /var/lib/pacman/local <tmp>/local`), fetch sync
dbs (`fakeroot pacman -Sy --disable-sandbox-filesystem --dbpath <tmp>` or
download `<repo>.db` from the mirrors listed by `pacman-conf --repo <r> Server`),
then `pacman -Qu --dbpath <tmp>`; compare `pacman -Qi` vs `pacman -Si`
metadata; upstream PKGBUILDs live at
`gitlab.archlinux.org/archlinux/packaging/packages/<pkgbase>` (tags
`<pkgver>-<pkgrel>`, sometimes epoch-prefixed; verify via `.SRCINFO`).

## Step 2 — Read the corpora

`aur.diff` layout:

- Header: counts (`N checked, M found in the AUR, K local-only`), the
  pending/actionable/held-back split, `# Overview` — one
  `name  old -> new` line per audited package — and, when updates are held
  back via `IgnorePkg`, a `# held back via IgnorePkg — … NOT audited` list
  (carry it into the report verbatim; those updates are intentionally not
  applied, no verdict needed).
- One section per pending AUR base:
  - `# <base> — AUR base with N pending package(s):` — split packages are
    grouped; audit once, one verdict covers all listed packages.
  - `# Changes from the installed version (<ver> at <sha1>) to the pending
    version (<ver> at <sha2>)` — the short hashes anchor the git history.
  - `# upstream commits:` — the commit log since the installed version.
  - `# all files changed`: a `--stat` of every changed file.
  - `# build-file diff`: full unified diffs of PKGBUILD and .SRCINFO.
  - or `# NOTE: none of the installed version(s) …` followed by the
    complete current PKGBUILD — the installed version is not in the AUR
    history (typical for `-git` packages); audit the whole file, not a diff.

Local-only packages (header, e.g. locally built or removed from the AUR)
are not update audits — but list them in the report: a vanished AUR
package may have been renamed, abandoned, or removed for cause.

`repo.diff` layout:

- Header: sync mode + freshness note, repositories, pending/actionable/
  held-back split, total download size, `# Overview`, and the same
  held-back semantics as `aur.diff`.
- One section per pending package:
  - `# <name> : <old> -> <new> [<repo>]` (+ `[held back: IgnorePkg]`).
  - `# metadata changes (installed vs pending sync db):` — only changed
    fields (Depends On, Optional Deps, Provides, Conflicts With, Replaces,
    Groups, Packager, Architecture, Installed Size); "all unchanged" is
    stated with the compared-fields list.
  - `# pending package: download <size>, sha256 <sum>` — from the sync db.
  - `# upstream PKGBUILD (archlinux/packaging/packages/<base>):` — the
    upstream `install=` values (old → new), optional
    `# (repo rebuilds normalized to the upstream tags: …)`, and a unified
    diff of the upstream PKGBUILD between the two versions; split packages
    share one PKGBUILD diff per pkgbase (later sections reference it).
  - or `# NOTE: no upstream PKGBUILD for …` — repo-specific package (e.g.
    CachyOS-only) or no matching tag; audit the metadata and say so.

## Step 3 — Audit every section (no sampling)

Every package in both `# Overview`s must appear in the report. For each
section, apply `references/red-flags.md` (open it now) part by part:

1. **Version sanity** — is the new version a real upstream release? An
   epoch addition masking a downgrade? A pkgrel-only bump on a `-bin`
   package with changed binary checksums?
2. **Sources** — every `-`/`+` `source =` line: same domain? URL version
   matches the new pkgver? Plain http, bare IPs, shorteners, lookalike
   domains, tag→branch switches, newly added files?
3. **Checksums** — changes confined to the changed sources? Any `SKIP` on
   non-VCS sources, empties, algorithm removals?
4. **Depends/options** — new `sudo`/fetchers/network tools, dropped crypto
   libraries, newly disabled checks. For repo sections also apply §8 of
   the reference (metadata red flags: new `install=` scripts, packager
   changes, repository moves).
5. **PKGBUILD logic** — read the full hunks of prepare()/build()/check()/
   package(): code execution, exfiltration, obfuscation, setuid, writes
   outside `$pkgdir`. Repo PKGBUILD diffs follow the same rules — they are
   the upstream recipes of the packages being updated.
6. **Stat-only files** (aur sections) — anything changed/added besides
   PKGBUILD/.SRCINFO (`.install`, `.sh`, `.patch`, units) is not diffed in
   the corpus. Fetch the current copy from
   `https://aur.archlinux.org/cgit/aur.git/plain/<file>?h=<base>` and, for
   changes, clone the base repo and `git diff <sha1>..HEAD -- <file>`
   (`sha1` from the section header).

Fast triage before deep reading (does not replace reading the hunks):

```sh
grep -nE 'curl|wget|http://|/dev/(tcp|udp)|base64|eval|chmod|sudo|\.install|SKIP' aur.diff repo.diff
```

Record every finding with evidence: `<file>:<line>` plus the offending
`-`/`+` lines quoted.

## Step 4 — Verify externally (anything not obviously SAFE)

- AUR metadata (orphaned? maintainer? votes? how recent?):
  `curl -G 'https://aur.archlinux.org/rpc/v5/info' --data-urlencode 'arg[]=<name>'`
  — `Maintainer: null` means orphaned; recent adoption plus source changes
  raises scrutiny.
- AUR comments (fastest early warning): fetch
  `https://aur.archlinux.org/packages/<name>`.
- Confirm the pending version exists upstream (follow `url` / the source
  domain) — a version upstream never released is fabricated.
- Commit authors: in a clone,
  `git log --format='%h %an %ae %s' <sha1>..HEAD` — bump commits by an
  author different from the package's history deserve scrutiny.
- For repo packages, the packaging repo's PKGBUILD history and the Arch
  news feed (`https://archlinux.org/news/`) are the equivalents; a repo
  update's trust baseline is the signed sync db — cite concrete evidence
  before challenging it.
- Web-search the package name and maintainer with "malware" or
  "compromised" when anything is off.

## Step 5 — Verdicts and report

Exactly one verdict per section (derivation rules at the end of the
reference):

- **SAFE** — only expected changes: pkgver/pkgrel bump, source URLs whose
  versions match, checksum updates for those same sources, trivia. For repo
  sections, rebuild-only updates (empty upstream PKGBUILD diff, pkgrel
  renumbered by the distro) are normally SAFE.
- **REVIEW** — plausible but needs human judgment: new `.install` hooks,
  plain-http sources, epoch masking, tag→branch source moves, orphan
  adoption plus source changes, unverifiable versions, repo metadata
  anomalies from §8 (new install script, packager change).
- **BLOCK** — credible malicious indicators: unknown or typosquat source
  domains, exec/exfiltration/obfuscation in build logic, setuid additions,
  `SKIP` checksums on binaries, same-pkgver repackaged `-bin` binaries.
  BLOCK means "do not update until a human verifies" — present evidence,
  not accusations.

Report shape:

```markdown
# Pending Updates Security Audit
<date> · <host> · corpora: aur.diff + repo.diff generated <ts> ·
N pending AUR packages in M bases · K pending repo packages

## Summary
| Package | Source | Installed → Pending | Verdict | Key finding |

## Findings
### <name> (<base> or <repo>)
- [SEVERITY] finding — evidence: <file>:NNN, `…`
- Checks: version ✓  sources ✓  checksums ✓  depends ✓  logic ✓  upstream ✓  metadata ✓
- Verdict: SAFE | REVIEW | BLOCK — recommended action

## Held-back (ignored) updates
## Local-only packages (AUR)
## Recommendation
```

## Validation before delivering

- Every package in both `# Overview`s appears in the report; counts match
  the headers, and held-back (IgnorePkg) updates are listed as held-back,
  not silently dropped.
- Every verdict cites findings; every finding cites evidence.
- Changed stat-only files were fetched and audited.
- Nothing was built, executed, or installed; the upgrade decision is the
  user's.

## Safety notes

- Read-only. Never run makepkg or any snippet from a PKGBUILD.
- Do not audit stale corpora — regenerate `aur.diff` / `repo.diff` if in
  doubt.
- A suspicious pattern is evidence for a verdict, not proof of malice;
  maintainers do odd-but-legitimate things. Quote the diff and let the
  human decide.
- Repo packages have a higher trust baseline (built and signed by repo
  packagers) — do not dilute BLOCK verdicts by applying AUR-level paranoia
  to routine repo rebuilds.