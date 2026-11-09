#!/bin/bash
# Erzeugt eine große synthetische Musiksammlung für Import-Messungen (erfundene Titel, kurze Sinustöne,
# je Album ein eigenes Cover mit Rauschen, damit es nicht winzig komprimiert). Aufbau wie eine echte
# Sammlung im HomeTune-Ordner: <Ordner>/<Album>/<Nr Titel>.flac plus einige .m3u-Playlists.
#   ./tools/make-bulk-library.sh <ziel> [alben=200] [titel je album=12]
# Wird nicht eingecheckt (Ziel z. B. im Scratch-Ordner). Messung: ImportBenchmarkTests (HOMETUNE_BULK_DIR).
set -euo pipefail
OUT=${1:?Zielordner angeben}; ALBUMS=${2:-200}; TRACKS=${3:-12}
FF=(ffmpeg -hide_banner -loglevel error -y)
mkdir -p "$OUT"; TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
for a in $(seq 1 "$ALBUMS"); do
  dir="$OUT/Collection $(( (a - 1) / 50 + 1 ))/Album $a"
  mkdir -p "$dir"
  # 800×800-Cover mit Rauschen (~150 kB wie ein typisches eingebettetes Cover)
  "${FF[@]}" -f lavfi -i "color=c=0x$(printf '%06X' $((a * 2654435761 % 16777216))):s=800x800:d=1,noise=alls=40:allf=t" \
    -frames:v 1 -q:v 3 "$TMP/c.jpg"
  "${FF[@]}" -f lavfi -i "sine=frequency=$((200 + a)):sample_rate=44100:duration=1" -i "$TMP/c.jpg" \
    -map 0:a -map 1:v -c:a flac -c:v copy -disposition:v attached_pic \
    -metadata album="Album $a" -metadata artist="Artist $(( a % 37 + 1 ))" -metadata album_artist="Artist $(( a % 37 + 1 ))" \
    -metadata date="$(( 1970 + a % 50 ))" -metadata genre="Genre $(( a % 9 + 1 ))" "$TMP/base.flac"
  for t in $(seq 1 "$TRACKS"); do
    f="$dir/$(printf '%02d' "$t") Track $t of Album $a.flac"
    cp "$TMP/base.flac" "$f"
    metaflac --set-tag="TITLE=Track $t of Album $a" --set-tag="TRACKNUMBER=$t" "$f"
  done
done
# Playlists: je 100 Einträge quer durch die Sammlung
mkdir -p "$OUT/Playlists"
for p in $(seq 1 10); do
  {
    echo "#EXTM3U"
    for i in $(seq 1 100); do
      a=$(( (p * 37 + i * 13) % ALBUMS + 1 )); t=$(( i % TRACKS + 1 ))
      echo "../Collection $(( (a - 1) / 50 + 1 ))/Album $a/$(printf '%02d' "$t") Track $t of Album $a.flac"
    done
  } > "$OUT/Playlists/Mix $p.m3u"
done
find "$OUT" -name '*.flac' | wc -l
du -sh "$OUT"
