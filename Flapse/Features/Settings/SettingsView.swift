import SwiftUI
import SwiftData
import UIKit
import AuthenticationServices
import UniformTypeIdentifiers

struct SettingsView: View {

    var onWelcomeFinished: () -> Void = {}

    @Environment(StoreService.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var settingsContext
    @State private var projectCount = 0
    @State private var entryCount = 0

    @AppStorage(AppTheme.storageKey) private var themeID = AppTheme.filmNegative.rawValue
    @AppStorage(ThemePreference.customEnabledKey) private var customThemeEnabled = false
    @AppStorage(ThemePreference.primaryHexKey) private var customPrimaryHex = ThemePreference.defaultPrimaryHex
    @AppStorage(ThemePreference.secondaryHexKey) private var customSecondaryHex = ThemePreference.defaultSecondaryHex
    @AppStorage(AppLanguage.storageKey) private var languageID = AppLanguage.system.rawValue
    @AppStorage(ReminderScheduler.enabledKey) private var remindersEnabled = false
    @AppStorage(ReminderScheduler.hourKey) private var reminderHour = 19
    @AppStorage(PremiumFeature.smartAlignmentPreferenceKey) private var smartAlignmentEnabled = true
    @AppStorage(PremiumFeature.cloudBackupPreferenceKey) private var cloudBackupEnabled = false

    @State private var auth = AuthService()
    @State private var showPaywall = false
    @State private var showFeedback = false
    @State private var cloudAccountAvailable: Bool?
    @State private var showWelcome = false
    @State private var shouldReturnHomeAfterWelcome = false
    @State private var signInMessage: String?
    @State private var isConfirmingAccountDeletion = false
    @State private var cloudRestartRequired = UserDefaults.standard.bool(forKey: CloudBackupPreference.restartRequiredKey)
    @State private var isImportingArchive = false
    @State private var importArchiveError: String?
    @State private var importedArchiveTitle: String?
    #if DEBUG
    @State private var debugLogoTapCount = 0
    @State private var debugProMessage: String?
    #endif

    var body: some View {
        List {
            Section("Üyelik") {
                if store.isPro {
                    Label {
                        Text("Flapse Pro aktif")
                            .font(.headline)
                            .foregroundStyle(theme.ink)
                    } icon: {
                        Image(systemName: "crown.fill")
                            .foregroundStyle(theme.accent)
                    }
                } else {
                    Button {
                        showPaywall = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Flapse Pro'ya Geç")
                                    .font(.headline)
                                    .foregroundStyle(theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 1)
                                Text("Sınırsız proje, 4K filigransız export")
                                    .font(.caption)
                                    .foregroundStyle(theme.inkMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        } icon: {
                            Image(systemName: "crown.fill")
                                .foregroundStyle(theme.accent)
                        }
                    }
                }
                Button("Satın alımları geri yükle") {
                    Task { await store.restore() }
                }
                .font(.callout)
                .foregroundStyle(theme.secondary)
            }

            Section {
                Button {
                    showFeedback = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Bildir")
                                .font(.headline)
                                .foregroundStyle(theme.ink)
                            Text("Hata bildir, özellik veya iyileştirme öner")
                                .font(.caption)
                                .foregroundStyle(theme.inkMuted)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.bubble")
                            .foregroundStyle(theme.accent)
                    }
                }
                .accessibilityIdentifier("feedbackButton")
            } footer: {
                Text("Karşılaştığın bir sorunu ya da eklenmesini istediğin bir şeyi doğrudan bana yazabilirsin.")
            }

            Section {
                accountContent
            } header: {
                Text("Hesap")
            } footer: {
                if let signInMessage {
                    Text(signInMessage)
                        .foregroundStyle(theme.accent)
                }
            }

            Section {
                ProToggleRow(
                    feature: .smartAlignment,
                    isOn: $smartAlignmentEnabled,
                    isPro: true
                ) {}
                ProToggleRow(
                    feature: .cloudBackup,
                    isOn: $cloudBackupEnabled,
                    isPro: store.isPro
                ) { showPaywall = true }
                if store.isPro, cloudBackupEnabled {
                    Label {
                        Text(iCloudActive
                             ? "iCloud yedekleme etkin."
                             : "iCloud isteği kaydedildi; şu an yerel depoya düşülüyor (ücretli Apple hesabı gerekir).")
                            .font(.caption)
                            .foregroundStyle(theme.inkMuted)
                    } icon: {
                        Image(systemName: iCloudActive ? "checkmark.icloud.fill" : "icloud.slash")
                            .foregroundStyle(iCloudActive ? theme.accent : theme.inkMuted)
                    }
                }
                if cloudRestartRequired {
                    Label {
                        Text("iCloud yedekleme açıldı. Projelerinin eşitlenmesi için uygulamayı kapatıp yeniden aç.")
                            .font(.caption)
                            .foregroundStyle(theme.inkMuted)
                    } icon: {
                        Image(systemName: "arrow.clockwise.icloud")
                            .foregroundStyle(theme.accent)
                    }
                }
            } header: {
                Text("Pro Özellikler")
            } footer: {
                if store.isPro {
                    Text("Çift modu (birlikte çekim) her projede sağ üstteki davet düğmesiyle açılır. iCloud değişikliği uygulama yeniden başlatılınca geçerli olur.")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Bu özellikler Flapse Pro ile açılır.")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                LabeledContent("Apple ile giriş") {
                    statusText(auth.isSignedIn, on: String(localized: "Var", bundle: .appLanguage), off: String(localized: "Yok", bundle: .appLanguage))
                }
                LabeledContent("iCloud hesabı") {
                    statusText(cloudAccountAvailable ?? false, on: String(localized: "Var", bundle: .appLanguage), off: String(localized: "Yok", bundle: .appLanguage))
                }
                LabeledContent("iCloud yedekleme") {
                    statusText(cloudBackupEnabled, on: String(localized: "Açık", bundle: .appLanguage), off: String(localized: "Kapalı", bundle: .appLanguage))
                }
                LabeledContent("Bulut deposu") {
                    statusText(iCloudActive, on: String(localized: "Aktif", bundle: .appLanguage), off: String(localized: "Yerel", bundle: .appLanguage))
                }
            } header: {
                Text("iCloud Durumu")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apple ile giriş ve iCloud hesabı ayrıdır. Eşitleme için bu cihazın Ayarlar uygulamasında aynı iCloud hesabı açık olmalı.")
                    Text(iCloudActive
                         ? "Fotoğrafların iCloud'a kaydediliyor; aynı hesapla giren her cihazda geri gelir."
                         : "Fotoğrafların şu an yalnızca bu cihazda. Eşitleme için Pro + iCloud yedekleme gerekir; açtıktan sonra uygulamayı yeniden başlat.")
                }
            }

            Section {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(AppTheme.allCases) { appTheme in
                        ThemePresetCard(
                            appTheme: appTheme,
                            isSelected: !customThemeEnabled && AppTheme.resolved(storedID: themeID) == appTheme
                        ) {
                            customThemeEnabled = false
                            themeID = appTheme.rawValue
                        }
                    }
                }
                .padding(.vertical, 4)

                customThemeEditor
            } header: {
                Text("Görünüm")
            } footer: {
                Text("Birincil renk arka planı; ikincil renk butonları, seçimleri ve vurguları belirler.")
            }

