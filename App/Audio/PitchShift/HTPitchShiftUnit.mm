#import "HTPitchShiftUnit.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

// signalsmith-stretch (MIT, Vendor/signalsmith-stretch) mit signalsmith-linear (MIT, Vendor/signalsmith-linear),
// FFT über Accelerate (SIGNALSMITH_USE_ACCELERATE, gesetzt in project.yml)
#include "signalsmith-stretch/signalsmith-stretch.h"

namespace {

constexpr int kMaxChannels = 2;

/// Spitzenbegrenzer mit 1,5 ms Vorausschau, Kanäle gekoppelt. Unter der Schwelle ist die Verstärkung
/// exakt 1. Ablauf: benötigte Dämpfung je Sample → Minimum über das Vorausschau-Fenster → sanftes
/// Zurückgehen (80 ms) → gleitender Mittelwert über das Fenster. So ist die Dämpfung voll erreicht,
/// wenn die (um Fenster − 1 verzögerte) Spitze ankommt – kein Übersteuern, kein hartes Abschneiden.
class PeakLimiter {
public:
    void configure(double sampleRate, int channels) {
        window = std::max(8, int(std::lround(0.0015 * sampleRate)));
        releaseCoef = float(1 - std::exp(-1 / (0.08 * sampleRate)));
        nch = channels;
        for (int c = 0; c < kMaxChannels; ++c) delay[c].assign(size_t(window - 1), 0.f);
        box.assign(size_t(window), 1.f);
        cap = 1;
        while (cap < window + 1) cap <<= 1;
        minVal.assign(size_t(cap), 1.f);
        minTime.assign(size_t(cap), 0);
        reset();
    }

    void reset() {
        for (int c = 0; c < kMaxChannels; ++c) std::fill(delay[c].begin(), delay[c].end(), 0.f);
        std::fill(box.begin(), box.end(), 1.f);
        boxSum = window;
        notOne = 0;
        boxIndex = delayIndex = 0;
        head = tail = 0;
        t = 0;
        rel = 1;
    }

    /// Verzögerung des Signals in Frames.
    int latency() const { return window - 1; }

    void process(float *const *io, int n) {
        const size_t mask = size_t(cap - 1);
        const int d = window - 1;
        for (int i = 0; i < n; ++i) {
            float peak = 0;
            for (int c = 0; c < nch; ++c) peak = std::max(peak, std::fabs(io[c][i]));
            const float need = peak > threshold ? threshold / peak : 1.f;

            // gleitendes Minimum (monotone Schlange)
            while (head != tail && minVal[(tail - 1) & mask] >= need) --tail;
            minVal[tail & mask] = need;
            minTime[tail & mask] = t;
            ++tail;
            while (minTime[head & mask] + uint64_t(window) <= t) ++head;
            const float held = minVal[head & mask];
            ++t;

            // sofort dämpfen, langsam zurück
            if (held < rel) rel = held;
            else rel += (held - rel) * releaseCoef;
            if (held >= 1.f && rel > 0.99999f) rel = 1.f;

            // gleitender Mittelwert
            const float old = box[size_t(boxIndex)];
            if (old != 1.f) --notOne;
            if (rel != 1.f) ++notOne;
            box[size_t(boxIndex)] = rel;
            boxIndex = boxIndex + 1 == window ? 0 : boxIndex + 1;
            boxSum += double(rel) - double(old);
            if (notOne == 0) boxSum = window;
            const float gain = notOne == 0 ? 1.f : float(boxSum / window);

            for (int c = 0; c < nch; ++c) {
                const float x = io[c][i];
                float y = x;
                if (d > 0) {
                    y = delay[c][size_t(delayIndex)];
                    delay[c][size_t(delayIndex)] = x;
                }
                io[c][i] = gain == 1.f ? y : y * gain;
            }
            if (d > 0) delayIndex = delayIndex + 1 == d ? 0 : delayIndex + 1;
        }
    }

private:
    static constexpr float threshold = 0.966f; // −0,3 dBFS
    int window = 72, nch = 2, cap = 128;
    float releaseCoef = 0.0003f, rel = 1;
    std::vector<float> delay[kMaxChannels], box, minVal;
    std::vector<uint64_t> minTime;
    double boxSum = 72;
    int notOne = 0, boxIndex = 0, delayIndex = 0;
    uint64_t head = 0, tail = 0, t = 0;
};

/// Bandbegrenzte Interpolation (Kaiser-gefensterter Sinc, 64 Stützstellen, 256 Phasen linear interpoliert).
/// Liest einen Datenstrom an gebrochenen Positionen – damit wird die Tonhöhe exakt um das gewünschte
/// Verhältnis verschoben (Abspielen schneller/langsamer = Frequenz × Verhältnis).
class SincTable {
public:
    static constexpr int half = 32, taps = 2 * half, phases = 256;

