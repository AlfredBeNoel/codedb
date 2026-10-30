"""Smoke test for a patched codedb binary.

Usage: smoke_test.py <codedb-binary>
Starts 3 `codedb mcp` clients on one temp git repo with an isolated HOME and checks:
each client forwards to the one shared mcp-server, codedb_search works for each, and idle exit.
"""
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time

CLIENTS = 3
IDLE_MS = 3000
MARKER = "codedb_smoke_marker"
FALLBACK_LOG = "shared server unavailable"

BIN = os.path.realpath(sys.argv[1])
# A short base keeps <HOME>/.codedb/run/<key>.sock inside the 104-byte socket path limit.
BASE = os.path.realpath(tempfile.mkdtemp(prefix="cdbsmoke.", dir="/tmp"))
HOME, REPO = os.path.join(BASE, "h"), os.path.join(BASE, "r")
ENV = {
    "HOME": HOME,
    "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    "CODEDB_NO_TELEMETRY": "1",
    "CODEDB_NO_AUTO_UPDATE": "1",
    "CODEDB_MCP_IDLE_MS": str(IDLE_MS),
}
clients = []


def our_servers():
    """Pids of mcp-server processes of this binary for this test's repo (argv: bin root mcp-server ...)."""
    out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    prefix = f"{BIN} {REPO} mcp-server "
    return [int(line.split(None, 1)[0]) for line in out.splitlines()
            if len(line.split(None, 1)) == 2 and (line.split(None, 1)[1] + " ").startswith(prefix)]


def make_repo():
    os.makedirs(HOME)
    os.makedirs(os.path.join(REPO, "src"))
    with open(os.path.join(REPO, "src", "smoke.py"), "w") as f:
        f.write(f"def {MARKER}():\n    return 42\n")
    with open(os.path.join(REPO, "README.md"), "w") as f:
        f.write("smoke test repo\n")
    git = ["git", "-c", "user.name=smoke", "-c", "user.email=smoke@example.invalid"]
    for args in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "init"]):
        subprocess.run(git + args, cwd=REPO, check=True, env=dict(ENV, GIT_CONFIG_NOSYSTEM="1"))


class Client:
    def __init__(self, n):
        self.n = n
        self.next_id = 1
        self.buf = b""
        self.stderr_path = os.path.join(BASE, f"client{n}.stderr")
        with open(self.stderr_path, "wb") as err:
            self.proc = subprocess.Popen([BIN, "mcp"], cwd=REPO, env=ENV, stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=err, bufsize=0)
        self.fd = self.proc.stdout.fileno()

    def send(self, msg):
        self.proc.stdin.write((json.dumps(msg) + "\n").encode())
        self.proc.stdin.flush()

    def read_message(self, deadline):
        # Raw fd reads with our own buffer: select() cannot see data a buffered reader already holds.
        while b"\n" not in self.buf:
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([self.fd], [], [], left)[0]:
                raise RuntimeError(f"client {self.n}: no reply in time")
            chunk = os.read(self.fd, 65536)
            if not chunk:
                raise RuntimeError(f"client {self.n}: stdout closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def request(self, method, params, timeout=60):
        rid = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            msg = self.read_message(deadline)
            if msg.get("id") == rid and "method" not in msg:
                if "error" in msg:
                    raise RuntimeError(f"client {self.n}: {method} error {msg['error']}")
                return msg["result"]

    def search_finds_marker(self):
        # The first index build can race the first call, so retry for a short while.
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            res = self.request("tools/call", {"name": "codedb_search",
                                              "arguments": {"query": MARKER, "max_results": 5}})
            text = "".join(c.get("text", "") for c in res.get("content", []))
            if not res.get("isError") and "smoke.py" in text:
                return True
            time.sleep(0.5)
        return False

    def fell_back(self):
        with open(self.stderr_path, errors="replace") as f:
            return FALLBACK_LOG in f.read()

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=15)


def main():
    results = {}
    make_repo()
    clients.extend(Client(i) for i in range(CLIENTS))
    for c in clients:
        c.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": f"smoke-{c.n}", "version": "1"}})
        c.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    results["search_each_client"] = all(c.search_finds_marker() for c in clients)
    servers = our_servers()
    results["one_mcp_server"] = len(servers) == 1
    # In-process fallback logs this line, so its absence means every client forwards to the server.
    results["no_client_fell_back"] = not any(c.fell_back() for c in clients)
    print(f"smoke: mcp-server pids {servers}")
    for c in clients:
        c.close()
    deadline = time.monotonic() + IDLE_MS / 1000 + 20
    while our_servers() and time.monotonic() < deadline:
        time.sleep(0.2)
    results["idle_exit"] = not our_servers()
    print("smoke:", json.dumps(results))
    if not all(results.values()):
        for c in clients:
            with open(c.stderr_path, errors="replace") as f:
                sys.stderr.write(f"--- client {c.n} stderr\n{f.read()[-2000:]}")
        sys.exit(1)


try:
    main()
finally:
    for c in clients:
        if c.proc.poll() is None:
            c.proc.kill()
    # Only the server for this test's private repo; nothing else that runs the binary.
    for pid in our_servers():
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
    shutil.rmtree(BASE, ignore_errors=True)
