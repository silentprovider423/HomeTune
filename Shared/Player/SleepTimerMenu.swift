import SwiftUI

/// Einträge des Schlaf-Timers für ein Menü (Mac: Symbolleiste und „Steuerungen“, iPhone: „Mehr“ im Player)
struct SleepTimerMenuItems: View {
    let player: PlayerController

    var body: some View {
        switch player.sleepTimer {
        case .off:
            EmptyView()
        case .at(let end):
            Text("Hält um \(end.formatted(date: .omitted, time: .shortened)) an")
            Button("Schlaf-Timer beenden", systemImage: "moon.zzz.fill") { player.cancelSleepTimer() }
            Divider()
        case .endOfTrack:
            Text("Hält am Ende des Titels an")
            Button("Schlaf-Timer beenden", systemImage: "moon.zzz.fill") { player.cancelSleepTimer() }
            Divider()
        }
        ForEach(SleepTimer.presets, id: \.self) { m in
            Button("\(m) Minuten") { player.setSleepTimer(minutes: m) }
        }
        Button("Ende des Titels") { player.setSleepTimerEndOfTrack() }
            .disabled(!player.hasItem)
    }
}
