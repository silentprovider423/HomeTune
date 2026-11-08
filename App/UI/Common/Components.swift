import SwiftUI

/// Titelzeile wie in Apples Listen: Cover oder Nummer, Titel, Künstler, Favoriten-Stern, „…“.
struct SongRow: View {
    @Environment(AppModel.self) private var app
    let song: Song
    var number: Int?
    var showArtwork = true
    var subtitle: String?
    var showGoToAlbum = true
    var onRemoveFromPlaylist: (() -> Void)?

    var body: some View {
        let isCurrent = app.player.currentSong?.id == song.id
        HStack(spacing: 12) {
            if let number {
                Group {
                    if isCurrent {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: app.player.isPlaying)
                            .foregroundStyle(.accent)
                    } else {
                        Text(verbatim: "\(number)").foregroundStyle(.secondary)
                    }
                }
                .font(.body.monospacedDigit())
                .frame(width: 26, alignment: .center)
            } else if showArtwork {
                CoverArt(id: song.coverArt, size: 46, corner: 5)
                    .frame(width: 46, height: 46)
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.35))
                            Image(systemName: "waveform").foregroundStyle(.white)
                                .symbolEffect(.variableColor.iterative, isActive: app.player.isPlaying)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                    .foregroundStyle(isCurrent && number != nil ? AnyShapeStyle(.accent) : AnyShapeStyle(.primary))
                if let sub = subtitle ?? song.artist, !sub.isEmpty {
                    Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if app.library.isStarred(song: song.id) {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.accent)
                    .accessibilityLabel(Text("Favorit"))
            }
            DownloadBadge(state: app.downloads.state(song.id))
            Menu {
                SongMenu(song: song, showGoToAlbum: showGoToAlbum, onRemoveFromPlaylist: onRemoveFromPlaylist)
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.primary)
                    .frame(width: 30, height: 36).contentShape(.rect)
            }
            .accessibilityLabel(Text("Mehr"))
        }
        .contentShape(.rect)
    }
}

struct DownloadBadge: View {
    let state: DownloadManager.State
    var body: some View {
        switch state {
        case .done: Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.secondary)
        case .downloading, .waiting: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
        case .none: EmptyView()
        }
    }
}

/// Albumkachel (Raster) wie in der Mediathek.
struct AlbumTile: View {
    @Environment(AppModel.self) private var app
    let album: Album
    var subtitle: String?

    var body: some View {
        // Knopf statt NavigationLink: in Listen-Zeilen sonst mit Pfeil rechts neben jeder Kachel
        Button { app.open(.album(album.id)) } label: {
            VStack(alignment: .leading, spacing: 4) {
                CoverArt(id: album.coverArt, size: 180, corner: 8)
                Text(album.name).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                Text(subtitle ?? album.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { AlbumMenu(album: album) } preview: {
            VStack(alignment: .leading) {
                CoverArt(id: album.coverArt, size: 300, corner: 10).frame(width: 280, height: 280)
                Text(album.name).font(.headline)
                Text(album.artist ?? "").foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

/// Zwei große Knöpfe „Wiedergeben“ und „Zufällig“ (oben in Album, Playlist, Titeln).
struct PlayShuffleButtons: View {
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: play) {
                Label("Wiedergeben", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("play.button")
            Button(action: shuffle) {
                Label("Zufällig", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("shuffle.button")
        }
        .font(.headline)
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 10))
        .controlSize(.large)
        .tint(.accent)
    }
}

/// Raster-Spalten für Albumkacheln.
let albumGrid = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

/// Hinweis bei leerem Inhalt.
struct EmptyHint: View {
    let title: LocalizedStringKey
    let icon: String
    var text: LocalizedStringKey?
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            if let text { Text(text) }
        }
    }
}

enum Fmt {
    static func time(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func minutes(_ seconds: Int) -> Int { max(1, Int((Double(seconds) / 60).rounded())) }

    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}
