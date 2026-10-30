#!/usr/bin/env python3
"""Soak one live `codedb mcp` under agent-style churn and sample its footprint.

Copies --source (without node_modules, .git or snapshots) into a disposable
directory under ~/tmp, commits it to a fresh Git repository with a second
branch, warms the index with one short-lived server, then runs the measured
server while mutating files, switching branches, churning ignored directories
and issuing tool calls. macOS `footprint` is sampled every --interval seconds.

The live corpus stays bounded: scratch files are rewritten in place, uniquely
named files are deleted after a short window, and edited tracked files are
restored. A footprint that keeps climbing therefore means retained garbage,
not a larger index. Semantic lanes point at a closed local port, telemetry and
updates are disabled, and HOME is isolated, so no source leaves the machine.
"""
import argparse
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from e2e_mcp_test import MCPProcess, do_initialize, all_tool_text

SOURCE_SUFFIXES = {'.ts', '.tsx', '.js', '.jsx', '.py', '.md', '.json', '.sql', '.css'}
# The soak writes only under its own top-level dirs, so none may come from the source copy.
GENERATED_DIRS = ['/soak', '/soak_alt_moved', '/soak_alt_added']
COPY_EXCLUDES = ['node_modules', '.git', 'codedb.snapshot*', '__pycache__', '.next', '.turbo', '.expo', 'coverage',
                 *GENERATED_DIRS]
WORD_RE = re.compile(rb'[A-Za-z_][A-Za-z0-9_]{5,30}')


def capture_stack(pid, path, seconds=3):
    subprocess.run(['sample', str(pid), str(seconds), '-file', str(path)], capture_output=True)
    return str(path)


def git(root, *argv, check=True):
    return subprocess.run(['git', '-C', str(root), *argv], check=check, capture_output=True, text=True)


