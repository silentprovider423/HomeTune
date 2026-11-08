#!/bin/bash
# Erzeugt die Testdateien für „Musik auf diesem iPhone“ mit ffmpeg: Sinustöne/Stille mit erfundenen
# Titeln, Künstler:innen und Verlaufs-Covern (keine echte Musik). Ergebnis liegt in Tests/Fixtures.
#   ./tools/make-test-audio.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Tests/Fixtures
rm -rf "$OUT"; mkdir -p "$OUT/LocalMusic/Morning Set" "$OUT/LocalMusic/Night Drive" "$OUT/DemoAlbums"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FF=(ffmpeg -hide_banner -loglevel error -y -fflags +bitexact)

# Cover: Farbverlauf 300×300 als JPEG (ohne EXIF)
cover() { "${FF[@]}" -f lavfi -i "gradients=s=300x300:c0=$2:c1=$3:c2=$4:nb_colors=3:x0=0:y0=0:x1=300:y1=300:type=$5:d=1" \
  -frames:v 1 -q:v 4 -flags +bitexact "$TMP/$1.jpg"; }
cover morning 0xF6A04D 0xE2557A 0x5B3C88 0
cover night   0x101D4A 0x3B5BDB 0xE64980 1
cover tidal   0x0B7285 0x63E6BE 0xF8F9FA 2
cover paper   0xFFE066 0xFF922B 0xC92A2A 0
cover weather 0x495057 0x91A7FF 0xE7F5FF 1
cover field   0x2B8A3E 0xA9E34B 0xFFF3BF 3

# Gemeinsame Tags: tag <titel> <künstler> <album> <albumkünstler> <track> <disc> <jahr> <genre>
tags() { TAGS=(-metadata "title=$1" -metadata "artist=$2" -metadata "album=$3" -metadata "album_artist=$4" \
  -metadata "track=$5" -metadata "disc=$6" -metadata "date=$7" -metadata "genre=$8"); }

M="$OUT/LocalMusic/Morning Set"
# FLAC 48 kHz, 440-Hz-Sinus (für die 432-Hz-Messung), mit Cover und Komponist
"${FF[@]}" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=3" -i "$TMP/morning.jpg" \
  -map 0:a -map 1:v -c:a flac -c:v copy -disposition:v attached_pic -metadata:s:v comment="Cover (front)" \
  -metadata title="Paper Boats" -metadata artist="Lumenfold" -metadata album="Morning Set" -metadata album_artist="Lumenfold" \
  -metadata track="1/3" -metadata disc="1/1" -metadata date="2021" -metadata genre="Ambient" -metadata composer="Ada Example" \
  "$M/01 - Paper Boats.flac"
# MP3 (ID3v2.3) mit Cover
"${FF[@]}" -f lavfi -i "sine=frequency=660:sample_rate=44100:duration=2" -i "$TMP/morning.jpg" \
  -map 0:a -map 1:v -c:a libmp3lame -b:a 96k -c:v copy -id3v2_version 3 -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" \
  -metadata title="Glass Harbor" -metadata artist="Lumenfold" -metadata album="Morning Set" -metadata album_artist="Lumenfold" \
  -metadata track="2/3" -metadata disc="1/1" -metadata date="2021" -metadata genre="Ambient" \
  "$M/02 - Glass Harbor.mp3"
# WAV ohne Tags → Titel/Nummer aus dem Dateinamen, Album aus dem Ordner
"${FF[@]}" -f lavfi -i "anullsrc=r=44100:cl=mono" -t 1 -map_metadata -1 -c:a pcm_s16le "$M/03 - Quiet Field.wav"
echo "keine Musik" > "$OUT/LocalMusic/Morning Set/notes.txt"

N="$OUT/LocalMusic/Night Drive"
tags "Neon Rain" "Velvetine Static" "Night Drive" "Velvetine Static" "1/2" "1/1" "2019" "Synthwave"
"${FF[@]}" -f lavfi -i "sine=frequency=523.25:sample_rate=44100:duration=2" -i "$TMP/night.jpg" \
  -map 0:a -map 1:v -c:a aac -b:a 64k -c:v copy -disposition:v attached_pic \
  "${TAGS[@]}" \
  "$N/01 - Neon Rain.m4a"
"${FF[@]}" -f lavfi -i "sine=frequency=392:sample_rate=44100:duration=2" -i "$TMP/night.jpg" \
  -map 0:a -map 1:v -c:a alac -c:v copy -disposition:v attached_pic \
  -metadata title="Tunnel Lights" -metadata artist="Velvetine Static feat. Kite Assembly Club" -metadata album="Night Drive" \
  -metadata album_artist="Velvetine Static" -metadata track="2/2" -metadata disc="1/1" -metadata date="2019" -metadata genre="Synthwave" \
  "$N/02 - Tunnel Lights.m4a"
# AIFF direkt im Wurzelordner, ohne Album
"${FF[@]}" -f lavfi -i "sine=frequency=330:sample_rate=44100:duration=1" -c:a pcm_s16be -write_id3v2 1 \
  -metadata title="Copper Sky" -metadata artist="Marigold Engine" -metadata date="2018" \
  "$OUT/LocalMusic/Copper Sky.aiff"

# Demo-Alben für den Screenshot (kurze Stille, AAC)
demo() { # <ordner> <cover> <künstler> <jahr> <genre> <titel1> <titel2>
  local d="$OUT/DemoAlbums/$1"; mkdir -p "$d"; local n=1
  for t in "$6" "$7"; do
    tags "$t" "$3" "$1" "$3" "$n/2" "1/1" "$4" "$5"
    "${FF[@]}" -f lavfi -i "anullsrc=r=22050:cl=mono" -i "$TMP/$2.jpg" -t 3 -map 0:a -map 1:v -c:a aac -b:a 24k -c:v copy \
      -disposition:v attached_pic "${TAGS[@]}" "$d/0$n - $t.m4a"
    n=$((n + 1))
  done
}
demo "Tidal Rooms" tidal "The Orchid Relay" 2023 "Dream Pop" "Low Tide" "Salt Glass"
demo "Paper Satellites" paper "Northbound Atlas" 2022 "Indie" "Orbiting Home" "Signal Fire"
demo "Slow Weather" weather "Marigold Engine" 2020 "Downtempo" "Grey Morning" "Window Rain"
demo "Field Recordings" field "Kite Assembly Club" 2024 "Folk" "Meadow Light" "Open Gate"
find "$OUT" -type f | sort
du -sh "$OUT"
