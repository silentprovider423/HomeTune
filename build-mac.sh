#!/bin/bash
# Baut die Mac-App (Release, ad hoc signiert) aus einem neutralen Klon unter /private/tmp/hrb/…, damit keine
# Pfade oder Namen des Bau-Rechners in die App gelangen. Gebaut wird der zuletzt committete Stand.
# Ergebnis: build-mac/HomeTune.app und build-mac/HomeTune-mac.zip
#   ./build-mac.sh             bauen
#   ./build-mac.sh --install   bauen und nach /Applications/HomeTune.app kopieren
set -euo pipefail
cd "$(dirname "$0")"
REPO="$PWD"
mkdir -p /private/tmp/hrb
WORK=$(mktemp -d /private/tmp/hrb/hometune.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
git clone -q "$REPO" "$WORK/src"
cd "$WORK/src"
xcodegen generate -q
xcodebuild -project HomeTune.xcodeproj -scheme HomeTuneMac -configuration Release -derivedDataPath "$WORK/dd" \
  CODE_SIGN_IDENTITY="-" OTHER_SWIFT_FLAGS="-file-prefix-map $PWD=." OTHER_CFLAGS="-ffile-prefix-map=$PWD=." \
  STRIP_INSTALLED_PRODUCT=YES DEPLOYMENT_POSTPROCESSING=YES STRIP_STYLE=non-global -quiet build 2>&1 \
  | grep -vE "appintentsmetadataprocessor|Metadata extraction skipped" || true
APP="$WORK/dd/Build/Products/Release/HomeTune.app"
[ -d "$APP" ] || { echo "FEHLER: $APP nicht gefunden"; exit 1; }
codesign -f -s - "$APP"
# Spuren-Prüfung: kein Benutzername, kein Home-Pfad, kein voller Name, kein Rechnername in der App.
# Zusätzliche eigene Muster (eins pro Zeile) können in einer Datei außerhalb des Repos stehen: $TRACE_PATTERNS
TRACES=(-e "$USER" -e "$HOME")
FULL=$(id -F 2>/dev/null || true); [ -n "$FULL" ] && TRACES+=(-e "$FULL")
HOST=$(scutil --get LocalHostName 2>/dev/null || true); [ -n "$HOST" ] && TRACES+=(-e "$HOST")
if grep -raqiF "${TRACES[@]}" "$APP"; then
  echo "FEHLER: Benutzername, Home-Pfad oder Rechnername in der App."; exit 1
fi
if [ -n "${TRACE_PATTERNS:-}" ] && [ -f "$TRACE_PATTERNS" ] && grep -raqiE -f "$TRACE_PATTERNS" "$APP"; then
  echo "FEHLER: private Kennung in der App."; exit 1
fi
cd "$REPO"
rm -rf build-mac; mkdir build-mac
ditto "$APP" build-mac/HomeTune.app
(cd build-mac && ditto -c -k --keepParent HomeTune.app HomeTune-mac.zip)
codesign --verify --strict build-mac/HomeTune.app
if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/HomeTune.app
  ditto build-mac/HomeTune.app /Applications/HomeTune.app
  echo "Installiert: /Applications/HomeTune.app"
fi
echo "Fertig: build-mac/HomeTune.app (+ HomeTune-mac.zip)"
