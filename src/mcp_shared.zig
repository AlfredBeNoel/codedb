//! One index per project root. `codedb mcp` forwards its stdio to a shared
//! `codedb <root> mcp-server` over a unix socket, so N agent sessions on one
//! root hold one Explorer instead of N. When the shared server cannot be
//! reached, `forward` returns null and the caller serves in-process.
const std = @import("std");
const builtin = @import("builtin");
const cio = @import("cio.zig");
const release_info = @import("release_info.zig");
const Config = @import("config.zig").Config;
const cli_proxy = @import("cli_proxy.zig");

pub const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

const hello_prefix = "codedb-mcp-shared/1 ";
const ready_reply = "ready";
const mismatch_reply = "mismatch";
const default_idle_ms: i64 = 5 * 60 * 1000;
/// Bounds spawning a server and seeing it listen. A slow index load is
/// covered by `ready_timeout_ms` instead, while the connection stays open.
const connect_timeout_ms: i64 = 10 * 1000;
/// MCP clients give up on server startup after about 30 s (Codex default).
const ready_timeout_ms: i64 = 30 * 1000;
/// The fd number the spawned server finds its inherited lock on.
const inherited_lock_fd: c_int = 3;
const listen_backlog = 128;
/// A connected peer that sends no hello in this time holds no session slot.
const hello_timeout_ms: i64 = 10 * 1000;

/// Knobs that choose the endpoint or the server lifetime, not what a session
/// returns, so clients that differ only in these still share one server.
const env_not_in_key = [_][]const u8{
    "CODEDB_MCP_SHARED",
    "CODEDB_MCP_SOCKET_DIR",
    "CODEDB_MCP_IDLE_MS",
    "CODEDB_ROOT",
};

/// Order-independent hash of the CODEDB_* entries of `env` ("NAME=VALUE").
pub fn envFingerprint(env: []const []const u8) u64 {
    var sum: u64 = 0;
    for (env) |entry| sum +%= envEntryHash(entry);
    return sum;
}

fn envEntryHash(entry: []const u8) u64 {
    if (!std.mem.startsWith(u8, entry, "CODEDB_")) return 0;
    const name = entry[0 .. std.mem.indexOfScalar(u8, entry, '=') orelse entry.len];
    for (env_not_in_key) |skip| {
        if (std.mem.eql(u8, name, skip)) return 0;
    }
    return std.hash.Wyhash.hash(0x636f646564620001, entry);
}

fn processEnvFingerprint() u64 {
    var sum: u64 = 0;
    var it = cio.environ();
    while (it[0]) |entry| : (it += 1) sum +%= envEntryHash(std.mem.span(entry));
    return sum;
}

/// Clients share a server only when they would run identical in-process
/// servers: same binary, root, effective config and CODEDB_* environment.
pub fn serverKey(abs_root: []const u8, cfg: Config, no_telemetry: bool, env_fingerprint: u64) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(hello_prefix);
    h.update(release_info.semver);
    h.update(&.{0});
    h.update(abs_root);
    h.update(&.{0});
    const max_versions: u64 = cfg.max_versions;
    h.update(std.mem.asBytes(&max_versions));
    h.update(std.mem.asBytes(&cfg.max_cached));
    h.update(std.mem.asBytes(&cfg.max_watched));
    h.update(&.{ @intFromBool(cfg.rerank_trace), @intFromBool(no_telemetry) });
    h.update(std.mem.asBytes(&env_fingerprint));
    return h.final();
}

fn helloLine(buf: []u8, key: u64) []const u8 {
    return std.fmt.bufPrint(buf, hello_prefix ++ "{x:0>16}", .{key}) catch unreachable;
}

