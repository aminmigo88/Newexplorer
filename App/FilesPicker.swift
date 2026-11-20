import UIKit
import SwiftUI
import UniformTypeIdentifiers

enum FilesPickerMode { case folder, files }

// DIAGNOSTIC BUILD ONLY: picker variants chosen by launch environment.
enum PickerDiag {
    static let env = ProcessInfo.processInfo.environment
    static var types: [UTType] { env["NX_TYPES"] == "item" ? [.item] : [.data, .package] }
    static var copy: Bool { env["NX_COPY"] == "1" }
    static var multi: Bool { env["NX_MULTI"] != "0" }
    static var full: Bool { env["NX_FULL"] == "1" }
    static var importer: Bool { env["NX_IMPORTER"] == "1" }
    static var embed: Bool { env["NX_EMBED"] == "1" }
}

@MainActor
final class FilesPicker: NSObject, UIDocumentPickerDelegate {
    private static var current: FilesPicker?
    private let controller: UIDocumentPickerViewController
    private let finish: ([URL]) -> Void

    private init(mode: FilesPickerMode, finish: @escaping ([URL]) -> Void) {
        let types: [UTType] = mode == .folder ? [.folder] : PickerDiag.types
        controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: mode == .files && PickerDiag.copy)
        controller.allowsMultipleSelection = mode == .files && PickerDiag.multi
        if PickerDiag.full { controller.modalPresentationStyle = .fullScreen }
        self.finish = finish
        super.init()
        controller.delegate = self
        NSLog("NXDIAG modal present mode=%@ types=%@ multi=%d copy=%d", "\(mode)", "\(types)", controller.allowsMultipleSelection ? 1 : 0, PickerDiag.copy ? 1 : 0)
    }

    static func present(_ mode: FilesPickerMode, finish: @escaping ([URL]) -> Void) {
        guard let host = topViewController() else { NSLog("NXDIAG no host"); return }
        let picker = FilesPicker(mode: mode, finish: finish)
        current = picker
        host.present(picker.controller, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        NSLog("NXDIAG modal didPick %@", "\(urls)")
        complete(urls)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        NSLog("NXDIAG modal cancelled")
        complete([])
    }

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

// The 0.2.2 approach, kept here only to compare in the diagnostic run.
struct LegacyRequest: Identifiable {
    let id = UUID()
    let mode: FilesPickerMode
    let pane: Pane
}

struct LegacyFilesPicker: UIViewControllerRepresentable {
    let mode: FilesPickerMode
    let finish: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: mode == .folder ? [.folder] : [.data, .package], asCopy: false)
        picker.allowsMultipleSelection = mode == .files
        picker.delegate = context.coordinator
        NSLog("NXDIAG embed present mode=%@", "\(mode)")
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finish: ([URL]) -> Void
        init(_ finish: @escaping ([URL]) -> Void) { self.finish = finish }
        deinit { NSLog("NXDIAG embed coordinator released") }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            NSLog("NXDIAG embed didPick %@", "\(urls)")
            finish(urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            NSLog("NXDIAG embed cancelled")
            finish([])
        }
    }
}
