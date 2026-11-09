#if DEBUG
import SwiftUI
import AppKit

/// Nur Debug: App ohne Maus und Tastatur steuern (für Selbsttests und Screenshots mit Demodaten, während am Mac
/// gearbeitet wird). Befehle kommen als verteilte Mitteilung „org.homeroll.hometune.debug“ (Feld „cmd“), z. B. von
/// `swift tools/mac-debug.swift "go albums"`. Aufnahmen zeigen nur das eigene Fenster der App.
@MainActor
enum DebugControl {
    static let name = Notification.Name("org.homeroll.hometune.debug")
    private static var observer: NSObjectProtocol?

    static func start(app: AppModel, mac: MacModel) {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { n in
            let cmd = n.userInfo?["cmd"] as? String ?? (n.object as? String) ?? ""
            MainActor.assumeIsolated { run(cmd, app: app, mac: mac) }
        }
    }

    static func run(_ line: String, app: AppModel, mac: MacModel) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "go":
            mac.search = ""
            switch arg {
            case "home": mac.go(.home)
            case "playlists": mac.go(.allPlaylists)
            case "favorites": mac.go(.favorites)
            default:
                if let s = MacSection(rawValue: arg) { mac.visibleSections.insert(s); mac.go(.library(s)) }
                else if let p = app.library.allPlaylists.first(where: { $0.name == arg }) { mac.go(.playlist(p.id)) }
            }
        case "album":
            if let a = app.library.albums.first(where: { $0.name == arg }) { mac.showAlbum(a.id) }
        case "artist":
            if let a = app.library.artists.first(where: { $0.name == arg }) { mac.showArtist(a.id) }
        case "search":
            mac.search = arg
        case "source":
            // „source local“ = Umschalter Alle/Server/Auf diesem Mac
            mac.source = MusicSource(rawValue: arg) ?? .all
        case "local":
            // „local albums“ = Darstellung von „Auf diesem Mac“ (playlists, albums, artists, songs)
            mac.localView = LocalView(rawValue: arg)
        case "inspector":
            mac.inspector = InspectorPanel(rawValue: arg)
        case "queueTab":
            mac.queueTab = Int(arg) ?? 0
        case "play":
            // stumm abspielen und sofort anhalten: Player zeigt den Titel, aus den Lautsprechern kommt nichts
            guard let a = app.library.albums.first(where: { $0.name == arg }) else { return }
            app.player.volume = 0
            Task {
                let songs = await app.songs(of: a)
                app.player.play(songs, name: a.name)
                try? await Task.sleep(for: .seconds(2))
                app.player.pause()
                app.player.seek(to: 47)
                app.player.volume = 0.7
            }
        case "queue":
            // weitere Alben „Als Nächstes“ einreihen (für die rechte Spalte)
            guard let a = app.library.albums.first(where: { $0.name == arg }) else { return }
            Task { app.player.playLast(await app.songs(of: a)) }
        case "pause": app.player.pause()
        case "stop": app.player.stopAndClear()
        case "settings":
            if let tab = Int(arg) { UserDefaults.standard.set(tab, forKey: "mac.settingsTab") }
            NSApp.activate()
            mac.openSettings?()
        case "mini": mac.openWindow?("mini")
        case "fullscreen": mac.fullScreenPlayer = arg != "off"
        case "close-settings":
            settingsWindow?.close()
        case "size":
            let wh = arg.split(separator: " ").compactMap { Double($0) }
            if wh.count == 2, let w = mainWindow {
                var f = w.frame
                f.origin.y += f.height - wh[1]
                f.size = NSSize(width: wh[0], height: wh[1])
                w.setFrame(f, display: true, animate: false)
            }
        case "appearance":
            NSApp.appearance = arg == "dark" ? NSAppearance(named: .darkAqua) : arg == "light" ? NSAppearance(named: .aqua) : nil
        case "snapshot":
            // „snapshot <Pfad>“ = Hauptfenster, „snapshot settings <Pfad>“ = Einstellungen
            let sub = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if sub.first == "settings", sub.count == 2, let w = settingsWindow { snapshot(w, to: sub[1]) }
            else if sub.first == "mini", sub.count == 2,
                    let w = NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").hasPrefix("mini") && $0.isVisible }) { snapshot(w, to: sub[1]) }
            else if let w = mainWindow { snapshot(w, to: arg) }
        case "dump":
            // Symbolleiste beschreiben (Fehlersuche)
            var out = NSApp.windows.map { "window \($0.identifier?.rawValue ?? "-") visible=\($0.isVisible) title=\($0.title)" }.joined(separator: "\n") + "\n"
            if let w = mainWindow, let tb = w.toolbar {
                out += "visible=\(tb.isVisible) display=\(tb.displayMode.rawValue)\n"
                for i in tb.items {
                    out += "\(i.itemIdentifier.rawValue) visible=\(tb.visibleItems?.contains(i) ?? false) view=\(i.view.map { "\($0.frame) hidden=\($0.isHidden)" } ?? "-")\n"
                }
            }
            try? out.write(toFile: arg, atomically: true, encoding: .utf8)
        case "scroll":
            // „scroll 0.5“ = längste Liste im Hauptfenster an diese Stelle (0…1) rollen
            scroll(to: Double(arg) ?? 0)
        case "stress":
            // „stress 20“ = so viele Sekunden lang rollen und dabei die Ansicht wechseln (Absturzsuche)
            stress(seconds: Double(arg) ?? 10, mac: mac)
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private static func scroll(to fraction: Double) {
        guard let root = mainWindow?.contentView else { return }
        let all = scrollViews(in: root).sorted { ($0.documentView?.frame.height ?? 0) > ($1.documentView?.frame.height ?? 0) }
        guard let sv = all.first, let doc = sv.documentView else { return }
        let y = max(0, doc.frame.height - sv.contentView.bounds.height) * fraction
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    private static func stress(seconds: Double, mac: MacModel) {
        let targets: [SidebarItem] = [.library(.songs), .library(.onThisMac), .library(.albums), .home,
                                         .library(.artists), .library(.songs), .allPlaylists, .library(.genres)]
        Task { @MainActor in
            let end = Date().addingTimeInterval(seconds)
            var step = 0
            while Date() < end {
                if step % 40 == 0 { mac.go(targets[(step / 40) % targets.count]) }
                if step % 97 == 96 { mac.onlyDownloaded.toggle() }
                scroll(to: Double((step * 37) % 100) / 100)
                step += 1
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { ($0.identifier?.rawValue ?? "").hasPrefix("main") && $0.isVisible }
    }

    private static var settingsWindow: NSWindow? {
        NSApp.windows.first { ($0.identifier?.rawValue ?? "").localizedCaseInsensitiveContains("settings") && $0.isVisible }
    }

    /// Nur das eigene Fenster aufnehmen (eigene Fenster brauchen keine Bildschirmaufnahme-Freigabe)
    private static func snapshot(_ w: NSWindow, to path: String) {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") else { return }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1, kCGWindowImageBestResolution = 8
        guard let cg = fn(.null, 8, UInt32(w.windowNumber), 1 | 8)?.takeRetainedValue() else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
