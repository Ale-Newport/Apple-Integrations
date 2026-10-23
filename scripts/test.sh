#!/bin/zsh
# Runs every automated test: the Swift package suites (fast, `swift test`) and the full Xcode scheme
# (the app tests plus the same package suites, through xcodebuild).
#
#   scripts/test.sh          both
#   scripts/test.sh package  only `swift test`
#   scripts/test.sh xcode    only `xcodebuild test`
#
# The tests use fake integrations and in-memory backends and never touch your data.
# For checks against the real Apple apps see scripts/live_tests.py.
set -u
cd "$(dirname "$0")/.."
what="${1:-all}"
rc=0
if [[ "$what" == "all" || "$what" == "package" ]]; then
  echo "══ swift test ══"
  scripts/swifttest.sh || rc=1
fi
if [[ "$what" == "all" || "$what" == "xcode" ]]; then
  echo "══ xcodebuild test ══"
  scripts/build.sh Debug test || rc=1
fi
exit $rc
