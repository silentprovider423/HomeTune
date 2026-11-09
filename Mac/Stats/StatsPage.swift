import SwiftUI
import Charts

/// Hör-Statistik: Kacheln, Verlauf je Tag, Uhrzeit und die meistgespielten Titel, Künstler:innen und Alben.
/// Alles stammt aus `ListeningStats` und bleibt auf diesem Mac.
struct StatsPage: View {
    @AppEnv private var app
    @MacEnv private var mac
    @AppStorage("mac.statsPeriod") private var periodRaw = StatsPeriod.month.rawValue
    @State private var confirmReset = false

    private var period: StatsPeriod { StatsPeriod(rawValue: periodRaw) ?? .month }

    var body: some View {
        let stats = app.stats
        VStack(spacing: 0) {
            PageHeader(title: Text("Hör-Statistik")) {
                if !stats.isEmpty {
                    Picker("Zeitraum", selection: $periodRaw) {
                        ForEach(StatsPeriod.allCases) { p in Text(p.title).tag(p.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("stats.period")
                }
            }
            if stats.isEmpty {
                EmptyState(title: "Noch keine Statistik", systemImage: "chart.bar",
                           message: "Sobald du Musik hörst, erscheint hier deine Auswertung. Sie bleibt auf diesem Mac.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        tiles(stats)
                        HStack(alignment: .top, spacing: 16) {
                            DailyChart(days: stats.daily(last: period == .week ? 7 : 30), week: period == .week)
                            HoursChart(hours: stats.hours)
                        }
                        top(stats)
                        footer(stats)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .confirmationDialog(Text("Statistik zurücksetzen?"), isPresented: $confirmReset) {
            Button("Zurücksetzen", role: .destructive) { stats.reset() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle gezählten Wiedergaben und Hörzeiten werden gelöscht. Deine Musik bleibt unberührt.")
        }
    }

    private func tiles(_ stats: ListeningStats) -> some View {
        let s = stats.summary(period)
        let streak = stats.streak
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
            StatTile(title: "Hörzeit", value: Fmt.total(Int(s.seconds)), icon: "clock")
            StatTile(title: "Wiedergaben", value: s.plays.formatted(), icon: "play")
            StatTile(title: "Verschiedene Titel", value: s.songs.formatted(), icon: "music.note")
            StatTile(title: "Hör-Serie (Tage)", value: streak.current.formatted(), icon: "flame",
                     note: Text("Längste Serie: \(streak.best)"))
        }
    }

    @ViewBuilder private func top(_ stats: ListeningStats) -> some View {
        let songs = stats.topSongs(period), artists = stats.topArtists(period), albums = stats.topAlbums(period)
        if songs.isEmpty {
            Text("In diesem Zeitraum wurde nichts gezählt.").foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: 16) {
                TopList(title: "Meistgespielte Titel", items: songs, showsCover: true) { r in
                    if let id = r.songID, let song = app.library.songs.first(where: { $0.id == id }) { mac.play([song], name: song.title) }
                }
                TopList(title: "Meistgespielte Künstler:innen", items: artists, showsCover: false, action: nil)
                TopList(title: "Meistgespielte Alben", items: albums, showsCover: true) { r in
                    if let id = r.albumId, app.library.album(id) != nil { mac.open(.album(id)) }
                }
            }
        }
    }

    private func footer(_ stats: ListeningStats) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let since = stats.since {
                    Text("Gezählt seit \(since.formatted(date: .abbreviated, time: .omitted))")
                }
                Text("Die Statistik bleibt auf diesem Mac und wird nirgendwohin übertragen.")
            }
            .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("Statistik zurücksetzen …") { confirmReset = true }
                .accessibilityIdentifier("stats.reset")
        }
    }
}

private struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String
    var note: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(verbatim: value).font(.system(size: 26, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            (note ?? Text(verbatim: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Minuten je Tag
private struct DailyChart: View {
    let days: [(day: Date, seconds: Double)]
    let week: Bool

    var body: some View {
        ChartCard(title: week ? "Letzte 7 Tage" : "Letzte 30 Tage") {
            Chart(days, id: \.day) { d in
                BarMark(x: .value("Tag", d.day, unit: .day), y: .value("Minuten", d.seconds / 60))
                    .foregroundStyle(Color.accent.gradient)
                    .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(preset: .aligned, values: .stride(by: .day, count: week ? 1 : 7)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: week ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxisLabel { Text("Minuten") }
        }
    }
}

/// Minuten je Uhrzeit (über die ganze Zeit)
private struct HoursChart: View {
    let hours: [Double]

    var body: some View {
        ChartCard(title: "Uhrzeit") {
            Chart(Array(hours.enumerated()), id: \.offset) { h in
                RectangleMark(xStart: .value("Uhrzeit", Double(h.offset) - 0.35), xEnd: .value("Uhrzeit", Double(h.offset) + 0.35),
                              yStart: .value("Minuten", 0), yEnd: .value("Minuten", h.element / 60))
                    .foregroundStyle(Color.accent.gradient)
                    .cornerRadius(2)
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis {
                AxisMarks(preset: .aligned, values: [0, 6, 12, 18, 23]) { v in
                    AxisGridLine()
                    AxisValueLabel { if let h = v.as(Int.self) { Text(verbatim: "\(h)") } }
                }
            }
            .chartYAxisLabel { Text("Minuten") }
        }
    }
}

private struct ChartCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content.frame(height: 150)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}

/// Bestenliste: Platz, Cover, Name, Wiedergaben. Doppelklick löst `action` aus (Titel spielen, Album öffnen).
private struct TopList: View {
    let title: LocalizedStringKey
    let items: [ListeningStats.Ranked]
    let showsCover: Bool
    let action: ((ListeningStats.Ranked) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, r in
                HStack(spacing: 10) {
                    Text(verbatim: "\(i + 1)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                    if showsCover { CoverArt(id: r.coverArt, size: 32, corner: 4) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: r.title).lineLimit(1)
                        if let s = r.subtitle, !s.isEmpty {
                            Text(verbatim: s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(verbatim: r.plays.formatted()).monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(minHeight: 34)
                .contentShape(.rect)
                .onTapGesture(count: 2) { action?(r) }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}
