import SwiftUI

/// Symbolleiste = Player: Transport · LCD-Anzeige · Lautstärke/Ausgabe · Liedtext/Nächster Titel
struct PlayerToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            TransportControls()
        }
        ToolbarItem(placement: .principal) {
            LCDView()
                .frame(minWidth: 200, idealWidth: 330, maxWidth: 620)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            VolumeControl()
            PanelButtons()
        }
    }
}

/// Zufällig · Zurück · Wiedergabe/Pause · Weiter · Wiederholen
struct TransportControls: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let p = app.player
        HStack(spacing: 2) {
            Button { p.toggleShuffle() } label: {
                ToggleGlyph(name: "shuffle", on: p.shuffle)
            }
            .help(p.shuffle ? Text("Zufällige Wiedergabe: Ein") : Text("Zufällige Wiedergabe: Aus"))
            .accessibilityIdentifier("player.shuffle")

            SeekButton(systemImage: "backward.fill", forward: false) { p.previous() }
                .help(Text("Vorheriger Titel"))
                .accessibilityIdentifier("player.previous")

            Button { p.togglePlay() } label: {
                Image(systemName: p.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 30)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(!p.hasItem && app.library.songs.isEmpty)
            .help(p.isPlaying ? Text("Pause") : Text("Wiedergabe"))
            .accessibilityIdentifier("player.playPause")

            SeekButton(systemImage: "forward.fill", forward: true) { p.next() }
                .help(Text("Nächster Titel"))
                .accessibilityIdentifier("player.next")

            Button { p.cycleRepeat() } label: {
                ToggleGlyph(name: p.repeatMode == .one ? "repeat.1" : "repeat", on: p.repeatMode != .off)
            }
            .help(Text(repeatHelp(p.repeatMode)))
            .accessibilityIdentifier("player.repeat")
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .tint(.primary)
    }

    private func repeatHelp(_ m: PlayQueue.RepeatMode) -> LocalizedStringKey {
        switch m { case .off: "Wiederholen: Aus"; case .all: "Wiederholen: Alle"; case .one: "Wiederholen: Eins" }
    }
}

/// Schalter-Symbol: aktiv in Akzentfarbe mit Punkt darunter
struct ToggleGlyph: View {
    let name: String
    let on: Bool
    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: name).font(.system(size: 13, weight: .medium))
            Circle().frame(width: 3, height: 3).opacity(on ? 1 : 0)
        }
        .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        .frame(width: 26, height: 26)
    }
}

/// Zurück/Weiter: Klick springt, gedrückt halten spult (Vor-/Zurückspringen)
struct SeekButton: View {
    @Environment(AppModel.self) private var app
    let systemImage: String
    let forward: Bool
    let tap: () -> Void
    @State private var holdTask: Task<Void, Never>?
    @State private var held = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15))
            .frame(width: 28, height: 26)
            .contentShape(.rect)
            .foregroundStyle(app.player.hasItem ? .primary : .tertiary)
            .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 20) {
                // gehalten: alle 0,25 s um 3 s springen, bis losgelassen
            } onPressingChanged: { pressing in
                if pressing {
                    held = false
                    holdTask = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        while !Task.isCancelled {
                            held = true
                            app.player.skip(by: forward ? 3 : -3)
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                    }
                } else {
                    holdTask?.cancel()
                    holdTask = nil
                    if !held { tap() }
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap() }
    }
}

/// Lautstärke der App (nicht des Systems) + Ausgabegerät
struct VolumeControl: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var player = app.player
        HStack(spacing: 4) {
            Image(systemName: speaker(player.volume))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .onTapGesture { player.volume = player.volume > 0 ? 0 : 0.8 }
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                .controlSize(.mini)
                .frame(width: 72)
                .accessibilityIdentifier("player.volume")
            OutputDeviceMenu()
        }
    }

    private func speaker(_ v: Float) -> String {
        v <= 0 ? "speaker.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

/// Liedtext (⌃⌘U) und Nächster Titel (⌥⌘U): schalten die rechte Spalte um
struct PanelButtons: View {
    @Environment(MacModel.self) private var mac
    var body: some View {
        HStack(spacing: 2) {
            Button { mac.toggleInspector(.lyrics) } label: {
                Image(systemName: mac.inspector == .lyrics ? "quote.bubble.fill" : "quote.bubble")
                    .foregroundStyle(mac.inspector == .lyrics ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            .help(Text("Liedtext"))
            .accessibilityIdentifier("player.lyrics")
            Button { mac.toggleInspector(.queue) } label: {
                Image(systemName: "list.bullet")
                    .foregroundStyle(mac.inspector == .queue ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            .help(Text("Nächster Titel"))
            .accessibilityIdentifier("player.queue")
        }
        .buttonStyle(.borderless)
        .tint(.primary)
    }
}
