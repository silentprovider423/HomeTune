#!/bin/bash
# Unit- und UI-Tests im eigenen Simulator gegen ein Test-Navidrome.
# Zugang aus der gitignorten Datei .test-account (HOMETUNE_SERVER, HOMETUNE_USER, HOMETUNE_PASSWORD,
# HOMETUNE_DEMO_USER, HOMETUNE_DEMO_PASSWORD) – nie committen.
#   SIM=<UDID> ./test.sh            alle Tests
#   SIM=<UDID> ./test.sh -only-testing:HomeTuneTests/TuningTests
set -euo pipefail
cd "$(dirname "$0")"
: "${SIM:?SIM=<Simulator-UDID> setzen}"
set -a; source .test-account; set +a
xcodegen generate -q
export TEST_RUNNER_HOMETUNE_SERVER="$HOMETUNE_SERVER" TEST_RUNNER_HOMETUNE_USER="$HOMETUNE_USER" \
  TEST_RUNNER_HOMETUNE_PASSWORD="$HOMETUNE_PASSWORD" TEST_RUNNER_HOMETUNE_DEMO_USER="$HOMETUNE_DEMO_USER" \
  TEST_RUNNER_HOMETUNE_DEMO_PASSWORD="$HOMETUNE_DEMO_PASSWORD"
xcodebuild test -project HomeTune.xcodeproj -scheme HomeTune -destination "id=$SIM" -derivedDataPath build "$@"
