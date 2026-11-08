import Foundation

/// Prüft das Signatur-Profil (embedded.mobileprovision) beim Sideloaden: Gilt es nur für eine feste App-ID, die
/// nicht zur Bundle-ID passt, übergibt iOS aus dem Dateien-Dialog nichts („Öffnen“ bleibt ohne Ergebnis).
/// Dann zeigt „Auf diesem iPhone“ einen Hinweis mit der App-ID, die das Profil erwartet.
enum SigningCheck {
    /// App-ID aus dem Profil (ohne Team-Präfix), wenn sie nicht zur Bundle-ID passt – sonst nil.
    static func mismatch(profile: Data, bundleID: String) -> String? {
        guard let appID = applicationIdentifier(in: profile) else { return nil }
        return matches(appID: appID, bundleID: bundleID) ? nil : appID
    }

    /// Ergebnis für die laufende App (nil ohne Profil, z. B. im Simulator oder aus dem App Store).
    static func currentMismatch() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url), let id = Bundle.main.bundleIdentifier else { return nil }
        return mismatch(profile: data, bundleID: id)
    }

    /// Das Profil ist eine CMS-Signatur; die Plist steckt im Klartext zwischen „<?xml“ und „</plist>“.
    static func applicationIdentifier(in profile: Data) -> String? {
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex) else { return nil }
        let plist = profile.subdata(in: start.lowerBound..<end.upperBound)
        guard let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let ent = dict["Entitlements"] as? [String: Any],
              let full = ent["application-identifier"] as? String else { return nil }
        // „TEAMID.org.example.app“ → „org.example.app“
        guard let dot = full.firstIndex(of: ".") else { return full }
        return String(full[full.index(after: dot)...])
    }

    /// „*“ passt immer, „org.example.*“ passt auf alles darunter, sonst exakt.
    static func matches(appID: String, bundleID: String) -> Bool {
        if appID == "*" { return true }
        if appID.hasSuffix(".*") { return bundleID.hasPrefix(String(appID.dropLast())) }
        return appID == bundleID
    }
}
