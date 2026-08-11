# Flapse 1.0 (1) — App Store Release Audit

Denetim tarihi: **11 Ağustos 2026**

Denetlenen commit tabanı: `main` / `a68a3ac` ve bu raporla gelen yayın sertleştirmeleri

Xcode: **26.6 (17F113)** · SDK: **iOS 26.5** · minimum iOS: **17.0**

## Executive Summary

Flapse kodu; mimari, Swift 6 concurrency, güvenlik, gizlilik, izinler,
yerelleştirme, erişilebilirlik, performans, veri saklama, StoreKit ve Release
imzalama açısından yeniden denetlendi. Kod tarafında bilinen kritik veya yüksek
öncelikli bir yayın engeli kalmadı.

Denetim sırasında Release paketine komut satırıyla UI-test veri deposu açabilen
kod yolları ve performans izleme state'i girebildiği görüldü. Bu yollar artık
`#if DEBUG` ile derleme zamanında ayrılıyor. Açık tema kontrastı, Dynamic Type,
boş durum erişilebilirliği ve CI doğrulamaları da güçlendirildi.

Son doğrulama:

- **201 uygun unit test geçti, 0 hata.** İmzasız test host'unda çalışamayan dört
  CloudKit-entitlement entegrasyon testi ayrı tutuldu.
- İki erişilebilirlik UI testi geçti: ana ekranların yapısal denetimi ve en büyük
  erişilebilirlik yazı boyutunda temel akış.
- Release build ve Xcode static analyzer geçti.
- Generic iOS archive ve App Store Connect IPA export geçti.
- IPA: `build/export-20260811-audit/Flapse.ipa` — **9,503,979 byte**.
- Apple Distribution imzası geçerli; `get-task-allow=false`, Push ve CloudKit
  ortamı `Production`; yalnızca `arm64`; app ve widget Privacy Manifest'i pakette.
- Release binary içinde `--uitests`, `FLAPSE_UI_TESTS`, Debug Pro veya performans
  trace işaretleri bulunmuyor.
- Dört String Catalog geçerli; 517 ana uygulama anahtarında eksik/boş/needs-review
  çeviri yok; IPA 20 yerelleştirme içeriyor.

## Architecture Score — 92/100

- SwiftUI + SwiftData katmanı feature bazlı klasörlere ayrılmıştır.
- Veri mutasyonları `ProjectRepository` üzerinden merkezileştirilmiştir.
- Donanım/işletim sistemi servisleri protokollerle test edilebilir hâle getirilmiş;
  paywall ve export katmanlarında sahte servis kullanımı mümkündür.
- Singleton kullanımı kamera, bildirim, CloudKit ve render gibi süreç çapında tek
  sahip gerektiren servislerle sınırlıdır.
- Üçüncü taraf dependency yoktur; paket tedarik zinciri riski düşüktür.
- Büyük medya/export dosyaları bilinçli olarak ayrıştırılmıştır; bu aşamada büyük
  mimari yeniden yazım risk/fayda açısından uygun değildir.

## Security Score — 96/100

- Kaynak ve kaynak paketinde API anahtarı, token, JWT, özel anahtar, gizli endpoint,
  analytics DSN'i veya HTTP uygulama endpoint'i bulunmadı.
- Harici uygulama bağlantıları HTTPS'tir; yalnızca sistem `mailto` akışı farklıdır.
- Apple kimlik bilgileri Keychain'de tutulur; hassas kimlik bilgisi UserDefaults'a
  yazılmaz.
- Pro yetkisi StoreKit 2 doğrulamasına bağlıdır. Geliştirici Pro anahtarı yalnızca
  Debug derlemesindedir ve Release binary taramasında yoktur.
- Proje arşivi import'u boyut, kayıt sayısı, göreli yol, symlink ve traversal
  kontrolleri uygular.
- Statik URL ve UIKit `layerClass` invariant'larında kalan force unwrap/cast'ler
  dış girdiye bağlı değildir. DSP pointer erişimleri sabit, boş olmayan buffer
  guard'larının içindedir.
- Certificate pinning uygulanmadı; uygulamanın özel HTTP sunucusu olmadığı ve
  CloudKit/StoreKit Apple sistem katmanlarını kullandığı için ek güvenlik sağlamaz.

## Performance Score — 92/100

- Thumbnail downsampling, sınırlı bellek cache'i, lazy grid/list ve proje detayı
  kademeli yükleme kullanılır; tam çözünürlüklü fotoğraflar liste hücresinde decode
  edilmez.
