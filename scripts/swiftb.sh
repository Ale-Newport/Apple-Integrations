#!/bin/zsh
# Runs `swift build` and prints only diagnostics (errors/warnings, de-duplicated, without compiler command lines).
# Usage: scripts/swiftb.sh build [--target X]
out=$(swift "$@" 2>&1); code=$?
echo "$out" | python3 -I -c '
import re, sys
text = re.sub(r"\x1b\][^\x1b]*\x1b\\", "", re.sub(r"\x1b\[[0-9;]*m", "", sys.stdin.read()))
seen = set()
for m in re.finditer(r"^(/[^\n]*\.swift:\d+:\d+: (?:error|warning): [^\n]*)$", text, re.M):
    line = m.group(1).replace("/Users/alejandro/Projects/Apple-Integrations/", "")
    if line not in seen:
        seen.add(line); print(line[:400])
for m in re.finditer(r"(Build complete[^\n]*|error: Build failed|^error: [^\n]*)", text, re.M):
    if "SwiftCompile" in m.group(1) or "Command line" in m.group(1): continue
    print(m.group(1)[:300])
'
exit $code
