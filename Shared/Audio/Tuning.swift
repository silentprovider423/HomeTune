import AVFoundation

/// Stimmung der Wiedergabe (Einstellungen → Stimmung). Musik ist (fast immer) auf A4 = 440 Hz gestimmt.
/// - 440 Hz (Standard): Original, keine Bearbeitung (bit-genau durchgereicht)
/// - 432 Hz: A4 = 432 Hz, 12·log2(432/440) ≈ −0,3177 Halbtöne (−31,77 Cent)
/// - 528 Hz: konventionell die Stimmung A4 = 444 Hz (dann liegt C5 bei 528 Hz), +15,67 Cent –
///   NICHT A4 = 528 Hz (das wären +3,15 Halbtöne). Wie die Frequenz-App: toA4Tuning(528) = 444.
/// Das Tempo bleibt immer exakt gleich (rate = 1).
enum Tuning: String, CaseIterable, Identifiable, Sendable {
    case hz440 = "440"
    case hz432 = "432"
    case hz528 = "528"

    static let storageKey = "tuning"
    static let standard = Tuning.hz440
    /// Kammerton der Aufnahmen
    static let sourceA4 = 440.0

    var id: String { rawValue }

    /// Angezeigte Frequenz (440, 432, 528)
    var hz: Int { Int(rawValue)! }

    /// Kammerton A4 der Zielstimmung
    var a4: Double {
        switch self {
        case .hz432: 432
        case .hz440: 440
        case .hz528: 444
        }
    }

    /// Frequenzverhältnis zum Original (432/440 ≈ 0,98182, 444/440 ≈ 1,00909)
    var ratio: Double { a4 / Self.sourceA4 }
    var semitones: Double { 12 * log2(ratio) }
    var cents: Double { 100 * semitones }
    var isOriginal: Bool { self == .hz440 }

    /// Gespeicherte Auswahl (Standard 440 Hz = Original)
    static var saved: Tuning {
        get { UserDefaults.standard.string(forKey: storageKey).flatMap(Tuning.init(rawValue:)) ?? standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}

/// Signalkette Player → Stimmung (signalsmith-stretch + Begrenzer, siehe HTPitchShiftUnit) → Mixer.
/// Wird von der Live-Wiedergabe und vom Offline-Messtest identisch benutzt.
final class PitchChain: @unchecked Sendable {
    let effect: AVAudioUnitEffect
    let shifter: HTPitchShiftUnit

    init(tuning: Tuning = .saved) {
        HTPitchShiftUnit.registerOnce()
        effect = AVAudioUnitEffect(audioComponentDescription: HTPitchShiftUnit.componentDescription())
        // Die Registrierung im Prozess liefert immer unsere Klasse
        shifter = effect.auAudioUnit as! HTPitchShiftUnit
        apply(tuning)
    }

    /// Wirkt sofort, auch mitten im Titel (Überblendung bzw. spektraler Übergang im Audio-Thread).
    func apply(_ tuning: Tuning) {
        shifter.semitones = Float(tuning.semitones)
        shifter.original = tuning.isOriginal
    }

    var tuning: Tuning {
        if shifter.original { return .hz440 }
        return Tuning.allCases.first { !$0.isOriginal && abs(Float($0.semitones) - shifter.semitones) < 1e-4 } ?? .standard
    }

    /// Feste Verzögerung der Kette (≈ 0,12 s, gleich in allen Stimmungen)
    var latencyFrames: Int { shifter.latencyFrames }

    func attach(to engine: AVAudioEngine, player: AVAudioPlayerNode, format: AVAudioFormat) {
        engine.attach(player)
        engine.attach(effect)
        engine.connect(player, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)
    }
}