- Export ve görsel analiz ağır işleri UI thread'i dışında yürütür; state yayınları
  UI actor'ına döner.
- Release'te `PerfTrace` ve kamera launch trace sözlük, kilit, logger ve zaman ölçümü
  tamamen no-op olur.
- Swift 6 strict concurrency, whole-module optimization, dead-code stripping ve
  warnings-as-errors etkindir.
- Uygulamanın gerçek fotoğraf arşivi ve fiziksel cihazla uzun süreli Instruments
  ölçümü otomatik denetimin yerini tutmaz; manuel matriste bırakılmıştır.

## Accessibility Score — 92/100

- Ana ekran, proje boş durumu ve Ayarlar semantik Dynamic Type fontlarına taşındı.
- Dekoratif ikonlar VoiceOver ağacından çıkarıldı; ana navigation yüzeyleri element,
  hit-region, açıklama ve trait audit'inden geçti.
- En büyük erişilebilirlik yazı boyutunda home → projects → settings akışı geçti.
- Altı hazır temada ana/ikincil metin ve vurgu düğmesi WCAG AA 4.5:1 testiyle
  otomatik doğrulanır.
- Liquid Glass üzerinde XCTest'in piksel kontrast ve sıkı glif sınırı denetimleri
  yanlış pozitif ürettiğinden kontrast deterministik luminance testiyle, yazı
  sığması ise gerçek erişilebilirlik boyutunda ekran-frame testiyle doğrulanır.

## Localization Score — 97/100

- Türkçe kaynak dahil 20 uygulama dili paketlenmiştir: `ar`, `de`, `en`, `es`,
  `fr`, `hi`, `id`, `it`, `ja`, `ko`, `nl`, `pl`, `pt`, `ru`, `sv`, `th`, `tr`,
  `vi`, `zh-Hans`, `zh-Hant`.
- Ana metin, Info.plist izin metinleri, arşiv export mesajları ve widget katalogları
  geçerli JSON'dur; boş veya needs-review çeviri yoktur.
- Arapça RTL içerik desteklenir; ürün navigasyon barı bilinçli olarak fiziksel
  konumunu korur.
- StoreKit ürün yerelleştirmeleri App Store Connect'te ayrıca manuel girilmelidir;
  yerel `.storekit` dosyası yalnızca test yapılandırmasıdır.

## Privacy Compliance Score — 96/100

- App ve widget `PrivacyInfo.xcprivacy` dosyaları geçerli ve IPA içinde doğru
  konumdadır.
- Required Reason API: UserDefaults `CA92.1` ve `1C8F.1`.
- Tracking ve tracking domain yoktur; ATT gerektiren reklam/izleme SDK'sı yoktur.
- Geri bildirim public CloudKit'e opsiyonel e-posta, kullanıcı metni ve cihaz/app
  tanılama bilgisi gönderdiği için manifestte Email Address, Other User Content ve
  Other Diagnostic Data; linked=yes, tracking=no, App Functionality beyan edilir.
- Kamera, Face ID, konum, mikrofon ve Fotoğraflar izin açıklamaları mevcut ve 20
  dile çevrilmiştir. Bluetooth, kişiler, takvim, hareket, konuşma veya sağlık izni
  istenmez.

## App Store Readiness Score — 89/100

Binary yayın adayıdır. Eksik puanlar koddan değil, Apple hesabında doğrulanamayan
CloudKit Production, IAP, metadata, içerik lisansı ve gerçek cihaz TestFlight
işlemlerinden kaynaklanır.

## Critical / Medium / Low Findings

### Kritik

- **Açık bulgu yok.** Release build, analyze, archive, export ve imza doğrulaması
  tamamlandı.

### Orta

- CloudKit Production şeması bu makineden doğrulanamaz/deploy edilemez.
- İlk abonelikler App Store Connect'te binary ile birlikte review'a eklenmelidir.
- Sekiz gömülü müzik parçasının ticari dağıtım ve kullanıcı çıktısında kullanım
  lisansı hesap sahibi tarafından belgelenmelidir.
- İki ayrı gerçek Apple hesabıyla paylaşım/senkron ve TestFlight satın alma testi
  hâlâ manueldir.

### Düşük

- `COPY_PHASE_STRIP=NO` proje seviyesinde görünse de Release'te
  `STRIP_INSTALLED_PRODUCT=YES`, `DEAD_CODE_STRIPPING=YES` ve archive logunda gerçek
  `strip` adımı doğrulanmıştır; değişiklik gerekmez.
