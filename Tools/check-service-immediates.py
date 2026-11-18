#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1
"""D4-20: find short names that a compiled service builds from immediates, for Tools/check-service-strings.sh.

  check-service-immediates.py DISASSEMBLY NAME...     DISASSEMBLY is `otool -tV` text; prints FOUND:<name> or MISSING:<name> for each

A Swift string of 15 bytes or fewer is not kept in the file's string table: the compiler builds it from `mov` / `movk` immediates
of 16 bits each (and compares it the same way), so `strings` cannot see it. A name is FOUND when every 16-bit piece of its bytes
is among the immediates close to each other (the second half of a small string goes in another register, set before or after).
arm64 only; other instruction sets find nothing, which the strings check reports as a missing name in a service that has the ops.
"""
import re
import sys

lines = open(sys.argv[1], errors="replace").read().split("\n")
# every mov / movk / movz with an immediate, in order: (line index, 16-bit value)
immediates = []
for index, line in enumerate(lines):
    match = re.search(r"\bmov[zk]?\s+[wx]\d+, #0x([0-9a-f]+)\b", line)
    if match:
        immediates.append((index, int(match.group(1), 16)))

def pieces(name):
    data = name.encode()
    return [data[i] | ((data[i + 1] if i + 1 < len(data) else 0) << 8) for i in range(0, len(data), 2)]

for name in sys.argv[2:]:
    wanted = pieces(name)
    found = False
    for position, (index, value) in enumerate(immediates):
        if value != wanted[0]:
            continue
        # the rest of the name's pieces are near (the second half of a small string goes in another register, set before or after)
        window = {v for i, v in immediates[max(0, position - 8):position + 14] if abs(i - index) <= 16}
        if all(piece in window for piece in wanted):
            found = True
            break
    print(("FOUND:" if found else "MISSING:") + name)
