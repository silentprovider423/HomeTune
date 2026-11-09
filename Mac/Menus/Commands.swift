import SwiftUI
import AppKit

/// Menüleiste mit den Kürzeln der Musik-App (Ablage, Bearbeiten, Titel, Darstellung, Steuerungen, Fenster, Hilfe)
struct MacCommands: Commands {
    let app: AppModel
    let mac: MacModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        SidebarCommands()

        // MARK: Ablage
        CommandGroup(replacing: .newItem) {
            Menu("Neu") {
                Button("Playlist") { mac.openMainWindow?(); mac.newPlaylist = [] }
                    .keyboardShortcut("n")
                Button("Playlist aus Auswahl") { mac.playlistFromSelection() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(mac.selectedSongs.isEmpty)
            }
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Musik auf diesem Mac hinzufügen …") { OpenPanel.addMusic(app) }
                .keyboardShortcut("o")
            Button("Server-Mediathek aktualisieren") { mac.reload() }
                .disabled(app.client == nil)
            Button("Im Finder anzeigen") { mac.revealInFinder(mac.selectedSongs) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!mac.selectedSongs.contains { $0.isLocal || app.downloads.isDownloaded($0.id) })
        }

        // MARK: Bearbeiten
        CommandGroup(after: .pasteboard) {
            Button("Auswahl aufheben") { NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSTableView.deselectAll(_:)), with: nil) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        // „Suchen ⌘F“ springt ins Suchfeld der Seitenleiste (ersetzt das Standard-Suchmenü für Text)
        CommandGroup(replacing: .textEditing) {
            Button("Suchen") { mac.openMainWindow?(); NotificationCenter.default.post(name: .focusSearch, object: nil) }
                .keyboardShortcut("f")
        }

        // MARK: Titel
        CommandMenu("menu.song") {
            SongMenuItems().environment(app).environment(mac)
        }

        // MARK: Darstellung
        CommandGroup(before: .sidebar) {
            Picker("Darstellung", selection: Binding(get: { mac.onlyDownloaded }, set: { mac.onlyDownloaded = $0 })) {
                Text("Alle Musikdateien").tag(false)
                Text("Nur geladene Musik").tag(true)
            }
            .pickerStyle(.inline)
            Divider()
            Menu("Sortieren nach") {
                ForEach(AlbumSort.allCases) { s in
                    Toggle(isOn: Binding(get: { mac.albumSort == s }, set: { if $0 { mac.albumSort = s } })) { Text(s.title) }
                }
                Divider()
                Toggle("Aufsteigend", isOn: Binding(get: { mac.albumSortAscending }, set: { if $0 { mac.albumSortAscending = true } }))
                Toggle("Absteigend", isOn: Binding(get: { !mac.albumSortAscending }, set: { if $0 { mac.albumSortAscending = false } }))
            }
            Button(mac.showFilter ? "Filterfeld ausblenden" : "Filterfeld einblenden") { mac.showFilter.toggle() }
            .keyboardShortcut("f", modifiers: [.command, .option])
            Divider()
            Button(mac.inspector == .queue ? "„Nächster Titel“ ausblenden" : "„Nächster Titel“ einblenden") { mac.toggleInspector(.queue) }
                .keyboardShortcut("u", modifiers: [.command, .option])
            Button(mac.inspector == .lyrics ? "Liedtexte ausblenden" : "Liedtexte anzeigen") { mac.toggleInspector(.lyrics) }
                .keyboardShortcut("u", modifiers: [.command, .control])
            Button(mac.showStatusBar ? "Statusleiste ausblenden" : "Statusleiste einblenden") { mac.showStatusBar.toggle() }
                .keyboardShortcut("/")
            Divider()
        }

        // MARK: Steuerungen
        CommandMenu("Steuerungen") {
            ControlsMenu(app: app, mac: mac)
        }

        // MARK: Fenster
        CommandGroup(before: .windowList) {
            Button("HomeTune") { openWindow(id: "main") }
                .keyboardShortcut("0")
            Button("MiniPlayer") { openWindow(id: "mini") }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Zum MiniPlayer wechseln") {
                openWindow(id: "mini")
                dismissWindow(id: "main")
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            Button(mac.fullScreenPlayer ? "Vollbild-Player schließen" : "Vollbild-Player") {
                openWindow(id: "main")
                withAnimation(.easeInOut(duration: 0.3)) { mac.fullScreenPlayer.toggle() }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(app.player.currentSong == nil && !mac.fullScreenPlayer)
            Divider()
        }

        // MARK: Hilfe
        CommandGroup(replacing: .help) {
            Button("HomeTune-Hilfe") {
                if let u = URL(string: "https://github.com/silentprovider423/HomeTune#readme") { NSWorkspace.shared.open(u) }
            }
        }
    }
}

/// Menü „Titel“: wirkt auf die gewählten Titel der aktuellen Liste
private struct SongMenuItems: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac

