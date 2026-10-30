#!/usr/bin/env bash
# Build codedb from an upstream release plus patches/series, test it, and install it.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: codedb-patched.sh [--ref <tag|commit|latest>] [--prefix <dir>] [--no-test] [--check]

  --ref <ref>     upstream tag, branch or commit (default: latest = the latest GitHub release)
  --prefix <dir>  install directory (default: $HOME/bin)
  --no-test       skip the unit tests (the smoke test still runs)
  --check         apply the patches and report per patch, then stop (no build, no install)

Environment:
  ZIG                   zig to build with (default: a zig on PATH with the version that
                        build.zig.zon asks for, else a signature-checked download)
  CODEDB_PATCHED_CACHE  cache directory (default: ${XDG_CACHE_HOME:-$HOME/.cache}/codedb-patched)
  CODEDB_UPSTREAM_REPO  upstream GitHub repo (default: justrach/codedb)
EOF
}

die() { printf 'codedb-patched: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*" >&2; }

ref=latest prefix=$HOME/bin run_tests=1 check_only=0
while [ $# -gt 0 ]; do
  case $1 in
    --ref) [ $# -ge 2 ] || die "--ref needs a value"; ref=$2; shift 2 ;;
    --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; prefix=$2; shift 2 ;;
    --no-test) run_tests=0; shift ;;
    --check) check_only=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
