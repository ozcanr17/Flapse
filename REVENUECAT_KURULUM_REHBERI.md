# Flapse — RevenueCat Kurulum ve Geçiş Rehberi

Son güncelleme: 12 Ağustos 2026

## Karar

Flapse 1.0, satın alma ve Pro yetkisini StoreKit 2 ile güvenli biçimde yönetmeye devam
edecek. İlk aşamada RevenueCat yalnızca App Store gelirlerini, abonelik olaylarını ve
müşteri yaşam döngüsünü raporlamak için bağlanacak. Bunun için 1.0 uygulama koduna SDK
eklemek gerekmez.

Bu yaklaşım yayın adayını değiştirmez ve satın alma/geri yükleme davranışına regresyon
riski eklemez. RevenueCat paywall, entitlement, deney ve hedefleme özellikleri istenirse
SDK geçişi 1.1 sürümünde ayrıca yapılacaktır.

## Aşama A — Yayın sonrası raporlama (kod değişikliği yok)

### 1. RevenueCat projesini oluştur

1. RevenueCat hesabında **Flapse** adlı bir proje oluştur.
2. Projeye **Apple App Store** uygulaması ekle.
3. Bundle ID olarak `rozcan.Flapse` gir.
4. App Store Connect'teki Flapse kaydıyla aynı uygulamanın seçildiğini iki kez kontrol et.

### 2. Apple mağaza kimlik bilgilerini bağla

RevenueCat uygulama ayarlarında Apple için istenen kimlik bilgilerini ekle:

- **In-App Purchase Key**: StoreKit 2 işlemlerinin RevenueCat tarafından güvenilir
  biçimde kaydedilmesi için gereklidir.
- **App Store Connect API Key**: ürünleri ve fiyatları App Store Connect'ten içe
  aktarmak için önerilir.
- RevenueCat paneli isterse app-specific shared secret alanını da tamamla.

`.p8` özel anahtarlarını, issuer ID'yi veya RevenueCat secret API key'lerini uygulama
koduna, GitHub'a, bu depoya ya da bir istemci yapılandırma dosyasına koyma. Bunlar yalnızca
RevenueCat ve App Store Connect'in güvenli panellerinde tutulmalıdır.

### 3. Ürünleri içe aktar

RevenueCat → Flapse → Products alanında App Store Connect'ten şu üç ürünü içe aktar:

- `com.ridvan.timelapse.pro.monthly`
- `com.ridvan.timelapse.pro.yearly`
- `com.ridvan.timelapse.pro.lifetime`

Product ID'leri değiştirme veya RevenueCat için ikinci kez ürün oluşturma. App Store'daki
mevcut ürünler tek ödeme kaynağıdır.

Raporlama için entitlement zorunlu değildir; yine de sonraki SDK geçişini hazırlamak için
`pro` adlı entitlement oluşturup üç ürünü buna bağlamak önerilir. Aylık ve yıllık ürün
abonelik süresince, lifetime ürünü süresiz olarak aynı Pro erişimini temsil eder.

İleride RevenueCat paywall kullanılacaksa `default` adlı Offering oluştur ve aylık,
yıllık ve lifetime paketlerini bu offering'e ekle. 1.0 uygulaması bu offering'i henüz
kullanmayacaktır.

### 4. App Store Server Notifications V2'yi bağla

1. RevenueCat'te Flapse uygulama ayarlarından **Apple Server Notification URL**'yi bul.
2. Mümkünse **Apply in App Store Connect** düğmesini kullan.
3. Manuel yapılıyorsa App Store Connect → Flapse → App Information →
   **App Store Server Notifications** bölümünde RevenueCat URL'sini hem Production hem
   Sandbox alanına eksiksiz yapıştır.
4. Bildirim sürümü olarak **V2** kullan.
5. RevenueCat'te **Track new purchases from server-to-server notifications** seçeneğini aç.

Apple her ortam için tek bildirim URL'si kabul eder. Flapse'ın ileride kendi sunucusu da
bu bildirimleri alacaksa Apple URL'sini doğrudan değiştirmek yerine RevenueCat'in notification
forwarding özelliği kullanılmalıdır.

SDK kurulmadan gelen işlemlerde `appAccountToken` bulunmayabilir. Bu durumda RevenueCat
satın almayı anonim bir müşteriyle ilişkilendirir. Gelir ve abonelik takibi çalışır; ancak
RevenueCat müşteri kaydını uygulamadaki belirli bir kullanıcıyla eşleştirmek için 1.1 SDK
geçişi gerekir.

### 5. Sandbox doğrulaması

1. App Store Connect'te bir Sandbox Tester oluştur.
2. TestFlight veya gerçek StoreKit sandbox ortamında aylık ürünü satın al.
3. RevenueCat panelinde **Sandbox data** görünümünü aç.
4. Initial Purchase olayının ve aktif aboneliğin göründüğünü kontrol et.
5. Aboneliğin hızlandırılmış sandbox yenilenmesini, iptalini ve sona ermesini izle.
6. Lifetime ürünü ayrı bir sandbox hesabıyla satın alıp non-subscription purchase olarak
   göründüğünü doğrula.
