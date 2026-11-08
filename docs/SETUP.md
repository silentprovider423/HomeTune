# Setup guide: from IPA to your music

HomeTune is only the app. Your music lives on your own **Navidrome server**, so you need one of those first. If you already run Navidrome, skip to step 3.

## What you need

- An iPhone with **iOS 26 or newer**
- A computer that runs all the time (NAS, mini PC, home server, old laptop) with **Docker**
- Your music as files (MP3, AAC/M4A, ALAC, FLAC, …) in a folder on that computer
- A free Apple ID for sideloading

## 1. Set up Navidrome with Docker

Official guide: <https://www.navidrome.org/docs/installation/docker/>

Short version – create a `docker-compose.yml`:

```yaml
services:
  navidrome:
    image: deluan/navidrome:latest
    user: 1000:1000            # owner of your music folder
    ports: ["4533:4533"]
    environment:
      ND_SCANSCHEDULE: 1h      # look for new files every hour
      ND_LOGLEVEL: info
    volumes:
      - ./data:/data
      - /path/to/your/music:/music:ro
    restart: unless-stopped
```

```bash
docker compose up -d
```

HomeTune is tested with Navidrome **0.64**. Navidrome only reads your files (`:ro`); it never changes tags or deletes music.

### Optional: several libraries

Since Navidrome 0.58 you can add more music folders as separate libraries (e.g. "Family", "Audiobooks"):

1. Mount the folder as well, read-only: `- /path/to/other/music:/other:ro`, then `docker compose up -d`.
2. In the Navidrome web UI: **Settings → Libraries → +**, name it and enter the path `/other`.
3. **Settings → Users**: choose which libraries each user may see. Admins see all libraries.

HomeTune shows everything the signed-in account is allowed to see.

## 2. Create your account

1. Open `http://<server-ip>:4533` in a browser on your computer.
2. The first user you create is the admin. Note the username and password, you sign in to the app with them.
3. Wait for the first scan to finish (the web UI shows the progress). New files are picked up automatically; an admin can also start a scan from the app (*Account → Rescan Server Library*).

Lyrics: put `.lrc` files next to your songs (same name) or embed lyrics in the tags. Synced lyrics then scroll along in the app.

## 3. Make the server reachable from the iPhone

| Where | Address to use in the app | Works away from home |
|---|---|---|
| Home Wi-Fi only | `http://192.168.x.y:4533` | no |
| VPN (Tailscale, WireGuard) | `http://100.x.y.z:4533` (Tailscale IP) or your WireGuard IP | yes, with VPN on |
| Public with HTTPS (reverse proxy, Cloudflare Tunnel) | `https://music.example.com` | yes |

Tips:

- Use HTTPS for anything that leaves your home network.
- Type `http://` in front of IP addresses if you don't use HTTPS. Without a scheme the app assumes `http://`.
- HomeTune loads the original files (lossless). On mobile data a FLAC album can be several hundred MB – download albums at home (*Download*) to listen offline.

## 4. Install the IPA

1. Install [SideStore](https://sidestore.io) (no computer needed later) or [AltStore](https://altstore.io) (needs AltServer on your computer) and sign in with your Apple ID.
2. Download `HomeTune-<version>.ipa` from the Releases page on the iPhone.
3. Open it with SideStore/AltStore ("Share" → SideStore, or the **+** button in My Apps).
4. If iOS asks: Settings → Privacy & Security → **Developer Mode** on, iPhone restarts.

With a free Apple ID the app has to be **refreshed every 7 days**. SideStore and AltStore do that for you, just open them once a week.

## 5. First start

1. Open HomeTune, enter the server address from step 3, your Navidrome username and password, tap **Sign In**.
2. Allow **local network** access when asked (needed for servers at home).
3. Your library loads and is stored on the iPhone, so the next start is instant (and works offline with downloaded music).

Songs play in **432 Hz by default; 440 Hz and 528 Hz are selectable in Settings** (*Account → Tuning*). 440 Hz plays the file unchanged; 528 Hz is the conventional A4 = 444 Hz tuning (C5 = 528 Hz). Switching works immediately, also during a song. The badge under the time line in *Now Playing* only shows the file format.

## Music on this iPhone (no server needed)

You can also play files that are already on the iPhone – in *On My iPhone*, iCloud Drive or any other location of the Files app. A server is optional for this.

**Easiest way – the HomeTune folder:** in the Files app, move or copy music to **On My iPhone › HomeTune** (on a Mac: Finder → your iPhone → Files → HomeTune). It shows up in *Library → On This iPhone* automatically, subfolders and playlist files included. This needs no Files dialog and therefore also works with sideloading profiles that only cover a different app ID.

1. On the sign-in screen tap **Continue Without a Server** (or, with a server, go to *Library → … → Add Folder … / Add Files …*).
2. Pick a folder (all subfolders are included) or several files. Supported: FLAC, MP3, AAC/M4A, ALAC, WAV, AIFF, CAF, Opus – whatever iOS can decode. Not supported by iOS: WMA, WavPack, APE, DSD, Ogg Vorbis.
3. The music appears under **Library → On This iPhone** and also in Albums, Artists, Songs and Search.

HomeTune does **not copy** these files. It keeps a security-scoped bookmark per folder and reads the original file when you play it, so your music only exists once on the phone. Pull to refresh (or *Rescan*) picks up new and deleted files. *Remove from Library* never deletes files outside the HomeTune folder (inside it, HomeTune asks). **Open in / Share** from the Files app also opens the original in place; only copies handed over by Mail, AirDrop or other apps are kept in HomeTune's own storage (shown as *Received Files*).

**Playlists:** *Library → Playlists → New Playlist …* works without a server too (marked *On This iPhone*). To bring playlists from Apple Music on a Mac: *File → Library → Export Playlist …* as `.m3u` (or `.m3u8`), then open the file in HomeTune (*Add Files …*, *Import Playlist …* or *Open in*). Songs are matched by file name, then by the title in the playlist file; HomeTune shows how many were found.

**"Open" in the Files dialog does nothing?** Some sideloading setups sign the app with a profile for a fixed, different app ID; iOS then hands nothing over from the Files dialog. *On This iPhone* shows a hint with the app ID from the profile – set the bundle ID to that value in your sideloading tool, or use the HomeTune folder instead.

Files that are only in iCloud (cloud icon in Files) are downloaded first; rescan once they are on the phone.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Could not connect" at sign-in | Open the address in Safari on the iPhone first. Missing `http://`? Port `4533`? VPN on? |
| "Wrong username or password" | Sign in to the Navidrome web UI with the same data to check. |
| Works at home, not on mobile data | Your address is a home IP. Use a VPN or HTTPS (step 3). |
| New music doesn't show up | Wait for the next scan or start one (*Account → Rescan Server Library*, admins only), then pull to refresh. |
| No lyrics | The file has no embedded lyrics and no `.lrc` next to it. |
| Folder "not reachable" (On This iPhone) | The folder was deleted, or a re-signed app (new bundle ID or certificate) lost access. Remove it and add it again. |
| A song is skipped | iOS can't decode that format and the server couldn't convert it. Check the Navidrome log (ffmpeg must be available – it is in the Docker image). |
