# Flapse App Store Yayın Durumu

Son güncelleme: 5 Ağustos 2026

## Kısa sonuç

Flapse'ın kod, Release derleme, güvenlik, gizlilik manifesti ve otomatik test tarafındaki hazırlıkları tamamlanmıştır. Uygulama henüz App Store'a gönderilmiş değildir. Yayın öncesinde Apple Developer Portal ve App Store Connect üzerinde yalnızca hesap sahibi tarafından tamamlanabilecek işlemler bulunmaktadır.

Kod tarafındaki mevcut durum: **Apple Developer işlemleri tamamlandıktan sonra yayına hazır.**

## Tamamlanan teknik çalışmalar

- Swift 6 ve Strict Concurrency etkinleştirildi.
- Release derlemesinde uyarılar hata olarak işleniyor.
- Release build ve static analyzer başarılı.
- Tüm birim testleri başarılı.
- App Store dağıtım arşivi ve IPA export işlemi doğrulandı.
- Apple Distribution imzası ve Production entitlement'ları kontrol edildi.
- CloudKit, Sign in with Apple, App Groups, Push Notifications ve widget yetkileri projede tanımlı.
- Gizli Pro/debug erişimleri kaldırıldı; Pro yalnızca StoreKit satın alma doğrulamasına bağlı.
- Hesap bilgileri Keychain'de saklanıyor.
- Privacy Manifest ve web gizlilik politikası gerçek veri akışına göre güncellendi.
- Proje arşivleri için boyut, kayıt sayısı, path traversal ve symlink kontrolleri eklendi.
- Proje arşivi dışa aktarmada kullanıcı Dosyalar/iCloud Drive içinden hedef konumu seçebiliyor.
- Paylaşım kartları 1080×1350 ve 1080×1920 sosyal medya ölçülerine göre yenilendi.
- GitHub Actions üzerinde Release build, analyze ve test kontrolü etkin.

## Geliştirme sırasında Pro özelliklerini test etme

Xcode'dan telefona yüklenen `DEBUG` sürümünde Ayarlar ekranının en altındaki Flapse logosuna beş kez dokunarak Test Pro açılıp kapatılabilir. Durum değiştiğinde uygulama bir onay mesajı gösterir ve seçim sonraki Debug açılışlarında korunur.

Bu mekanizma `#if DEBUG` ile korunur. App Store'a gönderilen Release derlemesinde kodu, anahtarı ve kullanıcı arayüzü bulunmaz. Archive alırken `Release` yapılandırmasının kullanıldığını yine de kontrol et.

Belirli bir Apple ID veya iCloud hesabına CloudKit/UserDefaults üzerinden Pro atama. Dijital özellikleri StoreKit dışında açan hesap tabanlı bir yetki App Review ve In-App Purchase kuralları açısından risklidir. TestFlight ve yayın sürümündeki satın alma testleri için bu Debug anahtarı yerine Apple'ın Sandbox hesaplarını, StoreKit Testing'i veya App Store Connect offer code sistemini kullan.

## Senin yapman gerekenler

### 1. Apple Developer hesabını kontrol et

