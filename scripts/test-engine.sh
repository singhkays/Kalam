#!/usr/bin/env bash
# Run the KalamTextEngine SwiftPM tests without Xcode.
#
# These tests cover the deterministic cleanup pipeline (fillers, backtrack,
# list formatting, punctuation) and dictionary compilation/case mimicry.
# They use Swift Testing (@Test / #expect) and run via `swift test` — no
# .xcodeproj, no AppKit, no NSSpellChecker, no XCTest dependency on Xcode.
#
# Usage:
#   ./scripts/test-engine.sh
#   SWIFT_TOOLCHAIN=/path/to/swift ./scripts/test-engine.sh

set -euo pipefail

# Resolve the repo root from the script location (handles symlinks too).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="$REPO_ROOT/app/Packages/KalamTextEngine"

if [[ ! -d "$PKG_DIR" ]]; then
  echo "error: KalamTextEngine package not found at: $PKG_DIR" >&2
  exit 1
fi

# Pick the Swift toolchain. Prefer an explicit override, then the Homebrew
# Swift formula (which bundles XCTest/Swift Testing), then fall back to
# whatever `swift` is on PATH (Apple CLT's swift lacks XCTest and will fail
# with "no such module 'XCTest'" — install `brew install swift` to fix).
if [[ -n "${SWIFT_TOOLCHAIN:-}" ]]; then
  SWIFT_BIN="$SWIFT_TOOLCHAIN/swift"
elif [[ -x "/opt/homebrew/opt/swift/bin/swift" ]]; then
  SWIFT_BIN="/opt/homebrew/opt/swift/bin/swift"
elif command -v swift &>/dev/null; then
  SWIFT_BIN="$(command -v swift)"
else
  echo "error: no 'swift' found. Install with: brew install swift" >&2
  echo "       or set SWIFT_TOOLCHAIN=/path/to/swift/bin" >&2
  exit 1
fi

echo "Using Swift: $SWIFT_BIN"
"$SWIFT_BIN" --version | head -1
echo "Package: $PKG_DIR"
echo "---"

cd "$PKG_DIR"
exec "$SWIFT_BIN" test
