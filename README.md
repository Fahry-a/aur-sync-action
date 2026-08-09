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

## License

MIT — see [LICENSE](LICENSE).