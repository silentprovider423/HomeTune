#!/bin/bash
# Baut die App und startet sie in einem Simulator, angemeldet über die Startumgebung (kein Passwort-Tippen).
# Zugang aus der gitignorten Datei .test-account (HOMESPIN_SERVER, HOMESPIN_USER, HOMESPIN_PASSWORD).
#   SIM=<UDID> ./sim-run.sh
set -euo pipefail
cd "$(dirname "$0")"
: "${SIM:?SIM=<Simulator-UDID> setzen}"
set -a; source .test-account; set +a
xcodegen generate -q
xcodebuild -project HomeSpin.xcodeproj -scheme HomeSpin -destination "id=$SIM" -derivedDataPath build -quiet build 2>&1 \
  | grep -E "error:|warning: unre" || true
xcrun simctl install "$SIM" build/Build/Products/Debug-iphonesimulator/HomeSpin.app
SIMCTL_CHILD_HOMESPIN_SERVER="$HOMESPIN_SERVER" SIMCTL_CHILD_HOMESPIN_USER="$HOMESPIN_USER" \
SIMCTL_CHILD_HOMESPIN_PASSWORD="$HOMESPIN_PASSWORD" \
  xcrun simctl launch --terminate-running-process "$SIM" org.homeroll.homespin >/dev/null
echo "gestartet"
