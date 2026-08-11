#!/bin/bash
# Real-model Parakeet smoke tests (RealModelSmokeTests).
#
# Loads the actual CoreML Parakeet model folders and transcribes a fixed
# TTS fixture, verifying the FluidAudio 0.15.5 load path end-to-end with
# ModelHub.offlineMode enforced (no network entitlement).
#
# Requirements:
#   - macOS with Xcode
#   - Model folders in <repo>/Models/ (parakeet-tdt-0.6b-v2/-v3/-ctc-110m),
#     or another directory via KALAM_MODEL_LIBRARY
#   - fixtures/dictation_fixture.wav (already committed)
#
# Exit codes: 0 = all smoke tests passed, 1 = failures, 2 = nothing ran
# (models/fixture missing — tests skipped, suite otherwise green).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KALAM_MODEL_LIBRARY="${KALAM_MODEL_LIBRARY:-$ROOT/Models}"
LOG="${TMPDIR:-/tmp}/parakeet-smoke.log"
REPORT="/tmp/parakeet-smoke-report.txt"
rm -f "$REPORT"

cd "$ROOT"
echo "Model library: $KALAM_MODEL_LIBRARY"

xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:KalamTests/RealModelSmokeTests 2>&1 | tee "$LOG" \
  | grep -E "Test case|Test Suite|TEST|skipped|error:" || true

echo "---"
if [ -f "$REPORT" ]; then
  echo "=== transcription evidence ==="
  cat "$REPORT"
else
  echo "(no transcription report — all tests skipped or failed before transcribing)"
fi
passed=$(grep -c "RealModelSmokeTests.*passed" "$LOG" || true)
failed=$(grep -c "RealModelSmokeTests.*failed" "$LOG" || true)
skipped=$(grep -c "RealModelSmokeTests.*skipped" "$LOG" || true)
echo "smoke results: passed=$passed failed=$failed skipped=$skipped"

if [ "$failed" -gt 0 ]; then
  echo "FAIL: $failed smoke test(s) failed"
  exit 1
fi
if [ "$passed" -eq 0 ]; then
  echo "NO SMOKE TESTS RAN: models or fixture missing (see skip messages above)"
  exit 2
fi
echo "PASS: $passed smoke test(s) green"
exit 0