7. Flapse'ta **Satın Alımları Geri Yükle** akışının Pro erişimini hâlâ açtığını doğrula.

Production metrikleriyle sandbox metriklerini karıştırma. Test işlemleri RevenueCat'te
ayrı sandbox filtresi altında incelenmelidir.

### 6. App Privacy beyanını güncelle

RevenueCat kullanılmaya başlandığında App Store Connect → App Privacy formunda en az
**Purchase History** beyanı eklenmelidir:

- Amaç: **Analytics** ve **App Functionality**
- Tracking: **Hayır** (Flapse reklam amaçlı çapraz uygulama takibi yapmıyorsa)
- Linked to User: yalnız anonim RevenueCat kullanıcıları kullanılıyorsa ve başka bir
  kimlikle eşleştirilmiyorsa **Hayır**; özel App User ID ile hesaba bağlanıyorsa **Evet**

1.0 yayımlandıktan sonra yalnız dashboard/server-notification bağlantısı kurulacak olsa
bile RevenueCat satın alma geçmişini işlediği için bu beyan göz ardı edilmemelidir. SDK
eklenen sürüm gönderilmeden önce Xcode privacy report yeniden üretilmeli ve RevenueCat'in
güncel privacy manifest'i doğrulanmalıdır.

## Aşama B — 1.1'de RevenueCat SDK geçişi (isteğe bağlı)

Bu aşama, yalnız raporlama yetmiyorsa ve RevenueCat entitlement, paywall, experiments veya
targeting özellikleri kullanılacaksa yapılmalıdır.

### Güvenli mimari

- Mevcut `StoreServiceProtocol` korunur; ekranlar ve `PaywallViewModel` yeniden yazılmaz.
- RevenueCat SDK Swift Package Manager ile eklenir.
- SDK uygulama açılışında yalnız bir kez, platforma ait **public SDK key** ile yapılandırılır.
- Secret (`sk_...`) anahtar hiçbir koşulda uygulamaya gömülmez.
- Pro durumu `CustomerInfo` içindeki aktif `pro` entitlement'ından okunur.
- Satın alma ve restore sonuçları mevcut `StorePackage` modeline çevrilerek UI davranışı
  korunur.
- Eski StoreKit 2 transaction listener ile RevenueCat'in aynı işlemi sahiplenmesine izin
  verilmez. Geçişte ya RevenueCat satın alma akışının tek sahibi olur ya da mevcut kodun
  işlemleri tamamladığı resmi migration/observer yapılandırması kullanılır.

### Kullanıcı kimliği kararı

Flapse hesap açmadan kullanılabildiği için başlangıçta RevenueCat'in anonim App User ID'si
en güvenli seçenektir. Bu, Apple hesabı/iCloud hesabı ile aynı şey değildir.

İleride Sign in with Apple kimliği RevenueCat'e bağlanacaksa:

- e-posta adresi App User ID olarak kullanılmaz;
- tahmin edilemeyen, kararlı ve kullanıcıya özel bir UUID kullanılır;
- girişte `logIn`, hesap değişiminde resmi identity/transfer kuralları uygulanır;
- entitlement'ın yanlış hesaba taşınmadığı iki hesap ve iki cihazla test edilir;
- App Privacy'de **User ID** ve kullanıcıyla ilişkilendirme beyanları güncellenir.

### 1.1 kabul kriterleri

- Mevcut aylık, yıllık ve lifetime müşteriler Pro kalır.
- Temiz kullanıcı üç ürünü de satın alabilir.
- İptal, expiration, billing retry ve refund sonrası entitlement doğru güncellenir.
- Restore aynı Apple hesabında çalışır.
- Uçak modunda daha önce doğrulanmış abonelik için beklenen cache davranışı korunur.
- RevenueCat kesintisi uygulamayı açılışta bloke etmez.
- Sandbox ve production anahtarları karışmaz.
- App Privacy ve üçüncü taraf SDK beyanları yeni binary ile uyumludur.

## Yayın sonrası izlenecek temel metrikler

- Trial başlangıcı ve trial → paid dönüşümü
- Aylık/yıllık/lifetime ürün dağılımı
- Aktif abonelik, renewal ve cancellation
- Billing issue ve recovered revenue
- MRR, gelir ve müşteri başına gelir
- Refund oranı
- Paywall görüntüleme → satın alma dönüşümü (SDK/RevenueCat paywall aşamasında)

RevenueCat raporu operasyonel analiz katmanıdır; ödeme işlemi ve App Store finansal
mutabakatı için nihai kaynak App Store Connect'tir. Vergi, ödeme ve banka mutabakatları
RevenueCat grafikleri yerine Apple'ın resmi finans raporlarıyla kontrol edilmelidir.

## Gerekli bilgiler

Aşama A'nın panel adımlarını hesap sahibi tamamlayabilir; uygulama kodu veya anahtar paylaşımı
gerekmez. Aşama B'ye geçildiğinde geliştiriciye yalnız RevenueCat'in Flapse Apple uygulaması
için ürettiği **public SDK key** verilmelidir. In-App Purchase `.p8`, App Store Connect `.p8`
ve RevenueCat secret API key paylaşılmamalıdır.
