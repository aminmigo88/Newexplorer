import SwiftUI
import UniformTypeIdentifiers

enum FilesPickerMode { case folder, files }

struct FilesPickerRequest: Identifiable {
    let id = UUID()
    let mode: FilesPickerMode
    let pane: Pane
}

struct FilesPicker: UIViewControllerRepresentable {
    let mode: FilesPickerMode
    let finish: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: mode == .folder ? [.folder] : [.data, .package], asCopy: false)
        picker.allowsMultipleSelection = mode == .files
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finish: ([URL]) -> Void
        init(_ finish: @escaping ([URL]) -> Void) { self.finish = finish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish([]) }
    }
}
