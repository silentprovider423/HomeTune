#!/bin/bash
# Legt die Testdateien (Tests/Fixtures/LocalMusic, erfundene Titel) im Simulator unter
# „Dateien → Auf meinem iPhone → HomeTune Demo“ ab – für den UI-Test, der den echten Dateien-Dialog bedient.
#   SIM=<UDID> ./tools/sim-files.sh          danach: TEST_RUNNER_PICKER=1 SIM=<UDID> ./test.sh -only-testing:HomeTuneUITests/LocalMusicFlowTests
#   SIM=<UDID> ./tools/sim-files.sh --remove  wieder entfernen
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIM:?SIM=<Simulator-UDID> setzen}"
xcrun simctl bootstatus "$SIM" -b >/dev/null
G=$(xcrun simctl get_app_container "$SIM" com.apple.DocumentsApp groups | awk -F'\t' '$1 ~ /group.com.apple.FileProvider.LocalStorage/ {print $2}')
[ -n "$G" ] || { echo "Speicher „Auf meinem iPhone“ nicht gefunden"; exit 1; }
dest="$G/File Provider Storage/HomeTune Demo"
rm -rf "$dest"
[ "${1:-}" = "--remove" ] && { echo "entfernt"; exit 0; }
mkdir -p "$dest"
cp -R Tests/Fixtures/LocalMusic/. "$dest/"
echo "Testdateien liegen in „Auf meinem iPhone/HomeTune Demo“"
