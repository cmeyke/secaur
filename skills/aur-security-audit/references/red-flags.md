# Red-flag catalog for AUR update diffs

Apply per section of `aur.diff` (or per reconstructed diff). Severity →
default verdict: any Critical → BLOCK · High → BLOCK unless the package's
nature clearly justifies it (then REVIEW) · Medium → REVIEW · Low → note
under the verdict. "Normal" rows never block an update on their own.

## 1. Version sanity (pkgver / pkgrel / epoch)

Normal: pkgver bumped to the next upstream release, pkgrel reset to `1`,
PKGBUILD and .SRCINFO agree with each other.

| Signal | Severity | Why |
|---|---|---|
| New pkgver does not exist upstream (check the `url` domain / release page) | Critical | Fabricated versions can point anywhere |
| pkgver drops and `epoch =` is added | High | Epoch forces "newer" over a higher number; can mask a downgrade to a vulnerable release |
| `-bin` package: pkgver unchanged, pkgrel bump, binary source checksum changed | Critical | Same-named, different binary |
| Version far beyond upstream (`9.9.9`, `9999`) | High | Classic takeover pattern |
| Version-scheme change (v-prefix, date-based) with upstream matching | Low | Cosmetic |

## 2. Sources (`source =`, `source_x86_64 =`, `git+…`)

Normal: same host and path with the new version spliced in; source set
otherwise unchanged.

| Signal | Severity | Why |
|---|---|---|
| New download domain: unknown hosts, file lockers (mega.nz, dropbox…), URL shorteners, web-archive links | Critical | Supply-chain swap |
| Typosquat of a well-known host (`github`→`githuhb`, `dl.google`→lookalike), punycode | Critical | |
| Bare IP or plain `http://` binary sources (Critical if combined with SKIP checksums) | Medium | Integrity still checked by checksums; privacy/reputation issue |
| URL version does not match the new pkgver | High | Repackaged or renamed artifact |
| Pinned source (tag/commit) → moving branch/HEAD | Medium | Build no longer reproducible |
| New source files added, especially scripts or prebuilt blobs | Medium–High | Fetch and audit each one |

## 3. Checksums (`sha256sums` / `sha512sums` / `md5sums`)

Normal: exactly the changed sources' checksum lines change, matching the
new upstream tarballs.

| Signal | Severity | Why |
|---|---|---|
| `SKIP` on a tarball or binary (normal only for git/VCS sources) | Critical | Content not verified |
| Checksum algorithm downgrade, or lines removed | High | |
| Checksums changed for a source whose URL did not change | High | Content silently replaced |
| `-bin`: binary checksums changed without a pkgver change | Critical | See §1 |

## 4. Depends / makedepends / checkdepends / options / arch

Normal: dependency bumps consistent with the new version.

| Signal | Severity | Why |
|---|---|---|
| `sudo` or privilege helpers added to depends/makedepends | Medium | Escalation surface at build time |
| Fetchers (`curl`, `wget`, `git`) newly in makedepends without a legitimate new fetch | Medium | Correlate with §5 |
| Security/crypto libraries dropped from depends | Medium | |
| `!check`/`!strip` newly set where previously enabled | Low | Reduced assurance |
| `arch` churn unrelated to the version | Low | |

## 5. PKGBUILD logic (prepare / build / check / package)

Read the full hunks. Normal: build-flag tweaks, new patches applied to the
declared sources, cosmetic refactors.

| Signal | Severity | Why |
|---|---|---|
| Network fetch outside declared sources: `curl … \| bash`, `wget -qO- … \| sh`, pip/curl in prepare()/build() | Critical | Arbitrary code at build time |
| Exfiltration: `curl -d @…`/`-T …`, `nc host port < file`, `> /dev/tcp/host/port`, ssh/scp out, upload of dotfiles, keys, history | Critical | |
| Decode/exec: `base64 -d … \| sh`, `eval "$(...)"`, hex/base64 blobs, string-massaging into commands | Critical | |
| `chmod` setuid/setgid (`u+s`, `4755`, `g+s`) in package() — unless the package is legitimately a suid helper installed from a declared source | High | |
| Writes outside `$pkgdir`: `$HOME`, `~/.ssh`, `/etc`, autostart, crontab, shell rc files | Critical | |
| Built artifacts replaced by downloaded prebuilt files not in `source` | Critical | |
| Post-download mutation of checksum-verified binaries in package() | High | |

## 6. `.install` and other stat-only files

The corpus lists these only in the `--stat`. Fetch the current copy
(`https://aur.archlinux.org/cgit/aur.git/plain/<file>?h=<base>`) and diff
against the baseline (`git diff <sha1>..HEAD -- <file>`) when changed.

| Signal | Severity | Why |
|---|---|---|
| post_install/post_upgrade editing system files, enabling services or timers, adding udev rules | High | Runs as root at install time |
| post_install adding autostart entries or shell-rc lines | Critical | Persistence |
| Standard post_install upkeep (`update-desktop-database`, icon cache, ldconfig notes) | Normal | |

## 7. Commit log, metadata, AUR context

- Bump commits authored by someone other than the package's usual
  committer → Medium; confirm against maintainer/adoption status.
- Rapid revert/re-bump churn, message-less bumps → Medium.
- Orphaned (`Maintainer: null`) + recent adoption + immediate source
  changes → High.
- Brand-new or zero-vote package with heavy shell logic → Medium context.
- AUR comments flagging the current update → investigate before verdict.
- `LastModified` minutes before the audit with sweeping changes → Medium.

## 8. Repository (non-AUR) updates (repo.diff)

Repo packages are built and signed by repo packagers — a much higher
baseline trust than AUR: metadata comes from signed sync dbs, PKGBUILD
diffs from the official Arch packaging repositories. Audit focus shifts to
packaging changes and repo-side anomalies:

| Signal | Severity | Why |
|---|---|---|
| `install script (upstream PKGBUILD install=)` gains a script or the script changed | High | Runs as root at install time; read the PKGBUILD diff around it |
| Metadata `Depends On` gains fetchers/privilege tools (curl, wget, sudo) | Medium | Correlate with the PKGBUILD diff |
| `Packager` changed to an unknown identity | High | Build origin changed |
| Package arrives from a different repository than usual | Medium | Repo move; verify the `Repository` field against the distro's layout |
| Upstream PKGBUILD diff shows any §1–§7 red flag | per §1–§7 | The same rules apply to upstream recipes |
| Rebuild-only update (empty PKGBUILD diff, pkgrel renumbered by the distro) | Normal | Common for repo rebuilds (CachyOS); the metadata diff still applies |
| `# NOTE: no upstream PKGBUILD` (repo-specific package) | Info | Audit the metadata; the distro's own sources are the origin |
| sha256 missing from the sync db | Low | Unusual on healthy repos |
| Locally-NEWER-than-repo packages are absent from the corpus | — | By design (pacman would not downgrade them) |

Verdict semantics are unchanged; the higher baseline trust means SAFE
verdicts are common and REVIEW/BLOCK require concrete evidence.

## Verdict derivation

- Any Critical finding → **BLOCK**.
- Any High finding without a legitimate, checkable justification →
  **BLOCK**; with one → **REVIEW**.
- Only Medium/Low findings → **REVIEW** with notes.
- Everything within "Normal" rows → **SAFE** (still summarize what changed).