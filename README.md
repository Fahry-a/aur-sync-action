# AUR Sync — GitHub Action

Publish `PKGBUILD` + assets to an [AUR](https://aur.archlinux.org) package
with **stale-version pruning**, as one atomic commit — no window where the
AUR repo is missing its sources.

Replaces hand-rolled sync scripts with a reusable, self-contained action.

## Usage

```yaml
- uses: Fahry-a/aur-sync-action@v1
  with:
    package_name: odm-bin
    ssh_key: ${{ secrets.AUR_SSH_PRIVATE_KEY }}
    git_username: ${{ secrets.AUR_USERNAME }}
    git_email: ${{ secrets.AUR_EMAIL }}
    version: "1.2.0"
    files: >-
      PKGBUILD,
      .SRCINFO,
      man:../docs/odm.1,
      conf:../configs/odm.conf.example,
      service:../packaging/odm.service,
      license:../LICENSE
    rm_patterns: >-
      odm-bin-*.1,
      odm-bin-*.conf.example,
      odm-bin-*.service,
      odm-bin-*.LICENSE
```

Run from a step whose working directory contains the sources (usually
`packaging/` or after a build step). Glob paths are relative to that
directory.

## Inputs

| Input            | Required | Default             | Description |
|------------------|----------|---------------------|-------------|
| `package_name`   | ✓        | —                   | AUR package name (matches the remote repo, e.g. `odm-bin`) |
| `ssh_key`        | ✓        | —                   | SSH private key with AUR push access (e.g. `secrets.AUR_SSH_PRIVATE_KEY`) |
| `git_username`   | ✓        | —                   | Commit author name |
| `git_email`      | ✓        | —                   | Commit author email |
| `files`          | ✓        | —                   | Comma-separated sources (see below) |
| `version`        | —        | `""`                | Version string. When set, every published file becomes `<name>-<version><ext>` |
| `rm_patterns`    | —        | `""`                | Comma-separated globs pruned before publishing (stale assets), relative to the AUR repo root |
| `ssh_host`       | —        | `aur.archlinux.org` | AUR SSH host (override for mirrors/testing) |
| `commit_message` | —        | `chore(aur): update to v{version}` | Commit message; `{version}` and `{pkgname}` are substituted |
| `dry_run`        | —        | `false`             | Clone + prune + stage without commit/push (CI dry-check) |
| `pkgrel_mode`    | —        | `none`              | How to handle `pkgrel` in the published `PKGBUILD` (see below) |

## Outputs

| Output      | Description |
|-------------|-------------|
| `committed` | `true` when a commit was pushed (or staged in dry-run); `false` when nothing changed |

## `files` syntax

Comma-separated. Each entry is:
- a **path** (relative to the working directory) — published under its basename, or with `name:` prefix:
  - `"PKGBUILD"` → published as `PKGBUILD`
  - `"man:../docs/odm.1"` → published as `odm.1` (or `odm-<version>.1` when `version` is set)
- a **glob** (e.g. `dist/*.tar.zst`) — every match is published under its basename (version-suffixed when `version` is set).

With `version` set, the version is inserted **before the extension**:
`odm.1` + version `1.2.0` → `odm-1.2.0.1`; `file.tar.zst` + `1.2.0` → `file.tar-1.2.0.zst`.

## `rm_patterns` syntax

Comma-separated globs evaluated in the AUR repo **after** a fresh clone, so
they prune the previous version's assets before the new set lands. Patterns
may contain `{version}` (replaced with the current version — mostly useful
for exact-version pruning); typically you prune by wildcard instead:

```
rm_patterns: "odm-bin-*.1,odm-bin-*.conf.example,odm-bin-*.service"
```

Unmatched patterns are harmless (`git rm --ignore-unmatch`).

## `pkgrel_mode`

AUR packages carry two version fields in `PKGBUILD`: `pkgver` (upstream
version, e.g. `1.2.0`) and `pkgrel` (rebuild counter for the same upstream
version — `1`, `2`, …). The rules:

| Situation            | `pkgver` | `pkgrel` |
|----------------------|----------|----------|
| New upstream release | bumped   | **reset to 1** |
| Re-publish same version (packaging fix) | same | **bump +1** (so AUR notices) |

`pkgrel_mode` automates the `pkgrel` half:

| Mode    | Behaviour |
|---------|-----------|
| `none`  | Leave the local PKGBUILD untouched (dumb sync) |
| `reset` | Set `pkgrel=1` — use in a release workflow when `pkgver` was just bumped |
| `bump`  | Read `pkgrel` from the current upstream AUR clone, set local = upstream + 1 |
| `auto`  | Compare upstream `pkgver` vs local: differ → `reset`, same → `bump` |

Requires `PKGBUILD` (plain path entry) in `files`. The upstream values are
read from the fresh clone *before* pruning, so they reflect the live AUR
even when this push replaces it.

```yaml
# Release workflow — always reset
pkgrel_mode: reset

# Re-publish workflow — bump if upstream is behind
pkgrel_mode: auto
```

## Typical workflow (Odm-style release)

`version` is optional — supply it when your assets carry a version suffix,
omit it for static-only packages (just `PKGBUILD` + `.SRCINFO`).

```yaml
name: Publish AUR
on:
  release:
    types: [published]

jobs:
  aur:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Prepare assets (pkbuild, sourceinfo…)
        working-directory: packaging
        run: | ... # produce PKGBUILD, .SRCINFO, versioned assets
      - name: Publish AUR
        uses: Fahry-a/aur-sync-action@v1
        with:
          package_name: odm-bin
          ssh_key: ${{ secrets.AUR_SSH_PRIVATE_KEY }}
          git_username: ${{ secrets.AUR_USERNAME }}
          git_email: ${{ secrets.AUR_EMAIL }}
          version: ${{ github.ref_name }}
          # ...
```

## Typical workflow (Odm-style release)

`version` is optional — supply it when your assets carry a version suffix,
omit it for static-only packages (just `PKGBUILD` + `.SRCINFO`).

```yaml
name: Publish AUR
on:
  release:
    types: [published]

jobs:
  aur:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Prepare assets (pkbuild, sourceinfo…)
        working-directory: packaging
        run: | ... # produce PKGBUILD, .SRCINFO, versioned assets
      - name: Publish AUR
        uses: Fahry-a/aur-sync-action@v1
        with:
          package_name: odm-bin
          ssh_key: ${{ secrets.AUR_SSH_PRIVATE_KEY }}
          git_username: ${{ secrets.AUR_USERNAME }}
          git_email: ${{ secrets.AUR_EMAIL }}
          version: ${{ github.ref_name }}
          # ...
```

## Usage examples

### 1. Release of a versioned package (reset pkgrel)

```yaml
- uses: Fahry-a/aur-sync-action@v1
  with:
    package_name: odm-bin
    ssh_key: ${{ secrets.AUR_SSH_PRIVATE_KEY }}
    git_username: ${{ secrets.AUR_USERNAME }}
    git_email: ${{ secrets.AUR_EMAIL }}
    version: 1.2.0
    pkgrel_mode: reset            # new release — always pkgrel=1
    files: |-
      PKGBUILD,
      .SRCINFO,
      man:docs/odm.1,
      conf:configs/odm.conf.example,
      service:service/odm.service,
      license:LICENSE
    rm_patterns: |-
      odm-bin-*.1,
      odm-bin-*.conf.example,
      odm-bin-*.service,
      odm-bin-*.LICENSE
```

Upstream AUR has `pkgrel=3` from an earlier re-publish; this push publishes
`pkgver=1.2.0, pkgrel=1` (reset).

### 2. Re-publish the same version (auto bump pkgrel)

```yaml
with:
  package_name: odm-bin
  version: 1.2.0
  pkgrel_mode: auto               # pkgver same → bump; differ → reset
  files: "PKGBUILD,.SRCINFO"
```

Upstream has `pkgver=1.2.0, pkgrel=2`; local PKGBUILD says `pkgver=1.2.0,
pkgrel=1` → action sets `pkgrel=3` and publishes the fix. AUR users get the
rebuilt package.

### 3. Static-only package (no version, no assets)

```yaml
with:
  package_name: my-config
  ssh_key: ${{ secrets.AUR_SSH_PRIVATE_KEY }}
  git_username: ${{ secrets.AUR_USERNAME }}
  git_email: ${{ secrets.AUR_EMAIL }}
  files: "PKGBUILD,.SRCINFO"
  rm_patterns: ""       # nothing to prune
  pkgrel_mode: bump     # re-release — upstream pkgrel + 1
```

No `version` → files keep their plain names (`PKGBUILD`, `.SRCINFO`).

### 4. Dry-run in CI (verify before publishing)

```yaml
- name: Verify AUR publish (no push)
  uses: Fahry-a/aur-sync-action@v1
  with:
    package_name: odm-bin
    ssh_key: ${{ secrets.AUR_SSH_PRIVATE_KEY }}
    git_username: ${{ secrets.AUR_USERNAME }}
    git_email: ${{ secrets.AUR_EMAIL }}
    version: 1.2.0
    files: "PKGBUILD,.SRCINFO"
    dry_run: "true"
```

Clones the AUR repo, applies pruning + pkgrel + staging — without committing
or pushing. The PR CI can assert `committed=true` (meaning "would publish").

## MIT — see [LICENSE](LICENSE).