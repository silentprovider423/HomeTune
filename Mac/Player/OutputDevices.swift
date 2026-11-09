import SwiftUI
import CoreAudio
import AudioToolbox
import AVFoundation

/// Ausgabegeräte (CoreAudio, inkl. AirPlay-Lautsprecher, sobald macOS sie anbietet). Die Auswahl gilt nur für
/// HomeTune: Das Gerät wird am Ausgang der eigenen AVAudioEngine gesetzt, die Systemeinstellung bleibt unberührt.
enum OutputDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let isAirPlay: Bool
    }

    static func all() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard outputChannels(id) > 0, let name = string(id, kAudioObjectPropertyName),
                  let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return Device(id: id, name: name, uid: uid, isAirPlay: transport(id) == kAudioDeviceTransportTypeAirPlay)
        }
    }

    static func systemDefault() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    /// Aktuelles Gerät am Ausgang der Engine
    static func current(of engine: AVAudioEngine) -> AudioDeviceID? {
        guard let unit = engine.outputNode.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let r = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return r == noErr ? id : nil
    }

    /// Gerät nur für HomeTune setzen; die Engine meldet danach eine Konfigurationsänderung und spielt weiter.
    @discardableResult
    static func select(_ id: AudioDeviceID, on engine: AVAudioEngine) -> Bool {
        guard let unit = engine.outputNode.audioUnit else { return false }
        var dev = id
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                    UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        return t
    }
}

/// AirPlay-/Ausgabe-Knopf neben der Lautstärke
struct OutputDeviceMenu: View {
    @Environment(AppModel.self) private var app
    @State private var devices: [OutputDevices.Device] = []
    @State private var current: AudioDeviceID?

    var body: some View {
        Menu {
            Section("Ausgabe") {
                ForEach(devices) { d in
                    Button {
                        if OutputDevices.select(d.id, on: app.player.engine.engine) {
                            current = d.id
                            app.notice.show(String(localized: "Ausgabe: \(d.name)"), icon: d.isAirPlay ? "airplayaudio" : "hifispeaker")
                        }
                    } label: {
                        if d.id == current { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                    }
                }
            }
        } label: {
            Image(systemName: "airplayaudio")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Ausgabegerät"))
        .accessibilityIdentifier("player.output")
        .onAppear(perform: refresh)
        .onHover { if $0 { refresh() } }
    }

    private func refresh() {
        devices = OutputDevices.all()
        current = OutputDevices.current(of: app.player.engine.engine) ?? OutputDevices.systemDefault()
    }
}