def prepare_corpus(source, root, rng, alt_files):
    subprocess.run(['rsync', '-a', '--max-size=2m', *[f'--exclude={e}' for e in COPY_EXCLUDES],
                    f'{source}/', f'{root}/'], check=True)
    git(root, 'init', '-q', '-b', 'base')
    git(root, 'config', 'user.email', 'soak@example.invalid')
    git(root, 'config', 'user.name', 'soak')
    git(root, 'config', 'core.fsmonitor', 'false')
    git(root, 'add', '-A')
    git(root, 'commit', '-q', '-m', 'base', '--no-verify')
    # Symlinks are never edited: an absolute link would write into the source repo.
    tracked = [p for p in git(root, 'ls-files').stdout.splitlines()
               if Path(p).suffix in SOURCE_SUFFIXES and not (root / p).is_symlink()
               and (root / p).lstat().st_size < 200_000]
    tracked.sort()
    git(root, 'checkout', '-q', '-b', 'alt')
    picks = rng.sample(tracked, min(alt_files, len(tracked)))
    edit, drop, move = picks[: len(picks) * 8 // 10], picks[len(picks) * 8 // 10: len(picks) * 9 // 10], picks[len(picks) * 9 // 10:]
    for i, rel in enumerate(edit):
        with open(root / rel, 'a') as f:
            f.write(f'\n// alt branch change {i}: altBranchMarker{i} handlesAltCase{i % 37}\n')
    for rel in drop:
        (root / rel).unlink()
    for i, rel in enumerate(move):
        dest = root / 'soak_alt_moved' / f'm{i}_{Path(rel).name}'
        dest.parent.mkdir(exist_ok=True)
        os.replace(root / rel, dest)
    added = root / 'soak_alt_added'
    added.mkdir(exist_ok=True)
    for i in range(len(drop)):
        (added / f'alt_{i}.ts').write_text(module_text(f'altOnly{i}', 12))
    git(root, 'add', '-A')
    git(root, 'commit', '-q', '-m', 'alt', '--no-verify')
    git(root, 'checkout', '-q', 'base')
    return tracked


def module_text(stem, functions):
    lines = [f'import {{ helper }} from "./helper_{stem}";', '']
    for k in range(functions):
        lines += [f'export function {stem}Step{k}(input: number): number {{',
                  f'  const {stem}Value{k} = helper(input) + {k};',
                  f'  return {stem}Value{k} * 2;', '}', '']
    return '\n'.join(lines)


def harvest_vocabulary(root, tracked, rng, size=400):
    counts = {}
    for rel in rng.sample(tracked, min(600, len(tracked))):
        try:
            data = (root / rel).read_bytes()
        except OSError:
            continue
        for m in WORD_RE.finditer(data):
            w = m.group().decode()
            counts[w] = counts.get(w, 0) + 1
    common = sorted(counts, key=counts.get, reverse=True)[: size // 2]
    rare = rng.sample(sorted(counts), min(size // 2, len(counts)))
    return common + rare


class Footprint:
    def __init__(self, pid, interval, scratch, spike_mb, spike_path):
        self.pid, self.interval, self.scratch = pid, interval, scratch
        self.spike_mb, self.spike_path, self.spike_stack = spike_mb, spike_path, None
        self.samples, self.phase, self.ops = [], 'start', 0
        self.t0 = time.monotonic()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.loop, daemon=True)

    def sample(self):
        out = self.scratch / f'fp-{self.pid}.json'
        r = subprocess.run(['footprint', '-p', str(self.pid), '-j', str(out)], capture_output=True)
        if r.returncode != 0 or not out.exists():
            return None
        proc = json.loads(out.read_text())['processes'][0]
        cats = proc['categories']
        malloc = [v for k, v in cats.items() if k.startswith('MALLOC_') and k != 'MALLOC metadata']
        ps = subprocess.run(['ps', '-o', 'rss=,time=', '-p', str(self.pid)], capture_output=True, text=True).stdout.split()
        row = {
            't': round(time.monotonic() - self.t0, 1), 'phase': self.phase, 'ops': self.ops,
            'footprint_mb': round(proc['footprint'] / 2**20, 1),
            'malloc_dirty_mb': round(sum(v['dirty'] for v in malloc) / 2**20, 1),
            'malloc_reclaimable_mb': round(sum(v['reclaimable'] for v in malloc) / 2**20, 1),
            'vm_allocate_mb': round(cats.get('untagged (VM_ALLOCATE)', {}).get('dirty', 0) / 2**20, 1),
            'mapped_clean_mb': round(cats.get('mapped file', {}).get('clean', 0) / 2**20, 1),
            'rss_mb': round(int(ps[0]) / 1024, 1) if ps else None,
            'cpu': ps[1] if len(ps) > 1 else None,
        }
        self.samples.append(row)
        print(json.dumps(row), flush=True)
        if self.spike_mb and row['footprint_mb'] > self.spike_mb and self.spike_stack is None:
            self.spike_stack = capture_stack(self.pid, self.spike_path)
        return row

    def loop(self):
        while not self.stop.is_set():
            self.sample()
            self.stop.wait(self.interval)


class Churn:
    """Agent-shaped file activity whose live corpus stays bounded."""

    def __init__(self, root, tracked, rng):
        self.root, self.tracked, self.rng = root, tracked, rng
        self.n = 0
        self.scratch = root / 'soak'
        (self.scratch / 'tmp').mkdir(parents=True, exist_ok=True)
        self.unique = deque()
        self.edited = deque()
        self.ignored = [root / 'node_modules' / '.soak-cache', root / '.next' / 'cache', root / 'coverage' / 'tmp']
        for d in self.ignored:
            d.mkdir(parents=True, exist_ok=True)
        self.npm_burst = None
        self.branch = 'base'
        self.counts = dict.fromkeys(['rewrite', 'create', 'delete', 'rename', 'edit', 'restore', 'ignored', 'npm_burst', 'checkout'], 0)

    def tick(self):
        self.n += 1
        n = self.n
        (self.scratch / f'scratch_{n % 200}.ts').write_text(module_text(f'scratchGen{n}', 6))
        self.counts['rewrite'] += 1
        path = self.scratch / 'tmp' / f'run_{n}.ts'
        path.write_text(module_text(f'uniqueRun{n}', 4))
        self.unique.append(path)
        self.counts['create'] += 1
        if n % 4 == 0 and self.unique:
            old = self.unique.popleft()
            new = old.with_name(f'renamed_{n}.ts')
            os.replace(old, new)
            self.unique.append(new)
            self.counts['rename'] += 1
        while len(self.unique) > 40:
            self.unique.popleft().unlink(missing_ok=True)
            self.counts['delete'] += 1
        if n % 2 == 0:
            rel = self.rng.choice(self.tracked)
            target = self.root / rel
            if target.exists():
                with open(target, 'a') as f:
                    f.write(f'\nexport const soakEdit{n} = "{rel}:{n}";\n')
                self.edited.append(rel)
                self.counts['edit'] += 1
        while len(self.edited) > 20:
            git(self.root, 'checkout', '-q', '--', self.edited.popleft(), check=False)
            self.counts['restore'] += 1
        for d in self.ignored:
            f = d / f'chunk_{n % 64}.js'
            f.write_text(f'module.exports = {n};\n' * 20)
            (d / f'chunk_{(n + 32) % 64}.js').unlink(missing_ok=True)
            self.counts['ignored'] += 1

    def npm_install(self):
        if self.npm_burst and self.npm_burst.exists():
            shutil.rmtree(self.npm_burst)
        self.npm_burst = self.root / 'node_modules' / f'.soak-pkg-{self.n}'
        for d in range(40):
            pkg = self.npm_burst / f'pkg{d}' / 'lib'
            pkg.mkdir(parents=True)
            for f in range(50):
                (pkg / f'm{f}.js').write_text(f'exports.v{f} = {d};\n')
        self.counts['npm_burst'] += 1

    def checkout(self):
        self.branch = 'alt' if self.branch == 'base' else 'base'
        git(self.root, 'checkout', '-q', '-f', self.branch)
        self.edited.clear()
        self.counts['checkout'] += 1


class Queries:
    """One tool call per step, cycling through the read-side tool surface."""

    def __init__(self, proc, root, tracked, vocab, rng):
        self.p, self.root, self.tracked, self.vocab, self.rng = proc, root, tracked, vocab, rng
        self.hashes = {}
        self.seq = 0
        self.calls, self.errors, self.slow, self.stalls = {}, {}, [], []
        self.stall_path, self.stall_stack, self.t0 = None, None, time.monotonic()
        self.kinds = ['search', 'word', 'symbol', 'outline', 'read', 'read_range', 'context', 'explain',
                      'callers', 'find', 'hot', 'changes', 'bundle', 'deps', 'search_new', 'read', 'ls']

    def path(self):
        return self.rng.choice(self.tracked)

    def word(self):
        return self.rng.choice(self.vocab)

    def call(self, name, args, timeout=60):
        t = time.monotonic()
        r = self.p.call_tool(name, args, timeout=timeout)
        dt = time.monotonic() - t
        self.calls[name] = self.calls.get(name, 0) + 1
        if r is None:
            self.stalls.append({'tool': name, 'at': round(t - self.t0, 1)})
            if self.stall_path and self.stall_stack is None:
                self.stall_stack = capture_stack(self.p.proc.pid, self.stall_path)
        if r is None or r.get('error') or r.get('result', {}).get('isError'):
            self.errors[name] = self.errors.get(name, 0) + 1
        if dt > 5:
            self.slow.append({'tool': name, 'seconds': round(dt, 1)})
        return all_tool_text(r)

    def step(self, n):
        kind = self.kinds[n % len(self.kinds)]
        if kind == 'search':
            self.call('codedb_search', {'query': self.word(), 'max_results': 10})
        elif kind == 'search_new':
            self.call('codedb_search', {'query': f'uniqueRun{max(1, n - self.rng.randint(1, 30))}Step', 'max_results': 5})
        elif kind == 'word':
            self.call('codedb_word', {'word': self.word()})
        elif kind == 'symbol':
            self.call('codedb_symbol', {'name': self.word()})
        elif kind == 'outline':
            self.call('codedb_outline', {'path': self.path()})
        elif kind == 'read':
            rel = self.path()
            args = {'path': rel}
            if rel in self.hashes and self.rng.random() < 0.5:
                args['if_hash'] = self.hashes[rel]
            m = re.match(r'hash:([0-9a-f]+)', self.call('codedb_read', args))
            if m:
                self.hashes[rel] = m.group(1)
        elif kind == 'read_range':
            start = self.rng.randint(1, 80)
            self.call('codedb_read', {'path': self.path(), 'line_start': start, 'line_end': start + 40})
        elif kind == 'context':
            task = f'fix the bug where {self.word()} breaks {self.word()} when {self.word()} is empty'
            self.call('codedb_context', {'task': task, 'semantic': 'local' if n % 2 else 'hybrid'})
        elif kind == 'explain':
            self.call('codedb_explain', {'name': self.word()})
        elif kind == 'callers':
            self.call('codedb_callers', {'name': self.word()})
        elif kind == 'find':
            self.call('codedb_find', {'query': Path(self.path()).stem[:8]})
        elif kind == 'hot':
            self.call('codedb_hot', {'limit': 10})
        elif kind == 'changes':
            text = self.call('codedb_changes', {'since': self.seq})
            m = re.search(r'seq[^0-9]{0,12}(\d+)', text)
            if m:
                self.seq = int(m.group(1))
        elif kind == 'bundle':
            self.call('codedb_bundle', {'ops': [
                {'tool': 'codedb_symbol', 'arguments': {'name': self.word()}},
                {'tool': 'codedb_outline', 'arguments': {'path': self.path()}},
                {'tool': 'codedb_search', 'arguments': {'query': self.word(), 'max_results': 5}}]})
        elif kind == 'deps':
            self.call('codedb_deps', {'path': self.path()})
        elif kind == 'ls':
            self.call('codedb_ls', {'path': str(Path(self.path()).parent)})


def status_text(p):
    return all_tool_text(p.call_tool('codedb_status', {}, timeout=30))


def wait_ready(p, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        text = status_text(p)
        if 'scan: ready' in text.lower():
            return text
        time.sleep(1)
    raise RuntimeError('scan did not reach ready')


def slope_mb_per_min(rows):
    if len(rows) < 3:
        return None
    xs = [r['t'] / 60 for r in rows]
    ys = [r['footprint_mb'] for r in rows]
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return round(sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den, 2) if den else None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--binary', required=True)
    ap.add_argument('--source', required=True, help='repository to copy; never modified')
    ap.add_argument('--out', required=True)
    ap.add_argument('--minutes', type=float, default=12)
    ap.add_argument('--interval', type=float, default=15)
    ap.add_argument('--tick', type=float, default=0.5, help='seconds between churn steps')
    ap.add_argument('--checkout-every', type=float, default=60)
    ap.add_argument('--npm-every', type=float, default=45)
    ap.add_argument('--index-every', type=float, default=0, help='seconds between codedb_index calls (0 = never)')
    ap.add_argument('--settle', type=float, default=60)
    ap.add_argument('--seed', type=int, default=7)
    ap.add_argument('--alt-files', type=int, default=400)
    ap.add_argument('--cold', action='store_true', help='skip the warm-up server, measure a cold scan')
    ap.add_argument('--keep', action='store_true')
    ap.add_argument('--spike-mb', type=float, default=0, help='save one `sample` stack when footprint first exceeds this')
    ap.add_argument('--max-stalls', type=int, default=3, help='stop after this many timed-out tool calls')
    ap.add_argument('--server-env', action='append', default=[], metavar='KEY=VALUE',
                    help='extra env for the measured server only, e.g. MallocStackLogging=lite')
    args = ap.parse_args()
    out_path = Path(args.out).resolve()
    if out_path.exists():
        ap.error('use a new --out path')
    binary = str(Path(args.binary).resolve())
    rng = random.Random(args.seed)
    base = Path.home() / 'tmp'
    base.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='codedb-soak-', dir=base))
    root, home = work / 'repo', work / 'home'
    root.mkdir()
    home.mkdir()
    env = {
        'HOME': str(home), 'PATH': os.environ['PATH'], 'TMPDIR': os.environ.get('TMPDIR', '/tmp'),
        'CODEDB_NO_AUTO_UPDATE': '1', 'CODEDB_NO_TELEMETRY': '1', 'CODEDB_NO_CLI_DAEMON': '1',
        'CODEDB_NO_CODEX_POLICY': '1', 'CODEDB_EMBEDDINGS_URL': 'http://127.0.0.1:9/v1/embeddings',
        # Footprint follows the spawned pid; in shared mode that is the stdio forwarder.
        'CODEDB_MCP_SHARED': '0',
    }
    report = {'binary': binary, 'sha256': hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
              'source': args.source, 'args': vars(args), 'started': time.strftime('%Y-%m-%dT%H:%M:%S')}
    procs, fp = [], None
    try:
        t = time.monotonic()
        tracked = prepare_corpus(Path(args.source).resolve(), root, rng, args.alt_files)
        report['corpus'] = {'tracked_source_files': len(tracked), 'prepare_seconds': round(time.monotonic() - t, 1)}
        vocab = harvest_vocabulary(root, tracked, rng)
        if not args.cold:
            warm = MCPProcess(binary, [], str(root), command=[binary, 'mcp'], env=env)
            procs.append(warm)
            assert do_initialize(warm, with_roots=False), 'warm-up initialize failed'
            report['warmup_status'] = wait_ready(warm, 900)
            time.sleep(20)
            warm.close()
            procs.remove(warm)
        p = MCPProcess(binary, [], str(root), command=[binary, 'mcp'],
                       env=env | dict(kv.split('=', 1) for kv in args.server_env))
        procs.append(p)
        fp = Footprint(p.proc.pid, args.interval, work, args.spike_mb, out_path.with_suffix('.spike.txt'))
        fp.phase = 'startup'
        fp.thread.start()
        assert do_initialize(p, with_roots=False), 'initialize failed'
        report['ready_status'] = wait_ready(p, 900)
        report['ready_seconds'] = round(time.monotonic() - fp.t0, 1)
        fp.phase = 'settle'
        time.sleep(args.settle)
        churn = Churn(root, tracked, rng)
        queries = Queries(p, root, tracked, vocab, rng)
        queries.stall_path, queries.t0 = out_path.with_suffix('.stall.txt'), fp.t0
        fp.phase = 'soak'
        start = time.monotonic()
        deadline = start + args.minutes * 60
        next_checkout = start + args.checkout_every
        next_npm = start + args.npm_every / 2
        next_index = start + args.index_every if args.index_every else float('inf')
        n = 0
        while time.monotonic() < deadline:
            if p.proc.poll() is not None:
                raise RuntimeError(f'server exited with {p.proc.returncode}')
            if len(queries.stalls) >= args.max_stalls:
                report['aborted'] = f'{len(queries.stalls)} tool calls timed out'
                break
            n += 1
            churn.tick()
            now = time.monotonic()
            if now >= next_checkout:
                churn.checkout()
                next_checkout = now + args.checkout_every
            if now >= next_npm:
                churn.npm_install()
                next_npm = now + args.npm_every
            if now >= next_index:
                queries.call('codedb_index', {'path': str(root)}, timeout=600)
                next_index = time.monotonic() + args.index_every
            queries.step(n)
            fp.ops = n
            time.sleep(max(0.0, args.tick - (time.monotonic() - now)))
        fp.phase = 'quiet'
        report['final_status_soak'] = status_text(p)
        time.sleep(args.settle)
        report['final_status_quiet'] = status_text(p)
        fp.stop.set()
        fp.thread.join()
        fp.phase = 'end'
        fp.sample()
        report['churn'] = churn.counts
        report['calls'] = queries.calls
        report['call_errors'] = queries.errors
        report['slow_calls'] = queries.slow[:50]
        report['stalls'] = queries.stalls
        report['stall_stack'] = queries.stall_stack
        report['spike_stack'] = fp.spike_stack
        report['samples'] = fp.samples
        soak_rows = [r for r in fp.samples if r['phase'] == 'soak']
        report['summary'] = {
            'ready_footprint_mb': next((r['footprint_mb'] for r in fp.samples if r['phase'] == 'settle'), None),
            'soak_first_mb': soak_rows[0]['footprint_mb'] if soak_rows else None,
            'soak_last_mb': soak_rows[-1]['footprint_mb'] if soak_rows else None,
            'peak_mb': max(r['footprint_mb'] for r in fp.samples),
            'end_mb': fp.samples[-1]['footprint_mb'],
            'soak_slope_mb_per_min': slope_mb_per_min(soak_rows),
            'soak_second_half_slope_mb_per_min': slope_mb_per_min(soak_rows[len(soak_rows) // 2:]),
        }
        report['stderr_tail'] = p.stderr_lines()[-40:]
    finally:
        if fp is not None:
            fp.stop.set()
            report.setdefault('samples', fp.samples)
        for proc in procs:
            proc.close()
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=1))
    print(json.dumps(report.get('summary'), indent=1))


if __name__ == '__main__':
    main()
