import SwiftUI

struct FeedbackSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    @State private var viewModel = FeedbackViewModel()
    @FocusState private var isMessageFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .sent: sentView
                default:    form
                }
            }
            .navigationTitle(Text("Geri bildirim"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
                if viewModel.state != .sent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Gönder") {
                            isMessageFocused = false
                            Task { await viewModel.submit() }
                        }
                        .disabled(!viewModel.canSubmit)
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var form: some View {
        List {
            Section {
                Picker(selection: $viewModel.kind) {
                    ForEach(FeedbackKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                } label: {
                    Text("Konu")
                }
                .pickerStyle(.segmented)
                .disabled(viewModel.state == .sending)
            } footer: {
                Text(viewModel.kind.prompt)
            }

            Section {
                TextField(
                    text: $viewModel.message,
                    prompt: Text(viewModel.kind.prompt),
                    axis: .vertical
                ) {
                    Text("Mesaj")
                }
                .lineLimit(6...14)
                .focused($isMessageFocused)
                .disabled(viewModel.state == .sending)
                .accessibilityIdentifier("feedbackMessageField")
            } header: {
                Text("Mesaj")
            } footer: {
                if viewModel.remainingCharacters > 0 {
                    Text("En az \(FeedbackReport.minimumMessageLength) karakter yaz.")
                }
            }

            Section {
                TextField(text: $viewModel.contactEmail) {
                    Text("E-posta (isteğe bağlı)")
                }
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .disabled(viewModel.state == .sending)
            } footer: {
                Text("Sana geri dönebilmem için e-postanı bırakabilirsin. Mesajınla birlikte yalnızca uygulama sürümü, iOS sürümü ve cihaz modeli gönderilir.")
            }

            if case .needsMailFallback(let report) = viewModel.state {
                Section {
                    Button {
                        if let url = FeedbackMailer.mailURL(for: report) {
                            openURL(url)
                        }
                    } label: {
                        Label("E-posta ile gönder", systemImage: "envelope")
                    }
                    Button("Tekrar dene") {
                        viewModel.resetToEditing()
                        Task { await viewModel.submit() }
                    }
                } footer: {
                    Text("Şu anda doğrudan gönderilemedi (iCloud oturumu veya bağlantı gerekiyor). Bulguyu e-posta olarak iletebilirsin.")
                        .foregroundStyle(theme.inkMuted)
                }
            }

            if viewModel.state == .sending {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Gönderiliyor…")
                            .foregroundStyle(theme.inkMuted)
                    }
                }
            }
        }
    }

    private var sentView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(theme.accent)
                Text("Geri bildiriminiz iletildi")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Bildiriminiz geliştirme ekibine ulaştı ve değerlendirmeye alındı. Katkınız için teşekkür ederiz.")
                    .font(.body)
                    .foregroundStyle(theme.inkMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Kapat")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
