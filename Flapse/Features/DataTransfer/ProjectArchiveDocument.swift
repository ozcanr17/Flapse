import SwiftUI
import UniformTypeIdentifiers

/// `.fileExporter` için ince bir sarmalayıcı: `ProjectArchive.write(_:)`'in diske
/// zaten yazdığı paket dizinini olduğu gibi taşır. Paylaşım sayfası (`UIActivityViewController`)
/// bir klasörü doğrudan gönderemiyor — cihazda "error fetching file provider domain"
/// hatasıyla boş/bozuk açılıyordu. Belge dışa aktarıcı (`UIDocumentPickerViewController`
/// tabanlı) klasörleri doğrudan kopyalayarak yazdığından bu sorunu yaşamıyor; kullanıcı
/// da depolamada tam olarak istediği yeri seçebiliyor.
struct ProjectArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [ProjectArchive.utType] }
    static var writableContentTypes: [UTType] { [ProjectArchive.utType] }

    let wrapper: FileWrapper

    init(wrapper: FileWrapper) {
        self.wrapper = wrapper
    }

    init(configuration: ReadConfiguration) throws {
        wrapper = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        wrapper
    }
}