            Section("Hatırlatıcı") {
                Toggle("Çekim hatırlatıcıları", isOn: $remindersEnabled)
                    .tint(theme.accent)
                if remindersEnabled {
                    Picker("Saat", selection: $reminderHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(String(format: "%02d:00", hour))
                                .font(.callout).monospacedDigit()
                                .tag(hour)
                        }
                    }
                }
            }

            Section("İstatistik") {
                LabeledContent("Proje") {
                    Text("\(projectCount)").font(.callout).monospacedDigit()
                }
                LabeledContent("Toplam çekim") {
                    Text("\(entryCount)").font(.callout).monospacedDigit()
                }
            }

            Section("Uygulama") {
                Picker(selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language.rawValue)
                    }
                } label: {
                    Label {
                        Text("Uygulama dili").foregroundStyle(theme.ink)
                    } icon: {
                        Image(systemName: "globe").foregroundStyle(theme.accent)
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.inkMuted)
                NavigationLink {
                    HiddenItemsView()
                } label: {
                    Label {
                        Text("Gizlenenler").foregroundStyle(theme.ink)
                    } icon: {
                        Image(systemName: "eye.slash").foregroundStyle(theme.accent)
                    }
                }
                NavigationLink {
                    RecentlyDeletedView()
                } label: {
                    Label {
                        Text("Son Silinenler").foregroundStyle(theme.ink)
                    } icon: {
                        Image(systemName: "trash").foregroundStyle(theme.accent)
                    }
                }
                Button {
                    importArchiveTapped()
                } label: {
                    Label {
                        Text("Proje Arşivi İçe Aktar").foregroundStyle(theme.ink)
                    } icon: {
                        Image(systemName: "tray.and.arrow.down").foregroundStyle(theme.accent)
                    }
                }
                .accessibilityIdentifier("importProjectArchiveButton")
                Button("Karşılama ekranını göster") {
                    showWelcome = true
                }
                .foregroundStyle(theme.ink)
                Button("Kamera izni ayarları") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .foregroundStyle(theme.ink)
            }

            Section {
                VStack(spacing: 10) {
                    LogoMark(size: 56)
                    Text("Flapse")
                        .font(.headline)
                        .foregroundStyle(theme.ink)
                    Text("Sürüm \(appVersion)")
                        .font(.caption)
                        .foregroundStyle(theme.inkMuted)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                #if DEBUG
                .onTapGesture {
                    debugLogoTapCount += 1
                    guard debugLogoTapCount >= 5 else { return }
                    debugLogoTapCount = 0
                    let enabled = store.toggleDebugProOverride()
                    debugProMessage = enabled ? "Test Pro etkinleştirildi." : "Test Pro kapatıldı."
                }
                #endif
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .navigationTitle("Ayarlar")
        .task {
            refreshStatistics()
            cloudAccountAvailable = await SharedProjectService.accountAvailableIfSupported()
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) {
            PaywallView(store: store)
        }
        .sheet(isPresented: $showFeedback) {
            FeedbackSheet()
        }
        .fileImporter(
            isPresented: $isImportingArchive,
            allowedContentTypes: [ProjectArchive.utType, .folder]
        ) { result in
            switch result {
            case .success(let url):
                importProjectArchive(from: url)
            case .failure(let error):
                importArchiveError = error.localizedDescription
            }
        }
        .alert("İçe aktarılamadı", isPresented: Binding(
            get: { importArchiveError != nil },
            set: { if !$0 { importArchiveError = nil } }
        )) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(importArchiveError ?? "")
        }
        .alert("İçe Aktarıldı", isPresented: Binding(
            get: { importedArchiveTitle != nil },
            set: { if !$0 { importedArchiveTitle = nil } }
        )) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text("\"\(importedArchiveTitle ?? "")\" yeni bir proje olarak eklendi.")
        }
        #if DEBUG
        .alert("Test Pro", isPresented: Binding(
            get: { debugProMessage != nil },
            set: { if !$0 { debugProMessage = nil } }
        )) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(debugProMessage ?? "")
        }
        #endif
        .fullScreenCover(isPresented: $showWelcome, onDismiss: finishWelcomeReplay) {
            WelcomeView {
                shouldReturnHomeAfterWelcome = true
                showWelcome = false
            }
        }
        .onChange(of: remindersEnabled) { _, enabled in
            if enabled {
                Task {
                    let granted = await ReminderScheduler.shared.requestAuthorization()
                    if granted {
                        syncReminders()
                    } else {
                        remindersEnabled = false
                    }
                }
            } else {
                syncReminders()
            }
        }
        .onChange(of: reminderHour) {
            syncReminders()
        }
        .onChange(of: cloudBackupEnabled) { _, enabled in
            CloudBackupPreference.setEnabled(enabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            let enabled = CloudBackupPreference.refreshFromCloud()
            cloudBackupEnabled = enabled
            cloudRestartRequired = UserDefaults.standard.bool(forKey: CloudBackupPreference.restartRequiredKey)
        }
        .confirmationDialog(
            "Hesap bilgilerin silinsin mi?",
            isPresented: $isConfirmingAccountDeletion,
            titleVisibility: .visible
        ) {
            Button("Hesabı sil", role: .destructive) {
                auth.deleteAccountData()
                signInMessage = nil
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Apple ile giriş kaydın bu cihazdan kaldırılır. Projelerin ve fotoğrafların cihazında kalır.")
        }
    }

    private var customThemeEditor: some View {
        VStack(spacing: 12) {
            Button {
                customThemeEnabled = true
            } label: {
                HStack(spacing: 12) {
                    CustomThemeSwatch(
                        configuration: ThemePreference.configuration(
                            themeID: themeID,
                            customEnabled: true,
                            primaryHex: customPrimaryHex,
                            secondaryHex: customSecondaryHex
                        )
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Özel Palet")
                            .font(.headline)
                            .foregroundStyle(theme.ink)
                        Text("Kendi renklerini oluştur")
                            .font(.caption)
                            .foregroundStyle(theme.inkMuted)
                    }
                    Spacer()
                    Image(systemName: customThemeEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(customThemeEnabled ? theme.accent : theme.inkMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("theme-custom")

            Divider()

            ColorPicker("Birincil renk · Arka plan", selection: primaryColorBinding, supportsOpacity: false)
                .font(.callout)
            ColorPicker("İkincil renk · Butonlar", selection: secondaryColorBinding, supportsOpacity: false)
                .font(.callout)
        }
        .padding(.vertical, 4)
    }

    private var primaryColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: customPrimaryHex) },
            set: { color in
                guard let hex = color.hexRGB else { return }
                customPrimaryHex = hex
                customThemeEnabled = true
            }
        )
    }

    /// Arşiv içe aktarma her zaman YENİ bir proje yaratır, bu yüzden proje sayısı
    /// sınırı diğer proje oluşturma yollarıyla aynı şekilde uygulanmalı
    /// (bkz. `ProjectListView.addProjectTapped` / `importTapped`). Kontrol yokken
    /// ücretsiz katmandaki kullanıcı sınırı arşiv üzerinden aşabiliyordu; dahası
    /// içe aktarılan proje kendi eski `createdAt`'ini koruduğu için `unlockedProjectID`
    /// onu en yeni saymıyor ve kullanıcı "İçe Aktarıldı" mesajının hemen ardından
    /// kilitli bir proje görüyordu.
    private func importArchiveTapped() {
        let descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.deletedAt == nil })
        let count = (try? settingsContext.fetchCount(descriptor)) ?? projectCount
        if FeatureGate.canCreateProject(isPro: store.isPro, currentProjectCount: count) {
            isImportingArchive = true
        } else {
            showPaywall = true
        }
    }

    /// Seçilen `.flapseproject` paketini okur (arka planda; SwiftData'ya dokunmaz)
    /// ve yeni bir proje olarak ekler (mevcut hiçbir veriyi değiştirmez). `url`
    /// güvenlik kapsamlı olabileceğinden erişim, okuma bitene kadar açık tutulur.
    private func importProjectArchive(from url: URL) {
        let maximumEntryCount = store.isPro ? nil : FeatureGate.freeEntryLimit
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try ProjectArchive.read(packageAt: url, maximumEntryCount: maximumEntryCount)
                }.value
                let project = try await ProjectArchive.materialize(
                    imported,
                    into: settingsContext.container
                )
                importedArchiveTitle = project.title
                refreshStatistics()
            } catch ProjectArchive.ArchiveError.requiresPro {
                showPaywall = true
            } catch {
                importArchiveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func refreshStatistics() {
        let projects = FetchDescriptor<Project>(
            predicate: #Predicate { $0.deletedAt == nil && $0.isHidden == false }
        )
        let entries = FetchDescriptor<Entry>(
            predicate: #Predicate {
                $0.deletedAt == nil && $0.project?.deletedAt == nil && $0.project?.isHidden == false
            }
        )
        projectCount = (try? settingsContext.fetchCount(projects)) ?? 0
        entryCount = (try? settingsContext.fetchCount(entries)) ?? 0
    }

    private func syncReminders() {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.deletedAt == nil && $0.isHidden == false }
        )
        ReminderScheduler.shared.sync(projects: (try? settingsContext.fetch(descriptor)) ?? [])
    }

    private var secondaryColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: customSecondaryHex) },
            set: { color in
                guard let hex = color.hexRGB else { return }
                customSecondaryHex = hex
                customThemeEnabled = true
            }
        )
    }

    private func finishWelcomeReplay() {
        guard shouldReturnHomeAfterWelcome else { return }
        shouldReturnHomeAfterWelcome = false
        onWelcomeFinished()
    }

    @ViewBuilder
    private var accountContent: some View {
        if auth.isSignedIn {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(auth.displayName ?? auth.email ?? String(localized: "Apple ID ile girildi", bundle: .appLanguage))
                        .font(.headline)
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let email = auth.email {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                }
            } icon: {
                Image(systemName: "apple.logo")
                    .foregroundStyle(theme.ink)
            }
            Button("Çıkış yap") {
                auth.signOut()
                signInMessage = nil
            }
            .font(.callout)
            .foregroundStyle(theme.secondary)
            Button("Hesabı sil", role: .destructive) {
                isConfirmingAccountDeletion = true
            }
            .font(.callout)
        } else {
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handleSignIn(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private func handleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            signInMessage = nil
            auth.handle(authorization)
            if store.isPro, !CloudBackupPreference.isEnabled {
                CloudBackupPreference.setEnabled(true)
                signInMessage = String(localized: "iCloud yedekleme açıldı. Projelerinin eşitlenmesi için uygulamayı kapatıp yeniden aç.", bundle: .appLanguage)
            }
        case .failure:
            signInMessage = String(localized: "Giriş tamamlanamadı. Tekrar dene.", bundle: .appLanguage)
        }
    }

    private var iCloudActive: Bool {
        UserDefaults.standard.bool(forKey: AppModelContainer.iCloudBackupActiveKey)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func statusText(_ on: Bool, on onText: String, off offText: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(on ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(on ? onText : offText)
                .font(.caption)
                .foregroundStyle(theme.ink)
        }
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { languageID },
            set: { newValue in
                LanguageOverrideBundle.apply(AppLanguage(rawValue: newValue) ?? .system)
                languageID = newValue
            }
        )
    }
}

