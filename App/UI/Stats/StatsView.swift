import SwiftUI

/// Hör-Statistik: Kacheln, Verlauf je Tag, Uhrzeit und die meistgespielten Titel, Künstler:innen und Alben.
/// Alles stammt aus `ListeningStats` und bleibt auf diesem iPhone.
struct StatsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("statsPeriod") private var periodRaw = StatsPeriod.month.rawValue
    @State private var confirmReset = false

    private var period: StatsPeriod { StatsPeriod(rawValue: periodRaw) ?? .month }

    var body: some View {
        let stats = app.stats
        Group {
            if stats.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Statistik", systemImage: "chart.bar")
                } description: {
                    Text("Sobald du Musik hörst, erscheint hier deine Auswertung. Sie bleibt auf diesem iPhone.")
                }
            } else {
                content(stats)
            }
        }
        .navigationTitle("Hör-Statistik")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog("Statistik zurücksetzen?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Zurücksetzen", role: .destructive) { stats.reset() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle gezählten Wiedergaben und Hörzeiten werden gelöscht. Deine Musik bleibt unberührt.")
        }
    }

    private func content(_ stats: ListeningStats) -> some View {
        let s = stats.summary(period)
        let streak = stats.streak
        let songs = stats.topSongs(period, limit: 5), artists = stats.topArtists(period, limit: 5), albums = stats.topAlbums(period, limit: 5)
        return List {
            Section {
                Picker("Zeitraum", selection: $periodRaw) {
                    ForEach(StatsPeriod.allCases) { p in Text(p.title).tag(p.rawValue) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("stats.period")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                    tile("Hörzeit", StatsText.duration(s.seconds), "clock")
                    tile("Wiedergaben", s.plays.formatted(), "play")
                    tile("Verschiedene Titel", s.songs.formatted(), "music.note")
                    tile("Hör-Serie (Tage)", streak.current.formatted(), "flame", note: Text("Längste Serie: \(streak.best)"))
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section(period == .week ? "Letzte 7 Tage" : "Letzte 30 Tage") {
                StatsDailyChart(days: stats.daily(last: period == .week ? 7 : 30), week: period == .week)
                    .frame(height: 150).padding(.vertical, 6)
            }
            Section("Uhrzeit") {
                StatsHoursChart(hours: stats.hours).frame(height: 130).padding(.vertical, 6)
            }
            if songs.isEmpty {
                Section { Text("In diesem Zeitraum wurde nichts gezählt.").foregroundStyle(.secondary) }
            } else {
                Section("Meistgespielte Titel") {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, r in
                        row(i, r, cover: true)
                            .contentShape(.rect)
                            .onTapGesture {
                                if let id = r.songID, let song = app.library.songs.first(where: { $0.id == id }) {
                                    app.player.play([song], name: song.title)
                                }
                            }
                    }
                }
                Section("Meistgespielte Künstler:innen") {
                    ForEach(Array(artists.enumerated()), id: \.element.id) { i, r in row(i, r, cover: false) }
                }
                Section("Meistgespielte Alben") {
                    ForEach(Array(albums.enumerated()), id: \.element.id) { i, r in
                        if let id = r.albumId, app.library.album(id) != nil {
                            NavigationLink(value: Route.album(id)) { row(i, r, cover: true) }
                        } else {
                            row(i, r, cover: true)
                        }
                    }
                }
            }
            Section {
                Button("Statistik zurücksetzen …", role: .destructive) { confirmReset = true }
                    .accessibilityIdentifier("stats.reset")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    if let since = stats.since {
                        Text("Gezählt seit \(since.formatted(date: .abbreviated, time: .omitted))")
                    }
                    Text("Die Statistik bleibt auf diesem iPhone und wird nirgendwohin übertragen.")
                }
            }
        }
    }

    private func tile(_ title: LocalizedStringKey, _ value: String, _ icon: String, note: Text? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(verbatim: value).font(.title2.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            (note ?? Text(verbatim: " ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func row(_ i: Int, _ r: ListeningStats.Ranked, cover: Bool) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(i + 1)").font(.subheadline.weight(.medium)).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
            if cover { CoverArt(id: r.coverArt, size: 40, corner: 5).frame(width: 40, height: 40) }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: r.title).lineLimit(1)
                if let s = r.subtitle, !s.isEmpty {
                    Text(verbatim: s).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(verbatim: r.plays.formatted()).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
