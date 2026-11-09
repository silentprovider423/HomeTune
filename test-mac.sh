#!/bin/bash
# Unit-Tests des gemeinsamen Kerns direkt auf dem Mac (ohne Simulator, ohne UI-Tests – Maus und Tastatur bleiben frei).
# Zugang aus der gitignorten Datei .test-account (wie test.sh).
#   ./test-mac.sh
#   ./test-mac.sh -only-testing:HomeTuneMacTests/TuningTests
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .test-account; set +a
xcodegen generate -q
export TEST_RUNNER_HOMETUNE_SERVER="$HOMETUNE_SERVER" TEST_RUNNER_HOMETUNE_USER="$HOMETUNE_USER" \
  TEST_RUNNER_HOMETUNE_PASSWORD="$HOMETUNE_PASSWORD" TEST_RUNNER_HOMETUNE_DEMO_USER="$HOMETUNE_DEMO_USER" \
  TEST_RUNNER_HOMETUNE_DEMO_PASSWORD="$HOMETUNE_DEMO_PASSWORD"
xcodebuild test -project HomeTune.xcodeproj -scheme HomeTuneMac -destination 'platform=macOS' -derivedDataPath build/mac-dd "$@"
