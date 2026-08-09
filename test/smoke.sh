#!/usr/bin/env bash
# End-to-end smoke test: run entrypoint.sh with a fake `git clone` (local
# fixture instead of SSH) and dry_run=true; assert pruning, pkgrel edit and
# version-suffixed staging all land in the AUR clone. No network, no SSH key.
set -euo pipefail
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
THIS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# --- fixtures ------------------------------------------------------------------
# AUR-side repo: old pkgver, old pkgrel, one stale asset (odm-bin-1.2.0.1).
git -C "$ROOT" init -q -b master aur
( cd "$ROOT/aur" && git config user.email t@t && git config user.name t \
  && printf 'pkgver=1.2.0\npkgrel=2\n' > PKGBUILD && echo x > odm-bin-1.2.0.1 \
  && git add -A && git commit -qm init )

# Source side (the "workspace" of the caller step).
mkdir -p "$ROOT/work" "$ROOT/docs"
( cd "$ROOT/work" \
  && printf 'pkgver=1.3.0\npkgrel=1\n' > PKGBUILD && echo x > .SRCINFO )
echo man > "$ROOT/docs/odm.1"   # referenced as ../docs/odm.1 from $ROOT/work

# --- fake git: only a clone into the fixture; everything else stays real ---
# The fixture is copied BEFORE entrypoint runs (its EXIT trap wipes the temp
# dir it clones into), so the copy is our "remote" the clone comes from.
mkdir -p "$ROOT/fakebin"
cp -a "$ROOT/aur" "$ROOT/remote"
cat >"$ROOT/fakebin/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == clone ]]; then
  rm -rf "\${@: -1}"
  cp -a "$ROOT/remote" "\${@: -1}"
else
  exec /usr/bin/git "\$@"
fi
EOF
chmod +x "$ROOT/fakebin/git"

echo "--- running entrypoint (dry-run) ---"
# The entrypoint's `git status --short` in dry-run is the observable truth of
# what got staged (its clone dir is wiped by the EXIT trap afterwards).
( cd "$ROOT/work" && PATH="$ROOT/fakebin:$PATH" \
  GITHUB_OUTPUT="$ROOT/out" \
  INPUT_PACKAGE_NAME=odm-bin INPUT_SSH_KEY=dummy INPUT_SSH_HOST=localhost \
  INPUT_GIT_USERNAME=t INPUT_GIT_EMAIL=t@t INPUT_VERSION=1.3.0 \
  INPUT_FILES='PKGBUILD,.SRCINFO,man:../docs/odm.1' \
  INPUT_RM_PATTERNS='odm-bin-*.1' INPUT_PKGREL_MODE=auto INPUT_DRY_RUN=true \
  bash "$THIS_DIR/../entrypoint.sh" > "$ROOT/run.log" 2>&1 )
cat "$ROOT/run.log"

echo "--- asserting (from entrypoint output) ---"
fail() { echo "FAIL: $1"; exit 1; }
grep -q '^committed=true' "$ROOT/out" || fail "committed=true (would publish)"
grep -q 'A  odm-1.3.0.1' "$ROOT/run.log" || fail "version-suffixed asset staged (A odm-1.3.0.1)"
grep -q 'R  odm-bin-1.2.0.1' "$ROOT/run.log" || fail "stale asset pruned (R odm-bin-1.2.0.1)"
grep -q '^M  PKGBUILD' "$ROOT/run.log" || fail "PKGBUILD modified (pkgrel) staged"
grep -q 'pkgrel: 2 -> 3 (mode auto)' "$ROOT/run.log" || fail "pkgrel auto bump output"
grep -q 'dry-run: staged but not committed' "$ROOT/run.log" || fail "dry-run announced"
echo "smoke test passed"