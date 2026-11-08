#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

/// Effekt-Baustein für die Stimmung: Tonhöhe per signalsmith-stretch (rate = 1, Tempo exakt gleich,
/// ohne Formant-Korrektur), dahinter ein kleiner Spitzenbegrenzer. „Original“ reicht die Samples
/// bit-genau durch (nur um die feste Latenz verzögert, damit das Umschalten ohne Sprung klappt) und
/// rechnet dann gar nichts. Umschalten mitten im Titel: kurze Überblendung bzw. spektraler Übergang.
@interface HTPitchShiftUnit : AUAudioUnit

/// Beschreibung, unter der der Baustein im Prozess registriert wird.
+ (AudioComponentDescription)componentDescription;
/// Einmal vor dem ersten `AVAudioUnitEffect(audioComponentDescription:)` aufrufen.
+ (void)registerOnce;

/// Ziel-Tonhöhe in Halbtönen (wird im Render-Thread übernommen).
@property (atomic) float semitones;
/// YES = Original (440 Hz): keine Bearbeitung, bit-genaue Samples.
@property (atomic) BOOL original;
/// Feste Verzögerung der Kette in Frames (gleich für bearbeitet und Original).
@property (nonatomic, readonly) NSInteger latencyFrames;
/// Läuft der Tonhöhen-Rechner gerade (NO im eingeschwungenen Original-Betrieb)?
@property (nonatomic, readonly) BOOL processingActive;

@end

NS_ASSUME_NONNULL_END
