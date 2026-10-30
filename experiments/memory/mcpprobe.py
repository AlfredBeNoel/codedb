#!/usr/bin/env python3
"""mem: initialize, wait for scan ready, one codedb_search, then footprint/vmmap.
queries: run a fixed tool-call list against one process and dump every output."""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time


def footprint_json(pid):
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tmp:
        path = tmp.name
    try:
        subprocess.run(["footprint", "-p", str(pid), "-j", path], capture_output=True, timeout=60)
        with open(path) as f:
            data = json.load(f)
    finally:
        os.unlink(path)
    proc = data["processes"][0]
    cats = {name: c["dirty"] + c.get("swapped", 0) for name, c in proc.get("categories", {}).items()}
    aux = proc.get("auxiliary", {})
    return {
        "phys_footprint": aux.get("phys_footprint"),
        "phys_footprint_peak": aux.get("phys_footprint_peak"),
        "footprint": proc.get("footprint"),
        "dirty_by_category": dict(sorted(cats.items(), key=lambda kv: -kv[1])),
    }


def vmmap_summary(pid):
    out = subprocess.run(["vmmap", "--summary", str(pid)], capture_output=True, text=True, timeout=120).stdout
    res = {"raw": out}
    m = re.search(r"Physical footprint:\s+(\S+)", out)
    if m:
        res["physical_footprint"] = m.group(1)
    m = re.search(r"Physical footprint \(peak\):\s+(\S+)", out)
    if m:
        res["physical_footprint_peak"] = m.group(1)
    return res


class Session:
    def __init__(self, binary, root, home, stderr_path, extra_env=None):
        env = {
            "HOME": home,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "CODEDB_NO_TELEMETRY": "1",
            "CODEDB_NO_AUTO_UPDATE": "1",
        }
        env.update(extra_env or {})
        self.stderr = open(stderr_path, "w")
        self.proc = subprocess.Popen(
            [binary, root, "mcp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr,
            env=env,
            cwd=home,
            bufsize=0,
        )
        self.next_id = 1
        self.buf = b""

    @property
    def pid(self):
        return self.proc.pid

    def _send(self, obj):
        self.proc.stdin.write((json.dumps(obj) + "\n").encode())
        self.proc.stdin.flush()

    def _readline(self):
        while b"\n" not in self.buf:
            chunk = os.read(self.proc.stdout.fileno(), 1 << 20)
            if not chunk:
                raise RuntimeError("codedb closed stdout (exit=%s)" % self.proc.poll())
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line

    def request(self, method, params):
        rid = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        while True:
            line = self._readline().strip()
            if not line:
                continue
            msg = json.loads(line)
            if msg.get("id") == rid and ("result" in msg or "error" in msg):
                return msg
            if "method" in msg and "id" in msg:
                self._send({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "unsupported"}})

    def notify(self, method, params=None):
        self._send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def call_tool(self, name, args):
        msg = self.request("tools/call", {"name": name, "arguments": args})
        if "error" in msg:
            return "ERROR: " + json.dumps(msg["error"])
        content = msg["result"].get("content") or []
        return "".join(part.get("text", "") for part in content)

    def initialize(self):
        self.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "memprobe", "version": "0"},
        })
        self.notify("notifications/initialized")

    def wait_ready(self, timeout_s):
        deadline = time.time() + timeout_s
        status = ""
        while time.time() < deadline:
            status = self.call_tool("codedb_status", {})
            if "scan: ready" in status:
                return status
            time.sleep(0.25)
        raise RuntimeError("scan not ready after %ss: %s" % (timeout_s, status))

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=15)
        self.stderr.close()


def settle(pid, seconds, interval):
    samples = []
    end = time.time() + seconds
    while time.time() < end:
        fp = footprint_json(pid)
        samples.append((round(time.time(), 2), fp["phys_footprint"]))
        time.sleep(interval)
    return samples


