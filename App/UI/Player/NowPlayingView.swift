import SwiftUI

/// Vollbild „Jetzt läuft“: Cover, Titel, Favorit, Mehr-Menü, Zeitleiste mit 432-Hz-Kennzeichen,
/// Steuerung, Lautstärke, unten Liedtext · AirPlay · Warteliste.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    enum Panel { case none, lyrics, queue }
    @State private var panel = Panel.none
    @State private var colors: (Color, Color) = (Color(white: 0.3), Color(white: 0.08))
    @State private var scrub: Double?

    var body: some View {
        let p = app.player
        let song = p.currentSong
        ZStack {
            LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: song?.coverArt)
            VStack(spacing: 0) {
                Capsule().fill(.white.opacity(0.35)).frame(width: 38, height: 5).padding(.top, 8)
                    .onTapGesture { dismiss() }
                    .accessibilityLabel(Text("Schließen"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("nowPlaying.close")
                if panel == .none {
                    Spacer(minLength: 16)
                    CoverArt(id: song?.coverArt, size: 360, corner: 12)
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 14)
                        .scaleEffect(p.isPlaying ? 1 : 0.82)
                        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: p.isPlaying)
                        .padding(.horizontal, 28)
                    Spacer(minLength: 16)
                    titleRow(song)
                } else {
                    compactHeader(song).padding(.top, 14)
                    Group {
                        if panel == .lyrics { LyricsView(song: song) } else { QueueView() }
                    }
                    .frame(maxHeight: .infinity)
                }
                progress(p).padding(.top, 14)
                transport(p).padding(.vertical, 18)
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.white.opacity(0.6))
                    VolumeSlider().frame(height: 30)
                    Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                bottomBar.padding(.top, 14).padding(.bottom, 6)
            }
            .padding(.horizontal, 24)
            .foregroundStyle(.white)
        }
        .environment(\.colorScheme, .dark)
        .task(id: song?.coverArt) { await loadColors(song?.coverArt) }
    }

    // MARK: Teile

    private func titleRow(_ song: Song?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song?.title ?? "").font(.title3.bold()).lineLimit(1)
                Button(song?.artist ?? "") { if let s = song { app.openArtist(of: s) } }
                    .font(.title3).foregroundStyle(.white.opacity(0.65)).buttonStyle(.plain).lineLimit(1)
            }
            Spacer()
            if let song {
                let fav = app.library.isStarred(song: song.id)
                Button { app.toggleFavorite(song) } label: {
                    Image(systemName: fav ? "star.fill" : "star").font(.body.weight(.semibold)).frame(width: 34, height: 34)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .accessibilityLabel(fav ? Text("„Favorit“ widerrufen") : Text("Als Favoriten markieren"))
                .accessibilityIdentifier("nowPlaying.star")
                Menu {
                    SongMenu(song: song)
                    Section {
                        Button("Liedtext anzeigen", systemImage: "quote.bubble") { panel = .lyrics }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 34, height: 34)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .accessibilityLabel(Text("Mehr"))
            }
        }
    }

    private func compactHeader(_ song: Song?) -> some View {
        HStack(spacing: 12) {
            CoverArt(id: song?.coverArt, size: 64, corner: 6).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(song?.title ?? "").font(.headline).lineLimit(1)
                Text(song?.artist ?? "").font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer()
            if let song {
                let fav = app.library.isStarred(song: song.id)
                Button { app.toggleFavorite(song) } label: { Image(systemName: fav ? "star.fill" : "star").frame(width: 30, height: 30) }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
            }
        }
        .onTapGesture { withAnimation(.spring) { panel = .none } }
    }

    private func progress(_ p: PlayerController) -> some View {
        let dur = max(p.duration, 0.1)
        let value = scrub ?? p.position
        return VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(scrub == nil ? 0.75 : 1))
                        .frame(width: max(0, min(w, w * value / dur)))
                }
                .frame(height: scrub == nil ? 7 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in scrub = min(max(0, g.location.x / w), 1) * dur }
                    .onEnded { _ in
                        if let s = scrub { p.seek(to: s) }
                        scrub = nil
                    })
                .animation(.easeOut(duration: 0.15), value: scrub == nil)
            }
            .frame(height: 20)
            .accessibilityElement()
            .accessibilityLabel(Text("Titelposition"))
            .accessibilityValue(Text(verbatim: "\(Fmt.time(value)) / \(Fmt.time(dur))"))
            .accessibilityAdjustableAction { dir in
                p.skip(by: dir == .increment ? 15 : -15)
            }
            HStack {
                Text(Fmt.time(value)).monospacedDigit()
                Spacer()
                tuningBadge(p.currentSong)
                Spacer()
                Text(verbatim: "-" + Fmt.time(max(0, dur - value))).monospacedDigit()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// Dezentes Kennzeichen: Wiedergabe immer in 432 Hz (+ Dateiformat).
    private func tuningBadge(_ song: Song?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "tuningfork").font(.caption2)
            Text(verbatim: "432 Hz")
            if let f = song?.formatBadge { Text(verbatim: "· \(f)") }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(.white.opacity(0.12), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Wiedergabe in 432 Hz"))
        .accessibilityIdentifier("badge432")
    }

    private func transport(_ p: PlayerController) -> some View {
        HStack {
            Spacer()
            Button { p.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 34)) }
                .accessibilityLabel(Text("Vorheriger Titel"))
            Spacer()
            Button { p.togglePlay() } label: {
                ZStack {
                    if p.isLoading { ProgressView().controlSize(.large).tint(.white) }
                    else { Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 50)).contentTransition(.symbolEffect(.replace)) }
                }
                .frame(width: 70, height: 70)
            }
            .accessibilityLabel(p.isPlaying ? Text("Pause") : Text("Wiedergeben"))
            .accessibilityIdentifier("nowPlaying.playPause")
            Spacer()
            Button { p.next() } label: { Image(systemName: "forward.fill").font(.system(size: 34)) }
                .accessibilityLabel(Text("Nächster Titel"))
                .accessibilityIdentifier("nowPlaying.next")
            Spacer()
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button { withAnimation(.spring) { panel = panel == .lyrics ? .none : .lyrics } } label: {
                Image(systemName: panel == .lyrics ? "quote.bubble.fill" : "quote.bubble").font(.title3)
                    .frame(width: 44, height: 44)
                    .background(panel == .lyrics ? .white.opacity(0.18) : .clear, in: .circle)
            }
            .accessibilityLabel(Text("Liedtexte"))
            .accessibilityIdentifier("nowPlaying.lyrics")
            Spacer()
            AirPlayButton().frame(width: 44, height: 44)
                .accessibilityLabel(Text("AirPlay"))
            Spacer()
            Button { withAnimation(.spring) { panel = panel == .queue ? .none : .queue } } label: {
                Image(systemName: "list.bullet").font(.title3)
                    .frame(width: 44, height: 44)
                    .background(panel == .queue ? .white.opacity(0.18) : .clear, in: .circle)
            }
            .accessibilityLabel(Text("Warteliste"))
            .accessibilityIdentifier("nowPlaying.queue")
            Spacer()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.8))
    }

    private func loadColors(_ cover: String?) async {
        guard let cover, let img = await Artwork.image(id: cover, size: 120, client: app.client) else { return }
        colors = img.dominantColors()
    }
}