- iPad uygulaması portrait/full-screen olarak tasarlanmıştır. Split View/landscape
  desteği eklemek ürün davranışını değiştirir; ilk sürüm için zorunlu kod düzeltmesi
  olarak uygulanmadı.

## Summary of Every Modification

1. UI-test in-memory store, CloudKit feedback bypass ve ortak proje bypass'ı yalnızca
   Debug derlemesine alındı.
2. Release performans ve kamera trace state'i/kilitleri tamamen derleme dışına alındı.
3. Açık tema tarih rengi ve Coastal ikincil metin tonu WCAG AA seviyesine yükseltildi.
4. Vurgu düğmesi yazı rengi accent luminance'ına göre siyah/beyaz seçilir hâle geldi.
5. Tema tipografi yardımcıları semantik Dynamic Type stillerine geçirildi.
6. Home, proje boş durumu ve Ayarlar metinleri büyüyebilir ve çok satıra sığabilir
   hâle getirildi; dekoratif ikonlar VoiceOver'dan çıkarıldı.
7. Altı paletin kontrastı için unit test, ana ekranlar ve en büyük yazı boyutu için
   UI erişilebilirlik testleri eklendi.
8. CI, entitlement gerektiren dört CloudKit entegrasyon testini açıkça ayırır;
   kalan 201 unit testi ve iki erişilebilirlik smoke testini çalıştırır.
9. Tema kategori vurgu fallback'indeki gereksiz force unwrap kaldırıldı.

## Files Changed

- `.github/workflows/ci.yml`
- `Flapse/FlapseApp.swift`
- `Flapse/PerfTrace.swift`
- `Flapse/Features/Camera/CameraLaunchTrace.swift`
- `Flapse/Features/CaptureTogether/SharedProjectService.swift`
- `Flapse/Features/Feedback/FeedbackService.swift`
- `Flapse/Theme.swift`
- `Flapse/Features/Home/HomeView.swift`
- `Flapse/Features/Projects/ProjectListView.swift`
- `Flapse/Features/Settings/SettingsView.swift`
- `FlapseTests/AppThemeTests.swift`
- `FlapseUITests/FlapseUITests.swift`
- `APP_STORE_YAYIN_DURUMU.md`
- `RELEASE_CHECKLIST.md`
- `RELEASE_AUDIT_REPORT.md`

## Remaining Manual Tasks

### Apple Developer Portal Tasks

| İşlem | Durum | Manuel | Nasıl tamamlanır |
| --- | --- | --- | --- |
| Üyelik, takım ve sertifika geçerliliği | Doğrulanmalı | Evet | Developer Account'ta üyelik ve Distribution sertifikasını kontrol et. |
| App ID capability'leri | Binary'de var, portal kontrolü gerekli | Evet | `rozcan.Flapse`: iCloud/CloudKit, Sign in with Apple, Push, App Groups. |
| Widget App Group | Binary'de var, portal kontrolü gerekli | Evet | `rozcan.Flapse.Widgets` ve app için `group.rozcan.Flapse`. |
| CloudKit Production schema | Bekliyor | Evet | `iCloud.rozcan.Flapse` → Development schema → Deploy to Production. |
| Production paylaşım testi | Bekliyor | Evet | İki gerçek Apple hesabıyla davet, ekleme, silme ve yeniden senkron dene. |
| Push ortamı | IPA'da Production | Kısmen | TestFlight'ta CloudKit remote notification yenilemesini doğrula. |
| Associated Domains / Apple Pay / Game Center | Kullanılmıyor | Hayır | Capability ekleme. |

### App Store Connect Tasks

