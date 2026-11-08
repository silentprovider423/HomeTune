#!/bin/bash
# Baut die App und startet sie in einem Simulator, angemeldet über die Startumgebung (kein Passwort-Tippen).
# Zugang aus der gitignorten Datei .test-account (HOMETUNE_SERVER, HOMETUNE_USER, HOMETUNE_PASSWORD).
#   SIM=<UDID> ./sim-run.sh
set -euo pipefail
cd "$(dirname "$0")"
: "${SIM:?SIM=<Simulator-UDID> setzen}"
set -a; source .test-account; set +a
xcodegen generate -q
xcodebuild -project HomeTune.xcodeproj -scheme HomeTune -destination "id=$SIM" -derivedDataPath build -quiet build 2>&1 \
  | grep -E "error:|warning: unre" || true
xcrun simctl install "$SIM" build/Build/Products/Debug-iphonesimulator/HomeTune.app
SIMCTL_CHILD_HOMETUNE_SERVER="$HOMETUNE_SERVER" SIMCTL_CHILD_HOMETUNE_USER="$HOMETUNE_USER" \
SIMCTL_CHILD_HOMETUNE_PASSWORD="$HOMETUNE_PASSWORD" \
  xcrun simctl launch --terminate-running-process "$SIM" org.homeroll.hometune >/dev/null
echo "gestartet"
