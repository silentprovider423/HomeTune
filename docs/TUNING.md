# Tuning (optional)

By default HomeTune plays every file untouched (440 Hz, bit-exact). In *Settings → Tuning* you can choose another tuning: at 432 Hz every track is pitched down by 1200·log2(432/440) ≈ **−31.77 cents** (A4 = 432 Hz instead of 440 Hz) on the device, with the tempo unchanged. *528 Hz* means the conventional A4 = 444 Hz tuning (C5 = 528 Hz, +15.67 cents) – not A4 = 528 Hz. The choice only appears in *Settings → Tuning*; the player and album pages show the file format, like Apple's Lossless badge.

Switching works instantly, also in the middle of a song, without a click.

## How good is the pitch shifting?

The test suite renders sine tones through exactly the same audio chain as the app and measures them with an FFT (simulator, 48 kHz). For comparison the same measurement with Apple's `AVAudioUnitTimePitch` (overlap 32), which HomeTune 1.0 used:

| Tuning | Input | Output | Expected | Signal-to-noise (1.0 → 1.1) |
|---|---|---|---|---|
| 432 Hz | 440 Hz | 431.99 Hz | 432.00 Hz | 75.8 → 65.3 dB |
| 432 Hz | 110 Hz | 108.01 Hz | 108.00 Hz | 69.1 → 59.0 dB |
| 432 Hz | 1000 Hz | 981.82 Hz | 981.82 Hz | 70.4 → 60.6 dB |
| 432 Hz | C-E-G chord | exact | – | 54.0 → 58.0 dB |
| 528 Hz (A4 = 444) | 440 Hz | 444.01 Hz | 444.00 Hz | 70.9 → 74.4 dB |
| 528 Hz (A4 = 444) | C-E-G chord | exact | – | 63.8 → 66.0 dB |
| 440 Hz | noise + tones | bit-exact | bit-exact | – |
| all | 2.000 s tone burst | 2.005 s | 2.000 s (tempo unchanged) | – |

Switching 432 → 528 → 440 → 432 in the middle of a tone keeps the level within 0.61–1.07× without gaps, and the largest sample step stays at the level of the input (no click). CPU load in the simulator (Mac, one core): 1.2 % for the pitch shifter, 0.03 % at 440 Hz, 1.6 % for TimePitch. The chain uses signalsmith-stretch only for time-stretching and does the pitch change by resampling, because its built-in semitone mode shifted pure low tones by only ~12 instead of 32 cents (100 Hz → 99.3 Hz instead of 98.2 Hz) in our tests.