    SincTable() {
        const double cutoff = 0.92; // relativ zur Nyquist-Frequenz (≈ 22 kHz bei 48 kHz)
        const double beta = 9.0;
        auto bessel0 = [](double x) {
            double sum = 1, term = 1;
            for (int k = 1; k < 30; ++k) { term *= (x / (2 * k)) * (x / (2 * k)); sum += term; }
            return sum;
        };
        const double norm = bessel0(beta);
        table.resize(size_t(phases + 1) * taps);
        for (int p = 0; p <= phases; ++p) {
            const double frac = double(p) / phases;
            double sum = 0;
            for (int t = 0; t < taps; ++t) {
                const double x = double(t - half + 1) - frac; // Abstand zur Leseposition
                const double sinc = x == 0 ? 1 : std::sin(M_PI * cutoff * x) / (M_PI * cutoff * x);
                const double r = x / half;
                const double w = std::fabs(r) >= 1 ? 0 : bessel0(beta * std::sqrt(1 - r * r)) / norm;
                table[size_t(p) * taps + size_t(t)] = float(cutoff * sinc * w);
                sum += cutoff * sinc * w;
            }
            // jede Phase mit Verstärkung 1 bei Gleichspannung (keine Pegel-Welligkeit)
            for (int t = 0; t < taps; ++t) table[size_t(p) * taps + size_t(t)] = float(table[size_t(p) * taps + size_t(t)] / sum);
        }
    }

    /// Koeffizienten für den Bruchteil `frac` ∈ [0, 1)
    void coefficients(double frac, float *out) const {
        const double pos = frac * phases;
        const int p = std::min(phases - 1, int(pos));
        const float f = float(pos - p);
        const float *a = &table[size_t(p) * taps], *b = a + taps;
        for (int t = 0; t < taps; ++t) out[t] = a[t] + f * (b[t] - a[t]);
    }

private:
    std::vector<float> table;
};

/// Rechenkern: Tonhöhe = Zeitdehnung (signalsmith-stretch, Tonhöhe bleibt) × bandbegrenztes Umtasten
/// (Tonhöhe und Tempo × Verhältnis). Zusammen: Frequenz exakt × Verhältnis, Tempo exakt 100 %.
/// (Der Halbton-Modus von signalsmith trifft reine Töne nur ungefähr – im Bass um bis zu 20 Cent daneben.)
/// Dahinter der Begrenzer; parallel das unbearbeitete Signal um dieselbe Latenz verzögert.
/// Original ↔ bearbeitet: 50-ms-Überblendung gleicher Leistung bei Verhältnis 1 (phasengleich), die
/// Tonhöhe gleitet danach bzw. davor in ≈ 50 ms; zwischen zwei Stimmungen gleitet nur die Tonhöhe.
class PitchKernel {
public:
    using Stretch = signalsmith::stretch::SignalsmithStretch<float>;

    std::atomic<float> semitones{float(12 * std::log2(432.0 / 440.0))};
    std::atomic<bool> original{false};
    std::atomic<bool> resetPending{false};
    std::atomic<bool> running{true};
    std::atomic<int> latency{0};