/// `<dir>/<key>.{sock,lock,log}`: the socket, the flock that admits one
/// server per key, and that server's stderr.
pub const Endpoint = struct {
    key: u64,
    dir_buf: [std.fs.max_path_bytes]u8 = undefined,
    dir_len: usize = 0,

    pub fn init(io: std.Io, key: u64) Unavailable!Endpoint {
        var ep = Endpoint{ .key = key };
        const dir = socketDir(&ep.dir_buf) orelse return error.NoSocketDir;
        ep.dir_len = dir.len;
        if (std.fs.path.dirname(dir)) |parent| std.Io.Dir.cwd().createDirPath(io, parent) catch {};
        var dir_z_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const dir_z = cio.bufPrintZ(&dir_z_buf, "{s}", .{dir}) catch return error.NoSocketDir;
        _ = std.c.mkdir(dir_z.ptr, 0o700);
        var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sock = ep.path(&sock_buf, "sock") orelse return error.SocketPathTooLong;
        // sockaddr_un holds 104 bytes on macOS, 108 on Linux.
        _ = cli_proxy.cliFillSockaddr(sock) orelse return error.SocketPathTooLong;
        return ep;
    }

    pub fn path(self: *const Endpoint, buf: []u8, ext: []const u8) ?[:0]const u8 {
        return cio.bufPrintZ(buf, "{s}/{x:0>16}.{s}", .{ self.dir_buf[0..self.dir_len], self.key, ext }) catch null;
    }
};

/// Why a client serves in-process; logged so a fallback is never silent.
const Unavailable = error{
    NoSocketDir,
    SocketPathTooLong,
    SocketDirNotWritable,
    ServerRefused,
    SpawnFailed,
    ServerExitedBeforeListening,
    ConnectTimeout,
};

fn socketDir(buf: []u8) ?[]const u8 {
    if (cio.posixGetenv("CODEDB_MCP_SOCKET_DIR")) |dir| {
        if (dir.len > 0) return std.fmt.bufPrint(buf, "{s}", .{dir}) catch null;
    }
    const home = cio.homeDir() orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.codedb/run", .{home}) catch null;
}

const LockAttempt = union(enum) {
    acquired: c_int,
    held,
    unavailable,
};

fn lockServer(lock_path: [:0]const u8) LockAttempt {
    const fd = std.c.open(lock_path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, @as(c_uint, 0o600));
    if (fd < 0) return .unavailable;
    if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) {
        _ = std.c.close(fd);
        return .held;
    }
    return .{ .acquired = fd };
}

// ── Client side ────────────────────────────────────────────────────────────

/// Serve this stdio session through the shared server for `abs_root`,
/// spawning it when none runs. Returns the exit code once the session ends,
/// or null before any stdin byte is consumed so the caller can serve in-process.
pub fn forward(io: std.Io, allocator: std.mem.Allocator, abs_root: []const u8, cfg: Config, no_telemetry: bool, config_file: ?[]const u8) ?u8 {
    if (comptime !supported) return null;
    if (cio.posixGetenv("CODEDB_MCP_SHARED")) |v| {
        if (std.mem.eql(u8, v, "0")) return null;
    }
    const key = serverKey(abs_root, cfg, no_telemetry, processEnvFingerprint());
    const spawn = SpawnArgs{ .io = io, .allocator = allocator, .abs_root = abs_root, .no_telemetry = no_telemetry, .config_file = config_file };
    const conn = connectOrSpawn(io, key, spawn) catch |err| {
        std.log.info("codedb mcp: shared server unavailable ({s}), serving in-process", .{@errorName(err)});
        return null;
    };
    return pump(conn);
}

const SpawnArgs = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    abs_root: []const u8,
    no_telemetry: bool,
    config_file: ?[]const u8,
};

fn connectOrSpawn(io: std.Io, key: u64, spawn: SpawnArgs) Unavailable!c_int {
    const ep = try Endpoint.init(io, key);
    var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    var log_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock = ep.path(&sock_buf, "sock") orelse return error.SocketPathTooLong;
    const lock = ep.path(&lock_buf, "lock") orelse return error.SocketPathTooLong;
    const log = ep.path(&log_buf, "log") orelse return error.SocketPathTooLong;

    const deadline = cio.milliTimestamp() + connect_timeout_ms;
    var spawned = false;
    var backoff_ms: u64 = 5;
    while (cio.milliTimestamp() < deadline) {
        switch (attach(sock, key)) {
            .ready => |fd| return fd,
            .refused => return error.ServerRefused,
            .absent => {},
        }
        switch (lockServer(lock)) {
            .unavailable => return error.SocketDirNotWritable,
            .held => {},
            .acquired => |lock_fd| {
                defer _ = std.c.close(lock_fd);
                // The lock is free again only if the server we started died.
                if (spawned) return error.ServerExitedBeforeListening;
                if (!spawnServer(spawn, lock_fd, log)) return error.SpawnFailed;
                spawned = true;
            },
        }
        cio.sleepMs(backoff_ms);
        backoff_ms = @min(backoff_ms * 2, 50);
    }
    return error.ConnectTimeout;
}

