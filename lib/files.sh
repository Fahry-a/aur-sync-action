#!/usr/bin/env bash
# files/paths helpers — pure functions. Import via `source`.

# Parses INPUT_FILES/INPUT_RM_PATTERNS into a bash array (comma-separated).
#   parse_csv <input> <varname>  -> fills <varname> with trimmed entries
#
# Portability + safety notes: macOS runners ship /bin/bash 3.2 (no namerefs),
# so the caller's array is filled via `read -a "$var"` — a dynamic NAME is
# fine there because read never re-parses VALUES as shell. No eval anywhere:
# inputs are workflow strings, not trusted code.
parse_csv() {
  local input="$1" var="$2" e out=""
  local -a tmp=()
  IFS=',' read -r -a tmp <<<"$input"
  for e in "${tmp[@]}"; do
    e="${e// /}"
    [[ -n "$e" ]] && out+="$e"$'\n'
  done
  IFS=',' read -r -a "$var" <<<"${out%$'\n'}"
}

# Splits a files entry into name/path ("name:path" renames; path alone keeps basename).
#   split_entry <entry> <name_var> <path_var>
#
# Assignments go through `printf -v` (bash >= 3.1): values land verbatim in
# the caller's variables with no eval and no quoting to break. History: this
# used to be eval-based — `local name` once shadowed an output variable
# literally called "name", and single-quote wrapping broke on entries
# containing a quote character.
split_entry() {
  local entry="$1" _name=""
  if [[ "$entry" == *:* ]]; then
    _name="${entry%%:*}"
    entry="${entry#*:}"
  fi
  printf -v "$2" '%s' "$_name"
  printf -v "$3" '%s' "$entry"
}

# Inserts "-<version>" before the extension; PKGBUILD/.SRCINFO keep bare names.
#   version_suffix <dest> <version>
version_suffix() {
  local dest="$1" ver="$2"
  case "$dest" in
    PKGBUILD | .SRCINFO) echo "$dest" ;;
    *) echo "$dest" | sed -E "s/(\.[^.]+)$/-${ver}\1/" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # self-test
  set -euo pipefail
  echo "parse_csv:"
  a=()
  parse_csv " PKGBUILD ,x:../docs/odm.1,,foo ," a
  [[ "${#a[@]}" == 3 ]] && [[ "${a[0]}" == "PKGBUILD" ]] && [[ "${a[1]}" == "x:../docs/odm.1" ]]
  echo "  ok"

  echo "split_entry:"
  n= p=
  split_entry "man:../docs/odm.1" n p
  [[ "$n" == "man" ]] && [[ "$p" == "../docs/odm.1" ]]
  split_entry "PKGBUILD" n p
  [[ "$n" == "" ]] && [[ "$p" == "PKGBUILD" ]]
  split_entry "weird'name:../d.1" n p # quote-bearing input stays inert data
  [[ "$n" == "weird'name" ]] && [[ "$p" == "../d.1" ]]
  echo "  ok"

  echo "version_suffix:"
  [[ "$(version_suffix PKGBUILD 1.2.0)" == "PKGBUILD" ]]
  [[ "$(version_suffix .SRCINFO 1.2.0)" == ".SRCINFO" ]]
  [[ "$(version_suffix odm.1 1.2.0)" == "odm-1.2.0.1" ]]
  [[ "$(version_suffix file.tar.zst 1.2.0)" == "file.tar-1.2.0.zst" ]]
  [[ "$(version_suffix LICENSE 1.2.0)" == "LICENSE" ]]    # no ext -> left bare
  echo "  ok"
  echo "files self-test passed"
fi