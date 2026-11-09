import SwiftUI
import AppKit

@main
struct HomeTuneMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var app: AppModel
    @State private var mac: MacModel

    init() {
        // Sichtbarer Musikordner „Auf diesem Mac“ (~/Music/HomeTune) – nur anlegen, nie etwas darin verschieben
        try? FileManager.default.createDirectory(at: AppPaths.appFolder, withIntermediateDirectories: true)
        let a = AppModel()
        let m = MacModel()
        m.app = a
        _app = State(initialValue: a)
        _mac = State(initialValue: m)
        MacAppDelegate.shared = (a, m)
        #if DEBUG
        DebugControl.start(app: a, mac: m)
        #endif
    }

    var body: some Scene {
        Window("HomeTune", id: "main") {
            MainView()
                .environment(app)
                .environment(mac)
                .tint(.accent)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { MacCommands(app: app, mac: mac) }

        Window("MiniPlayer", id: "mini") {
            MiniPlayerView()
                .environment(app)
                .environment(mac)
                .tint(.accent)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.bottomTrailing)
        .commandsRemoved()

        Window("Informationen", id: "info") {
            InfoWindow()
                .environment(app)
                .environment(mac)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Settings {
            MacSettingsView()
                .environment(app)
                .environment(mac)
                .tint(.accent)
        }
    }
}

extension Color {
    /// Akzentfarbe von HomeTune (aus dem Asset „AccentColor“, folgt einer eigenen Systemakzentfarbe)
    static let accent = Color.accentColor
}

extension ShapeStyle where Self == Color {
    static var accent: Color { Color.accent }
}

/// Mac-Besonderheiten: Fenster zu ≠ App beenden, Dock-Menü, Leertaste, Nachfrage bei laufenden Downloads.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static var shared: (app: AppModel, mac: MacModel)?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Leertaste und ⌘-Pfeile gehören in Textfeldern dem Textfeld, sonst den Menüs (Wiedergabe/Pause …)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = event.window, window.firstResponder is NSTextView else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
            let isSpace = event.keyCode == 49 && mods.isEmpty
            let isCmdArrow = mods == .command && [123, 124, 125, 126].contains(event.keyCode)
            guard isSpace || isCmdArrow else { return event }
            window.sendEvent(event)
            return nil
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                MacAppDelegate.shared?.app.library.retryIfOffline()
                MacAppDelegate.shared?.app.becameActive()
            }
        }
    }

    /// Wie Apple: Wiedergabe läuft weiter, wenn das Hauptfenster zu ist
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MacAppDelegate.shared?.mac.openMainWindow?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app = MacAppDelegate.shared?.app, !app.downloads.active.isEmpty || !app.downloads.waiting.isEmpty else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Es werden gerade Titel geladen. Möchtest du den Vorgang abbrechen?")
        alert.addButton(withTitle: String(localized: "Beenden"))
        alert.addButton(withTitle: String(localized: "Abbrechen"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        MacAppDelegate.shared?.app.player.saveQueue()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MacAppDelegate.shared?.app.receive(urls)
    }

    // MARK: Dock-Menü

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let (app, _) = MacAppDelegate.shared else { return nil }
        let menu = NSMenu()
        if let s = app.player.currentSong {
            let title = NSMenuItem(title: [s.title, s.artist].compactMap { $0 }.joined(separator: " – "), action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(.separator())
        }
        let p = app.player
        menu.addItem(BlockMenuItem(p.isPlaying ? String(localized: "Pause") : String(localized: "Wiedergabe")) { p.togglePlay() })
        menu.addItem(BlockMenuItem(String(localized: "Nächster Titel")) { p.next() })
        menu.addItem(BlockMenuItem(String(localized: "Vorheriger Titel")) { p.previous() })
        menu.addItem(.separator())
        let sh = BlockMenuItem(String(localized: "Zufällige Wiedergabe")) { p.toggleShuffle() }
        sh.state = p.shuffle ? .on : .off
        menu.addItem(sh)
        let rep = NSMenuItem(title: String(localized: "Wiederholen"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (mode, name) in [(PlayQueue.RepeatMode.off, String(localized: "Aus")), (.all, String(localized: "Alle")), (.one, String(localized: "Eins"))] {
            let i = BlockMenuItem(name) { p.setRepeat(mode) }
            i.state = p.repeatMode == mode ? .on : .off
            sub.addItem(i)
        }
        rep.submenu = sub
        menu.addItem(rep)
        return menu
    }
}

/// Menüpunkt mit Block statt Selektor (Dock-Menü)
@MainActor final class BlockMenuItem: NSMenuItem {
    private let block: @MainActor () -> Void
    init(_ title: String, _ block: @escaping @MainActor () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { block() }
}