const Attach = union(enum) {
    /// Greeted by a server that has loaded its index.
    ready: c_int,
    /// Nothing listens yet, or the server closed before greeting us.
    absent,
    /// A live peer that is not, or will not be, our server.
    refused,
};

fn attach(sock: [:0]const u8, key: u64) Attach {
    var sa = cli_proxy.cliFillSockaddr(sock) orelse return .refused;
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return .absent;
    if (std.c.connect(fd, @ptrCast(&sa.addr), sa.len) != 0) {
        _ = std.c.close(fd);
        return .absent;
    }
    if (!cli_proxy.unixPeerTrusted(fd)) {
        _ = std.c.close(fd);
        return .refused;
    }
    var hello_buf: [64]u8 = undefined;
    var reply_buf: [64]u8 = undefined;
    const reply = if (writeLine(fd, helloLine(&hello_buf, key))) readLine(fd, &reply_buf, cio.milliTimestamp() + ready_timeout_ms) else .closed;
    switch (reply) {
        .line => |line| if (std.mem.eql(u8, line, ready_reply)) return .{ .ready = fd },
        .closed => {
            _ = std.c.close(fd);
            return .absent;
        },
        .timeout => {},
    }
    _ = std.c.close(fd);
    return .refused;
}

const LineRead = union(enum) { line: []const u8, closed, timeout };

/// Reads one short line byte by byte, so no MCP bytes after it are consumed.
fn readLine(fd: c_int, buf: []u8, deadline_ms: i64) LineRead {
    var len: usize = 0;
    while (len < buf.len) {
        const wait_ms = deadline_ms - cio.milliTimestamp();
        if (wait_ms <= 0) return .timeout;
        var fds = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
        const ready = std.c.poll(&fds, 1, @intCast(@min(wait_ms, std.math.maxInt(c_int))));
        if (ready < 0) {
            if (std.c.errno(ready) == .INTR) continue;
            return .closed;
        }
        if (ready == 0) return .timeout;
        const n = cli_proxy.connRead(fd, buf[len .. len + 1]) orelse return .closed;
        if (n == 0) return .closed;
        if (buf[len] == '\n') return .{ .line = buf[0..len] };
        len += 1;
    }
    return .closed;
}

fn writeLine(fd: c_int, line: []const u8) bool {
    return cli_proxy.cliWriteFull(fd, line) and cli_proxy.cliWriteFull(fd, "\n");
}

/// Copies stdin to the server and the server to stdout until the session ends.
fn pump(conn: c_int) u8 {
    var stdin_done = std.atomic.Value(bool).init(false);
    const upstream = std.Thread.spawn(.{}, copyStdinToServer, .{ conn, &stdin_done }) catch {
        _ = std.c.close(conn);
        return 1;
    };
    upstream.detach();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = cli_proxy.connRead(conn, &buf) orelse break;
        if (n == 0) break;
        cio.File.stdout().writeAll(buf[0..n]) catch return 0;
    }
    if (stdin_done.load(.acquire)) return 0;
    std.log.err("codedb mcp: lost the shared server connection", .{});
    return 1;
}

fn copyStdinToServer(conn: c_int, stdin_done: *std.atomic.Value(bool)) void {
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = cli_proxy.connRead(0, &buf) orelse break;
        if (n == 0 or !cli_proxy.cliWriteFull(conn, buf[0..n])) break;
    }
    stdin_done.store(true, .release);
    _ = std.c.shutdown(conn, std.c.SHUT.WR);
}

