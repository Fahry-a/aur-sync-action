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
SRC_DIR="$GITHUB_WORKSPACE"
if [[ -z "$SRC_DIR" ]]; then
  SRC_DIR="$(pwd)"
fi
SSH_HOST="${INPUT_SSH_HOST:-aur.archlinux.org}"

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

# Parse INPUT_FILES into two arrays. Each entry is "name:path" (rename) or
# "path". Glob entries expand in the working directory (GLOBIGNORE avoids
# literal-star leftovers).
declare -a SRC_PATHS=()
declare -a DEST_NAMES=() # empty = keep basename
IFS=',' read -r -a ENTRIES <<<"$INPUT_FILES"
for e in "${ENTRIES[@]}"; do
  e="${e// /}" # trim spaces around commas
  [[ -z "$e" ]] && continue
  name=""
  path="$e"
  if [[ "$e" == *:* ]]; then
    name="${e%%:*}"
    path="${e#*:}"
  fi
  SRC_PATHS+=("$path")
  DEST_NAMES+=("$name")
done

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
# mode: none | reset | bump | auto
#   none  — leave the local PKGBUILD untouched (dumb sync)
#   reset — set pkgrel=1 (a new upstream release)
#   bump  — set local pkgrel = upstream pkgrel + 1 (re-publish of a version
#           already on the AUR; namanya harus berubah biar AUR detect)
#   auto  — compare upstream pkgver vs local: differ → reset; same → bump
# The upstream values are read from the fresh clone BEFORE pruning, so they
# reflect the current live AUR state even when this push replaces it.
PKGREL_MODE="${INPUT_PKGREL_MODE:-none}"
LOCAL_PKGBUILD=""
for i in "${!SRC_PATHS[@]}"; do
  if [[ "${DEST_NAMES[$i]}" == "" && "$(basename "${SRC_PATHS[$i]}")" == "PKGBUILD" ]]; then
    LOCAL_PKGBUILD="${SRC_PATHS[$i]}"
    break
  fi
done
if [[ "$PKGREL_MODE" != "none" && -n "$LOCAL_PKGBUILD" ]]; then
  UP_VER=$(grep -oP '^pkgver=\K.*' "$AUR_DIR/PKGBUILD" 2>/dev/null || true)
  UP_REL=$(grep -oP '^pkgrel=\K.*' "$AUR_DIR/PKGBUILD" 2>/dev/null || true)
  LOCAL_VER=$(grep -oP '^pkgver=\K.*' "$LOCAL_PKGBUILD" 2>/dev/null || true)
  LOCAL_REL=$(grep -oP '^pkgrel=\K.*' "$LOCAL_PKGBUILD" 2>/dev/null || true)

  case "$PKGREL_MODE" in
    reset)
      NEW_REL=1
      ;;
    bump)
      NEW_REL=$((UP_REL + 1))
      ;;
    auto)
      if [[ -n "$UP_VER" && "$UP_VER" != "$LOCAL_VER" ]]; then
        NEW_REL=1
      else
        NEW_REL=$((UP_REL + 1))
      fi
      ;;
  esac
  if [[ -n "$NEW_REL" && "$NEW_REL" != "$LOCAL_REL" ]]; then
    sed -i "s/^pkgrel=.*/pkgrel=${NEW_REL}/" "$LOCAL_PKGBUILD"
    echo "pkgrel: ${LOCAL_REL:-none} -> ${NEW_REL} (mode $PKGREL_MODE)"
  else
    echo "pkgrel: keeping ${LOCAL_REL:-none} (mode $PKGREL_MODE)"
  fi
fi

# --- Prune stale assets ----------------------------------------------------
# Glob expansion happens in the AUR repo; GLOBIGNORE keeps unmatched patterns
# literal so git rm --ignore-unmatch stays quiet.
GLOBIGNORE=""
if [[ -n "${INPUT_RM_PATTERNS:-}" ]]; then
  IFS=',' read -r -a RMP <<<"$INPUT_RM_PATTERNS"
  for pat in "${RMP[@]}"; do
    pat="${pat// /}"
    [[ -z "$pat" ]] && continue
    # {version} placeholder in a pattern is replaced with the actual version
    # so "odm-bin-{version}.1" prunes exactly the old versions.
    pat="${pat//\{version\}/$VERSION}"
    git rm -q --ignore-unmatch "$pat" || true
  done
fi
# The old script also swept unversioned leaks (e.g. odm.service) — keep that
# as a documented opt-in pattern, not implicit behaviour.

# --- Copy files ------------------------------------------------------------
missing=0
# versionSuffix inserts "-<version>" before the extension of a destination
# name. PKGBUILD / .SRCINFO never get suffixed — they must stay bare for the
# AUR toolchain (and for pkgrel handling), even when version is set.
versionSuffix() {
  local dest="$1"
  case "$dest" in
    PKGBUILD | .SRCINFO) echo "$dest" ;;
    *) echo "$dest" | sed -E "s/(\.[^.]+)$/-${VERSION}\1/" ;;
  esac
}
for i in "${!SRC_PATHS[@]}"; do
  path="${SRC_PATHS[$i]}"
  name="${DEST_NAMES[$i]}"
  # Expand globs to real files.
  if [[ "$path" == *\** ]]; then
    GLOBIGNORE=""
    matches=( $path )
    if [[ ${#matches[@]} -eq 0 || ! -e "${matches[0]}" ]]; then
      echo "::error::glob matched nothing: $path" >&2
      missing=1
      continue
    fi
    for m in "${matches[@]}"; do
      dest="$(basename "$m")"
      if [[ -n "$VERSION" ]]; then
        dest="$(versionSuffix "$dest")"
      fi
      cp -v "$m" "./$dest"
    done
    continue
  fi
  if [[ ! -f "$path" ]]; then
    echo "::error::missing $path" >&2
    missing=1
    continue
  fi
  dest="$(basename "$path")"
  if [[ -n "$name" ]]; then
    dest="$name"
  fi
  if [[ -n "$VERSION" ]]; then
    dest="$(versionSuffix "$dest")"
  fi
  cp -v "$path" "./$dest"
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
  echo "committed=false" >>"$GITHUB_OUTPUT"
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