    void configure(double sampleRate, int channels, int maxFrames) {
        nch = std::min(channels, kMaxChannels);
        this->maxFrames = maxFrames;
        // Standard-Voreinstellung wie in der Frequenz-App (Block 120 ms, Abstand 30 ms), ohne Formant-Korrektur
        stretch.presetDefault(nch, float(sampleRate));
        limiter.configure(sampleRate, nch);
        const int lat = stretch.inputLatency() + stretch.outputLatency() + readLag + limiter.latency();
        latency.store(lat);
        seekLength = stretch.seekLength();
        warmup = stretch.outputLatency() + stretch.intervalSamples() + readLag + limiter.latency() + 1;
        fadeStep = float(1 / (0.05 * sampleRate));
        glideStep = 0.6 / sampleRate; // Verhältnis je Sample → 432 ↔ 528 in ≈ 45 ms
        size_t size = 1;
        while (size < size_t(std::max(lat, seekLength) + maxFrames + 1)) size <<= 1;
        ringMask = size - 1;
        size_t fifo = 1;
        while (fifo < size_t(2 * maxFrames + 4 * SincTable::taps)) fifo <<= 1;
        fifoSize = fifo;
        for (int c = 0; c < kMaxChannels; ++c) {
            ring[c].assign(size, 0.f);
            proc[c].assign(size_t(maxFrames), 0.f);
            stretched[c].assign(size_t(2 * maxFrames + 2 * SincTable::taps), 0.f);
            fifoBuf[c].assign(2 * fifo, 0.f);
            history[c].assign(size_t(seekLength), 0.f);
        }
        resetState();
        configured = true;
    }

    /// Alles leeren und ohne Überblendung in den gewünschten Zustand springen.
    void resetState() {
        for (int c = 0; c < kMaxChannels; ++c) std::fill(ring[c].begin(), ring[c].end(), 0.f);
        writePos = 0;
        stretch.reset();
        limiter.reset();
        resetFifo();
        warmupLeft = 0;
        if (original.load()) {
            stretchOn = false;
            mix = 0;
            ratio = 1;
        } else {
            stretchOn = true;
            mix = 1;
            ratio = targetRatio();
        }
        running.store(stretchOn);
    }

