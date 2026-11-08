import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Namespace private var playerNS

    var body: some View {
        if app.client == nil {
            LoginView()
        } else {
            tabs
        }
    }

    private var tabs: some View {
        @Bindable var app = app
        return TabView(selection: $app.tab) {
            Tab("Startseite", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack(path: $app.homePath) { HomeView().withRoutes() }
            }
            Tab("Mediathek", systemImage: "square.stack.fill", value: AppTab.library) {
                NavigationStack(path: $app.libraryPath) { LibraryView().withRoutes() }
            }
            Tab("Suchen", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack(path: $app.searchPath) { SearchView().withRoutes() }
            }
        }
        .tabViewBottomAccessory {
            MiniPlayer(namespace: playerNS)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .fullScreenCover(isPresented: $app.showNowPlaying) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "miniArtwork", in: playerNS))
        }
        .sheet(isPresented: Binding(get: { app.addToPlaylist != nil }, set: { if !$0 { app.addToPlaylist = nil } })) {
            AddToPlaylistSheet(songs: app.addToPlaylist ?? [])
        }
        .sheet(isPresented: $app.showSettings) {
            SettingsView()
        }
        .overlay(alignment: .top) { NoticeOverlay() }
    }
}

extension View {
    /// Detailseiten für alle Navigationsstapel.
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .album(let id): AlbumDetailView(albumID: id)
            case .artist(let id): ArtistDetailView(artistID: id)
            case .playlist(let id): PlaylistDetailView(playlistID: id)
            case .genre(let g): GenreDetailView(genre: g)
            case .composer(let c): ComposerDetailView(name: c)
            case .section(let s): s.destination
            }
        }
    }
}

extension LibrarySection {
    @ViewBuilder var destination: some View {
        switch self {
        case .playlists: PlaylistsView()
        case .artists: ArtistsView()
        case .albums: AlbumsView()
        case .songs: SongsView()
        case .genres: GenresView()
        case .composers: ComposersView()
        case .favorites: FavoriteSongsView()
        case .downloaded: DownloadedView()
        }
    }
}

/// Einblendung oben (Apple: MusicNotice).
struct NoticeOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let n = app.notice.current {
            Label(n.text, systemImage: n.icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 11)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(n.id)
                .accessibilityIdentifier("notice")
                .animation(.spring(duration: 0.35), value: n.id)
        }
    }
}
