import AVFoundation
import AudioToolbox

/// Die feste 432-Hz-Stimmung von HomeTune (kein Schalter – Kernmerkmal).
/// Musik ist (fast immer) auf A4 = 440 Hz gestimmt. Um auf A4 = 432 Hz zu kommen, wird die
/// Tonhöhe um 1200·log2(432/440) ≈ −31,77 Cent verschoben; das Tempo bleibt exakt gleich (rate = 1).
enum Tuning432 {
    static let sourceHz = 440.0
    static let targetHz = 432.0
    /// ≈ −31,766 Cent
    static let cents = Float(1200 * log2(targetHz / sourceHz))
    /// Frequenzverhältnis 432/440 ≈ 0,98182
    static let ratio = targetHz / sourceHz
    /// Überlappung des Phasen-Vocoders: höher = sauberer (3…32, Standard 8).
    static let overlap: Float = 32
}

/// Baut die Signalkette Player → TimePitch (−31,77 Cent) → Limiter → Mixer.
/// Wird von der Live-Wiedergabe und vom Offline-Messtest identisch benutzt.
struct PitchChain {
    let timePitch: AVAudioUnitTimePitch
    let limiter: AVAudioUnitEffect

    init() {
        timePitch = AVAudioUnitTimePitch()
        timePitch.pitch = Tuning432.cents
        timePitch.rate = 1
        timePitch.overlap = Tuning432.overlap
        limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        // Kurzer Angriff, damit Spitzen aus der Tonhöhenverschiebung nicht übersteuern; kein Vorverstärken.
        let au = limiter.audioUnit
        AudioUnitSetParameter(au, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.002, 0)
        AudioUnitSetParameter(au, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.06, 0)
        AudioUnitSetParameter(au, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
    }

    func attach(to engine: AVAudioEngine, player: AVAudioPlayerNode, format: AVAudioFormat) {
        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(limiter)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
    }
}
