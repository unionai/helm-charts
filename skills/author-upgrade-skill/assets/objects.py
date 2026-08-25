#!/usr/bin/env python3
"""Reduce a rendered Helm manifest stream to a sorted, deduplicated Kind/name list.

Used by render-diff.sh. Deliberately does not depend on a YAML library: it splits on
document separators and reads the first top-level `kind:` plus the `name:` under the
first top-level `metadata:` block. Anything nested deeper -- roleRef targets, embedded
templates inside ConfigMap data -- is ignored, which is the point.

Usage: objects.py <rendered-manifest.yaml>
"""

import re
import sys


def objects(path):
    docs, cur = [], []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.rstrip("\n") == "---" or line.startswith("--- "):
                docs.append(cur)
                cur = []
            else:
                cur.append(line)
    docs.append(cur)

    found = []
    for doc in docs:
        kind = name = None
        in_meta = False
        for line in doc:
            if line.startswith("kind:"):
                kind = line.split(":", 1)[1].strip().strip("'\"")
            elif line.startswith("metadata:"):
                in_meta = True
            elif in_meta and re.match(r"^\s{1,2}name:", line):
                name = line.split(":", 1)[1].strip().strip("'\"")
                in_meta = False
            elif in_meta and re.match(r"^[a-zA-Z]", line):
                in_meta = False
        if kind and name:
            found.append(f"{kind}/{name}")
    return sorted(set(found))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: objects.py <rendered-manifest.yaml>")
    for obj in objects(sys.argv[1]):
        print(obj)