/// Double-forks `codedb <root> mcp-server` so it is reparented to init and
/// outlives this client, and hands it `lock_fd` as fd 3 so it owns the key.
fn spawnServer(spawn: SpawnArgs, lock_fd: c_int, log_path: [:0]const u8) bool {
    const self_exe = std.process.executablePathAlloc(spawn.io, spawn.allocator) catch return false;
    defer spawn.allocator.free(self_exe);
    const root_z = spawn.allocator.dupeSentinel(u8, spawn.abs_root, 0) catch return false;
    defer spawn.allocator.free(root_z);
    var config_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    var argv: [7:null]?[*:0]const u8 = @splat(null);
    var argc: usize = 0;
    for ([_][*:0]const u8{ self_exe.ptr, root_z.ptr, "mcp-server", "--lock-fd=3" }) |arg| {
        argv[argc] = arg;
        argc += 1;
    }
    if (spawn.no_telemetry) {
        argv[argc] = "--no-telemetry";
        argc += 1;
    }
    if (spawn.config_file) |config_file| {
        const arg = cio.bufPrintZ(&config_buf, "--config-file={s}", .{config_file}) catch return false;
        argv[argc] = arg.ptr;
        argc += 1;
    }

    const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, @as(c_uint, 0));
    if (devnull < 0) return false;
    defer _ = std.c.close(devnull);
    const log_fd = std.c.open(log_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c_uint, 0o600));
    defer if (log_fd >= 0) {
        _ = std.c.close(log_fd);
    };
    const envp = cio.environ();

    const pid = std.c.fork();
    if (pid < 0) return false;
    if (pid == 0) daemonize(self_exe.ptr, &argv, envp, devnull, if (log_fd >= 0) log_fd else devnull, lock_fd);
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, 0);
        if (rc >= 0) break;
        if (std.c.errno(rc) != .INTR) return false;
    }
    return status == 0;
}

/// Runs in the forked child: only async-signal-safe calls until execve.
fn daemonize(exe: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, devnull: c_int, log_fd: c_int, lock_fd: c_int) noreturn {
    _ = std.c.setsid();
    const pid = std.c.fork();
    if (pid != 0) std.c._exit(if (pid > 0) 0 else 1);
    // Lift every fd above the targets first so no dup2 clobbers a source.
    const high_null = std.c.fcntl(devnull, std.c.F.DUPFD, @as(c_int, 10));
    const high_log = std.c.fcntl(log_fd, std.c.F.DUPFD, @as(c_int, 10));
    const high_lock = std.c.fcntl(lock_fd, std.c.F.DUPFD, @as(c_int, 10));
    if (high_null < 0 or high_log < 0 or high_lock < 0) std.c._exit(1);
    _ = std.c.dup2(high_null, 0);
    _ = std.c.dup2(high_null, 1);
    _ = std.c.dup2(high_log, 2);
    _ = std.c.dup2(high_lock, inherited_lock_fd);
    // The server must not keep an agent's pipes, or that agent never sees EOF.
    var fd: c_int = inherited_lock_fd + 1;
    while (fd < 256) : (fd += 1) _ = std.c.close(fd);
    _ = std.c.execve(exe, argv, envp);
    std.c._exit(127);
}

// ── Server side ────────────────────────────────────────────────────────────

pub fn idleMsFromEnv() i64 {
    const raw = cio.posixGetenv("CODEDB_MCP_IDLE_MS") orelse return default_idle_ms;
    return std.fmt.parseInt(i64, raw, 10) catch default_idle_ms;
}

/// `--lock-fd=N` from the spawning client, if present among `args`.
pub fn inheritedLockFd(args: []const []const u8) ?c_int {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--lock-fd=")) {
            return std.fmt.parseInt(c_int, arg["--lock-fd=".len..], 10) catch null;
        }
    }
    return null;
}

