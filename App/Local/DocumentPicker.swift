import UIKit
import UniformTypeIdentifiers

/// Dateien-Dialog direkt über UIKit statt SwiftUIs `.fileImporter` (der hing im Simulator nach „Öffnen“):
/// wie in der Frequenz-App vom obersten Controller zeigen, Ergebnis über den Delegate. Geöffnet wird ohne Kopie
/// (`asCopy: false`) – die URLs sind security-scoped und werden als Bookmark gemerkt (LocalLibrary).
@MainActor
final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPicker()
    private var completion: (([URL]) -> Void)?

    func present(_ kind: LocalImportKind, completion: @escaping ([URL]) -> Void) {
        let types: [UTType] = kind == .folder ? [.folder] : TagReader.contentTypes
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        self.completion = completion
        Self.topController()?.present(picker, animated: true)
    }

    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        MainActor.assumeIsolated {
            let done = completion
            completion = nil
            done?(urls)
        }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        MainActor.assumeIsolated { completion = nil }
    }

    /// Oberster sichtbarer Controller (auch wenn gerade ein Sheet oder der Player offen ist).
    private static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}
