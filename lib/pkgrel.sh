#!/usr/bin/env bash
# pkgrel helpers — pure functions, no side effects. Import via `source`.

# Reads a PKGBUILD variable, stripping quotes/parens and trailing CR.
#   pkgval <file> <var>   -> e.g. pkgval PKGBUILD pkgver -> 1.2.0 ('' if absent)
pkgval() {
  local f="$1" k="$2"
  grep -oP "^$k=\K.*" "$f" 2>/dev/null | sed 's/#.*//' | tr -d "'\"() \t" | tr -d '\r' | tail -n1
}

# Computes the new pkgrel. $1 mode, followed by current values:
#   $2 up_ver  $3 up_rel  $4 lo_ver  $5 lo_rel   ('' = absent)
# Prints the new value; exits 1 when the mode says leave it alone.
pkgrel_new() {
  local mode="$1" up_ver="$2" up_rel="$3" lo_ver="$4" lo_rel="$5"
  case "$mode" in
    reset) echo 1 ;;
    bump)
      [[ -n "$up_rel" ]] || return 1          # nothing to bump against
      echo $((up_rel + 1))
      ;;
    auto)
      if [[ -n "$up_ver" && "$up_ver" != "$lo_ver" ]]; then
        echo 1                                # new upstream version -> reset
      elif [[ -n "$up_rel" ]]; then
        echo $((up_rel + 1))                  # same version -> re-publish, bump
      else
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

# Reads values and applies the mode by editing the LOCAL pkgbuild (lo_file).
# Upstream values (up_file) are the fresh AUR clone. Prints what happened;
# exits 1 when the mode left the file unchanged (never a fatal error).
pkgrel_apply() {
  local mode="$1" up_file="$2" lo_file="$3"
  local up_ver up_rel lo_ver lo_rel new
  up_ver="$(pkgval "$up_file" pkgver)"
  up_rel="$(pkgval "$up_file" pkgrel)"
  lo_ver="$(pkgval "$lo_file" pkgver)"
  lo_rel="$(pkgval "$lo_file" pkgrel)"
  new="$(pkgrel_new "$mode" "$up_ver" "$up_rel" "$lo_ver" "$lo_rel")" || return 1
  if [[ "$new" != "$lo_rel" ]]; then
    sed -i "s/^pkgrel=.*/pkgrel=${new}/" "$lo_file"
    echo "pkgrel: ${lo_rel:-none} -> ${new} (mode $mode)"
  else
    echo "pkgrel: keeping ${lo_rel:-none} (mode $mode)"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # self-test
  set -euo pipefail
  echo "pkgval strips quotes/parens/CR:"
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  printf "pkgver='1.2.0'\r\npkgrel=(3)\r\n" >"$tmp"
  [[ "$(pkgval "$tmp" pkgver)" == "1.2.0" ]] || { echo "FAIL pkgver"; exit 1; }
  [[ "$(pkgval "$tmp" pkgrel)" == "3" ]] || { echo "FAIL pkgrel"; exit 1; }
  echo "  ok"

  echo "pkgval strips inline comments:"
  printf "pkgver=1.3.0 # latest stable\npkgrel=2 # bumped\n" >"$tmp"
  [[ "$(pkgval "$tmp" pkgver)" == "1.3.0" ]] || { echo "FAIL pkgver inline comment"; exit 1; }
  [[ "$(pkgval "$tmp" pkgrel)" == "2" ]] || { echo "FAIL pkgrel inline comment"; exit 1; }
  echo "  ok"

  echo "pkgrel_new rules:"
  [[ "$(pkgrel_new reset x 5 1 2)" == "1" ]]
  [[ "$(pkgrel_new bump 1.2.0 3 1.2.0 1)" == "4" ]]
  [[ "$(pkgrel_new auto 1.2.0 3 1.3.0 1)" == "1" ]]   # differ -> reset
  [[ "$(pkgrel_new auto 1.2.0 3 1.2.0 1)" == "4" ]]   # same -> bump
  pkgrel_new bump 1.2.0 "" 1.2.0 1 && { echo "FAIL bump-empty-up"; exit 1; }
  [[ "$(pkgrel_new auto "" "" 1.2.0 1)" == "" ]]      # nothing comparable
  echo "  ok"

  echo "missing var is empty:"
  printf 'pkgver=1.2.0\n' >"$tmp"
  [[ -z "$(pkgval "$tmp" pkgrel)" ]] || { echo "FAIL missing"; exit 1; }
  echo "  ok"
  echo "pkgrel self-test passed"
fi