    void process(const AudioBufferList *in, AudioBufferList *out, int n) {
        const int ch = std::min<int>({nch, int(in->mNumberBuffers), int(out->mNumberBuffers)});
        float *outs[kMaxChannels];
        const float *ins[kMaxChannels];
        for (int c = 0; c < ch; ++c) {
            ins[c] = static_cast<const float *>(in->mBuffers[c].mData);
            outs[c] = static_cast<float *>(out->mBuffers[c].mData);
        }
        if (!configured || ch < nch || n > maxFrames) {
            for (int c = 0; c < ch; ++c) std::memcpy(outs[c], ins[c], size_t(n) * sizeof(float));
            return;
        }
        if (resetPending.exchange(false)) resetState();
        const bool wantOriginal = original.load(std::memory_order_relaxed);
        const int lat = latency.load(std::memory_order_relaxed);

        // 1. Eingang in den Ring (Vorlauf für den Stretcher und verzögertes Original)
        for (int c = 0; c < nch; ++c) {
            for (int i = 0; i < n; ++i) ring[c][(writePos + uint64_t(i)) & ringMask] = ins[c][i];
        }

        // 2. Original → bearbeitet: Stretcher mit dem Vorlauf neu ansetzen, Verhältnis 1 (phasengleich zum
        //    Original, Überblendung ohne Auslöschung), danach gleitet die Tonhöhe zur Zielstimmung.
        if (!wantOriginal && !stretchOn) {
            for (int c = 0; c < nch; ++c) {
                for (int i = 0; i < seekLength; ++i) {
                    history[c][size_t(i)] = ring[c][(writePos - uint64_t(seekLength) + uint64_t(i)) & ringMask];
                }
            }
            float *hist[kMaxChannels];
            for (int c = 0; c < nch; ++c) hist[c] = history[c].data();
            stretch.reset();
            stretch.seek(hist, seekLength, 1.0);
            limiter.reset();
            resetFifo();
            ratio = 1;
            warmupLeft = warmup;
            stretchOn = true;
        }
        if (wantOriginal) warmupLeft = 0;

        // 3. Bearbeiten: Ziel-Verhältnis erst nach dem Einblenden, vor dem Ausblenden zurück auf 1
        float *procs[kMaxChannels];
        for (int c = 0; c < nch; ++c) procs[c] = proc[c].data();
        if (stretchOn) {
            const double goal = (!wantOriginal && mix >= 1 && warmupLeft == 0) ? targetRatio() : 1.0;
            render(ins, procs, n, goal);
            limiter.process(procs, n);
        }

        // 4. Ausgeben bzw. überblenden
        const uint64_t dryStart = writePos - uint64_t(lat);
        const float target = wantOriginal ? 0.f : 1.f;
        const bool mayFadeOut = ratio == 1.0; // erst ausblenden, wenn die Tonhöhe beim Original ist
        if (!stretchOn) {
            // Original: bit-genau, nur verzögert
            for (int c = 0; c < nch; ++c) {
                for (int i = 0; i < n; ++i) outs[c][i] = ring[c][(dryStart + uint64_t(i)) & ringMask];
            }
        } else if (mix >= 1 && (target >= 1 || !mayFadeOut) && warmupLeft == 0) {
            for (int c = 0; c < nch; ++c) std::memcpy(outs[c], procs[c], size_t(n) * sizeof(float));
        } else {
            // Einblenden aus dem Original ist phasengleich → lineare Überblendung (konstanter Pegel);
            // Ausblenden nach dem Gleiten hat beliebige Phasenlagen → gleiche Leistung.
            if (mix >= 1 && target <= 0) coherentFade = false;
            if (mix <= 0 && target >= 1) coherentFade = true;
            for (int i = 0; i < n; ++i) {
                if (warmupLeft > 0) --warmupLeft;
                else if (mix < target) mix = std::min(target, mix + fadeStep);
                else if (mix > target && mayFadeOut) mix = std::max(target, mix - fadeStep);
                const uint64_t r = (dryStart + uint64_t(i)) & ringMask;
                if (mix <= 0) {
                    for (int c = 0; c < nch; ++c) outs[c][i] = ring[c][r];
                } else if (mix >= 1) {
                    for (int c = 0; c < nch; ++c) outs[c][i] = procs[c][i];
                } else {
                    const float a = mix * float(M_PI_2);
                    const float gp = coherentFade ? mix : std::sin(a), gd = coherentFade ? 1 - mix : std::cos(a);
                    for (int c = 0; c < nch; ++c) outs[c][i] = gp * procs[c][i] + gd * ring[c][r];
                }
            }
            if (mix <= 0 && target <= 0) stretchOn = false; // ab jetzt rechnet nichts mehr
        }
        writePos += uint64_t(n);
        running.store(stretchOn, std::memory_order_relaxed);
    }

private:
    /// Abstand der Leseposition zum neuesten gedehnten Sample (halbe Filterlänge + 1)
    static constexpr int readLag = SincTable::half + 1;

    double targetRatio() const { return std::pow(2.0, double(semitones.load(std::memory_order_relaxed)) / 12.0); }

    void resetFifo() {
        for (int c = 0; c < kMaxChannels; ++c) std::fill(fifoBuf[c].begin(), fifoBuf[c].end(), 0.f);
        fifoWrite = 0;
        readPos = -double(readLag);
    }

