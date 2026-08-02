# Flapse — App Store Release Checklist

Son doğrulama: **2026-08-02**. "Doğrulandı" yazan maddeler bu tarihte gerçekten
ölçüldü; ölçülemeyenler açıkça öyle işaretlendi.

## Code & build

- [x] Release configuration: whole-module optimization, `-O`, `VALIDATE_PRODUCT=YES`
- [x] **Release'de sıfır uyarı** — 2026-08-02'de ölçüldü (`xcodebuild -configuration Release build`).
      Bu tarihte iki uyarı düzeltildi: `FileDocument`'ın Sendable ihlali ve
      beyan edilip karşılığı olmayan `CFBundleDocumentTypes` girdisi.
- [x] 1024px app icon alfa kanalı içermiyor — `sips` ile doğrulandı (1024×1024, hasAlpha: no)
- [x] Privacy manifest'ler app **ve** widget uzantısında (UserDefaults, CA92.1 + 1C8F.1)
- [x] `ITSAppUsesNonExemptEncryption = NO` (export-compliance sorusunu atlar)
- [x] Tüm izin metinleri mevcut ve 12 dile çevrili (`InfoPlist.xcstrings`)
- [x] Üçüncü taraf bağımlılık yok, analytics yok
- [x] Kullanıcıya görünen tüm dizeler 12 dilde — 2026-08-02'de tamamlandı
      (`Localizable.xcstrings` 522 anahtar, çevrilmemiş kalan yok)
- [ ] **CI GitHub'da koşmuyor.** `.github/workflows/` `.gitignore`'da (commit `23f57c7`:
      token'da `workflow` yetkisi olmadığı için push engelleniyordu), yani workflow
      dosyası repoda yok ve Actions hiç çalışmadı. Ayrıca yerel dosya hâlâ eski proje
      adı `Timelapse` şemasını gösteriyordu; 2026-08-02'de `Flapse`/`FlapseTests`
      olarak düzeltildi ama bu düzeltme de yalnızca yerelde duruyor. CI istiyorsan
      token'a `workflow` yetkisi ver, `.gitignore:25`'i kaldır ve dosyayı commit'le.
- [ ] **Unit testler doğrulanmadı.** `FlapseTests` üç ayrı oturumda başlatıldı, hiçbirinde
      tamamlanmadı (simülatör boot ile `xctest` başlangıcı arasında takılıyor). Yayından
      önce koşturulup yeşil olduğu görülmeli.

## Gizlilik beyanı — DİKKAT

Bu bölümün önceki hâli yanlıştı ve "Data Not Collected" diyordu. Uygulama
**veri topluyor**: "Bildir" özelliği (`FeedbackService.swift:57`) bulguları
`iCloud.rozcan.Flapse` kabının **public** veritabanına yazıyor ve bu kayıtlar
CloudKit Dashboard'dan geliştirici tarafından okunabiliyor. Kayıt şunları taşır:
serbest metin mesaj, isteğe bağlı iletişim e-postası, uygulama sürümü, iOS sürümü,
donanım modeli, dil.

App Store Connect gizlilik anketi `Flapse/PrivacyInfo.xcprivacy` ile **birebir
aynı** olmalı, aksi hâlde App Review tutarsızlığı yakalar:

- [ ] **Email Address** — Linked: Hayır, Tracking: Hayır, Amaç: App Functionality
- [ ] **Other User Content** — Linked: Hayır, Tracking: Hayır, Amaç: App Functionality

Not: Projeler, fotoğraflar ve videolar kullanıcının **private** CloudKit
veritabanında durur; geliştirici erişemez, dolayısıyla "toplanan veri" sayılmaz.
Beyan edilmesi gereken tek şey geri bildirim akışıdır.

## İmzalama — bu makinede yapılamayanlar

2026-08-02 itibarıyla bu Mac'te yalnızca **Apple Development** sertifikası var ve
**hiç provisioning profile yüklü değil**. App Store arşivi burada üretilemedi,
dolayısıyla aşağıdakiler ölçülemedi:

- [ ] Dağıtım (Apple Distribution) sertifikası ve App Store provisioning profile kur
- [ ] **`aps-environment` doğrula.** `Flapse/Flapse.entitlements` içinde değer
      `development`. App Store derlemesinde `production` olması gerekir. Arşivi
      aldıktan sonra gömülü değeri şununla oku — tahmin etme:
      ```sh
      codesign -d --entitlements - /path/to/Flapse.xcarchive/Products/Applications/Flapse.app
      ```
      `development` çıkarsa entitlement'ı Release için `production` yap.
- [ ] Archive → Organizer'da validate

## App ID capabilities (zorunlu)

Entitlement'lar **silinemez**, hepsi gerçekten kullanılıyor:

- [ ] **Sign in with Apple** — `AuthService.swift`, `SignInGateSheet.swift` kullanıyor
- [ ] **CloudKit** (`iCloud.rozcan.Flapse`) — proje paylaşımı + geri bildirim
- [ ] **App Groups** (`group.rozcan.Flapse`) — widget veri paylaşımı
- [ ] **Push Notifications** — CloudKit abonelikleri

## Before archiving (owner)

- [x] GitHub Pages yayında — `main` / `/docs`, doğrulandı (privacy, support ve kök URL 200 döndü)
- [ ] Ücretli Apple Developer hesabı aktif; Signing & Capabilities'te takım seçili
- [ ] Yeniden gönderimse `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` artır
      (şu an 1.0 / 1 — ilk sürüm için doğru)

## App Store Connect (owner, manuel)

- [ ] App kaydı: bundle ID `rozcan.Flapse`, ad **Flapse**, kategori Productivity
- [ ] `Products.storekit` ile eşleşen IAP'ler: `com.ridvan.timelapse.pro.monthly` / `.yearly` / `.lifetime`
- [ ] Abonelik grubu + yerelleştirilmiş IAP metinleri; IAP'leri binary ile birlikte gönder
- [ ] Gizlilik anketi — yukarıdaki "Gizlilik beyanı" bölümüne göre doldur
- [ ] Privacy Policy URL: https://ozcanr17.github.io/Flapse/privacy
- [ ] Support URL: https://ozcanr17.github.io/Flapse/support
- [ ] Ekran görüntüleri: 6.9" ve 6.5" iPhone (portre); isteğe bağlı 13" iPad
- [ ] App Review notları: paywall restore akışı, hesap gerekmediği, Live Activity'yi
      tetiklemek için render nasıl başlatılır
- [ ] TestFlight internal build önce; cihazda Live Activity, background-retry, QR doğrula

## İsteğe bağlı (yayını bloke etmez)

- [ ] CloudKit `Feedback` şemasını Development'tan Production'a taşı. Taşınmazsa
      "Bildir" **sessizce başarısız olmaz**: `FeedbackViewModel.swift:45` her hatada
      hazır doldurulmuş e-posta yoluna düşer. Taşımak kullanıcıları o yoldan kurtarır.

## Post-approval

- [ ] İstenirse `LegalLinks.appSite` QR hedefini App Store bağlantısıyla değiştir
- [ ] Xcode Organizer'da çökme raporlarını izle
