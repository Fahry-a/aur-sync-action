#!/usr/bin/env bash
# files/paths helpers — pure functions. Import via `source`.

# Parses INPUT_FILES/INPUT_RM_PATTERNS into a bash array (comma-separated).
#   parse_csv <input> <varname>  -> fills <varname> with trimmed entries
parse_csv() {
  local input="$1" var="$2" e
  local -a tmp=()
  IFS=',' read -r -a tmp <<<"$input"
  for e in "${tmp[@]}"; do
    e="${e// /}"
    [[ -n "$e" ]] && eval "${var}+=(\"\$e\")"
  done
}

# Splits a files entry into name/path ("name:path" renames; path alone keeps basename).
#   split_entry <entry> <name_var> <path_var>
split_entry() {
  local e="$1" nv="$2" pv="$3"
  local name=""
  if [[ "$e" == *:* ]]; then
    name="${e%%:*}"
    e="${e#*:}"
  fi
  eval "$nv='$name'"
  eval "$pv='$e'"
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