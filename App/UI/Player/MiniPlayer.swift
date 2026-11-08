import SwiftUI
import AVKit
import MediaPlayer

/// Mini-Player über der Tab-Leiste (iOS 26: `tabViewBottomAccessory`).
struct MiniPlayer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let namespace: Namespace.ID

    var body: some View {
        let p = app.player
        let song = p.currentSong
        HStack(spacing: 10) {
            CoverArt(id: song?.coverArt, size: 34, corner: 7)
                .frame(width: 34, height: 34)
                .matchedTransitionSource(id: "miniArtwork", in: namespace)
            VStack(alignment: .leading, spacing: 0) {
                Text(song?.title ?? String(localized: "Nicht wiedergegeben"))
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                if placement != .inline, let a = song?.artist {
                    Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if p.isLoading {
                ProgressView().frame(width: 36, height: 36)
            } else {
                Button { p.togglePlay() } label: {
                    Image(systemName: p.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 36, height: 36).contentShape(.rect)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(song == nil)
                .accessibilityLabel(p.isPlaying ? Text("Pause") : Text("Wiedergeben"))
                .accessibilityIdentifier("mini.playPause")
            }
            if placement != .inline {
                Button { p.next() } label: {
                    Image(systemName: "forward.fill").font(.title3).frame(width: 36, height: 36).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(song == nil)
                .accessibilityLabel(Text("Nächster Titel"))
            }
        }
        .padding(.horizontal, 12)
        .contentShape(.rect)
        .onTapGesture { if p.hasItem { app.showNowPlaying = true } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("miniPlayer")
        .accessibilityLabel(Text("Mini-Player, Wiedergabesteuerung"))
    }
}

/// AirPlay-/Ausgabegerät-Auswahl (AVRoutePickerView).
struct AirPlayButton: UIViewRepresentable {
    var tint: UIColor = .white
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = tint.withAlphaComponent(0.75)
        v.activeTintColor = tint
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

/// Systemlautstärke (wie in Apples „Jetzt läuft“).
struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.tintColor = .white
        v.setVolumeThumbImage(UIImage(), for: .normal)
        return v
    }
    func updateUIView(_ v: MPVolumeView, context: Context) {}
}
