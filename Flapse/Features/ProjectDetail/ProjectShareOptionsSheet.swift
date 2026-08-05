import SwiftUI

enum ProjectShareAction: Equatable {
    case streak
    case compare
    case story
    case archive
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
                    option("Seri Kartı", icon: "flame.fill", action: .streak)

                    if canCreateComparison {
                        option("Önce & Sonra Kartı", icon: "rectangle.split.2x1.fill", action: .compare)
                        option("Hikaye Kartı (9:16)", icon: "rectangle.portrait.fill", action: .story)
                    }

                    option("Proje Arşivi (Tüm Kareler)", icon: "archivebox.fill", action: .archive)
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
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.canvas)
    }

    private func option(_ title: LocalizedStringKey, icon: String, action: ProjectShareAction) -> some View {
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

                Text(title)
                    .font(Theme.body(16))
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.ink)

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