    /// n Eingangs-Samples → n Ausgangs-Samples mit Verhältnis `ratio` (gleitet auf `goal`).
    void render(const float *const *ins, float *const *outs, int n, double goal) {
        // a) Wie weit liest das Umtasten in diesem Durchgang? (Verhältnis gleitet je Sample)
        double r = ratio, advance = 0;
        for (int i = 0; i < n; ++i) {
            if (r < goal) r = std::min(goal, r + glideStep);
            else if (r > goal) r = std::max(goal, r - glideStep);
            advance += r;
        }
        // b) So viele gedehnte Samples anfordern, dass das Filter bis zur letzten Leseposition reicht
        // (+ 1 Vorrat, damit der Stretcher schon im ersten Durchgang n:n läuft – sonst 1 Sample Versatz)
        const int64_t needEnd = int64_t(std::floor(readPos + advance - r)) + SincTable::half + 2;
        const int k = int(std::clamp<int64_t>(needEnd - fifoWrite, 0, int64_t(stretched[0].size())));
        float *tmp[kMaxChannels];
        for (int c = 0; c < nch; ++c) tmp[c] = stretched[c].data();
        stretch.process(ins, n, tmp, k);
        const uint64_t mask = uint64_t(fifoSize - 1);
        for (int c = 0; c < nch; ++c) {
            float *buf = fifoBuf[c].data();
            for (int i = 0; i < k; ++i) {
                const uint64_t w = uint64_t(fifoWrite + i) & mask;
                buf[w] = buf[w + fifoSize] = tmp[c][i]; // doppelt abgelegt → Filterfenster immer zusammenhängend
            }
        }
        fifoWrite += k;
        // c) Umtasten
        float coef[SincTable::taps];
        r = ratio;
        for (int i = 0; i < n; ++i) {
            const double base = std::floor(readPos);
            sinc.coefficients(readPos - base, coef);
            const uint64_t start = uint64_t(int64_t(base) - SincTable::half + 1) & mask;
            for (int c = 0; c < nch; ++c) {
                const float *src = fifoBuf[c].data() + start;
                float acc = 0;
                for (int t = 0; t < SincTable::taps; ++t) acc += coef[t] * src[t];
                outs[c][i] = acc;
            }
            if (r < goal) r = std::min(goal, r + glideStep);
            else if (r > goal) r = std::max(goal, r - glideStep);
            readPos += r;
        }
        ratio = r;
    }

    Stretch stretch;
    PeakLimiter limiter;
    SincTable sinc;
    bool configured = false;
    int nch = 2, maxFrames = 4096, seekLength = 0, warmup = 0, warmupLeft = 0;
    float fadeStep = 0.0004f, mix = 1;
    double ratio = 1, glideStep = 1e-5, readPos = 0;
    int64_t fifoWrite = 0;
    size_t fifoSize = 0;
    bool stretchOn = true, coherentFade = true;
    std::vector<float> ring[kMaxChannels], proc[kMaxChannels], history[kMaxChannels];
    std::vector<float> stretched[kMaxChannels], fifoBuf[kMaxChannels];
    uint64_t ringMask = 0, writePos = 0;
};

/// Alles, was der Render-Block braucht (ohne Objective-C im Audio-Thread).
struct RenderState {
    PitchKernel kernel;
    AudioBufferList *inputList = nullptr;
    std::vector<float> inputMemory[kMaxChannels], outputMemory[kMaxChannels];
    int capacity = 0;
    int channels = 2;

    void configure(double sampleRate, int ch, int maxFrames) {
        channels = std::min(ch, kMaxChannels);
        capacity = maxFrames;
        for (int c = 0; c < kMaxChannels; ++c) {
            inputMemory[c].assign(size_t(maxFrames), 0.f);
            outputMemory[c].assign(size_t(maxFrames), 0.f);
        }
        if (!inputList) {
            inputList = static_cast<AudioBufferList *>(calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * kMaxChannels));
        }
        kernel.configure(sampleRate, channels, maxFrames);
    }

    ~RenderState() { free(inputList); }
};

} // namespace

@implementation HTPitchShiftUnit {
    RenderState *_state;
    AUAudioUnitBus *_inputBus;
    AUAudioUnitBus *_outputBus;
    AUAudioUnitBusArray *_inputBusArray;
    AUAudioUnitBusArray *_outputBusArray;
}

