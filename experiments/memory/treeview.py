#!/usr/bin/env python3
"""Print malloc_history -callTree lines above a size threshold, with depth limit."""
import re, sys

UNITS = {"": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30}

def parse_size(tok):
    m = re.match(r"([\d.]+)([KMG]?)", tok)
    return float(m.group(1)) * UNITS[m.group(2)]

def main(path, min_mb, max_depth):
    started = False
    for line in open(path, errors="replace"):
        if line.startswith("Call graph:"):
            started = True
            continue
        if not started:
            continue
        m = re.match(r"^(\s*[+!:| ]*)(\d+) \(([\d.]+[KMG]?)\) (.*)$", line.rstrip())
        if not m:
            continue
        depth = len(m.group(1)) // 2
        size = parse_size(m.group(3))
        if size < min_mb * (1 << 20) or depth > max_depth:
            continue
        frame = re.sub(r"\s+\(in [^)]*\)", "", m.group(4))
        frame = re.sub(r"\s+\[0x[0-9a-f]+\]", "", frame)
        print("%s%s (%s) %s" % ("  " * depth, m.group(2), m.group(3), frame[:150]))

if __name__ == "__main__":
    main(sys.argv[1], float(sys.argv[2]), int(sys.argv[3]))
