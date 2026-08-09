#!/usr/bin/env bash
# AUR Sync action — publish PKGBUILD + assets to an AUR package with
# stale-version pruning, as one atomic commit (no window where the AUR repo
# is missing its sources).
#
# Inputs arrive as INPUT_* env vars (composite action convention):
#   INPUT_PACKAGE_NAME  required — AUR package name
#   INPUT_SSH_KEY       required — SSH private key with AUR push access
#   INPUT_GIT_USERNAME  required — commit author name
#   INPUT_GIT_EMAIL     required — commit author email
#   INPUT_VERSION       optional — version string; when set, published files
#                       get a -<version> suffix before their extension
#   INPUT_FILES         required — comma-separated sources; each is a path or
#                       glob relative to the working directory, optionally
#                       "name:path" to rename on the AUR side
#   INPUT_RM_PATTERNS   optional — comma-separated globs (relative to the AUR
#                       repo root) pruned before publishing
#   INPUT_SSH_HOST      optional — default aur.archlinux.org
#   INPUT_COMMIT_MESSAGE optional — {version}/{pkgname} placeholders
#   INPUT_DRY_RUN       optional — clone+prune+stage without commit/push
set -euo pipefail

PKGNAME="${INPUT_PACKAGE_NAME:?package_name input required}"
VERSION="${INPUT_VERSION:-}"
SSH_HOST="${INPUT_SSH_HOST:-aur.archlinux.org}"
WORKDIR="$(pwd)"

# --- Input validation ------------------------------------------------------
for v in INPUT_SSH_KEY INPUT_GIT_USERNAME INPUT_GIT_EMAIL; do
  if [[ -z "${!v:-}" ]]; then
    echo "::error::${v} is not set" >&2
    exit 1
  fi
done
if [[ -z "${INPUT_FILES:-}" ]]; then
  echo "::error::files input is required (comma-separated paths/globs)" >&2
  exit 1
fi

# --- Load helpers ----------------------------------------------------------
LIB="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/files.sh source=lib/pkgrel.sh
source "$LIB/files.sh"
source "$LIB/pkgrel.sh"

# --- Parse INPUT_FILES into two aligned arrays -----------------------------
# Each entry is "name:path" (rename) or "path". Glob entries expand later in
# the caller's working directory. No GLOBIGNORE — it silently re-enables
# dotglob, which would let a bare '*' prune dotfiles in the AUR repo; bash's
# default keeps unmatched globs literal, and --ignore-unmatch stays quiet.
declare -a SRC_PATHS=() DEST_NAMES=() # empty name = keep basename
{
  declare -a ENTRIES=()
  parse_csv "$INPUT_FILES" ENTRIES
  for e in "${ENTRIES[@]}"; do
    declare name="" path="$e"
    split_entry "$e" name path
    SRC_PATHS+=("$path")
    DEST_NAMES+=("$name")
  done
}

# --- SSH identity ----------------------------------------------------------
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
ssh-keyscan -t rsa,ecdsa,ed25519 "$SSH_HOST" >>"$HOME/.ssh/known_hosts" 2>/dev/null || true
umask 077
printf '%s\n' "$INPUT_SSH_KEY" >"$HOME/.ssh/aur_key"
chmod 600 "$HOME/.ssh/aur_key"
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/aur_key -o IdentitiesOnly=yes"

# --- Clone the AUR repo ----------------------------------------------------
AUR_DIR="$(mktemp -d)"
trap 'rm -rf "$AUR_DIR"' EXIT
git clone -q "ssh://aur@${SSH_HOST}/${PKGNAME}.git" "$AUR_DIR"

cd "$AUR_DIR"

# --- pkgrel handling (optional) --------------------------------------------
# mode: none | reset | bump | auto (rules in lib/pkgrel.sh).
# Upstream values are read from the fresh clone BEFORE pruning, so they
# reflect the current live AUR state even when this push replaces it.
# `pkgver`/`pkgrel` fields are untrusted input (a shell file) — read-only
# grep, never evaluated.
PKGREL_MODE="${INPUT_PKGREL_MODE:-none}"
LOCAL_PKGBUILD=""
for i in "${!SRC_PATHS[@]}"; do
  if [[ "${DEST_NAMES[$i]}" == "" && "$(basename "${SRC_PATHS[$i]}")" == "PKGBUILD" ]]; then
    LOCAL_PKGBUILD="${SRC_PATHS[$i]}"
    break
  fi