1. [Apple Developer](https://developer.apple.com/account/) hesabına giriş yap.
2. Üyeliğin aktif ve sözleşme sahibinin doğru kişi/şirket olduğundan emin ol.
3. `Certificates, Identifiers & Profiles` bölümünü aç.
4. Flapse App ID'sinde aşağıdaki capability'lerin açık olduğunu kontrol et:
   - iCloud ve CloudKit
   - Sign in with Apple
   - Push Notifications
   - App Groups
5. Ana uygulama ile widget extension'ın aynı App Group'u kullandığını kontrol et.
6. Distribution certificate ve provisioning profile'ların geçerli olduğunu doğrula. Xcode otomatik imzalama kullanıyorsa doğru Team'in seçili olması yeterlidir.

### 2. CloudKit Production şemasını yayınla

Bu adım yapılmazsa geliştirme ortamında çalışan proje senkronizasyonu ve birlikte çekim özellikleri App Store sürümünde çalışmayabilir.

1. [CloudKit Console](https://icloud.developer.apple.com/) sayfasına gir.
2. Flapse'ın kullandığı iCloud container'ını seç.
3. Development ortamında gerekli record type, field ve index'lerin oluştuğunu kontrol et.
4. `Deploy Schema Changes` ile şemayı Production ortamına gönder.
5. Production ortamında `Project`, `Entry`, paylaşım kayıtları ve feedback için kullanılan tiplerin mevcut olduğunu kontrol et.
6. İki farklı gerçek Apple hesabıyla ortak proje daveti, kare ekleme ve senkronizasyon testi yap.

Production veritabanındaki kullanıcı verilerini test amacıyla topluca silme. Schema deploy işleminden önce container adını iki kez kontrol et.

### 3. App Store Connect uygulama kaydını tamamla

1. [App Store Connect](https://appstoreconnect.apple.com/) içinde `My Apps > Flapse` uygulamasını aç.
2. Bundle ID'nin Xcode projesindeki Bundle ID ile aynı olduğunu kontrol et.
3. Birincil kategori olarak `Photo & Video` seç.
4. Uygulama adı, alt başlık, açıklama, anahtar kelimeler, destek URL'si ve gizlilik politikası URL'sini gir.
5. Güncel metinler için `docs/AppStoreListing.md` dosyasını kullan.
6. iPhone ve desteklenen iPad ekran boyutları için güncel ekran görüntülerini yükle.
7. Yaş derecelendirme sorularını uygulamanın gerçek özelliklerine göre yanıtla.
8. Export Compliance bölümünde uygulamanın yalnızca Apple'ın standart şifreleme altyapısını kullanıp kullanmadığını doğru şekilde beyan et.

### 4. App Privacy cevaplarını gir

App Store Connect'teki App Privacy formunda kod ve gizlilik politikasıyla uyumlu olarak şunları beyan et:

| Veri türü | Toplanıyor | Kullanıcıyla ilişkili | Tracking | Amaç |
| --- | --- | --- | --- | --- |
| E-posta adresi | Evet, feedback sırasında opsiyonel | Evet | Hayır | App Functionality |
| Diğer kullanıcı içeriği | Evet, feedback metni | Evet | Hayır | App Functionality |
| Diğer diagnostik veriler | Evet, feedback'e eklenen uygulama/iOS/cihaz bilgisi | Evet | Hayır | App Functionality |

Fotoğraflar, projeler ve videolar kullanıcının iCloud hesabında uygulama işlevi için tutulur; reklam veya üçüncü taraf tracking yapılmaz. Form sorularını yanıtlarken [Apple'ın App Privacy tanımlarını](https://developer.apple.com/app-store/app-privacy-details/) esas al.

### 5. StoreKit ürünlerini tamamla

App Store Connect'te aylık, yıllık ve lifetime ürünlerinin kodda kullanılan ürün kimlikleriyle birebir eşleşmesi gerekir.

1. Aylık ve yıllık ürünleri aynı subscription group içine ekle.
2. Fiyat bölgelerini ve yerelleştirilmiş ürün adlarını doldur.
3. Deneme süresi sunulacak ürünlerde introductory offer ayarını yap.
4. Lifetime ürününü non-consumable olarak tanımla.
5. Her ürün için App Review screenshot ve açıklamasını yükle.
6. Paid Apps Agreement, banka ve vergi bilgilerini tamamla.
7. Sandbox hesabıyla satın alma, iptal, yeniden abone olma ve `Satın Alımları Geri Yükle` akışlarını test et.

Deneme kampanyası yalnızca StoreKit'in uygun gördüğü kullanıcıya gösterilir. App Store Connect'te trial tanımlanmadan uygulama kendi başına deneme süresi veremez.

### 6. Müzik ve içerik haklarını doğrula

Uygulamayla dağıtılan sekiz müzik dosyasının App Store'da ticari dağıtım, videoya ekleme ve kullanıcı tarafından oluşturulan çıktılarda kullanım hakkının bulunduğunu belgeleyebilmelisin.

- Lisans faturalarını veya izin belgelerini sakla.
- Atıf zorunluluğu varsa uygulama içi lisans ekranına ekle.
- Haklarından emin olmadığın parçayı sürümden önce kaldır veya lisansını tamamla.

### 7. Gerçek cihaz TestFlight testi yap

Archive yüklenip TestFlight build'i işlendikten sonra en az şu senaryoları dene:

- Temiz kurulum ve onboarding
- Sign in with Apple ile giriş/çıkış
- iCloud senkronizasyonu ve iki hesapla ortak proje
- Kamera, mikrofon, fotoğraf kütüphanesi ve konum izinleri
- Manuel fotoğraf ve video ekleme
- Face ID/cihaz şifresi ile gizlenenler ve son silinenler
- Proje arşivini iCloud Drive ve Telefonda klasörlerine dışa aktarma
- Aynı adlı arşivin bulunduğu klasöre tekrar dışa aktarma
- Arşivi yeniden içe aktarma
- Seri, önce/sonra ve 9:16 hikâye kartlarını paylaşma
- Büyük projede timelapse üretme, uygulamayı arka plana alma ve geri dönme
- Müzik senkronu, fade-in/fade-out ve videoyu Fotoğraflar'a kaydetme
- Widget, Live Activity ve Dynamic Island
- Satın alma, restore ve trial uygunluğu
- Uçak modu, yavaş bağlantı ve düşük depolama alanı

Test sırasında Xcode Organizer veya TestFlight'ta crash/hang raporu oluşursa göndermeden önce incelenmelidir.

### 8. Erişilebilirlik ve cihaz matrisi

- VoiceOver açıkken tüm ana akışları tamamla.
- Büyük Dynamic Type boyutlarında butonların kaybolmadığını kontrol et.
- Reduce Motion açıkken animasyonları kontrol et.
- Türkçe, İngilizce ve Arapça/RTL düzenlerini kontrol et.
- En küçük desteklenen iPhone, güncel Pro Max ve iPad üzerinde test et.
- Açık ve koyu temaların her birinde kontrastı kontrol et.

### 9. Review için gönder

1. Xcode'da `Product > Archive` çalıştır.
2. Organizer'da `Validate App` ile doğrula.
3. `Distribute App > App Store Connect > Upload` yoluyla yükle.
4. App Store Connect'te build'i sürüme bağla.
5. Review Notes alanına şu bilgileri ekle:
   - Birlikte çekim ve CloudKit paylaşımı nasıl test edilir.
   - Gizlenenlere Face ID veya cihaz şifresiyle nasıl girilir.
   - Pro özelliklerinin nasıl test edileceği.
   - Gerekliyse inceleme için sandbox hesap veya davet bağlantısı.
6. Tüm eksik metadata uyarıları kapandıktan sonra `Add for Review`, ardından `Submit for Review` seç.

Gizli özellik bırakma ve açıklamada uygulamanın yapmadığı bir işlevi vaat etme. Apple'ın güncel kuralları için [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) sayfasını gönderim günü yeniden kontrol et.

## Gönderim öncesi son kontrol listesi

- [ ] Apple Developer üyeliği aktif
- [ ] App ID capability'leri doğru
- [ ] CloudKit schema Production'a deploy edildi
- [ ] İki Apple hesabıyla paylaşım testi geçti
- [ ] App Store Connect metadata ve ekran görüntüleri tamamlandı
- [ ] App Privacy cevapları girildi
- [ ] Aylık, yıllık ve lifetime ürünleri hazır
- [ ] Paid Apps Agreement, banka ve vergi işlemleri tamamlandı
- [ ] Sekiz müzik dosyasının lisansı doğrulandı
- [ ] TestFlight gerçek cihaz regresyon testi geçti
- [ ] VoiceOver, Dynamic Type, RTL ve iPad testleri geçti
- [ ] Organizer validation başarılı
- [ ] Review Notes hazır
- [ ] Build sürüme bağlandı ve incelemeye gönderildi

## Şu anda yayını engelleyen konular

Kod tarafında bilinen kritik bir yayın engeli yoktur. Kalan engeller Apple hesabı üzerinde yapılacak CloudKit Production deploy, App Store Connect ürün/metadata/privacy işlemleri, içerik lisans kontrolü ve gerçek cihaz TestFlight doğrulamasıdır.

Bu adımlar tamamlanmadan uygulama için “App Store'da yayına hazır ve gönderildi” denmemelidir.