/// Pro'ya bağlı bir özelliğin ayarlar satırı. Pro kullanıcıda gerçek bir anahtar (toggle),
/// ücretsiz kullanıcıda ise pasif (inactive) görünen, dokununca paywall açan kilitli satır.
private struct ProToggleRow: View {
    let feature: PremiumFeature
    @Binding var isOn: Bool
    let isPro: Bool
    let onLockedTap: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        if isPro {
            Toggle(isOn: $isOn) { label }
                .tint(theme.accent)
        } else {
            Button(action: onLockedTap) {
                HStack {
                    label
                    Spacer()
                    proBadge
                }
            }
        }
    }

    private var label: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.headline)
                    .foregroundStyle(isPro ? theme.ink : theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 1)
                Text(feature.subtitle)
                    .font(.caption)
                    .foregroundStyle(theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } icon: {
            Image(systemName: isPro ? feature.iconName : "lock.fill")
                .foregroundStyle(isPro ? theme.accent : theme.inkMuted)
        }
    }

    private var proBadge: some View {
        Text("PRO")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(theme.accent)
            .clipShape(Capsule())
    }
}

private struct ThemePresetCard: View {
    let appTheme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(appTheme.palette.canvas)
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(appTheme.palette.surface)
                        .frame(width: 48, height: 24)
                        .padding(7)
                    Capsule()
                        .fill(appTheme.palette.accent)
                        .frame(width: 38, height: 10)
                        .padding(10)
                    Circle()
                        .fill(appTheme.palette.secondary)
                        .frame(width: 17, height: 17)
                        .overlay(Circle().strokeBorder(.white.opacity(0.65), lineWidth: 1))
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .frame(height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? theme.accent : theme.inkMuted.opacity(0.2), lineWidth: isSelected ? 2 : 0.8)
                }

                HStack(spacing: 5) {
                    Text(appTheme.displayName)
                        .font(.caption)
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : (appTheme.preferredColorScheme == .dark ? "moon.fill" : "sun.max.fill"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? theme.accent : theme.inkMuted)
                }
            }
            .padding(8)
            .background(theme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("theme-\(appTheme.rawValue)")
    }
}

private struct CustomThemeSwatch: View {
    let configuration: ThemeConfiguration

    var body: some View {
        ZStack {
            Circle()
                .fill(configuration.palette.canvas)
                .overlay(Circle().strokeBorder(configuration.palette.inkMuted.opacity(0.35), lineWidth: 1))
            Circle()
                .fill(configuration.palette.accent)
                .frame(width: 22, height: 22)
                .offset(x: 9, y: 9)
            Circle()
                .fill(configuration.palette.secondary)
                .frame(width: 13, height: 13)
                .offset(x: -10, y: -9)
        }
        .frame(width: 42, height: 42)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .modelContainer(AppModelContainer.makeInMemory())
    .environment(StoreService())
}