case $prefix in /*) ;; *) prefix=$PWD/$prefix ;; esac

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
patch_dir=$here/patches
cache=${CODEDB_PATCHED_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/codedb-patched}
upstream_repo=${CODEDB_UPSTREAM_REPO:-justrach/codedb}
# Zig's release signing key, as published on https://ziglang.org/download/
zig_pubkey=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U

for tool in git curl python3 tar; do
  command -v "$tool" >/dev/null || die "missing required tool: $tool"
done
[ -f "$patch_dir/series" ] || die "no patch series at $patch_dir/series"

# Children never inherit the lock fds, so a leftover process cannot keep the cache locked.
git() { command git "$@" 8>&- 9>&-; }
sha256_of() { python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
series_patches() { grep -v -e '^#' -e '^[[:space:]]*$' "$patch_dir/series"; }

mkdir -p "$cache"
cache=$(cd "$cache" && pwd -P)
case $cache/ in
  /tmp/* | /private/tmp/* | /var/* | /private/var/*)
    # codedb refuses project roots there, so the tests that index temp dirs inside the clone fail.
    [ "$run_tests" = 0 ] || [ "$check_only" = 1 ] || die "CODEDB_PATCHED_CACHE=$cache is under /tmp or /var; pick another directory" ;;
esac
# A short path: two shared-server tests put <src>/.zig-cache/tmp/<16>/run/<16>.sock in a 104-byte sockaddr.
src=$cache/src
if [ "$run_tests" = 1 ] && [ "$check_only" = 0 ] && [ "${#src}" -gt 45 ]; then
  die "the unit tests need the clone path $src to be at most 45 characters; set CODEDB_PATCHED_CACHE to a shorter directory"
fi
tmp_root= staged=
cleanup() {
  [ -z "$staged" ] || rm -f "$staged"
  [ -z "$tmp_root" ] || rm -rf "$tmp_root"
}
trap cleanup EXIT
# Kernel locks on the cache and on this checkout (whose patches/ refresh-patches.sh replaces);
# they drop when the script exits, also on kill -9.
exec 8>>"$here/.lock" 9>>"$cache/.lock"
python3 -I -c 'import fcntl
for fd in (8, 9): fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>/dev/null ||
  die "another codedb-patched.sh or refresh-patches.sh run uses $cache or $here"
# /tmp, not $TMPDIR: the test socket path must fit in 104 bytes.
tmp_root=$(mktemp -d /tmp/codedb-patched.XXXXXX)

# ── 1. Upstream checkout ──
upstream_url=https://github.com/$upstream_repo.git
if [ ! -d "$src/.git" ]; then
  log "cloning $upstream_url into $src"
  rm -rf "$src.partial"
  git clone -q "$upstream_url" "$src.partial"
  mv "$src.partial" "$src"
else
  [ "$(git -C "$src" remote get-url origin)" = "$upstream_url" ] ||
    die "the clone in $src tracks $(git -C "$src" remote get-url origin), not $upstream_url; use another CODEDB_PATCHED_CACHE"
  git_dir=$(git -C "$src" rev-parse --absolute-git-dir)
  for op in rebase-merge MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    [ ! -e "$git_dir/$op" ] || die "a git operation is in progress in $src ($op); finish or abort it, then run again"
  done
  if [ -d "$git_dir/rebase-apply" ]; then
    die "an earlier run stopped on a patch conflict in $src.
  Finish it: fix the files, git add them, git -C $src am --continue (until done), then run $here/refresh-patches.sh
  Or drop it: git -C $src am --abort
  Then run this script again."
  fi
  # Work the script did not make (a resolved conflict, an edited patch) lives only here until refresh.
  tip=$(git -C "$src" rev-parse -q --verify refs/heads/codedb-patched || true)
  applied=$(git -C "$src" rev-parse -q --verify refs/codedb-patched/applied || true)
  head_ref=$(git -C "$src" symbolic-ref -q HEAD || true)
  if [ -n "$(git -C "$src" status --porcelain)" ] ||
    { [ -n "$tip" ] && { [ "$tip" != "$applied" ] || [ "$head_ref" != refs/heads/codedb-patched ]; }; }; then
    die "$src has changes this script did not make (uncommitted edits, commits on codedb-patched, or a detached HEAD).
  Keep them: commit them on branch codedb-patched, then run $here/refresh-patches.sh
  Drop them: git -C $src checkout -q -f codedb-patched && git -C $src update-ref refs/codedb-patched/applied codedb-patched"
  fi
  log "fetching $upstream_url"
  git -C "$src" fetch -q --force --tags --prune --prune-tags origin
fi

if [ "$ref" = latest ]; then
  # The API, not a version sort: an old tag (v0.2.58181) sorts above newer releases.
  ref=$(curl -fsSL --retry 2 "https://api.github.com/repos/$upstream_repo/releases/latest" 2>/dev/null |
    python3 -I -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null) || ref=
  if [ -z "$ref" ] && command -v gh >/dev/null; then
    ref=$(gh release view -R "$upstream_repo" --json tagName -q .tagName 2>/dev/null) || ref=
  fi
  [ -n "$ref" ] || die "cannot resolve the latest release of $upstream_repo.
  Pick a tag from https://github.com/$upstream_repo/releases and pass --ref <tag>."
  log "latest release: $ref"
fi
case $ref in -* | '') die "invalid ref: '$ref'" ;; esac
sha=
for cand in "refs/tags/$ref" "refs/remotes/origin/$ref" "$ref"; do
  sha=$(git -C "$src" rev-parse -q --verify "$cand^{commit}" 2>/dev/null) && break || sha=
done
if [ -z "$sha" ] && git -C "$src" fetch -q origin "$ref" 2>/dev/null; then
  sha=$(git -C "$src" rev-parse -q --verify "FETCH_HEAD^{commit}") || sha=
fi
[ -n "$sha" ] || die "unknown upstream ref: $ref"

# ── 2. Apply the series ──
log "applying $(series_patches | wc -l | tr -d ' ') patches to $ref ($(git -C "$src" rev-parse --short "$sha"))"
git -C "$src" checkout -q -f -B codedb-patched "$sha"
git -C "$src" update-ref refs/codedb-patched/base "$sha"
git -C "$src" update-ref refs/codedb-patched/applied "$sha"
am() {
  git -C "$src" -c user.name=codedb-patched -c user.email=codedb-patched@localhost \
    -c commit.gpgSign=false -c core.hooksPath=/dev/null \
    am -q --3way --committer-date-is-author-date "$@"
}
conflict= remaining=()
while IFS= read -r p; do
  [ -f "$patch_dir/$p" ] || die "series lists a missing patch: $p"
  if [ -n "$conflict" ]; then
    remaining+=("$patch_dir/$p")
    printf '  %-64s not tried\n' "$p"
    continue
  fi
  if git -C "$src" apply --check "$patch_dir/$p" 2>/dev/null; then how=clean; else how=3-way; fi
  if am "$patch_dir/$p" >"$tmp_root/am.log" 2>&1; then
    git -C "$src" update-ref refs/codedb-patched/applied HEAD
    printf '  %-64s %s\n' "$p" "$how"
  else
    files=$(git -C "$src" diff --name-only --diff-filter=U | tr '\n' ' ')
    printf '  %-64s CONFLICT %s\n' "$p" "${files:-(see below)}"
    [ -n "$files" ] || sed 's/^/    /' "$tmp_root/am.log" >&2
    conflict=$p
    git -C "$src" am --abort
    remaining=("$patch_dir/$p")
  fi
done < <(series_patches)

if [ -n "$conflict" ]; then
  # Queue the rest behind the conflict, so `git am --continue` carries on through the series.
  am "${remaining[@]}" >/dev/null 2>&1 || true
  die "$conflict does not apply to $ref. The conflict is left in $src.
  To resolve: cd $src, fix the conflicted files, git add them, git am --continue
  (repeat until the series is done), then run $here/refresh-patches.sh.
  To give up: git -C $src am --abort"
fi
if [ "$check_only" = 1 ]; then
  log "all patches apply to $ref; the result is branch codedb-patched in $src"
  exit 0
fi

# ── 3. Zig ──
zig_want=$(sed -n 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$src/build.zig.zon")
[ -n "$zig_want" ] || die "no minimum_zig_version in $src/build.zig.zon"

fetch_zig() {
  local os arch name dl mirrors base ok=
  case $(uname -s) in Darwin) os=macos ;; Linux) os=linux ;; *) die "no Zig download for $(uname -s); set ZIG" ;; esac
  case $(uname -m) in arm64 | aarch64) arch=aarch64 ;; x86_64 | amd64) arch=x86_64 ;; *) die "no Zig download for $(uname -m); set ZIG" ;; esac
  name=zig-$arch-$os-$zig_want.tar.xz
  dl=$cache/zig/.download.$$
  rm -rf "$dl" && mkdir -p "$dl"
  # Community mirrors first in random order, as mlugg/setup-zig does; ziglang.org drops old dev builds.
  mirrors=$(curl -fsSL --max-time 20 https://ziglang.org/download/community-mirrors.txt 2>/dev/null |
    grep '^https://' | python3 -I -c 'import random,sys; m=sys.stdin.read().split(); random.shuffle(m); print(*m)') || mirrors=
  for base in $mirrors https://ziglang.org/builds "https://ziglang.org/download/$zig_want"; do
    curl -fsSL --max-time 600 -o "$dl/$name" "$base/$name?source=codedb-patched" 2>/dev/null &&
      curl -fsSL --max-time 30 -o "$dl/$name.minisig" "$base/$name.minisig?source=codedb-patched" 2>/dev/null || continue
    if python3 -I "$here/lib/minisign_verify.py" "$zig_pubkey" "$dl/$name" "$dl/$name.minisig" "$name"; then
      log "downloaded and verified $name from $base"
      ok=1
      break
    fi
    log "signature check failed for $base/$name; trying the next source"
  done
  if [ -z "$ok" ]; then
    rm -rf "$dl"
    die "cannot download a verified Zig $zig_want. Do it by hand:
  1. Download $name and $name.minisig from a mirror in https://ziglang.org/download/community-mirrors.txt
  2. Verify: minisign -Vm $name -P $zig_pubkey
  3. Unpack it and run again with ZIG=<unpacked dir>/zig"
  fi
  tar -xJf "$dl/$name" -C "$dl"
  [ -x "$dl/${name%.tar.xz}/zig" ] || die "unexpected layout in $name"
  rm -rf "${cache:?}/zig/$zig_want"
  mv "$dl/${name%.tar.xz}" "$cache/zig/$zig_want"
  rm -rf "$dl"
}

if [ -n "${ZIG:-}" ]; then
  zig=$(command -v "$ZIG") || die "ZIG=$ZIG is not an executable"
  have=$("$zig" version) || die "ZIG=$ZIG does not run"
  [ "$have" = "$zig_want" ] || log "warning: ZIG is $have; build.zig.zon asks for $zig_want"
elif command -v zig >/dev/null && [ "$(zig version 2>/dev/null)" = "$zig_want" ]; then
  zig=$(command -v zig)
else
  zig=$cache/zig/$zig_want/zig
  [ -x "$zig" ] && [ "$("$zig" version 2>/dev/null)" = "$zig_want" ] || fetch_zig
fi
zig_dir=$(cd "$(dirname "$zig")" && pwd -P)
zig=$zig_dir/$(basename "$zig")
# Some tests start `zig` from PATH.
export PATH="$zig_dir:$PATH"

# ── 4. Build, test, smoke ──
out=$cache/build
rm -rf "$out"
log "building with zig $("$zig" version)"
(cd "$src" && "$zig" build -Doptimize=ReleaseFast --prefix "$out" 8>&- 9>&-) || die "zig build failed"
bin=$out/bin/codedb
[ -x "$bin" ] || die "build produced no $bin"

if [ "$run_tests" = 1 ]; then
  log "running unit tests"
  zig_cache=$("$zig" env | sed -nE 's/.*"?global_cache_dir"?[[:space:]]*[=:][[:space:]]*"([^"]*)".*/\1/p')
  mkdir -p "$tmp_root/home" && mkdir -m 700 "$tmp_root/sock"
  test_log=$cache/last-test.log
  # Isolated HOME keeps the tests out of ~/.codedb; the shared zig cache avoids re-fetching deps.
  # CODEDB_* from the caller's shell (CODEDB_NO_TELEMETRY, CODEDB_MCP_SHARED, ...) change test results.
  (unset $(compgen -e | grep '^CODEDB_') && cd "$src" &&
    env HOME="$tmp_root/home" ZIG="$zig" ${zig_cache:+ZIG_GLOBAL_CACHE_DIR="$zig_cache"} \
      CODEDB_MCP_SOCKET_DIR="$tmp_root/sock" CODEDB_MCP_IDLE_MS=1000 \
      "$zig" build test --summary all 8>&- 9>&-) >"$test_log" 2>&1 || {
    grep -E "^error: '|Build Summary" "$test_log" | head -20 >&2
    die "unit tests failed; full log: $test_log"
  }
  grep -m1 'Build Summary' "$test_log" >&2 || true
