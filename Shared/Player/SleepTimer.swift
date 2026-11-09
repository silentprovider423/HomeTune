import Foundation

/// Schlaf-Timer der Wiedergabe
enum SleepTimer: Equatable, Sendable {
    case off
    /// Zu diesem Zeitpunkt anhalten
    case at(Date)
    /// Nach dem laufenden Titel anhalten
    case endOfTrack

    /// Auswahl in Minuten (Menü)
    static let presets = [5, 10, 15, 30, 45, 60, 90]
    /// So viele Sekunden vor dem Ende wird die Musik leiser
    static let fade: TimeInterval = 8

    var isOn: Bool { self != .off }

    /// Restzeit in Sekunden (nur bei festem Zeitpunkt)
    func remaining(now: Date = Date()) -> TimeInterval? {
        if case .at(let end) = self { return max(0, end.timeIntervalSince(now)) }
        return nil
    }
}
