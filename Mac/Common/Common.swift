import SwiftUI
import UniformTypeIdentifiers

// MARK: Cover

/// Coverbild mit Platzhalter (Note auf grauem Grund)
struct CoverArt: View {
    @AppEnv private var app
    let id: String?
    var size: CGFloat = 160
    var corner: CGFloat = 6
    var circle = false
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                    .overlay(Image(systemName: circle ? "music.microphone" : "music.note")
                        .font(.system(size: max(9, size * 0.3)))
                        .foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: corner, style: .continuous)))
        .overlay {
            if !circle {
                RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
        .task(id: id) {
            image = nil
            guard let id else { return }
            image = await Artwork.image(id: id, size: Int(size * 2), client: app.client)
        }
    }
}

/// Initialen-Kreis, wenn eine Künstler:in kein Bild hat
struct ArtistAvatar: View {
    let artist: Artist
    var size: CGFloat = 32
    var body: some View {
        if artist.coverArt != nil {
            CoverArt(id: artist.coverArt, size: size, circle: true)
        } else {
            Circle().fill(.quaternary)
                .overlay(Text(String(artist.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.secondary))
                .frame(width: size, height: size)
        }
    }
}

// MARK: Formatierung

enum Fmt {
    /// „m:ss“ bzw. „h:mm:ss“
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func time(_ seconds: Int?) -> String { seconds.map { time(Double($0)) } ?? "" }

    /// Gesamtdauer für Fußzeilen („42 Min.“, „3 Std., 12 Min.“, „3,2 Tage“)
    static func total(_ seconds: Int) -> String {
        if seconds >= 86_400 {
            let days = Double(seconds) / 86_400
            return String(localized: "\(days.formatted(.number.precision(.fractionLength(1)))) Tage")
        }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? String(localized: "\(h) Std., \(m) Min.") : String(localized: "\(max(1, m)) Min.")
    }

    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    static func date(_ iso: String?) -> String {
        guard let iso, let d = parse(iso) else { return "" }
        return d.formatted(date: .numeric, time: .shortened)
    }

    static func parse(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    /// Art der Datei, z. B. „FLAC-Audiodatei“
    static func kind(_ song: Song) -> String {
        guard let s = song.suffix?.uppercased(), !s.isEmpty else { return "" }
        return String(localized: "\(s)-Audiodatei")
    }
}

// MARK: Ziehen und Ablegen

extension UTType {
    /// App-interner Typ für gezogene Titel, Alben, Künstler:innen und Playlists
    static let hometuneItems = UTType(exportedAs: "org.homeroll.hometune.items")
}

/// Inhalt eines Ziehvorgangs (wird beim Ablegen in Titel aufgelöst)
struct ItemsTransfer: Codable, Transferable, Sendable {
    enum Kind: String, Codable, Sendable { case songs, album, artist, playlist }
    var kind: Kind
    var songs: [Song] = []
    var id: String?
    var name: String?
    /// Herkunft beim Ziehen innerhalb einer Playlist (zum Neu-Ordnen)
    var fromPlaylist: String?
    var indexes: [Int] = []

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .hometuneItems)
    }

    static func songs(_ s: [Song], fromPlaylist: String? = nil, indexes: [Int] = []) -> ItemsTransfer {
        ItemsTransfer(kind: .songs, songs: s, fromPlaylist: fromPlaylist, indexes: indexes)
    }
    static func album(_ a: Album) -> ItemsTransfer { ItemsTransfer(kind: .album, id: a.id, name: a.name) }
    static func artist(_ a: Artist) -> ItemsTransfer { ItemsTransfer(kind: .artist, id: a.id, name: a.name) }
    static func playlist(_ p: Playlist) -> ItemsTransfer { ItemsTransfer(kind: .playlist, id: p.id, name: p.name) }

    /// Aus einem NSItemProvider lesen (Ablegen über onInsert)
    static func load(from provider: NSItemProvider) async -> ItemsTransfer? {
        await withCheckedContinuation { cont in
            _ = provider.loadTransferable(type: ItemsTransfer.self) { result in
                cont.resume(returning: try? result.get())
            }
        }
    }

    @MainActor func resolve(_ app: AppModel) async -> [Song] {
        switch kind {
        case .songs: return songs
        case .album:
            guard let id else { return [] }
            if let a = app.library.album(id) { return await app.songs(of: a) }
            return (try? await app.client?.album(id: id).song) ?? []
        case .artist:
            guard let id else { return [] }
            if let a = app.library.artist(id) { return await app.songs(of: a) }
            return []
        case .playlist:
            guard let id else { return [] }
            return (try? await app.library.playlistSongs(id).entry) ?? []
        }
    }
}

extension Array where Element == ItemsTransfer {
    @MainActor func resolve(_ app: AppModel) async -> [Song] {
        var out: [Song] = []
        for t in self { out += await t.resolve(app) }
        return out
    }
}

// MARK: Kleine Bausteine

/// Knopf, der beim Überfahren erscheint (Raster, Zeilen)
struct HoverCircleButton: View {
    let systemImage: String
    var size: CGFloat = 27
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.black.opacity(0.55), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
    }
}

/// Große Knöpfe „Wiedergabe“ und „Zufällige Wiedergabe“ (Album-, Playlist-, Künstlerkopf)
struct PlayShuffleButtons: View {
    let play: () -> Void
    let shuffle: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) { Label("Wiedergabe", systemImage: "play.fill").frame(minWidth: 110) }
                .buttonStyle(.borderedProminent)
            Button(action: shuffle) { Label("Zufällige Wiedergabe", systemImage: "shuffle").frame(minWidth: 110) }
                .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }
}

/// Leerzustand mittig
struct EmptyState: View {
    let title: LocalizedStringKey
    var systemImage = "music.note"
    var message: LocalizedStringKey?
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Kopfzeile einer Inhaltsseite (großer Titel, rechts optional Bedienelemente)
struct PageHeader<Trailing: View>: View {
    let title: Text
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            title.font(.system(size: 26, weight: .bold)).lineLimit(1)
            Spacer()
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: Text) { self.title = title; self.trailing = EmptyView() }
}

/// Glas-Hintergrund ab macOS 26, sonst Material
struct GlassBackground: ViewModifier {
    var corner: CGFloat = 8
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: corner))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: corner))
        }
    }
}
