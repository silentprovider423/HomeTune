# Vendored third-party code

Only the headers needed for building are included (no tests, demos or build files). Both libraries are
header-only and MIT-licensed; their license files are next to the sources.

| Library | Version | Source | License |
|---|---|---|---|
| signalsmith-stretch | 1.4.0 + 1 commit (`88061fd`, header reports 1.3.2) | https://github.com/Signalsmith-Audio/signalsmith-stretch | MIT, [signalsmith-stretch/LICENSE.txt](signalsmith-stretch/LICENSE.txt) |
| signalsmith-linear | 0.6.6 (`7bb1c8f`) | https://github.com/Signalsmith-Audio/linear | MIT, [signalsmith-linear/LICENSE.txt](signalsmith-linear/LICENSE.txt) |

Used in `App/Audio/PitchShift/HTPitchShiftUnit.mm` with `SIGNALSMITH_USE_ACCELERATE` (FFT via Apple's Accelerate).
HomeTune uses the stretcher for time-stretching only (rate = n:n·ratio, no formant correction) and changes
the pitch by band-limited resampling, so the frequency ratio is exact and the tempo stays at 100 %.
