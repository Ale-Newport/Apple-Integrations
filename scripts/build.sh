#!/bin/zsh
# Builds the app with xcodebuild and prints a short digest (errors, warnings, result, product path).
#
#   scripts/build.sh                 Debug build
#   scripts/build.sh Release         Release build
#   scripts/build.sh Debug test      Build and run the unit tests
#
# The full log is kept in build/xcodebuild-<action>.log.
set -u
cd "$(dirname "$0")/.."

configuration="${1:-Debug}"
action="${2:-build}"
derived="build/DerivedData"
log="build/xcodebuild-${action}.log"
mkdir -p build

# Regenerate the project (fast and deterministic) so new or removed source files are picked up.
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet || exit 1
fi

xcodebuild \
  -project JarvisAppleIntegrations.xcodeproj \
  -scheme JarvisAppleIntegrations \
  -configuration "$configuration" \
  -derivedDataPath "$derived" \
  -destination 'platform=macOS' \
  "$action" > "$log" 2>&1
rc=$?

strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*[a-zA-Z]//g'; }

echo "── diagnostics ──"
grep -a -E "(error|warning):" "$log" | strip_ansi | grep -a -v "CoreSimulator is out of date" | grep -a -E "^/|^[a-zA-Z]+:" | sort -u | head -80
if [[ "$action" == "test" ]]; then
  echo "── tests ──"
  result_bundle=$(sed -n 's/^[[:space:]]*\(.*\.xcresult\)[[:space:]]*$/\1/p' "$log" | tail -1)
  summary=$(xcrun xcresulttool get test-results summary --path "$result_bundle" --compact 2>/dev/null)
  if [[ -n "$summary" ]]; then
    printf '%s' "$summary" | python3 -c 'import json,sys; s=json.load(sys.stdin); print("  Total: {} · Passed: {} · Failed: {} · Skipped: {}".format(s["totalTestCount"],s["passedTests"],s["failedTests"],s["skippedTests"]))'
  else
    # Parallel test bundles interleave their output, so adjacent Executed lines cannot be attributed reliably.
    strip_ansi < "$log" | grep -a -E "^Test Suite .*\.xctest. (passed|failed)"
  fi
fi
echo "── result ──"
grep -a -E "\*\* (BUILD|TEST) (SUCCEEDED|FAILED) \*\*" "$log" | strip_ansi | tail -2
if [[ $rc -eq 0 && "$action" == "build" ]]; then
  echo "product: $derived/Build/Products/$configuration/Jarvis Apple Integrations.app"
fi
exit $rc
