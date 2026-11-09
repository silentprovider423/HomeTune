import SwiftUI
import AppKit

/// MiniPlayer (⌥⌘M): quadratisches Fenster in Covergröße. Maus darüber → oben Titel/Künstler:in mit Schließen,
/// „⋯“ und Ausgabe, unten Transport, Fortschritt mit Zeiten und Lautstärke. Doppelklick aufs Cover → Hauptfenster.
struct MiniPlayerView: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("mac.miniOnTop") private var onTop = false
    @State private var hover = false

    var body: some View {
        let p = app.player
        ZStack {
            Color.black
            if let s = p.currentSong {
                GeometryReader { g in
                    CoverArt(id: s.coverArt, size: min(g.size.width, g.size.height), corner: 0)
                        .onTapGesture(count: 2) { backToMain() }
                }
            } else {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).opacity(0.6)
            }
            if hover {
                controls.transition(.opacity)
            }
        }
        .frame(minWidth: 200, idealWidth: 300, maxWidth: 500, minHeight: 200, idealHeight: 300, maxHeight: 500)
        .aspectRatio(1, contentMode: .fit)
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { hover = h } }
        .onTapGesture(count: 2) { backToMain() }
        .background(MiniWindowConfigurator(onTop: onTop))
        .accessibilityIdentifier("miniPlayer")
    }

    private var controls: some View {
        let p = app.player
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { dismissWindow(id: "mini") } label: { Image(systemName: "xmark") }
                    .help(Text("Schließen"))
                VStack(spacing: 1) {
                    MarqueeText(text: p.currentSong?.title ?? "HomeTune", font: .system(size: 12, weight: .semibold))
                    MarqueeText(text: p.currentSong?.artist ?? "", font: .system(size: 11), secondary: true)
                }
                if let s = p.currentSong {
                    Menu { SongContextMenu(songs: [s], source: .nowPlaying) } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                OutputDeviceMenu()
            }
            .padding(8)
            .background(.ultraThinMaterial)
            Spacer()
            HStack {
                Button { backToMain() } label: { Image(systemName: "macwindow") }
                    .help(Text("Aus MiniPlayer wechseln"))
                Spacer()
            }
            .padding(.horizontal, 10)
            VStack(spacing: 6) {
                ProgressLine(hover: true).frame(height: 12)
                HStack(spacing: 14) {
                    Button { p.previous() } label: { Image(systemName: "backward.fill") }
                    Button { p.togglePlay() } label: { Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 22)) }
                        .accessibilityIdentifier("mini.playPause")
                    Button { p.next() } label: { Image(systemName: "forward.fill") }
                }
                .font(.system(size: 15))
                @Bindable var player = app.player
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").font(.caption2)
                    Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1).controlSize(.mini)
                    Image(systemName: "speaker.wave.3.fill").font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.ultraThinMaterial)
        }
        .buttonStyle(.borderless)
    }

    private func backToMain() {
        openWindow(id: "main")
        dismissWindow(id: "mini")
    }
}

/// Fenster des MiniPlayers: ohne Titelleiste ziehbar, festes Seitenverhältnis, Position gemerkt, optional im Vordergrund
private struct MiniWindowConfigurator: NSViewRepresentable {
    let onTop: Bool
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { configure(v.window) } }

    private func configure(_ w: NSWindow?) {
        guard let w else { return }
        w.isMovableByWindowBackground = true
        w.contentAspectRatio = NSSize(width: 1, height: 1)
        w.level = onTop ? .floating : .normal
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.titlebarAppearsTransparent = true
        w.setFrameAutosaveName("HomeTuneMiniPlayer")
    }
}

/// Vollbild-Player (⇧⌘F oder Klick aufs LCD-Cover): unscharfe Coverfarben, großes Cover, Transport, Lautstärke,
/// rechts optional Liedtext. Esc schließt.
struct FullScreenPlayer: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    @State private var showLyrics = false

    var body: some View {
        let p = app.player
        let s = p.currentSong
        ZStack {
            Color.black
            if let s {
                CoverArt(id: s.coverArt, size: 600, corner: 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(2.2)
                    .blur(radius: 70)
                    .opacity(0.75)
                    .clipped()
            }
            Color.black.opacity(0.25)
            HStack(spacing: 50) {
                VStack(spacing: 18) {
                    CoverArt(id: s?.coverArt, size: 380, corner: 10)
                        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
                    VStack(spacing: 4) {
                        Text(s?.title ?? "").font(.title.bold()).lineLimit(1)
                        Text([s?.artist, s?.album].compactMap { $0 }.joined(separator: " — ")).font(.title3).opacity(0.75).lineLimit(1)
                    }
                    ProgressLine(hover: true).frame(width: 380, height: 14)
                    HStack(spacing: 34) {
                        Button { p.toggleShuffle() } label: { Image(systemName: "shuffle").opacity(p.shuffle ? 1 : 0.5) }
                        Button { p.previous() } label: { Image(systemName: "backward.fill") }
                        Button { p.togglePlay() } label: { Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 40)) }
                        Button { p.next() } label: { Image(systemName: "forward.fill") }
                        Button { p.cycleRepeat() } label: {
                            Image(systemName: p.repeatMode == .one ? "repeat.1" : "repeat").opacity(p.repeatMode == .off ? 0.5 : 1)
                        }
                    }
                    .font(.system(size: 24))
                    @Bindable var player = app.player
                    HStack {
                        Image(systemName: "speaker.fill")
                        Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                        Image(systemName: "speaker.wave.3.fill")
                    }
                    .frame(width: 300).opacity(0.8)
                }
                .frame(width: 420)
                if showLyrics {
                    LyricsPanel(large: true).frame(maxWidth: 520)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            VStack {
                HStack {
                    Button { close() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).padding(10) }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                        .help(Text("Vollbild-Player schließen"))
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Button { withAnimation { showLyrics.toggle() } } label: {
                        Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble").font(.system(size: 18)).padding(10)
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
                    .help(Text("Liedtext"))
                }
            }
            .padding(14)
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .onExitCommand { close() }
        .accessibilityIdentifier("fullScreenPlayer")
    }

    private func close() { withAnimation(.easeInOut(duration: 0.3)) { mac.fullScreenPlayer = false } }
}