    var body: some View {
        let songs = mac.selectedSongs
        let none = songs.isEmpty
        let server = songs.filter { !$0.isLocal }
        let allFav = !none && songs.allSatisfy { app.library.isStarred(song: $0.id) }
        Menu("Zur Playlist hinzufügen") {
            Button("Neue Playlist") { mac.newPlaylist = songs }
            Divider()
            ForEach(app.library.allPlaylists.filter { $0.readonly != true }) { p in
                Button(p.name) { mac.add(songs, to: p) }
            }
        }
        .disabled(none)
        Button("Link kopieren") { mac.shareLink(server) }
            .disabled(server.isEmpty || app.client == nil)
        Divider()
        Button("Als Nächstes wiedergeben") { app.player.playNext(songs) }.disabled(none)
        Button("Zuletzt wiedergeben") { app.player.playLast(songs) }.disabled(none)
        Button("Sender erstellen") { if let s = server.first { mac.startStation(from: s) } }
            .disabled(server.count != 1 || app.client == nil)
        Divider()
        Button("Informationen") { mac.showInfo(songs) }
            .keyboardShortcut("i")
            .disabled(none)
        Button(allFav ? "„Favorit“ widerrufen" : "Favorit") {
            for s in songs where app.library.isStarred(song: s.id) == allFav { app.toggleFavorite(s) }
        }
        .disabled(none)
        Menu("Bewertung") {
            Button("Ohne") { mac.setRating(server, 0) }
            ForEach(1...5, id: \.self) { n in Button(String(repeating: "★", count: n)) { mac.setRating(server, n) } }
        }
        .disabled(server.isEmpty || app.client == nil)
        Divider()
        Button("Künstler:in in Mediathek anzeigen") { if let id = songs.first?.artistId { mac.showArtist(id) } }
            .disabled(songs.count != 1 || songs.first?.artistId == nil)
        Button("Album in Mediathek anzeigen") { if let id = songs.first?.albumId { mac.showAlbum(id) } }
            .disabled(songs.count != 1 || songs.first?.albumId == nil)
        Divider()
        Button("Aus Playlist entfernen") { mac.removeSelectionFromPlaylist?() }
            .disabled(none || mac.focusedPlaylist == nil || mac.focusedPlaylist?.readonly == true)
        Button("Laden") { app.download(server) }
            .disabled(server.isEmpty || app.downloads.allDownloaded(server))
        Button("Download entfernen") { app.removeDownload(server) }
            .disabled(!app.downloads.anyDownloaded(server))
    }
}

/// Menü „Steuerungen“
private struct ControlsMenu: View {
    let app: AppModel
    let mac: MacModel

    var body: some View {
        let p = app.player
        Button(p.isPlaying ? "Pause" : "Wiedergabe") {
            if p.hasItem { p.togglePlay() } else { app.shuffleAll() }
        }
        .keyboardShortcut(.space, modifiers: [])
        Button("Stoppen") { p.pause(); p.seek(to: 0) }
            .keyboardShortcut(".")
            .disabled(!p.hasItem)
        Button("Nächster Titel") { p.next() }
            .keyboardShortcut(.rightArrow)
            .disabled(!p.hasItem)
        Button("Vorheriger Titel") { p.previous() }
            .keyboardShortcut(.leftArrow)
            .disabled(!p.hasItem)
        Button("Vorspringen") { p.skip(by: 10) }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(!p.hasItem)
        Button("Zurückspringen") { p.skip(by: -10) }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(!p.hasItem)
        Divider()
        Button("Zum aktuellen Titel") { mac.openMainWindow?(); mac.revealCurrent() }
            .keyboardShortcut("l")
            .disabled(p.currentSong?.albumId == nil)
        Divider()
        Button("Lautstärke erhöhen") { p.volume += 0.1 }
            .keyboardShortcut(.upArrow)
        Button("Lautstärke verringern") { p.volume -= 0.1 }
            .keyboardShortcut(.downArrow)
        Divider()
        Menu("Zufällige Wiedergabe") {
            Toggle("Ein", isOn: Binding(get: { p.shuffle }, set: { if $0 != p.shuffle { p.toggleShuffle() } }))
            Toggle("Aus", isOn: Binding(get: { !p.shuffle }, set: { if $0 == p.shuffle { p.toggleShuffle() } }))
        }
        Menu("Wiederholen") {
            Toggle("Aus", isOn: Binding(get: { p.repeatMode == .off }, set: { if $0 { p.setRepeat(.off) } }))
            Toggle("Alle", isOn: Binding(get: { p.repeatMode == .all }, set: { if $0 { p.setRepeat(.all) } }))
            Toggle("Eins", isOn: Binding(get: { p.repeatMode == .one }, set: { if $0 { p.setRepeat(.one) } }))
        }
        Divider()
        Button("Zurück") { mac.back() }
            .keyboardShortcut("[")
            .disabled(mac.path.isEmpty)
        Button("Seite neu laden") { mac.reload() }
            .keyboardShortcut("r")
            .disabled(app.client == nil)
    }
}
