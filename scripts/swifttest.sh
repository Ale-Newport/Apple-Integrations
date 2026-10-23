#!/bin/zsh
# Runs `swift test` and prints a compact digest: one block per failing test (first messages only) plus totals.
# Usage: scripts/swifttest.sh [--filter Name]
out=$(swift test "$@" 2>&1); code=$?
echo "$out" | python3 -I -c '
import re, sys
text = re.sub(r"\x1b\][^\x1b]*\x1b\\", "", re.sub(r"\x1b\[[0-9;]*m", "", sys.stdin.read()))
fails = {}
order = []
for m in re.finditer(r"^(?P<file>/[^\n]*?):(?P<line>\d+): error: -\[(?P<test>[^\]]+)\] : (?P<msg>[^\n]*)$", text, re.M):
    key = m.group("test").split(" ")[-1] if " " in m.group("test") else m.group("test")
    if key not in fails:
        fails[key] = []
        order.append(key)
    fails[key].append((m.group("file").split("/")[-1], m.group("line"), m.group("msg")))
for key in order:
    print("✘", key)
    for f, l, msg in fails[key][:3]:
        msg = msg.replace("JarvisCore.JSONValue.", "")
        print("    %s:%s %s" % (f, l, msg[:300]))
    if len(fails[key]) > 3:
        print("    … %d more" % (len(fails[key]) - 3))
seen = set()
for m in re.finditer(r"(Fatal error[^\n]*|exited with unexpected signal[^\n]*|^/[^\n]*\.swift:\d+:\d+: (?:error|warning): [^\n]*)", text, re.M):
    line = m.group(1)[:320].replace("/Users/alejandro/Projects/Apple-Integrations/", "")
    if " -module-name " in line or "swift-frontend" in line:
        continue
    if line not in seen:
        seen.add(line)
        print(line)
totals = re.findall(r"Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\)", text)
if totals:
    tests = max(int(t[0]) for t in totals)
    print("Executed up to %d tests; failing tests: %d" % (tests, len(order)))
elif not order:
    print(text[-1500:])
'
exit $code
