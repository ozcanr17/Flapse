import SwiftUI
import AuthenticationServices

/// Proje oluşturmadan önce zorunlu Apple ile giriş. Girişten sonra projeler hesapla
/// eşleşir; Pro kullanıcıda iCloud yedekleme otomatik açılır ve projeler her cihazda
/// geri gelir.
struct SignInGateSheet: View {

    let onSignedIn: () -> Void
    var onSkip: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(StoreService.self) private var store

    @State private var auth = AuthService()
    @State private var failed = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle().fill(theme.accent.opacity(0.12)).frame(width: 84, height: 84)
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 36))
                    .foregroundStyle(theme.accent)
            }
            Text("Proje oluşturmak için giriş yap")
                .font(Theme.headline(22))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
            Text("Projelerin hesabınla eşleşir; iCloud yedekleme açıkken başka bir cihazda da geri gelir.")
                .font(Theme.body(15))
                .foregroundStyle(theme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            if failed {
                Text("Giriş tamamlanamadı. Tekrar dene.")
                    .font(Theme.caption(13))
                    .foregroundStyle(theme.secondary)
            }
            Spacer()
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let onSkip {
                Button("Giriş yapmadan devam et") {
                    dismiss()
                    onSkip()
                }
                .font(Theme.body(15))
                .foregroundStyle(theme.accent)
            }
            Button("Vazgeç") { dismiss() }
                .font(Theme.body(15))
                .foregroundStyle(theme.inkMuted)
                .padding(.bottom, 6)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .background(theme.canvas)
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            auth.handle(authorization)
            if store.isPro {
                CloudBackupPreference.setEnabled(true)
            }
            dismiss()
            onSignedIn()
        case .failure:
            failed = true
        }
    }
}