+ (AudioComponentDescription)componentDescription {
    AudioComponentDescription d = {};
    d.componentType = kAudioUnitType_Effect;
    d.componentSubType = 'htpt';
    d.componentManufacturer = 'Htun';
    return d;
}

+ (void)registerOnce {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [AUAudioUnit registerSubclass:self asComponentDescription:[self componentDescription]
                                 name:@"HomeTune: Stimmung" version:1];
    });
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)componentDescription
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)outError {
    self = [super initWithComponentDescription:componentDescription options:options error:outError];
    if (!self) return nil;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _inputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:outError];
    _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:outError];
    if (!_inputBus || !_outputBus) return nil;
    _inputBus.maximumChannelCount = kMaxChannels;
    _outputBus.maximumChannelCount = kMaxChannels;
    _inputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_inputBus]];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outputBus]];
    _state = new RenderState();
    self.maximumFramesToRender = 4096;
    return self;
}

- (void)dealloc {
    delete _state;
}

- (AUAudioUnitBusArray *)inputBusses { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }
- (BOOL)canProcessInPlace { return NO; }

- (float)semitones { return _state->kernel.semitones.load(); }
- (void)setSemitones:(float)semitones { _state->kernel.semitones.store(semitones); }
- (BOOL)original { return _state->kernel.original.load(); }
- (void)setOriginal:(BOOL)original { _state->kernel.original.store(original); }
- (NSInteger)latencyFrames { return _state->kernel.latency.load(); }
- (BOOL)processingActive { return _state->kernel.running.load(); }

- (NSTimeInterval)latency {
    double rate = _outputBus.format.sampleRate;
    return rate > 0 ? double(_state->kernel.latency.load()) / rate : 0;
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) return NO;
    AVAudioFormat *inF = _inputBus.format, *outF = _outputBus.format;
    if (inF.channelCount != outF.channelCount || inF.sampleRate != outF.sampleRate || outF.channelCount > kMaxChannels
        || outF.commonFormat != AVAudioPCMFormatFloat32 || outF.isInterleaved || inF.isInterleaved) {
        if (outError) *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
        return NO;
    }
    _state->configure(outF.sampleRate, int(outF.channelCount), int(MAX(self.maximumFramesToRender, 512)));
    return YES;
}

- (void)reset {
    [super reset];
    _state->kernel.resetPending.store(true);
}

- (AUInternalRenderBlock)internalRenderBlock {
    RenderState *state = _state;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                              AUAudioFrameCount frameCount, NSInteger outputBusNumber, AudioBufferList *outputData,
                              const AURenderEvent *realtimeEventListHead, AURenderPullInputBlock pullInputBlock) {
        if (!pullInputBlock) return kAudioUnitErr_NoConnection;
        if (int(frameCount) > state->capacity || !state->inputList) return kAudioUnitErr_TooManyFramesToProcess;
        AudioBufferList *inList = state->inputList;
        inList->mNumberBuffers = UInt32(state->channels);
        for (int c = 0; c < state->channels; ++c) {
            inList->mBuffers[c].mNumberChannels = 1;
            inList->mBuffers[c].mData = state->inputMemory[c].data();
            inList->mBuffers[c].mDataByteSize = UInt32(frameCount * sizeof(float));
        }
        AudioUnitRenderActionFlags pullFlags = 0;
        AUAudioUnitStatus err = pullInputBlock(&pullFlags, timestamp, frameCount, 0, inList);
        if (err != noErr) return err;
        for (UInt32 c = 0; c < outputData->mNumberBuffers && c < UInt32(kMaxChannels); ++c) {
            if (!outputData->mBuffers[c].mData) outputData->mBuffers[c].mData = state->outputMemory[c].data();
            outputData->mBuffers[c].mDataByteSize = UInt32(frameCount * sizeof(float));
        }
        state->kernel.process(inList, outputData, int(frameCount));
        return noErr;
    };
}

@end