def cmd_mem(a):
    t0 = time.time()
    s = Session(a.bin, a.root, a.home, a.stderr, json.loads(a.env) if a.env else None)
    result = {"label": a.label, "bin": a.bin, "root": a.root, "pid": s.pid, "query": a.query}
    try:
        s.initialize()
        result["status_at_ready"] = s.wait_ready(a.ready_timeout)
        result["ready_s"] = round(time.time() - t0, 2)
        t1 = time.time()
        result["search_output"] = s.call_tool("codedb_search", {"query": a.query, "max_results": 10})
        result["search_s"] = round(time.time() - t1, 3)
        result["settle_samples"] = settle(s.pid, a.settle, 1.0)
        if a.edit:
            result["footprint_before_edit"] = footprint_json(s.pid)
            target = os.path.join(a.root, a.edit)
            original = open(target, "rb").read()
            original_stat = os.stat(target)
            try:
                with open(target, "ab") as f:
                    f.write(b"\n// memprobe edit\n")
                result["edit_samples"] = settle(s.pid, a.edit_settle, 1.0)
                result["edit_search_output"] = s.call_tool("codedb_search", {"query": a.query, "max_results": 10})
                result["footprint_after_edit"] = footprint_json(s.pid)
            finally:
                with open(target, "wb") as f:
                    f.write(original)
                os.utime(target, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
        result["footprint"] = footprint_json(s.pid)
        vm = vmmap_summary(s.pid)
        result["vmmap_physical_footprint"] = vm.get("physical_footprint")
        result["vmmap_physical_footprint_peak"] = vm.get("physical_footprint_peak")
        if a.vmmap_out:
            with open(a.vmmap_out, "w") as f:
                f.write(vm["raw"])
        with open(a.out, "w") as f:
            json.dump(result, f, indent=1)
        if a.hold:
            print("holding pid %d for %ss" % (s.pid, a.hold), file=sys.stderr, flush=True)
            end = time.time() + a.hold
            while time.time() < end and s.proc.poll() is None:
                time.sleep(0.5)
    finally:
        s.close()
    fp = result["footprint"]
    print("%s pid=%d ready=%.1fs footprint=%.1fMiB peak=%.1fMiB vmmap=%s/%s" % (
        a.label, result["pid"], result["ready_s"], fp["phys_footprint"] / 2**20,
        fp["phys_footprint_peak"] / 2**20, result["vmmap_physical_footprint"], result["vmmap_physical_footprint_peak"]))


def cmd_queries(a):
    with open(a.calls) as f:
        calls = json.load(f)
    s = Session(a.bin, a.root, a.home, a.stderr, json.loads(a.env) if a.env else None)
    outputs = []
    try:
        s.initialize()
        s.wait_ready(a.ready_timeout)
        for call in calls:
            outputs.append({"tool": call["tool"], "args": call["args"], "output": s.call_tool(call["tool"], call["args"])})
    finally:
        s.close()
    with open(a.out, "w") as f:
        json.dump(outputs, f, indent=1)
    print("%d calls -> %s" % (len(outputs), a.out))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("mem", "queries"):
        sp = sub.add_parser(name)
        sp.add_argument("--bin", required=True)
        sp.add_argument("--root", required=True)
        sp.add_argument("--home", required=True)
        sp.add_argument("--out", required=True)
        sp.add_argument("--stderr", required=True)
        sp.add_argument("--env", default="")
        sp.add_argument("--ready-timeout", type=float, default=900)
        if name == "mem":
            sp.add_argument("--label", default="run")
            sp.add_argument("--query", default="request handler")
            sp.add_argument("--settle", type=float, default=15)
            sp.add_argument("--vmmap-out", default="")
            sp.add_argument("--hold", type=float, default=0)
            sp.add_argument("--edit", default="")
            sp.add_argument("--edit-settle", type=float, default=15)
        else:
            sp.add_argument("--calls", required=True)
    a = p.parse_args()
    {"mem": cmd_mem, "queries": cmd_queries}[a.cmd](a)


if __name__ == "__main__":
    main()
