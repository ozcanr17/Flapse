# Flapse — App Store Yayınlama Rehberi

Bu doküman, uygulamayı App Store'da yayınlamak için gereken tüm adımları sırayla anlatır.
Teknik ön hazırlık (kod tarafı) tamamlandı: paywall yasal metinleri, hesap silme, isteğe
bağlı giriş, değerlendirme istemi, widget yerelleştirmesi ve `Products.storekit`
depoda hazır. Kalan adımların tamamı Apple hesabı gerektiren, insan eliyle yapılacak işler.

---

## 1. Apple Developer Program üyeliği — ✅ TAMAMLANDI (2026-08-05 doğrulandı)

Üyelik aktif ve doğrulandı: `xcodebuild archive -allowProvisioningUpdates` ile gerçek bir
App Store arşivi alındı; Xcode her iki hedef için (`rozcan.Flapse`, `rozcan.Flapse.Widgets`)
profilleri otomatik oluşturdu. 2026-08-05'te App Store Connect yöntemiyle 8.8 MB IPA
dışa aktarıldı; Apple Distribution imzası, `aps-environment = production`, Production
CloudKit, Sign in with Apple ve App Groups entitlement'ları paketin içinden doğrulandı
(Team `5ZYCHZ39QV`).

**Small Business Program**: başvuru yapıldı, onay bekleniyor. Bu, yayını **beklemez** —
uygulamayı gönderebilirsin; onaylandığı andan itibaren komisyon %30 yerine %15 uygulanır.

## 2. Gizlilik sayfaları — ✅ TAMAMLANDI (2026-07-18)

GitHub Pages açıldı (`main` / `/docs`); üç adres de canlı ve Flapse markalı sayfaları sunuyor
(uygulamadaki `LegalLinks` bunlara işaret eder):

- Gizlilik: `https://ozcanr17.github.io/Flapse/privacy`
- Destek: `https://ozcanr17.github.io/Flapse/support`
- Site (outro QR kodu): `https://ozcanr17.github.io/Flapse/`

App Store Connect'e yazılacak adresler bunlardır.

> ⚠️ `https://github.com/ozcanr17/Flapse/tree/main/docs/privacy` gibi repo adresleri
> **kullanılmaz** — GitHub'ın kod görünümüdür; politika metnini değil dosya listesini gösterir.

Not: Sayfa içerikleri `docs/privacy/index.html` ve `docs/support/index.html` dosyalarından
sunulur; düzenledikten sonra main'e push yeterlidir (Pages 1-2 dakikada yeniden yayınlar).

## 3. Sertifikalar ve imzalama — ✅ TAMAMLANDI (2026-08-05 doğrulandı)

Otomatik imzalama çalışıyor; arşiv başarıyla alındı (bkz. 1. adım). Yapılacak tek şey:
gerçek iPhone'da **Release** yapılandırmasıyla bir kez çalıştırıp son bir duman testi yapmak
(Product → Scheme → Edit Scheme → Run → Build Configuration: Release).

Not: Arşiv önce Apple Development kimliğiyle üretilebilir; Organizer veya
`-exportArchive` App Store paketini Apple Distribution kimliğiyle yeniden imzalar.
Bu akış bu makinede uçtan uca doğrulandı. CLI ile paket çıkarmak istersen repo kökünde
hazır `ExportOptions.plist` var:

```sh
xcodebuild archive -scheme Flapse -destination 'generic/platform=iOS' \
  -archivePath build/Flapse.xcarchive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/Flapse.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export -allowProvisioningUpdates
```

## 4. App Store Connect'te uygulamayı oluştur

