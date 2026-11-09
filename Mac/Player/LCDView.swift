import SwiftUI

/// Mittelstück der Symbolleiste: Cover, Titel, „Künstler:in — Album“, Fortschrittslinie, Zeiten beim Überfahren, „⋯“
struct LCDView: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    @State private var hover = false
    @State private var hoverCover = false

    var body: some View {
        let p = app.player
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.055))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            if let song = p.currentSong {
                HStack(spacing: 0) {
                    Button { withAnimation(.easeInOut(duration: 0.3)) { mac.fullScreenPlayer = true } } label: {
                        CoverArt(id: song.coverArt, size: 44, corner: 3)
                            .overlay {
                                if hoverCover {
                                    RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.35))
                                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                }
                            }
                            .onHover { hoverCover = $0 }
                    }
                    .buttonStyle(.plain)
                    .help(Text("Vollbild-Player"))
                    .draggable(ItemsTransfer.songs([song]))
                    VStack(spacing: 1) {
                        Spacer(minLength: 0)
                        MarqueeText(text: song.title, font: .system(size: 12, weight: .semibold))
                            .onTapGesture { mac.revealCurrent() }
                        MarqueeText(text: [song.artist, song.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "),
                                    font: .system(size: 11), secondary: true)
                            .onTapGesture { if let id = song.artistId { mac.showArtist(id) } }
                        Spacer(minLength: 0)
                        ProgressLine(hover: hover)
                            .frame(height: 10)
                    }
                    .padding(.horizontal, 8)
                    .overlay(alignment: .trailing) {
                        if hover {
                            Menu {
                                SongContextMenu(songs: [song], source: .nowPlaying)
                            } label: {
                                Image(systemName: "ellipsis").frame(width: 20, height: 20)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .padding(.trailing, 6)
                            .padding(.bottom, 10)
                            .accessibilityIdentifier("lcd.more")
                        }
                    }
                }
                .transition(.opacity)
                .id(song.id)
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 24, height: 24)
                    .saturation(0).opacity(0.45)
                    .accessibilityLabel(Text("HomeTune"))
            }
        }
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(.easeInOut(duration: 0.3), value: p.currentSong?.id)
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { hover = h } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lcd")
    }
}

/// Dünne Fortschrittslinie; beim Überfahren Knopf und Zeiten, Klicken/Ziehen springt. Beim Laden ein laufender Balken.
struct ProgressLine: View {
    @Environment(AppModel.self) private var app
    let hover: Bool
    @State private var dragValue: Double?

    var body: some View {
        let p = app.player
        let dur = max(p.duration, 0.01)
        let value = dragValue ?? min(1, p.position / dur)
        HStack(spacing: 6) {
            if hover {
                Text(Fmt.time(dragValue.map { $0 * dur } ?? p.position)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    if p.isLoading {
                        IndeterminateBar()
                    } else {
                        Capsule().fill(.primary.opacity(0.15)).frame(height: hover ? 3 : 2)
                        Capsule().fill(.primary.opacity(0.55)).frame(width: max(0, g.size.width * value), height: hover ? 3 : 2)
                        if hover {
                            RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.85))
                                .frame(width: 8, height: 10)
                                .offset(x: max(0, min(g.size.width - 8, g.size.width * value - 4)))
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in dragValue = min(1, max(0, v.location.x / g.size.width)) }
                    .onEnded { v in
                        let f = min(1, max(0, v.location.x / g.size.width))
                        dragValue = nil
                        p.seek(to: f * dur)
                    })
            }
            if hover {
                Text("-" + Fmt.time(max(0, p.duration - (dragValue.map { $0 * dur } ?? p.position))))
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Wiedergabeposition"))
        .accessibilityValue(Text(Fmt.time(p.position)))
        .accessibilityIdentifier("lcd.progress")
    }
}

/// Gestreifter, laufender Balken während des Ladens
struct IndeterminateBar: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        GeometryReader { g in
            Capsule().fill(.primary.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.45))
                        .frame(width: g.size.width * 0.3)
                        .offset(x: phase * g.size.width * 0.7)
                }
                .clipShape(Capsule())
        }
        .frame(height: 3)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = 1 } }
    }
}

/// Zu langer Text läuft langsam durch (30 pt/s, 1,5 s Pause an den Enden); bei „Bewegung reduzieren“ nur abgeschnitten.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var secondary = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        let overflow = textWidth - boxWidth
        Text(text)
            .font(font)
            .foregroundStyle(secondary ? .secondary : .primary)
            .lineLimit(1)
            .fixedSize()
            .background(GeometryReader { g in Color.clear.preference(key: WidthKey.self, value: g.size.width) })
            .onPreferenceChange(WidthKey.self) { w in Task { @MainActor in textWidth = w } }
            .offset(x: overflow > 0 && !reduceMotion ? -offset : 0)
            .frame(maxWidth: .infinity, alignment: overflow > 0 ? .leading : .center)
            .background(GeometryReader { g in Color.clear.onAppear { boxWidth = g.size.width }.onChange(of: g.size.width) { _, w in boxWidth = w } })
            .clipped()
            .task(id: "\(text)|\(Int(overflow))|\(reduceMotion)") {
                offset = 0
                guard overflow > 4, !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.5))
                    let dur = Double(overflow / 30)
                    withAnimation(.linear(duration: dur)) { offset = overflow }
                    try? await Task.sleep(for: .seconds(dur + 1.5))
                    withAnimation(.linear(duration: dur)) { offset = 0 }
                    try? await Task.sleep(for: .seconds(dur))
                }
            }
            .help(text)
    }

    private struct WidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}
