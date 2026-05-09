#!/bin/zsh
set -euo pipefail

# Run formatting, linting, and build/tests for the AICoven Xcode project.
# This is used by both local git hooks and CI.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# 1) SwiftFormat (if available) - auto-format code
if command -v swiftformat >/dev/null 2>&1; then
  echo "Running swiftformat..."
  # Ignore disk cache so results match CI (`swiftformat … --lint --cache ignore`).
  swiftformat swift/AICoven --cache ignore
else
  echo "swiftformat not found; skipping formatting. Install via Homebrew (brew install swiftformat) to enable."
fi

# 2) SwiftLint (if available) - static analysis
if command -v swiftlint >/dev/null 2>&1; then
  echo "Running swiftlint..."
  swiftlint --quiet
else
  echo "swiftlint not found; skipping lint. Install via Homebrew (brew install swiftlint) to enable."
fi

# 3) Build the main scheme in Debug configuration. This will fail on compiler errors.
echo "Building AICoven (Debug, code signing disabled)..."
xcodebuild \
  -project "swift/AICoven/AICoven Local.xcodeproj" \
  -scheme AICoven \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build

# 4) Run the test suite so CI and local hooks execute all XCTest cases.
# We only attempt this when the AICoven.xctestplan has at least one test
# target configured; otherwise Xcode will report that the scheme is not
# configured for testing. This way, as soon as you wire tests into the
# plan in Xcode, CI will start running them automatically.
PLAN_PATH="swift/AICoven/AICovenTests/AICoven.xctestplan"
if [[ -f "$PLAN_PATH" && $(grep -c '"target"' "$PLAN_PATH") -gt 0 ]]; then
  echo "Running AICoven tests (Debug, macOS, code signing disabled)..."
  xcodebuild \
    -project "swift/AICoven/AICoven Local.xcodeproj" \
    -scheme AICoven \
    -configuration Debug \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    test
else
  echo "No XCTest targets configured in $PLAN_PATH; skipping tests. Add test targets to the plan in Xcode to enable CI tests."
fi
