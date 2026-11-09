#!/bin/bash
# Baut die Debug-App („HomeTune Test“, eigene Ordner) und startet sie angemeldet über die Startumgebung
# (Zugang aus .test-account, kein Schlüsselbund-Eintrag). DEMO=1 nimmt das Demo-Konto (nur Demodaten, für Screenshots).
#   ./run-mac.sh          DEMO=1 ./run-mac.sh
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .test-account; set +a
xcodegen generate -q
xcodebuild -project HomeTune.xcodeproj -scheme HomeTuneMac -configuration Debug -derivedDataPath build/mac-dd -quiet build 2>&1 \
  | grep -E "error:" || true
APP="build/mac-dd/Build/Products/Debug/HomeTune Test.app"
pkill -f "HomeTune Test.app/Contents/MacOS" || true
if [ "${DEMO:-0}" = "1" ]; then HOMETUNE_USER="$HOMETUNE_DEMO_USER"; HOMETUNE_PASSWORD="$HOMETUNE_DEMO_PASSWORD"; fi
HOMETUNE_SERVER="$HOMETUNE_SERVER" HOMETUNE_USER="$HOMETUNE_USER" HOMETUNE_PASSWORD="$HOMETUNE_PASSWORD" \
  nohup "$APP/Contents/MacOS/HomeTune Test" >/dev/null 2>&1 &
echo "gestartet (PID $!)"
