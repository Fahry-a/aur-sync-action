#!/usr/bin/env bash
# files/paths helpers — pure functions. Import via `source`.

# Parses INPUT_FILES/INPUT_RM_PATTERNS into a bash array (comma-separated).
#   parse_csv <input> <varname>  -> fills <varname> (a NAMEREF) with trimmed entries
parse_csv() {
  local input="$1" var="$2" e
  local -a tmp=()
  IFS=',' read -r -a tmp <<<"$input"
  local -n out="$var" # assignment writes straight through to the caller's array
  for e in "${tmp[@]}"; do
    e="${e// /}"
    [[ -n "$e" ]] && out+=("$e")
  done
}

# Splits a files entry into name/path ("name:path" renames; path alone keeps basename).
#   split_entry <entry> <name_var> <path_var>
#
# Outputs are bash NAMEREFS (>= 4.3). This replaced an eval-based version that
# had two defects: `local name` shadowed the caller's output variable when it
# was literally called "name" (silently dropping the rename), and the
# single-quote wrapping in `eval "$_pv='$_e'"` broke on values containing a
# quote character. Inputs are workflow strings, not trusted code — they must
# never be parsed back as shell, so there is no eval left on this path.
split_entry() {
  local entry="$1"
  local -n name_out="$2"
  local -n path_out="$3"
  name_out=""
  if [[ "$entry" == *:* ]]; then
    name_out="${entry%%:*}"
    entry="${entry#*:}"
  fi
  path_out="$entry"
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