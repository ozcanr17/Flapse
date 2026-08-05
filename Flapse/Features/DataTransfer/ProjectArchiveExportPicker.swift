import SwiftUI
import UniformTypeIdentifiers

struct ProjectArchiveExportPicker: UIViewControllerRepresentable {
    let sourceURL: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [sourceURL], asCopy: true)
        controller.shouldShowFileExtensions = true
        controller.allowsMultipleSelection = false
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}
