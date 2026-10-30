# codedb-patched

Patches for [codedb](https://github.com/justrach/codedb) that cut its memory use and share one MCP
server per repo. One script applies them to an upstream release, then builds, tests and installs.
This branch holds only the patch tooling. It is not a fork to merge.

## Set up a new Mac

```sh
xcode-select --install          # git, python3 (skip if already installed)
git clone -b patches https://github.com/AlfredBeNoel/codedb.git ~/dev/codedb-patched
~/dev/codedb-patched/codedb-patched.sh
```

The script installs `~/bin/codedb` and writes `~/bin/.codedb-patched` (upstream ref, patch-series hash,
binary sha256). It fetches the exact Zig that upstream's `build.zig.zon` asks for, from a community
mirror, and checks its minisign signature. Build, unit tests and smoke test took 66–81 s on an Apple
Silicon Mac. A first run on a new Mac also clones upstream, downloads Zig and compiles dependencies cold.

## What the patches do

| Patch | What | Lines |
|---|---|---|
| 0001 growth | Call graph built per file. Watcher reconciles only changed files on a git HEAD change. Call-path results own their strings. `codedb_context` deadlock fixed. | +255 −91 |
| 0002 footprint | Word index stays on its mmap with an edit overlay, and rebuilds once in a private heap. Call-graph arena is unmapped after use. | +609 −188 |
| 0003 shared server | `codedb mcp` forwards to one `mcp-server` per project root over a private Unix socket. Falls back to in-process when the socket is not usable. | +1058 −83 |
| 0004 follow-ups | Page-backed call-graph arenas. Lock-safe publish of the call graph and centrality across concurrent sessions. | +100 −49 |
| 0005 auto-update | Background auto-update only with `CODEDB_AUTO_UPDATE=1`, so codedb never replaces itself with the unpatched upstream build. | +44 −22 |

Measured on a 16k-file repo, macOS `phys_footprint`, upstream 0.2.5862 against the full series:

| Case | Upstream | Patched |
|---|---|---|
| Warm start + search | 547 MiB | 168–185 MiB |
| Warm start + one edit | 1158 MiB | 170–172 MiB |
| Empty HOME (cold index) | 1113 MiB | 343–367 MiB |
| 10 agent sessions on one repo | 10 in-process servers | 1 server, 179 MB warm (peak 227) + 1.2 MB per session |

A 15-minute soak under agent-style churn ends at peak / mean / end 601 / 327 / 394 MB with the full
series, against 1429 / 1090 / 785 MB with only the growth fixes (0001).

## Script usage

```
codedb-patched.sh [--ref <tag|commit|latest>] [--prefix <dir>] [--no-test] [--check]
```

| Option | Default | Effect |
|---|---|---|
| `--ref` | `latest` | Upstream tag, branch or commit. `latest` is the GitHub "latest release". |
| `--prefix` | `$HOME/bin` | Install directory. |
| `--no-test` | off | Skip the unit tests. The smoke test still runs. |
| `--check` | off | Apply the patches and report each one as `clean`, `3-way` or `CONFLICT`. No build. |

Steps: clone or fetch upstream into `~/.cache/codedb-patched/src`, apply `patches/series` with
`git am --3way`, build with `-Doptimize=ReleaseFast`, run `zig build test`, run a smoke test (3 clients,
1 shared server, `codedb_search` per client, idle exit), check `codesign -v`, then install by an atomic `mv`.
It is safe to run again. It refuses to reset work in the cache clone that it did not make, and locks
stop two runs from sharing one cache or one checkout of this branch. On a test failure the full log is in `<cache>/last-test.log`.

Script environment: `ZIG` (zig to use), `CODEDB_UPSTREAM_REPO` (default `justrach/codedb`), and
`CODEDB_PATCHED_CACHE` (cache directory). The cache must not be under `/tmp` or `/var`, because upstream
refuses project roots there. The clone path `<cache>/src` must be at most 45 characters, because two tests
put a Unix socket inside it.

## Update to a new upstream release

1. `cd ~/dev/codedb-patched && git pull`
2. `./codedb-patched.sh --check` and read the per-patch report.
3. If every patch applies: `./codedb-patched.sh`.
4. Restart your agent sessions. A shared server of the old build keeps serving until it idles out.

`latest` reads the GitHub API, not a version sort: the old tag `v0.2.58181` sorts above newer releases.

## Refresh the patches after a conflict

1. `./codedb-patched.sh --check --ref <tag>` stops at the conflict and leaves it in `~/.cache/codedb-patched/src`.
2. `cd ~/.cache/codedb-patched/src`, fix the files, `git add` them, then `git am --continue`.
3. Repeat step 2 until `git am` finishes the series.
4. `~/dev/codedb-patched/refresh-patches.sh` regenerates `patches/` from the result.
5. `./codedb-patched.sh --ref <tag>` builds, tests and installs.
6. Commit `patches/` and push.

To change a patch without a conflict, edit the commits on branch `codedb-patched` in the cache clone
(`git commit --amend`, `git rebase -i`), then run step 4. Branch `memory-fix` keeps the original merge
history that the series came from.

## MCP config

Claude Code, Cursor and other `mcp.json` clients:

```json
{ "mcpServers": { "codedb": { "command": "/Users/<you>/bin/codedb", "args": ["mcp"] } } }
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.codedb]
command = "/Users/<you>/bin/codedb"
args = ["mcp"]
```

## Environment variables

| Variable | Default | Effect |
|---|---|---|
| `CODEDB_MCP_SHARED` | on | `0` serves each session in its own process, as upstream does. |
| `CODEDB_MCP_IDLE_MS` | `300000` | The shared server exits after this long without a client. |
| `CODEDB_MCP_SOCKET_DIR` | `~/.codedb/run` | Directory for the socket, lock and server log. |
| `CODEDB_AUTO_UPDATE` | unset | `1` turns on the background auto-update. It installs the **unpatched** upstream build. |
| `CODEDB_NO_AUTO_UPDATE` | unset | Turns the auto-update off, also when `CODEDB_AUTO_UPDATE=1`. |

`codedb update` (manual) also installs the unpatched upstream build when upstream is newer.
Use `codedb-patched.sh` instead.

## Which build is installed

`cat ~/bin/.codedb-patched`. `codedb --version` prints the plain upstream version. A `+patched` suffix
would change the shared-server key, the update check, telemetry and the hosted-embedding handshake,
and `scripts/test_update_resolution.py` parses `--version` as a bare version.

## Roll back to plain upstream

```sh
( set -euo pipefail
  v=0.2.5862 a=codedb-darwin-arm64        # or codedb-darwin-x86_64
  cd "$(mktemp -d)"
  curl -fsSLO "https://github.com/justrach/codedb/releases/download/v$v/$a"
  curl -fsSLO "https://github.com/justrach/codedb/releases/download/v$v/checksums.sha256"
  grep " $a\$" checksums.sha256 | shasum -a 256 -c -
  cp "$a" ~/bin/.codedb.new
  chmod 755 ~/bin/.codedb.new
  mv -f ~/bin/.codedb.new ~/bin/codedb
  rm -f ~/bin/.codedb-patched )
```

The subshell stops at the first failure, so a bad download or checksum leaves the installed binary alone.

Running shared servers exit on their own after the idle time. Upstream's own installer
(`curl -fsSL https://codedb.codegraff.com/install.sh | bash`) also works, but it also edits agent configs and hooks.

## Test tooling

The soak (`scripts/soak_growth.py`), the memory probe (`experiments/memory/`) and the e2e scenario S10
are not in the series. They never reach the binary, and in the series they would only add conflict surface.
Get them from branch `memory-fix`, for example
`git show origin/memory-fix:scripts/soak_growth.py > soak_growth.py`.

## Files

- `patches/series`: patch order. `patches/base`: the upstream ref the series was last generated on.
- `codedb-patched.sh`: check, build, test, install.
- `refresh-patches.sh`: regenerate `patches/` from the cache clone.
- `lib/smoke_test.py`, `lib/minisign_verify.py`: helpers for the script.
