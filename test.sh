#!/bin/bash
# Unit- und UI-Tests im eigenen Simulator gegen ein Test-Navidrome.
# Zugang aus der gitignorten Datei .test-account (HOMESPIN_SERVER, HOMESPIN_USER, HOMESPIN_PASSWORD,
# HOMESPIN_DEMO_USER, HOMESPIN_DEMO_PASSWORD) – nie committen.
#   SIM=<UDID> ./test.sh            alle Tests
#   SIM=<UDID> ./test.sh -only-testing:HomeSpinTests/Tuning432Tests
set -euo pipefail
cd "$(dirname "$0")"
: "${SIM:?SIM=<Simulator-UDID> setzen}"
set -a; source .test-account; set +a
xcodegen generate -q
export TEST_RUNNER_HOMESPIN_SERVER="$HOMESPIN_SERVER" TEST_RUNNER_HOMESPIN_USER="$HOMESPIN_USER" \
  TEST_RUNNER_HOMESPIN_PASSWORD="$HOMESPIN_PASSWORD" TEST_RUNNER_HOMESPIN_DEMO_USER="$HOMESPIN_DEMO_USER" \
  TEST_RUNNER_HOMESPIN_DEMO_PASSWORD="$HOMESPIN_DEMO_PASSWORD"
xcodebuild test -project HomeSpin.xcodeproj -scheme HomeSpin -destination "id=$SIM" -derivedDataPath build "$@"
