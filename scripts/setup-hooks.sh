#!/bin/zsh
# Setup script to install git hooks for the repository.
# Run this once after cloning to enable pre-commit testing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

echo "Setting up git hooks for aicoven-local-opensource..."

# Create hooks directory if it doesn't exist
mkdir -p "$HOOKS_DIR"

# Create pre-commit hook
cat > "$HOOKS_DIR/pre-commit" << 'EOF'
#!/bin/zsh
# Pre-commit hook that runs linting and tests before each commit.
# To skip this hook temporarily, use: git commit --no-verify

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "🔍 Running pre-commit checks..."

# Check if we have Swift files staged
STAGED_SWIFT=$(git diff --cached --name-only --diff-filter=ACM | grep '\.swift$' || true)

if [[ -z "$STAGED_SWIFT" ]]; then
  echo "✅ No Swift files staged, skipping checks."
  exit 0
fi

# Run SwiftFormat on staged files (if available)
if command -v swiftformat >/dev/null 2>&1; then
  echo "🎨 Running SwiftFormat..."
  echo "$STAGED_SWIFT" | while read -r file; do
    if [[ -f "$REPO_ROOT/$file" ]]; then
      swiftformat --cache ignore "$REPO_ROOT/$file"
      git add "$REPO_ROOT/$file"
    fi
  done
else
  echo "⚠️  swiftformat not found; skipping formatting."
fi

# Run SwiftLint (if available)
if command -v swiftlint >/dev/null 2>&1; then
  echo "🔎 Running SwiftLint..."
  cd "$REPO_ROOT"
  if ! swiftlint --quiet; then
    echo "❌ SwiftLint found issues. Please fix them before committing."
    exit 1
  fi
else
  echo "⚠️  swiftlint not found; skipping lint."
fi

echo "✅ Pre-commit checks passed!"
EOF

# Make the hook executable
chmod +x "$HOOKS_DIR/pre-commit"

echo "✅ Git hooks installed successfully!"
echo ""
echo "The pre-commit hook will now run SwiftFormat and SwiftLint on each commit."
echo "To skip the hook temporarily, use: git commit --no-verify"
echo ""
echo "For full lint/build/test, run: ./scripts/lint.sh"
