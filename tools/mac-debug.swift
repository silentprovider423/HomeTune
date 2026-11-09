// Steuert eine laufende Debug-Mac-App („HomeTune Test“) ohne Maus und Tastatur (siehe Mac/Debug/DebugControl.swift).
//   swift tools/mac-debug.swift "go albums" "album Golden Hour" "inspector queue" "snapshot /tmp/a.png"
import Foundation
for cmd in CommandLine.arguments.dropFirst() {
    if cmd.hasPrefix("sleep ") { Thread.sleep(forTimeInterval: Double(cmd.dropFirst(6)) ?? 1); continue }
    DistributedNotificationCenter.default().postNotificationName(.init("org.homeroll.hometune.debug"), object: nil,
                                                                 userInfo: ["cmd": cmd], deliverImmediately: true)
    Thread.sleep(forTimeInterval: 0.6)
}
