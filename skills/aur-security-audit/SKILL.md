---
name: aur-security-audit
description: "Security audit of all pending Arch Linux AUR package updates. Use when: the user asks to audit, review, vet, or safety-check pending AUR updates; before running an AUR upgrade; when asked to analyze aur.diff or the PKGBUILD/.SRCINFO diffs of pending AUR updates; or when the user mentions AUR updates together with security, safety, malware, or supply-chain concerns. Regenerates the diff corpus with aur-diff.sh (manual fallback included), audits every pending update against a red-flag catalog, verifies findings against the AUR and upstream, and delivers a per-package SAFE/REVIEW/BLOCK verdict report. The audit is read-only: never builds, executes, or installs anything."
---

# AUR Pending-Update Security Audit

PKGBUILDs are arbitrary shell code executed at build time, and `-bin`
packages ship prebuilt binaries. An AUR update is code the user is about to
run — the diff between the installed version and the pending version is the
exact attack surface. This skill audits every pending AUR update and
reports verdicts. Never build, execute, or install anything during the
audit; the report recommends, the human decides.

## Inputs and assumptions

- An Arch(-based) machine with `pacman` (provides `vercmp`), `curl`, `git`,
  `diff` available.
- `aur-diff.sh` (this repository) produces the audit corpus `./aur.diff`.
  If it is not available, use the fallback in Step 1 — the audit itself is
  unchanged.
- Deliver the report as markdown (in chat, or to a file such as
  `aur-audit-report.md` if the user asks for a file).

## Step 1 — Produce a fresh corpus

Always generate the corpus yourself; never audit an `aur.diff` whose header
(`# generated <timestamp> UTC`) you cannot attribute to a fresh run.

```sh
./aur-diff.sh        # or: bash /path/to/secaur/aur-diff.sh
```

- Exit `0` — no pending updates: report "nothing to audit" and stop.
- Exit `3` — updates pending: `./aur.diff` was just (over)written; audit it.
- Exit `1` — the tool failed; `aur.diff` then contains an `# ERROR` note.
  Do not audit stale data — rerun or fix first.

Fallback without `aur-diff.sh` (reproduce its core):
1. Pending list: `pacman -Qm`; query the AUR in chunks of ~50 with
   `curl -G 'https://aur.archlinux.org/rpc/v5/info' --data-urlencode 'arg[]=<name>'`;
   a package is pending when `vercmp <installed> <remote>` is negative.
2. Per pending base: `git clone https://aur.archlinux.org/<PackageBase>.git`,
   find the newest commit whose `epoch:pkgver-pkgrel` (from its `.SRCINFO`)
   equals the installed version, then `git diff <commit>..HEAD --stat` and
   `git diff <commit>..HEAD -- PKGBUILD .SRCINFO`.

## Step 2 — Read the corpus

`aur.diff` layout:

- Header: counts (`N checked, M found in the AUR, K local-only`) and
  `# Overview` — one `name  old -> new` line per pending package.
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

## Step 3 — Audit every section (no sampling)

Every package in `# Overview` must appear in the report. For each section,
apply `references/red-flags.md` (open it now) part by part:

1. **Version sanity** — is the new version a real upstream release? An
   epoch addition masking a downgrade? A pkgrel-only bump on a `-bin`
   package with changed binary checksums?
2. **Sources** — every `-`/`+` `source =` line: same domain? URL version
   matches the new pkgver? Plain http, bare IPs, shorteners, lookalike
   domains, tag→branch switches, newly added files?
3. **Checksums** — changes confined to the changed sources? Any `SKIP` on
   non-VCS sources, empties, algorithm removals?
4. **Depends/options** — new `sudo`/fetchers/network tools, dropped crypto
   libraries, newly disabled checks.
5. **PKGBUILD logic** — read the full hunks of prepare()/build()/check()/
   package(): code execution, exfiltration, obfuscation, setuid, writes
   outside `$pkgdir`.
6. **Stat-only files** — anything changed/added besides PKGBUILD/.SRCINFO
   (`.install`, `.sh`, `.patch`, units) is not diffed in the corpus. Fetch
   the current copy from
   `https://aur.archlinux.org/cgit/aur.git/plain/<file>?h=<base>` and, for
   changes, clone the base repo and `git diff <sha1>..HEAD -- <file>`
   (`sha1` from the section header).

Fast triage before deep reading (does not replace reading the hunks):

```sh
grep -nE 'curl|wget|http://|/dev/(tcp|udp)|base64|eval|chmod|sudo|\.install|SKIP' aur.diff
```

Record every finding with evidence: `aur.diff:<line>` plus the offending
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
- Web-search the package name and maintainer with "malware" or
  "compromised" when anything is off.

## Step 5 — Verdicts and report

Exactly one verdict per section (derivation rules at the end of the
reference):

- **SAFE** — only expected changes: pkgver/pkgrel bump, source URLs whose
  versions match, checksum updates for those same sources, trivia.
- **REVIEW** — plausible but needs human judgment: new `.install` hooks,
  plain-http sources, epoch masking, tag→branch source moves, orphan
  adoption plus source changes, unverifiable versions.
- **BLOCK** — credible malicious indicators: unknown or typosquat source
  domains, exec/exfiltration/obfuscation in build logic, setuid additions,
  `SKIP` checksums on binaries, same-pkgver repackaged `-bin` binaries.
  BLOCK means "do not update until a human verifies" — present evidence,
  not accusations.

Report shape:

```markdown
# AUR Pending Updates Security Audit
<date> · <host> · corpus: aur.diff generated <ts> · N pending packages in M bases

## Summary
| Package | Installed → Pending | Verdict | Key finding |

## Findings
### <name> (<base>)
- [SEVERITY] finding — evidence: aur.diff:NNN, `…`
- Checks: version ✓  sources ✓  checksums ✓  depends ✓  logic ✓  upstream ✓  AUR ✓
- Verdict: SAFE | REVIEW | BLOCK — recommended action

## Local-only packages
## Recommendation
```

## Validation before delivering

- Every package in `# Overview` appears in the report; counts match the
  header.
- Every verdict cites findings; every finding cites evidence.
- Changed stat-only files were fetched and audited.
- Nothing was built, executed, or installed; the upgrade decision is the
  user's.

## Safety notes

- Read-only. Never run makepkg or any snippet from a PKGBUILD.
- Do not audit stale corpora — regenerate `aur.diff` if in doubt.
- A suspicious pattern is evidence for a verdict, not proof of malice;
  maintainers do odd-but-legitimate things. Quote the diff and let the
  human decide.