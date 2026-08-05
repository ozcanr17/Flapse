import SwiftUI

enum ProjectShareAction: Equatable {
    case streak
    case compare
    case story
    case archiveFolder
    case archiveSingleFile
}

struct ProjectShareOptionsSheet: View {
    let canCreateComparison: Bool
    let onSelect: (ProjectShareAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    option(
                        String(localized: "Seri Kartı", bundle: .appLanguage),
                        icon: "flame.fill",
                        action: .streak
                    )

                    if canCreateComparison {
                        option(
                            String(localized: "Önce & Sonra Kartı", bundle: .appLanguage),
                            icon: "rectangle.split.2x1.fill",
                            action: .compare
                        )
                        option(
                            String(localized: "Hikaye Kartı (9:16)", bundle: .appLanguage),
                            icon: "rectangle.portrait.fill",
                            action: .story
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Proje Arşivi (Tüm Kareler)")
                            .font(Theme.caption(13))
                            .foregroundStyle(theme.inkMuted)
                            .padding(.horizontal, 4)

                        option(
                            String(localized: "Klasör Olarak", table: "ArchiveExport", bundle: .appLanguage),
                            subtitle: String(localized: "Fotoğraf ve videolar Dosyalar'da ayrı ayrı görünür", table: "ArchiveExport", bundle: .appLanguage),
                            icon: "folder.fill",
                            action: .archiveFolder
                        )
                        option(
                            String(localized: "Tek Dosya Olarak", table: "ArchiveExport", bundle: .appLanguage),
                            subtitle: String(localized: "Göndermek için sıkıştırılmış .flapseproject", table: "ArchiveExport", bundle: .appLanguage),
                            icon: "archivebox.fill",
                            action: .archiveSingleFile
                        )
                    }
                }
                .padding(16)
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Paylaş")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.canvas)
    }

    private func option(
        _ title: String,
        subtitle: String? = nil,
        icon: String,
        action: ProjectShareAction
    ) -> some View {
        Button {
            onSelect(action)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 44, height: 44)
                    .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(Theme.body(16))
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.ink)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(Theme.caption(12))
                            .foregroundStyle(theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.inkMuted)
            }
            .padding(14)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(theme.inkMuted.opacity(0.12), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