/// The listening side of one key. It holds the key's flock for its whole
/// life, so it alone may unlink and bind the socket path.
pub const Server = struct {
    key: u64,
    listen_fd: c_int,
    lock_fd: c_int,
    sock_buf: [std.fs.max_path_bytes]u8 = undefined,
    sock_len: usize = 0,
    idle_ms: i64,
    mu: cio.Mutex = .{},
    active: usize = 0,
    idle_since_ms: i64,

    /// Null when another server owns the key or the socket cannot be bound;
    /// the caller then exits without loading anything.
    pub fn bind(io: std.Io, abs_root: []const u8, cfg: Config, no_telemetry: bool, inherited_lock: ?c_int, idle_ms: i64) ?Server {
        if (comptime !supported) return null;
        const key = serverKey(abs_root, cfg, no_telemetry, processEnvFingerprint());
        const ep = Endpoint.init(io, key) catch return null;
        var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
        const lock_path = ep.path(&lock_buf, "lock") orelse return null;
        const lock_fd = inherited_lock orelse switch (lockServer(lock_path)) {
            .acquired => |fd| fd,
            .held, .unavailable => return null,
        };
        if (std.c.flock(lock_fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) return null;
        _ = std.c.fcntl(lock_fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));

        var server = Server{ .key = key, .listen_fd = -1, .lock_fd = lock_fd, .idle_ms = idle_ms, .idle_since_ms = cio.milliTimestamp() };
        const sock = ep.path(&server.sock_buf, "sock") orelse return null;
        server.sock_len = sock.len;
        const sa = cli_proxy.cliFillSockaddr(sock) orelse return null;
        _ = std.c.unlink(sock.ptr);
        server.listen_fd = cli_proxy.cliBindListen(sa, sock, listen_backlog) orelse return null;
        _ = std.c.fcntl(server.listen_fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
        std.log.info("codedb mcp-server: root={s} socket={s} idle_ms={d}", .{ abs_root, sock, idle_ms });
        return server;
    }

    fn sockPath(self: *const Server) [:0]const u8 {
        return self.sock_buf[0..self.sock_len :0];
    }

    /// Accepts clients until no session has been open for `idle_ms`, then
    /// unlinks the socket and returns. `handler.runSession(fd)` runs per client.
    /// Admission and the idle verdict share this thread, so a client accepted
    /// before the verdict always keeps the server alive.
    pub fn serve(self: *Server, handler: anytype) void {
        // The index load ran before this; clients queued during it count as new.
        self.mu.lock();
        self.idle_since_ms = cio.milliTimestamp();
        self.mu.unlock();
        while (!self.idleExpired(cio.milliTimestamp())) {
            var fds = [_]std.c.pollfd{.{ .fd = self.listen_fd, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, 250) <= 0) continue;
            const conn = std.c.accept(self.listen_fd, null, null);
            if (conn < 0) continue;
            _ = std.c.fcntl(conn, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
            if (!cli_proxy.unixPeerTrusted(conn)) {
                _ = std.c.close(conn);
                continue;
            }
            self.enter();
            const thread = std.Thread.spawn(.{}, runClient, .{ self, conn, handler }) catch {
                self.leave(conn);
                continue;
            };
            thread.detach();
        }
        _ = std.c.unlink(self.sockPath().ptr);
        _ = std.c.close(self.listen_fd);
        // A newer client may start the next server while this one shuts down.
        _ = std.c.close(self.lock_fd);
        self.lock_fd = -1;
        std.log.info("codedb mcp-server: idle for {d}ms with no clients, exiting", .{self.idle_ms});
    }

    fn runClient(self: *Server, conn: c_int, handler: anytype) void {
        defer self.leave(conn);
        if (!self.greet(conn)) return;
        handler.runSession(conn);
    }

    fn greet(self: *const Server, conn: c_int) bool {
        var expected_buf: [64]u8 = undefined;
        var got_buf: [64]u8 = undefined;
        const got = switch (readLine(conn, &got_buf, cio.milliTimestamp() + hello_timeout_ms)) {
            .line => |line| line,
            .closed, .timeout => return false,
        };
        if (!std.mem.eql(u8, got, helloLine(&expected_buf, self.key))) {
            _ = writeLine(conn, mismatch_reply);
            return false;
        }
        return writeLine(conn, ready_reply);
    }

    fn enter(self: *Server) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.active += 1;
    }

    fn leave(self: *Server, conn: c_int) void {
        _ = std.c.close(conn);
        self.mu.lock();
        defer self.mu.unlock();
        self.active -= 1;
        if (self.active == 0) self.idle_since_ms = cio.milliTimestamp();
    }

    fn idleExpired(self: *Server, now_ms: i64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.active == 0 and now_ms - self.idle_since_ms >= self.idle_ms;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "mcp shared: env fingerprint covers CODEDB_ knobs only" {
    const base = envFingerprint(&.{ "PATH=/bin", "CODEDB_TOOLS_PROFILE=mini" });
    try testing.expectEqual(base, envFingerprint(&.{ "CODEDB_TOOLS_PROFILE=mini", "PATH=/usr/bin", "TERM=xterm" }));
    try testing.expect(base != envFingerprint(&.{"CODEDB_TOOLS_PROFILE=full"}));
    try testing.expect(base != envFingerprint(&.{ "CODEDB_TOOLS_PROFILE=mini", "CODEDB_MCP_LEAN=1" }));
    try testing.expectEqual(base, envFingerprint(&.{
        "CODEDB_TOOLS_PROFILE=mini",
        "CODEDB_MCP_SOCKET_DIR=/tmp/x",
        "CODEDB_MCP_IDLE_MS=10",
        "CODEDB_MCP_SHARED=1",
        "CODEDB_ROOT=/elsewhere",
    }));
}

test "mcp shared: server key separates roots, configs and telemetry" {
    const cfg = Config.default;
    const key = serverKey("/repo", cfg, false, 0);
    try testing.expectEqual(key, serverKey("/repo", cfg, false, 0));
    try testing.expect(key != serverKey("/repo2", cfg, false, 0));
    try testing.expect(key != serverKey("/repo", cfg, true, 0));
    try testing.expect(key != serverKey("/repo", cfg, false, 1));
    var small = cfg;
    small.max_cached = 8;
    try testing.expect(key != serverKey("/repo", small, false, 0));
}

test "mcp shared: a socket path beyond sockaddr_un is refused, not truncated" {
    if (comptime !supported) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const prev_dir = cio.posixGetenv("CODEDB_MCP_SOCKET_DIR");
    defer if (prev_dir) |d| cio.posixSetenv("CODEDB_MCP_SOCKET_DIR", d) else cio.posixUnsetenv("CODEDB_MCP_SOCKET_DIR");
    const long_dir = "/nonexistent-codedb-test/" ++ @as([96]u8, @splat('d'));
    cio.posixSetenv("CODEDB_MCP_SOCKET_DIR", long_dir);
    try testing.expectError(error.SocketPathTooLong, Endpoint.init(threaded.io(), 1));
}

test "mcp shared: lock fd argument parsing" {
    try testing.expectEqual(@as(?c_int, 3), inheritedLockFd(&.{ "--no-telemetry", "--lock-fd=3" }));
    try testing.expectEqual(@as(?c_int, null), inheritedLockFd(&.{"--lock-fd=x"}));
    try testing.expectEqual(@as(?c_int, null), inheritedLockFd(&.{}));
}

const EchoHandler = struct {
    fn runSession(_: *const EchoHandler, conn: c_int) void {
        var buf: [256]u8 = undefined;
        while (cli_proxy.connRead(conn, &buf)) |n| {
            if (n == 0 or !cli_proxy.cliWriteFull(conn, buf[0..n])) return;
        }
    }
};

fn serveEcho(server: *Server, returned: *std.atomic.Value(bool)) void {
    const handler = EchoHandler{};
    server.serve(&handler);
    returned.store(true, .release);
}

test "mcp shared: server greets, serves, and retires once idle" {
    if (comptime !supported) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    var env_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prev_dir = cio.posixGetenv("CODEDB_MCP_SOCKET_DIR");
    cio.posixSetenv("CODEDB_MCP_SOCKET_DIR", try std.fmt.bufPrint(&env_buf, "{s}/run", .{dir_buf[0..dir_len]}));
    defer if (prev_dir) |d| cio.posixSetenv("CODEDB_MCP_SOCKET_DIR", d) else cio.posixUnsetenv("CODEDB_MCP_SOCKET_DIR");

    var server = Server.bind(io, "/shared-test-root", Config.default, true, null, 300) orelse return error.TestUnexpectedResult;
    try testing.expect(Server.bind(io, "/shared-test-root", Config.default, true, null, 300) == null);

    var returned = std.atomic.Value(bool).init(false);
    const serve_thread = try std.Thread.spawn(.{}, serveEcho, .{ &server, &returned });

    const conn = switch (attach(server.sockPath(), server.key)) {
        .ready => |fd| fd,
        .absent, .refused => return error.TestUnexpectedResult,
    };
    try testing.expect(writeLine(conn, "ping"));
    var echo_buf: [16]u8 = undefined;
    try testing.expectEqualStrings("ping", switch (readLine(conn, &echo_buf, cio.milliTimestamp() + 5000)) {
        .line => |line| line,
        .closed, .timeout => return error.TestUnexpectedResult,
    });
    try testing.expect(attach(server.sockPath(), server.key +% 1) == .refused);

    cio.sleepMs(900);
    try testing.expect(!returned.load(.acquire));
    _ = std.c.close(conn);

    serve_thread.join();
    try testing.expect(attach(server.sockPath(), server.key) == .absent);
    // serve released the key, so the next server can take it at once.
    const next = Server.bind(io, "/shared-test-root", Config.default, true, null, 300) orelse return error.TestUnexpectedResult;
    _ = std.c.close(next.listen_fd);
    _ = std.c.close(next.lock_fd);
}
