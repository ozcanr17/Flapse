import SwiftUI

/// Premium aboneliği tanıtan paywall. Fiyatlar damga (monospaced) fontuyla yazılır —
/// uygulama genelindeki numara/tarih diliyle aynı.
struct PaywallView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var viewModel: PaywallViewModel
    @State private var selectedPackageID: String?

    init(store: StoreServiceProtocol) {
        _viewModel = State(initialValue: PaywallViewModel(store: store))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedAccentBackground(base: theme.accent)
                    .ignoresSafeArea()
                LinearGradient(colors: [.clear, .clear, theme.canvas],
                                startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {
                        header
                        featureList
                        packageList
                        restoreButton
                        legalText
                    }
                    .padding(20)
                    .padding(.top, 12)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .accessibilityLabel(Text("Kapat"))
                }
            }
            .task { await viewModel.load() }
            .alert("Hata", isPresented: errorBinding) {
                Button("Tamam", role: .cancel) {}
            } message: { Text(viewModel.errorMessage ?? "") }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(.white.opacity(0.2)).frame(width: 72, height: 72)
                Image(systemName: "crown.fill").font(.system(size: 30)).foregroundStyle(.white)
            }
            Text("Flapse Pro")
                .font(Theme.headline(26))
                .foregroundStyle(.white)
            Text("Hikayeni en iyi haliyle anlat")
                .font(Theme.body(15))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.top, 8)
    }

    private var featureList: some View {
        VStack(spacing: 12) {
            ProFeatureRow(icon: "infinity", title: "Sınırsız proje", subtitle: "İstediğin kadar hikaye takip et")
            ProFeatureRow(icon: "scope", title: "Manuel hizalama", subtitle: "Her kareyi elle hizala, döndür ve yakınlaştır")
            ProFeatureRow(icon: "icloud.fill", title: "iCloud yedekleme", subtitle: "Fotoğrafların hep güvende")
            ProFeatureRow(icon: "person.2.fill", title: "Birlikte Çekim", subtitle: "Arkadaşını davet et; aynı projeye ikiniz de kare ekleyin, önceki kareleri birlikte görün")
            ProFeatureRow(icon: "photo.on.rectangle.angled", title: "Sınırsız fotoğraf aktarımı", subtitle: "14 kare sınırı olmadan içe aktar")
            ProFeatureRow(icon: "wand.and.rays", title: "Otomatik proje ayırma", subtitle: "Kare doğru projeye kendiliğinden gitsin")
            ProFeatureRow(icon: "film", title: "4K, filigransız export", subtitle: "Paylaşıma hazır video")
        }
        .padding(18)
        .background(.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private var packageList: some View {
        VStack(spacing: 10) {
            if viewModel.loadFailed {
                VStack(spacing: 10) {
                    Text("Fiyatlar yüklenemedi. Bağlantını kontrol edip tekrar dene.")
                        .font(Theme.caption(13))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await viewModel.load() }
                    } label: {
                        Label("Tekrar Dene", systemImage: "arrow.clockwise")
                            .font(Theme.headline(15))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(.white.opacity(0.16), in: Capsule())
                    }
                }
                .padding(.vertical, 12)
            } else if viewModel.packages.isEmpty {
                ProgressView().tint(.white).padding()
            } else {
                ForEach(viewModel.packages) { package in
                    PackageCard(
                        package: package,
                        badge: badge(for: package),
                        isSelected: selectedPackageID == package.id
                    ) {
                        selectedPackageID = package.id
                    }
                }
                Button {
                    guard let id = selectedPackageID,
                          let package = viewModel.packages.first(where: { $0.id == id }) ?? viewModel.packages.first
                    else { return }
                    Task { if await viewModel.purchase(package) { dismiss() } }
                } label: {
                    Text(ctaTitle)
                }
                .buttonStyle(.flapsePrimary)
                .disabled(viewModel.isPurchasing)
                .padding(.top, 4)
            }
        }
        .onChange(of: viewModel.packages) { _, packages in
            if selectedPackageID == nil {
                selectedPackageID = packages.first(where: { $0.id.contains("yearly") })?.id ?? packages.first?.id
            }
        }
    }

    private var ctaTitle: LocalizedStringKey {
        if viewModel.isPurchasing { return "İşleniyor…" }
        let selected = viewModel.packages.first { $0.id == selectedPackageID }
        return selected?.hasTrial == true ? "7 Gün Ücretsiz Başla" : "Devam Et"
    }

    private func badge(for package: StorePackage) -> LocalizedStringKey? {
        if package.id.contains("yearly") { return "EN AVANTAJLI" }
        if package.id.contains("lifetime") { return "TEK SEFERLİK" }
        return nil
    }

    private var restoreButton: some View {
        Button("Satın alımları geri yükle") {
            Task { await viewModel.restore(); if viewModel.isPro { dismiss() } }
        }
        .font(Theme.caption(13))
        .foregroundStyle(.white.opacity(0.85))
        .disabled(viewModel.isPurchasing)
    }

    private var legalText: some View {
        VStack(spacing: 10) {
            Text(legalDisclosure)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                Link("Kullanım Koşulları", destination: LegalLinks.termsOfUse)
                Text("·").foregroundStyle(.white.opacity(0.4))
                Link("Gizlilik Politikası", destination: LegalLinks.privacyPolicy)
            }
            .font(.caption2.weight(.semibold))
            .tint(.white.opacity(0.85))
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })
    }

    private var legalDisclosure: LocalizedStringKey {
        let selected = viewModel.packages.first { $0.id == selectedPackageID }
        if selected?.id == StoreProduct.lifetime.rawValue {
            return "Ömür boyu erişim tek seferlik bir satın alımdır; yinelenen ücret yoktur."
        }
        if selected?.hasTrial == true {
            return "Abonelikler 7 günlük ücretsiz denemeyle başlar; deneme bitmeden en az 24 saat önce iptal etmezsen abonelik otomatik başlar ve dönem sonunda yenilenir. Ücret Apple Kimliği hesabından tahsil edilir. Ömür boyu seçenek tek seferlik bir satın alımdır. Aboneliğini App Store hesap ayarlarından yönetebilir veya iptal edebilirsin."
        }
        return "Abonelik otomatik yenilenir; istediğin zaman Ayarlar’dan iptal edebilirsin."
    }
}

private struct ProFeatureRow: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.headline(15)).foregroundStyle(.white)
                Text(subtitle).font(Theme.caption(12)).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        }
    }
}

private struct PackageCard: View {
    let package: StorePackage
    let badge: LocalizedStringKey?
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(package.displayName).font(Theme.headline(16)).foregroundStyle(theme.ink)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(theme.secondary)
                                .clipShape(Capsule())
                        }
                    }
                    Text(package.displayPrice)
                        .font(Theme.body(15)).monospacedDigit()
                        .foregroundStyle(theme.inkMuted)
                    if package.hasTrial {
                        Text("İlk 7 gün ücretsiz")
                            .font(Theme.caption(12))
                            .foregroundStyle(theme.accent)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? theme.accent : theme.inkMuted.opacity(0.4))
            }
            .padding(16)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? theme.accent : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    PaywallView(store: StoreService())
}
