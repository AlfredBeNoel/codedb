#!/bin/zsh
# Usage: profile.sh <name> <codedb-binary> <isolated-home> [mcpprobe mem args...]
# Needs an unstripped binary. HIGHWATER=1 adds the peak (high-water mark) call tree.
set -u
here=${0:A:h}
work=${MEMFOOT_DIR:-${here:h:h}/logs/memfoot}
root=${MEMFOOT_ROOT:?set MEMFOOT_ROOT to the repo to profile}
py=${MEMFOOT_PY:-python3}
name=$1; bin=$2; home=$3; shift 3
out=$work/prof/$name
mkdir -p $out $work/msl
$py -I $here/mcpprobe.py mem --bin $bin --root $root --home $home --out $out/probe.json --stderr $out/server.stderr \
  --vmmap-out $out/vmmap-summary.txt --label $name --hold 600 \
  --env "{\"MallocStackLogging\":\"full\",\"MallocStackLoggingDirectory\":\"$work/msl\"}" "$@" 2> $out/probe.stderr &
probe=$!
for i in {1..1200}; do
  grep -q "holding pid" $out/probe.stderr 2>/dev/null && break
  sleep 0.5
done
pid=$(sed -n 's/.*holding pid \([0-9]*\).*/\1/p' $out/probe.stderr)
echo "pid=$pid"
vmmap $pid > $out/vmmap-full.txt 2>&1
malloc_history $pid -callTree -ignoreThreads -q > $out/calltree.txt 2>&1
malloc_history $pid -callTree -invert -ignoreThreads -q > $out/calltree-inverted.txt 2>&1
if [[ -n "${HIGHWATER:-}" ]]; then
  malloc_history $pid -highWaterMark -callTree -ignoreThreads -q > $out/highwater.txt 2>&1
fi
grep -E "^MALLOC_LARGE \(empty\)" $out/vmmap-full.txt | awk '{print $3}' | cut -d- -f1 | head -40 > $out/empty-addrs.txt
if [[ -s $out/empty-addrs.txt ]]; then
  malloc_history $pid $(sed 's/^/0x/' $out/empty-addrs.txt | tr '\n' ' ') -q > $out/empty-history.txt 2>&1
fi
kill $pid 2>/dev/null
wait $probe
rm -rf $work/msl/*
pgrep -fl "$bin" || echo "no leftover"
ls -la $out
