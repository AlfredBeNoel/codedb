#!/usr/bin/env python3
"""Posting-list statistics for a word.index file, plus the posting bytes behind sample files."""
import mmap, struct, sys, re
path = sys.argv[1]
f = open(path, 'rb'); d = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
assert d[0:4] == b'CDBW'
fc = struct.unpack_from('<I', d, 6)[0]
off = 51
paths = []
for _ in range(fc):
    pl = struct.unpack_from('<H', d, off)[0]; off += 2
    paths.append(d[off:off+pl].decode('utf-8', 'replace')); off += pl
wc = struct.unpack_from('<I', d, off)[0]; off += 4
counts = []
words = {}
unsorted = 0
for _ in range(wc):
    wl = struct.unpack_from('<H', d, off)[0]; off += 2
    w = d[off:off+wl]; off += wl
    hc = struct.unpack_from('<I', d, off)[0]; off += 4
    counts.append(hc)
    words[w] = (off, hc)
    # check sortedness by doc id
    prev = -1
    for i in range(0, min(hc, 64)):
        doc = struct.unpack_from('<I', d, off + 8*i)[0]
        if doc < prev: unsorted += 1; break
        prev = doc
    off += 8*hc
tot = sum(counts)
print('files', fc, 'words', wc, 'hits', tot, 'hit bytes MiB', round(tot*8/2**20,1), 'unsorted(first64)', unsorted)
cs = sorted(counts, reverse=True)
for n in (10, 100, 1000, 10000, 100000):
    print('top', n, 'share %.1f%%' % (100*sum(cs[:n])/tot), 'MiB', round(sum(cs[:n])*8/2**20,1))
small = sum(1 for c in counts if c <= 16)
print('lists with <=16 hits', small, '(%.1f%%)' % (100*small/wc))
# estimated heap form cost: arm64 ArrayList min capacity 16, growth +50%+16
def cap(n):
    c = 0
    while c < n: c += c//2 + 16
    return c
heap = sum(cap(c)*8 for c in counts)
print('heap list capacity MiB (pre-shrink)', round(heap/2**20,1))
# sample file: words contained
for sample in sys.argv[2:]:
    content = open(sample, 'rb').read()
    toks = set(t.lower() for t in re.findall(rb'[A-Za-z_][A-Za-z0-9_]+', content))
    s = sum(words[t][1] for t in toks if t in words)
    print(sample.split('/')[-1], 'distinct tokens', len(toks), 'their posting MiB', round(s*8/2**20,1))