1. [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **My Apps → + → New App**.
2. Platform: iOS · Name: **Flapse** · Primary language: Turkish ·
   Bundle ID: **rozcan.Flapse** · SKU: `flapse-ios` · Primary category: **Photo & Video**.
3. Bundle ID listede yoksa: [developer.apple.com/account/resources/identifiers](https://developer.apple.com/account/resources/identifiers)
   → App IDs → `rozcan.Flapse`'ı kaydet.

## 5. Uygulama içi satın almaları tanımla

**Önce**: App Store Connect → **Business** (Agreements, Tax, and Banking) →
**Paid Applications** sözleşmesini kabul et, banka hesabı + vergi formlarını doldur.
Bu tamamlanmadan IAP oluşturulamaz/satılamaz.

Sonra App Store Connect → uygulama → **Monetization → Subscriptions / In-App Purchases**:

1. **Abonelik grubu** oluştur: "Flapse Pro".
2. Grup içine iki otomatik yenilenen abonelik — Product ID'ler koddakiyle **birebir** aynı olmalı:
   - `com.ridvan.timelapse.pro.monthly` (1 ay)
   - `com.ridvan.timelapse.pro.yearly` (1 yıl)
3. Her ikisine **Introductory Offer**: 1 hafta, **Free trial**. Paywall bu metni yalnızca
   StoreKit kullanıcının denemeye uygun olduğunu bildirdiğinde gösterir.
4. **Non-Consumable** ürün: `com.ridvan.timelapse.pro.lifetime`.
5. Her ürüne Türkçe + İngilizce ad/açıklama ve fiyat gir; "Review Information" kısmına
   paywall ekran görüntüsü ekle.
6. IAP'ler ilk sürümle **birlikte** incelemeye girer — sürüm sayfasında üçünü de sürüme iliştir.

**Yayın öncesi cihazsız test:** depodaki `Products.storekit` dosyası Flapse şemasına
zaten bağlı — Xcode'dan çalıştırınca satın alma akışı sahte mağazayla uçtan uca denenebilir
(fiyatlar App Store Connect'e girilecek değerlerle aynı tutuluyor). Gerçek sandbox testi
için: App Store Connect → Users and Access → **Sandbox Testers**'dan test hesabı aç.

## 6. Sürüm sayfasını doldur

1. **Ekran görüntüleri**: 6.9" (iPhone 17 Pro Max) zorunlu. Önerilen kareler: Ana sayfa,
   kamera (ghost overlay), proje detayı, export stüdyosu, Kaydedilenler, paywall.
   Simülatörde `Cmd+S` ile alınır.
2. **Description / Keywords / Promotional Text**: Türkçe + istenen diğer diller.
   (`docs/AppStoreListing.md` taslak metinleri içerir.)
3. **Support URL**: `https://ozcanr17.github.io/Flapse/support`
   **Privacy Policy URL**: `https://ozcanr17.github.io/Flapse/privacy`
4. **App Privacy** anketi: **Data Collected** seç. "Bildir" özelliği için
   **Other User Content**, isteğe bağlı iletişim alanı için **Email Address** ve uygulama/iOS
   sürümü ile cihaz modeli için **Other Diagnostic Data** beyan et. Üçünde de Linked: Evet,
   Tracking: Hayır, Purpose: App Functionality. Birlikte Çekim ve isteğe bağlı yedekleme
   kullanıcının private iCloud/CloudKit hesabını kullanır; geliştirici bu içeriklere erişmez.
5. **Age rating**: tüm sorulara "None" → 4+.
6. **App Review Information → Notes** (İngilizce öneri):
   > Photos and projects stay on device unless the user enables an iCloud feature.
   > Optional feedback is stored in the developer's public CloudKit database as disclosed
   > in App Privacy. Sign in with Apple is optional
   > (there is a "Continue without signing in" option). Account deletion is under
   > Settings → Hesap → Hesabı sil. Pro features can be tested with the free trial
   > or the provided sandbox account.

## 7. Build yükle ve TestFlight

1. Xcode'da hedef: **Any iOS Device (arm64)** → **Product → Archive**.
2. Organizer → **Distribute App → App Store Connect → Upload**.
   (Şifreleme sorusu sorulmaz; `ITSAppUsesNonExemptEncryption=NO` ayarlı.)
3. 10-30 dk sonra build TestFlight'ta görünür. **Internal Testing**'e kendini ekle ve
   gerçek cihazda şunları doğrula:
   - Widget'tan `flapse://capture` derin bağlantısı (ücretsiz kullanıcı limitteyken paywall açmalı)
   - Arka planda render + Dynamic Island + öne dönünce otomatik retry
   - Fotoğraf içe aktar → "Bitti" ile kapanış
   - Kırpma, Fotoğraflara kaydetme, bildirimler, 2-3 dilde arayüz
4. İstenirse **External Testing** grubu (ilk dış grup kısa bir TestFlight incelemesinden geçer).

## 8. İncelemeye gönder

1. Sürüm sayfasında build'i seç, IAP'leri iliştir.
2. **Add for Review → Submit to App Review**.
3. İnceleme genelde 24-48 saat. Ret gelirse Resolution Center'daki gerekçe tek maddelik
   olur; düzeltip yeniden göndermek hızlıdır.
4. Onay sonrası yayına alma anını kontrol etmek için "Manually release this version" seç.

## 9. Yayın sonrası

- Xcode Organizer → Crashes ve App Analytics'i izle.
- Yeni sürümde `MARKETING_VERSION`'ı artır (1.0 → 1.1); her yüklemede
  `CURRENT_PROJECT_VERSION` da artmalı.
- `CKShare.publicPermission = .readWrite` bilinçli tercih (linki olan herkes katılabilir) —
  Birlikte Çekim'i geniş duyurmadan önce bir kez daha gözden geçir.
- GitHub Actions CI her main push ve pull request için Release build, static analyze
  ve unit test çalıştırır; kırmızı bir koşuyla yayın yapma.

---

*Ayrıca bkz. `RELEASE_CHECKLIST.md` (gönderim öncesi teknik kontrol listesi).*