fi

log "smoke test: 3 clients, 1 shared server, idle exit"
python3 -I "$here/lib/smoke_test.py" "$bin" 8>&- 9>&- || die "smoke test failed"

# ── 5. Install ──
if [ "$(uname -s)" = Darwin ]; then
  codesign -v "$bin" || die "codesign -v failed for $bin"
fi
mkdir -p "$prefix"
staged=$(mktemp "$prefix/.codedb.new.XXXXXX")
cp "$bin" "$staged"
chmod 755 "$staged"
if [ "$(uname -s)" = Darwin ]; then
  codesign -v "$staged" || die "codesign -v failed for the staged copy"
fi
# Same-directory rename: running codedb processes keep the old inode.
mv -f "$staged" "$prefix/codedb"
staged=

series_hash=$( { cat "$patch_dir/series"; series_patches | while IFS= read -r p; do cat "$patch_dir/$p"; done; } |
  python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
record=$prefix/.codedb-patched
cat >"$record.tmp" <<EOF
upstream_repo=$upstream_repo
upstream_ref=$ref
upstream_commit=$sha
patched_commit=$(git -C "$src" rev-parse HEAD)
patch_series_sha256=$series_hash
patches=$(series_patches | tr '\n' ' ' | sed 's/ $//')
binary_sha256=$(sha256_of "$prefix/codedb")
version=$("$prefix/codedb" --version)
zig=$("$zig" version)
unit_tests=$([ "$run_tests" = 1 ] && echo passed || echo skipped)
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
mv -f "$record.tmp" "$record"

log "installed $prefix/codedb ($("$prefix/codedb" --version), $ref + $(series_patches | wc -l | tr -d ' ') patches)"
log "install record: $record"
on_path=$(command -v codedb 2>/dev/null || true)
if [ -n "$on_path" ] && [ "$on_path" != "$prefix/codedb" ]; then
  log "note: 'codedb' on PATH is $on_path, not $prefix/codedb"
fi
