import SwiftUI

/// Startseite aus eigenen Serverlisten (Apple: personalisierter Katalog, hier: Zuletzt gespielt, Neu, Häufig, Favoriten, Zufall).
struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Button { app.shuffleAll() } label: {
                    Label("Alles zufällig", systemImage: "shuffle").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large).tint(.accent)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .accessibilityIdentifier("home.shuffleAll")

                if app.client == nil && app.local.isEmpty && !app.local.isScanning {
                    AddLocalMusicHint().padding(.horizontal)
                }
                shelf("Zuletzt gespielt", app.library.recentlyPlayed)
                shelf("Zuletzt hinzugefügt", app.library.recentlyAdded)
                shelf("Auf diesem iPhone", app.local.recentAlbums)
                shelf("Häufig gespielt", app.library.frequent)
                shelf("Favoriten", app.library.albums.filter { app.library.isStarred(album: $0.id) })
                shelf("Zufällige Alben", app.library.randomAlbums)
            }
            .padding(.vertical)
        }
        .navigationTitle("Startseite")
        .refreshable {
            await app.library.refreshRecent()
            await app.library.shuffleRandomAlbums()
        }
        .task { await app.library.refreshRecent() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { app.showSettings = true } label: { Image(systemName: "person.crop.circle") }
                    .accessibilityLabel(Text("Konto und Einstellungen"))
            }
        }
    }

    @ViewBuilder
    private func shelf(_ title: LocalizedStringKey, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title2.bold()).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(albums) { AlbumTile(album: $0).frame(width: 160) }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}
