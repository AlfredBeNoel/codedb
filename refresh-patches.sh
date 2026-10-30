#!/usr/bin/env bash
# Regenerate patches/ from branch codedb-patched in the cache clone, after a conflict was fixed there.
set -euo pipefail

die() { printf 'refresh-patches: %s\n' "$*" >&2; exit 1; }
git() { command git "$@" 8>&- 9>&-; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
cache=${CODEDB_PATCHED_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/codedb-patched}
src=$cache/src

[ -d "$src/.git" ] || die "no clone at $src; run codedb-patched.sh --check --ref <tag> first"
exec 8>>"$here/.lock" 9>>"$cache/.lock"
python3 -I -c 'import fcntl
for fd in (8, 9): fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>/dev/null ||
  die "another codedb-patched.sh or refresh-patches.sh run uses $cache or $here; wait for it to finish"
[ ! -e "$here/.patches.old" ] ||
  die "an earlier refresh was interrupted. If patches/ is missing: mv $here/.patches.old $here/patches. Else: rm -rf $here/.patches.old"
git_dir=$(git -C "$src" rev-parse --absolute-git-dir)
[ ! -d "$git_dir/rebase-apply" ] || die "git am is still in progress in $src; finish it with git am --continue"
[ "$(git -C "$src" symbolic-ref -q --short HEAD)" = codedb-patched ] || die "$src is not on branch codedb-patched"
[ -z "$(git -C "$src" status --porcelain)" ] ||
  die "uncommitted changes in $src; commit them into the right patch (git commit --amend, or a fixup and rebase) first"
base=$(git -C "$src" rev-parse -q --verify refs/codedb-patched/base) || die "no base recorded; run codedb-patched.sh first"
[ -z "$(git -C "$src" rev-list --merges "$base..HEAD")" ] || die "the patch branch has merge commits; keep it linear"
count=$(git -C "$src" rev-list --count "$base..HEAD")
[ "$count" -gt 0 ] || die "no commits on top of the base"

new=$(mktemp -d "$here/.patches.new.XXXXXX")
trap 'rm -rf "$new"' EXIT
git -C "$src" format-patch -q --zero-commit --no-signature -o "$new" "$base..HEAD"
(cd "$new" && ls -- *.patch >series)
base_name=$(git -C "$src" describe --tags --exact-match "$base" 2>/dev/null || echo "$base")
printf '%s %s\n' "$base_name" "$base" >"$new/base"

mv "$here/patches" "$here/.patches.old"
mv "$new" "$here/patches" || { mv "$here/.patches.old" "$here/patches"; die "cannot publish the new patches"; }
rm -rf "$here/.patches.old"
trap - EXIT
# The branch now matches patches/, so codedb-patched.sh may reset it again.
git -C "$src" update-ref refs/codedb-patched/applied HEAD

echo "Regenerated $count patches against $base_name."
git -C "$here" status --short -- patches
echo "Next: review with git -C $here diff, run $here/codedb-patched.sh --ref $base_name, then commit."