| İşlem | Durum | Manuel | Nasıl tamamlanır |
| --- | --- | --- | --- |
| App kaydı ve SKU | Doğrulanmalı | Evet | Bundle ID `rozcan.Flapse`, ad `Flapse`, 1.0 sürümü. |
| Kategori | Bekliyor | Evet | Birincil `Photo & Video`; ikincil uygun görülürse `Lifestyle`. |
| Metadata/URL | Metinler hazır | Evet | `docs/AppStoreListing.md`, support ve privacy URL'lerini gir. |
| Ekran görüntüleri | Dosyalar hazır | Evet | `AppStoreScreenshots/6.9-inch/tr` ve `13-inch/tr` setlerini yükle. |
| Privacy Nutrition Label | Bekliyor | Evet | Manifestteki üç veri türünü linked=yes/tracking=no olarak gir. |
| Yaş derecelendirmesi | Bekliyor | Evet | Güncel yaş derecelendirme sorularını yanıtla. |
| Export compliance | Bekliyor | Evet | Standart Apple şifreleme kullanımını doğru beyan et. |
| IAP/abonelik | Bekliyor | Evet | Aylık/yıllık aynı grupta; lifetime non-consumable; fiyat, lokalizasyon, review screenshot. |
| Sözleşme/vergi/banka | Bekliyor | Evet | Paid Apps Agreement ve ödeme bilgilerini tamamla. |
| TestFlight | Bekliyor | Evet | IPA'yı yükle, internal test ve aşağıdaki release checklist'i uygula. |
| Review Notes | Bekliyor | Evet | CloudKit paylaşımı, Face ID, render/Live Activity ve Pro test adımlarını yaz. |
| Müzik hakları | Bekliyor | Evet | Lisans belgelerini sakla; emin olunmayan parçayı çıkar. |

## Risks

- Production şema deploy edilmezse CloudKit proje paylaşımı çalışmayabilir.
- App Store Connect IAP kimlikleri `Products.storekit` ile birebir uyuşmazsa paywall
  fiyatları yüklenmez ve review tamamlanamaz.
- Geri bildirim veri akışı App Privacy formunda “Data Not Collected” seçilirse
  manifest/politika ile çelişir.
- Review sırasında internet/CloudKit servisi kapalıysa paylaşım veya feedback yolu
  eksik görünebilir; Review Notes test yöntemini açıkça anlatmalıdır.
- Büyük gerçek arşivlerde bellek/FPS, simülatör testinden sonra fiziksel cihazda
  Instruments ile son kez ölçülmelidir.

## Recommended Improvements

İlk sürümü bloke etmeyen sonraki sürüm önerileri:

- MetricKit hang/crash metriklerini sürüm sonrası takip et.
- Gerçek kullanıcı verisi toplamadan App Store Connect Product Page Optimization ile
  screenshot sıralamasını test et.
- Fiziksel eski cihazda 500+ kare proje için Time Profiler, Core Animation ve
  Allocations baseline'ı sakla.
- Çevirileri mağaza yayılımından önce ana dil editörlerine son kez okut.

## Release Checklist

- [x] Swift 6 strict concurrency
- [x] Release warnings-as-errors build
- [x] Xcode static analyze
- [x] 201 uygun unit test
- [x] Ana ekran accessibility audit
- [x] En büyük erişilebilirlik yazı boyutu smoke test
- [x] Privacy Manifest ve String Catalog doğrulaması
- [x] Archive + App Store Connect IPA export
- [x] Apple Distribution / Production entitlement / `get-task-allow=false`
- [ ] CloudKit schema Production deploy
- [ ] İki hesapla CloudKit paylaşım testi
- [ ] App Store Connect metadata, privacy ve güncel age rating
- [ ] IAP'ler, review screenshot'ları, fiyatlar ve lokalizasyonlar
- [ ] Paid Apps Agreement, banka ve vergi
- [ ] Müzik lisans belgeleri
- [ ] TestFlight gerçek cihaz regresyonu
- [ ] Organizer Validate App ve Upload
- [ ] Build'i 1.0 sürümüne bağla ve Submit for Review

## Instruments ile Son Manuel Doğrulama

1. TestFlight build'ini gerçek cihazda, 300–500 kareli en büyük proje ile aç.
2. Time Profiler'da launch, sekme geçişi ve proje açılışında main-thread >100 ms
   blok arayıp call tree'yi “Invert Call Tree + Hide System Libraries” ile incele.
3. Core Animation'da sekmeler ve fotoğraf listesinde hitch/FPS kaydı al.
4. Allocations + Leaks ile proje ekranını 10 kez aç/kapat; kalıcı büyüme olmamalı.
5. Memory Graph'ta `ProjectDetailView`, player, timer, observer ve task sahiplerinin
   ekran kapandıktan sonra tutulmadığını kontrol et.
6. Network/CloudKit loglarında yinelenen fetch, sonsuz retry veya paylaşım duplicate
   record olmadığını iki hesapla doğrula.
7. Background render sırasında uygulamayı kilitle/aç; Live Activity ilerlemesi ve
   tamamlanan videonun bütünlüğünü doğrula.

## Final Decision

**READY AFTER MANUAL APPLE DEVELOPER STEPS**
