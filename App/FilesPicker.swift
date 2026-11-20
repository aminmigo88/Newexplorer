import UIKit
import UniformTypeIdentifiers

enum FilesPickerMode { case folder, files }

// Presents the Files picker on its own, as UIKit expects, and keeps this
// delegate alive until the picker reports Open or Cancel.
@MainActor
final class FilesPicker: NSObject, UIDocumentPickerDelegate {
    private static var current: FilesPicker?
    private let controller: UIDocumentPickerViewController
    private let finish: ([URL]) -> Void

    private init(mode: FilesPickerMode, finish: @escaping ([URL]) -> Void) {
        controller = UIDocumentPickerViewController(forOpeningContentTypes: mode == .folder ? [.folder] : [.data, .package], asCopy: false)
        controller.allowsMultipleSelection = mode == .files
        self.finish = finish
        super.init()
        controller.delegate = self
    }

    static func present(_ mode: FilesPickerMode, finish: @escaping ([URL]) -> Void) {
        guard let host = topViewController() else { return }
        let picker = FilesPicker(mode: mode, finish: finish)
        current = picker
        host.present(picker.controller, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { complete(urls) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { complete([]) }

    private func complete(_ urls: [URL]) {
        if FilesPicker.current === self { FilesPicker.current = nil }
        finish(urls)
    }

    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
