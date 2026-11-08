import SwiftUI

/// Warteliste wie bei Apple: Zufall/Wiederholen oben, „Als Nächstes“ (von Hand eingereiht),
/// „Wiedergabe fortsetzen von …“, Verlauf; ziehen zum Ordnen, wischen zum Entfernen, „Leeren“.
struct QueueView: View {
    @Environment(AppModel.self) private var app
    @State private var showHistory = false
    @State private var confirmClear = false

    var body: some View {
        let p = app.player
        let q = p.queue
        VStack(spacing: 0) {
            controls(p)
            List {
                if showHistory {
                    Section {
                        ForEach(q.history.reversed()) { e in row(e).opacity(0.6).onTapGesture { p.jump(to: e) } }
                    } header: {
                        HStack {
                            Text("Verlauf").font(.headline).foregroundStyle(.white)
                            Spacer()
                            if !q.history.isEmpty {
                                Button("Löschen") { p.clearHistory() }.font(.subheadline).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }
                }
                if !q.upNext.isEmpty {
                    Section {
                        ForEach(q.upNext) { e in row(e).onTapGesture { p.jump(to: e) } }
                            .onMove { p.moveUpNext(from: $0, to: $1) }
                            .onDelete { idx in idx.map { q.upNext[$0] }.forEach(p.remove) }
                    } header: { header("Als Nächstes", subtitle: nil) }
                }
                if !q.source.isEmpty {
                    Section {
                        ForEach(q.source) { e in row(e).onTapGesture { p.jump(to: e) } }
                            .onMove { p.moveSource(from: $0, to: $1) }
                            .onDelete { idx in idx.map { q.source[$0] }.forEach(p.remove) }
                    } header: {
                        header(q.upNext.isEmpty ? "Als Nächstes" : "Wiedergabe fortsetzen", subtitle: q.sourceName)
                    }
                }
                if q.upNext.isEmpty && q.source.isEmpty {
                    Text(q.repeatMode == .all ? "Die Wiedergabe beginnt danach von vorn." : "Keine weiteren Titel")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.6)).listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("queue.list")
        }
        .confirmationDialog("Warteliste leeren?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Warteliste leeren", role: .destructive) { p.clearUpcoming() }
        }
    }

    private func controls(_ p: PlayerController) -> some View {
        HStack(spacing: 10) {
            toggle(icon: "shuffle", on: p.shuffle, label: "Zufällig") { p.toggleShuffle() }
                .accessibilityIdentifier("queue.shuffle")
            toggle(icon: p.repeatMode == .one ? "repeat.1" : "repeat", on: p.repeatMode != .off, label: "Wiederholen") { p.cycleRepeat() }
                .accessibilityIdentifier("queue.repeat")
            toggle(icon: "clock.arrow.circlepath", on: showHistory, label: "Verlauf") { withAnimation { showHistory.toggle() } }
            Spacer()
            Button("Leeren") { confirmClear = true }
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                .disabled(p.queue.upNext.isEmpty && p.queue.source.isEmpty)
                .accessibilityIdentifier("queue.clear")
        }
        .padding(.vertical, 10)
    }

    private func toggle(icon: String, on: Bool, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 30)
                .foregroundStyle(on ? Color.black : Color.white.opacity(0.85))
                .background(on ? Color.white.opacity(0.85) : Color.white.opacity(0.14), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(on ? Text("Ein") : Text("Aus"))
    }

    private func header(_ title: LocalizedStringKey, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.headline).foregroundStyle(.white)
            if let subtitle { Text("von „\(subtitle)“").font(.subheadline).foregroundStyle(.white.opacity(0.6)) }
        }
        .textCase(nil)
    }

    private func row(_ e: PlayQueue.Entry) -> some View {
        HStack(spacing: 12) {
            CoverArt(id: e.song.coverArt, size: 44, corner: 5).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.song.title).lineLimit(1).foregroundStyle(.white)
                Text(e.song.artist ?? "").font(.subheadline).lineLimit(1).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
        }
        .contentShape(.rect)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.white.opacity(0.15))
    }
}

/// Liedtext: zeitsynchron (aktuelle Zeile hervorgehoben, antippen springt) oder als ganzer Text.
struct LyricsView: View {
    @Environment(AppModel.self) private var app
    let song: Song?
    @State private var lyrics: StructuredLyrics?
    @State private var plain: String?
    @State private var loaded = false

    var body: some View {
        Group {
            if let l = lyrics, l.synced == true, let lines = l.line, !lines.isEmpty {
                synced(lines, offset: Double(l.offset ?? 0) / 1000)
            } else if let text = plain ?? lyrics?.line?.map(\.value).joined(separator: "\n") {
                ScrollView {
                    Text(text).font(.title3.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical)
                }
            } else if loaded {
                ContentUnavailableView("Keine Liedtexte verfügbar", systemImage: "quote.bubble")
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("lyrics")
        .task(id: song?.id) { await load() }
    }

    private func synced(_ lines: [StructuredLyrics.Line], offset: Double) -> some View {
        let t = app.player.position + offset
        let current = lines.lastIndex { Double($0.start ?? 0) / 1000 <= t } ?? -1
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line.value.isEmpty ? "♪" : line.value)
                            .font(.title2.bold())
                            .foregroundStyle(.white.opacity(i == current ? 1 : 0.35))
                            .blur(radius: i == current ? 0 : 0.4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                            .onTapGesture { app.player.seek(to: Double(line.start ?? 0) / 1000 - offset) }
                    }
                }
                .padding(.vertical, 40)
            }
            .onChange(of: current) { _, c in withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(max(0, c), anchor: .center) } }
        }
    }

    private func load() async {
        lyrics = nil; plain = nil; loaded = false
        defer { loaded = true }
        guard let song, let client = app.client else { return }
        if let list = try? await client.lyrics(songId: song.id), !list.isEmpty {
            lyrics = list.first { $0.synced == true } ?? list.first
            return
        }
        if let a = song.artist { plain = try? await client.legacyLyrics(artist: a, title: song.title) }
    }
}
