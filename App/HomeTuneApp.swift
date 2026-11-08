import SwiftUI

@main
struct HomeTuneApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(.accent)
        }
        .onChange(of: phase) { _, p in
            if p == .background { app.player.saveQueue() }
            if p == .active { app.library.retryIfOffline() }
        }
    }
}

extension Color {
    /// Akzentfarbe von HomeTune (warmes Rot wie die Musik-App, eigener Ton)
    static let accent = Color(red: 0.98, green: 0.24, blue: 0.33)
}

extension ShapeStyle where Self == Color {
    static var accent: Color { Color.accent }
}
