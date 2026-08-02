import SwiftUI
import UniformTypeIdentifiers

/// `.fileExporter` için ince bir sarmalayıcı: `ProjectArchive.write(project:)`'in diske
/// zaten yazdığı paket dizinini olduğu gibi taşır. Paylaşım sayfası (`UIActivityViewController`)
/// bir klasörü doğrudan gönderemiyor — cihazda "error fetching file provider domain"
/// hatasıyla boş/bozuk açılıyordu. Belge dışa aktarıcı (`UIDocumentPickerViewController`
/// tabanlı) klasörleri doğrudan kopyalayarak yazdığından bu sorunu yaşamıyor; kullanıcı
/// da depolamada tam olarak istediği yeri seçebiliyor.
struct ProjectArchiveDocument: FileDocument {
    /// Yalnızca dışa aktarma için var; içe aktarma `.fileImporter` + `ProjectArchive.read`
    /// üzerinden yürüdüğü için bu tip hiçbir zaman okuma amacıyla kurulmaz.
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [ProjectArchive.utType] }

    /// `FileWrapper` Sendable değil, `FileDocument` ise Sendable bir tip istiyor; bu
    /// yüzden sarmalayıcıyı saklamak yerine yazma anında kuruyoruz.
    let packageURL: URL

    init(packageURL: URL) {
        self.packageURL = packageURL
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: packageURL)
    }
}
