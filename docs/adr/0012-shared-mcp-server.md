# ADR 0012: One shared MCP server per project root

Status: implemented on branch `shared-daemon`.

## Context

Each Claude or Codex agent starts its own `codedb mcp` stdio process, and each
process builds its own index of the same repository. On one Mac, 21 parallel
agents gave 24 codedb processes at 1.4-3.1 GB `footprint -p` each, and the
machine ran out of memory.

## Decision

`codedb mcp` becomes a thin stdio forwarder when its root is known at launch.
It connects to `codedb <root> mcp-server` over a Unix socket in
`~/.codedb/run`, and starts that server when none runs.

1. Key. A Wyhash of the codedb version, the root, the effective config,
   `--no-telemetry` and the `CODEDB_*` environment. Clients that would run
   different servers never share one, and a new binary gets a new server.
2. One server per key. The client takes `flock(<key>.lock)` and passes the
   locked fd to the server as fd 3. The lock has no gap between client and
   server, so 20 clients that start in the same second start one server.
3. Detached server. A double fork with `setsid` reparents the server to init,
   so killing one agent's process tree does not stop it. Its stdin and stdout
   are `/dev/null`, its stderr is `<key>.log`, and it closes every other fd so
   that it never holds an agent's pipes open.
4. Handshake. The client sends `codedb-mcp-shared/1 <key>`, and the server
   answers `ready` after its index load. The client reads stdin only after
   `ready`. Any earlier failure falls back to in-process serving with no lost
   bytes, and the log names the reason.
5. Sessions. One thread per client, each with its own `Session`,
   `ProjectCache` and broken-pipe flag, so one dead client ends only its own
   session. The Explorer, Store, watcher, agent registry, telemetry and CLI
   proxy listener are shared.
6. Lifetime. The accept loop exits after `CODEDB_MCP_IDLE_MS` (default 5 min)
   without a session. Admission and the idle verdict run on one thread. The
   server releases the lock when its listener closes, so a later client can
   start the next server at once.

7. Trust. The socket directory must be a real directory that the user owns
   and that group and others cannot write. The lock and log open with
   `O_NOFOLLOW`, the socket is 0600, and both ends check the peer uid.
8. One index per root, also for explicit calls. A `project` argument that
   names the server's own root uses the shared index, not a per-session
   snapshot copy.

Concurrent sessions exposed one shared-state cost: `Explorer.rebuildWordIndex`
had no single-flight guard, so N sessions that missed the word index each read
every file and built a full copy. A build mutex with a re-check of
`word_index_complete` makes them wait for one build.

## Rejected alternatives

- The existing CLI proxy socket. Its framed request and response protocol
  cannot carry server-to-client requests such as `roots/list`, or connections
  that last hours.
- `codedb serve`. It is HTTP on one fixed port and has no MCP endpoint.
- An external `mcp-proxy` per root. It works, but each client costs 35-65 MB of
  Python, and the root registry would live outside codedb.

## Consequences

Measured on a 16k-file repository with 10 concurrent clients (initialize,
tools/list, codedb_search each): one server at 567 MB warm and 858 MB cold
(peak 859 MB), plus 10 forwarders at 1.2 MB each. In-process mode uses about
530 MB per client warm, about 5.3 GB for 10.

Costs:

- One server is a shared failure domain. A crash ends every session on that
  root, and the MCP clients must restart `codedb mcp`.
- Tool calls from different agents now run concurrently on one Explorer.
  Explorer already takes a reader-writer lock, and the CLI proxy already ran
  calls concurrently with the MCP session, but contention is new at this scale.
- A socket path longer than 104 bytes (a very long HOME or
  `CODEDB_MCP_SOCKET_DIR`) falls back to in-process mode.
- Roots that come only from the client's `roots/list` and `CODEDB_LAZY_MCP`
  sessions stay in-process. Windows stays in-process.
