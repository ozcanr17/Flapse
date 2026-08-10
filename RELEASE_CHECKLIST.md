# Flapse — App Store Release Checklist

Son doğrulama: **2026-08-11**. "Doğrulandı" yazan maddeler bu tarihte gerçekten
ölçüldü; ölçülemeyenler açıkça öyle işaretlendi.

## Code & build

- [x] Release configuration: whole-module optimization, `-O`, `VALIDATE_PRODUCT=YES`
- [x] **Swift 6 + strict concurrency** tüm hedeflerde açık; Release'de Swift ve C/ObjC
      uyarıları hata kabul ediliyor.
- [x] **Release build ve static analyze başarılı** — 2026-08-11'de sıfır derleyici
      uyarısıyla ölçüldü.
- [x] 1024px app icon alfa kanalı içermiyor — `sips` ile doğrulandı (1024×1024, hasAlpha: no)
- [x] Privacy manifest'ler app **ve** widget uzantısında (UserDefaults, CA92.1 + 1C8F.1)
- [x] `ITSAppUsesNonExemptEncryption = NO` (export-compliance sorusunu atlar)
- [x] Tüm izin metinleri mevcut ve 20 dile çevrili (`InfoPlist.xcstrings`)
- [x] Üçüncü taraf bağımlılık yok, analytics yok
- [x] Kullanıcıya görünen dizeler 20 dilde; biçim/oran anahtarları çevrilmez olarak
      işaretli. Güvenlik denetiminde kaldırılan gizli geliştirici metinleri Release
      kaynaklarında bulunmuyor.
- [x] GitHub Actions CI etkin: macOS 26 / Xcode 26.6 üzerinde Release build,
      static analyze ve unit test çalıştırıyor.
- [x] **Unit testler yeşil — 2026-08-11: 198 uygun test, 0 hata.** CloudKit entitlement
      isteyen testler simülatör paketinden ayrı tutuldu.
- [x] **UI testi doğrulandı** — 13 inç iPad simülatöründe tam kullanıcı yolculuğu geçti.

## Gizlilik beyanı — DİKKAT

Bu bölümün önceki hâli yanlıştı ve "Data Not Collected" diyordu. Uygulama
**veri topluyor**: "Bildir" özelliği (`FeedbackService.swift:57`) bulguları
`iCloud.rozcan.Flapse` kabının **public** veritabanına yazıyor ve bu kayıtlar
CloudKit Dashboard'dan geliştirici tarafından okunabiliyor. Kayıt şunları taşır:
serbest metin mesaj, isteğe bağlı iletişim e-postası, uygulama sürümü, iOS sürümü,
donanım modeli. Dil/locale artık gönderilmiyor.

App Store Connect gizlilik anketi `Flapse/PrivacyInfo.xcprivacy` ile **birebir
aynı** olmalı, aksi hâlde App Review tutarsızlığı yakalar:

- [ ] **Email Address** — Linked: Evet, Tracking: Hayır, Amaç: App Functionality
- [ ] **Other User Content** — Linked: Evet, Tracking: Hayır, Amaç: App Functionality
- [ ] **Other Diagnostic Data** — Linked: Evet, Tracking: Hayır, Amaç: App Functionality

Üç tür aynı geri bildirim kaydında bulunabildiği ve CloudKit kayda kararlı bir kullanıcı
tanımlayıcısı atadığı için Linked alanında temkinli ve doğru seçim **Evet**'tir.

Not: Projeler, fotoğraflar ve videolar kullanıcının **private** CloudKit
veritabanında durur; geliştirici erişemez, dolayısıyla "toplanan veri" sayılmaz.
Beyan edilmesi gereken tek şey geri bildirim akışıdır.

## İmzalama

- [x] 2026-08-11'de otomatik provisioning ile generic iOS Release arşivi üretildi.
- [x] Arşiv App Store Connect yöntemiyle dışa aktarıldı: **9.1 MB IPA**,
      Apple Distribution imzası geçerli, `get-task-allow = false`,
      `aps-environment = production`, CloudKit environment = Production.
- [ ] Organizer'da **Validate App** ve ardından Upload işlemini owner tamamlamalı.

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

- [ ] App kaydı: bundle ID `rozcan.Flapse`, ad **Flapse**, kategori **Photo & Video**
- [ ] `Products.storekit` ile eşleşen IAP'ler: `com.ridvan.timelapse.pro.monthly` / `.yearly` / `.lifetime`
- [ ] Abonelik grubu + yerelleştirilmiş IAP metinleri; IAP'leri binary ile birlikte gönder
- [ ] Gizlilik anketi — yukarıdaki "Gizlilik beyanı" bölümüne göre doldur
- [ ] Privacy Policy URL: https://ozcanr17.github.io/Flapse/privacy
- [ ] Support URL: https://ozcanr17.github.io/Flapse/support
- [x] Ekran görüntüleri: 6.9" iPhone ve uygulama iPad'i desteklediği için zorunlu
      13" iPad seti `AppStoreScreenshots/` altında hazır
- [ ] App Review notları: paywall restore akışı, hesap gerekmediği, Live Activity'yi
      tetiklemek için render nasıl başlatılır
- [ ] TestFlight internal build önce; cihazda Live Activity, background-retry, QR doğrula

## CloudKit Production (owner, zorunlu)

- [ ] `iCloud.rozcan.Flapse` içindeki proje/paylaşım ve `Feedback` record tiplerini
      Development'tan Production'a deploy et. Feedback deploy edilmezse uygulama
      e-posta yedeğine düşer; proje senkronu için Production şemasının hazır olması gerekir.

## Post-approval

- [ ] İstenirse `LegalLinks.appSite` QR hedefini App Store bağlantısıyla değiştir
- [ ] Xcode Organizer'da çökme raporlarını izle