done
if [[ "$PKGREL_MODE" != "none" && -n "$LOCAL_PKGBUILD" ]]; then
  # Resolve the local PKGBUILD against the caller's working directory
  # (paths/globs are relative to the workspace, NOT to the AUR clone).
  resolved="$(cd "$WORKDIR" && ls ${LOCAL_PKGBUILD} 2>/dev/null | head -n1)"
  if [[ -n "$resolved" ]]; then
    # Upstream values come from the fresh clone (read before pruning), local
    # values from the file itself. "No change" is fine.
    pkgrel_apply "$PKGREL_MODE" "$AUR_DIR/PKGBUILD" "$resolved" || true
  fi
fi

# --- Prune stale assets ----------------------------------------------------
# Comma-separated globs evaluated in the AUR repo; {version} is substituted
# so "odm-bin-{version}.1" prunes exactly the old versions. Unmatched globs
# stay literal and are silently ignored (git rm --ignore-unmatch).
if [[ -n "${INPUT_RM_PATTERNS:-}" ]]; then
  declare -a RMP=()
  parse_csv "$INPUT_RM_PATTERNS" RMP
  for pat in "${RMP[@]}"; do
    pat="${pat//\{version\}/$VERSION}"
    git rm -q --ignore-unmatch "$pat" || true
  done
fi

# --- Copy files ------------------------------------------------------------
# `path`s are relative to the caller's working directory — but cwd is now
# the AUR clone, so sources are resolved against $WORKDIR before copying.
missing=0
for i in "${!SRC_PATHS[@]}"; do
  path="${SRC_PATHS[$i]}"
  name="${DEST_NAMES[$i]}"
  if [[ "$path" == *\** ]]; then
    matches=( "$WORKDIR"/$path )          # expand globs in the workspace
    if [[ ${#matches[@]} -eq 0 || ! -e "${matches[0]}" ]]; then
      echo "::error::glob matched nothing: $path" >&2
      missing=1
      continue
    fi
    for m in "${matches[@]}"; do
      dest="$(basename "$m")"
      if [[ -n "$VERSION" ]]; then
        dest="$(version_suffix "$dest" "$VERSION")"
      fi
      cp -v "$m" "./$dest"
    done
    continue
  fi
  src="$path"
  [[ "$src" != /* ]] && src="$WORKDIR/$src"
  if [[ ! -f "$src" ]]; then
    echo "::error::missing $path" >&2
    missing=1
    continue
  fi
  dest="$(basename "$src")"
  if [[ -n "$name" ]]; then
    dest="$name"
  fi
  if [[ -n "$VERSION" ]]; then
    dest="$(version_suffix "$dest" "$VERSION")"
  fi
  cp -v "$src" "./$dest"
done
if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

git add --all
if git diff --cached --quiet; then
  echo "No changes to publish"
  echo "committed=false" >>"$GITHUB_OUTPUT"
  exit 0
fi

if [[ "${INPUT_DRY_RUN:-false}" == "true" ]]; then
  echo "dry-run: staged but not committed"
  git status --short
  echo "committed=true" >>"$GITHUB_OUTPUT"   # would publish (changes staged)
  exit 0
fi

git config user.name "$INPUT_GIT_USERNAME"
git config user.email "$INPUT_GIT_EMAIL"
MSG="${INPUT_COMMIT_MESSAGE:-chore(aur): update to v{version}}"
MSG="${MSG//\{version\}/$VERSION}"
MSG="${MSG//\{pkgname\}/$PKGNAME}"
git commit -q -m "$MSG"
git push -q origin HEAD:master
echo "committed=true" >>"$GITHUB_OUTPUT"
echo "Published ${PKGNAME} ${VERSION} to ${SSH_HOST}"