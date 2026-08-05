import StoreKit

/// Mağaza/yetki katmanına erişimin tek kapısı. Arayüz ve ViewModel'lar bunu tanır;
/// testte sahte (fake) bir implementasyon enjekte edilebilir.
@MainActor
protocol StoreServiceProtocol: AnyObject {
    var packages: [StorePackage] { get }
    var isPro: Bool { get }
    func loadProducts() async
    func purchase(_ package: StorePackage) async throws -> Bool
    func restore() async
}

/// StoreKit 2 tabanlı gerçek mağaza servisi. Baştan sona async/await.
@MainActor
@Observable
final class StoreService: StoreServiceProtocol {

    private(set) var packages: [StorePackage] = []

    /// StoreKit'ten türetilen gerçek satın alma durumu.
    private(set) var entitlementActive = false

    /// Uygulamanın her yerinde okunan tek doğruluk kaynağı.
    ///
    /// Yayın sürümünde Pro yalnızca doğrulanmış StoreKit yetkisiyle açılır.
    var isPro: Bool { entitlementActive }

    private var storeProducts: [Product] = []   // satın alma için Product'ları içeride tutuyoruz
    @ObservationIgnored nonisolated(unsafe) private var updatesTask: Task<Void, Never>?

    init() {
        // Uygulama açıkken DIŞARIDA olan işlemleri (yenileme, başka cihaz, iade, "Ask to Buy"
        // onayı) yakalamak için Transaction.updates'i sürekli dinliyoruz.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
    }

    deinit { updatesTask?.cancel() }

    func loadProducts() async {
        do {
            let products = try await Product.products(for: StoreProduct.allCases.map(\.rawValue))
            let order = StoreProduct.allCases.map(\.rawValue)
            storeProducts = products.sorted {
                (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max)
            }
            var built: [StorePackage] = []
            for product in storeProducts {
                var hasTrial = false
                if let subscription = product.subscription,
                   subscription.introductoryOffer?.paymentMode == .freeTrial {
                    hasTrial = await subscription.isEligibleForIntroOffer
                }
                built.append(StorePackage(
                    id: product.id,
                    displayName: product.displayName,
                    displayPrice: product.displayPrice,
                    hasTrial: hasTrial
                ))
            }
            packages = built
        } catch {
            storeProducts = []
            packages = []
        }
    }

    func purchase(_ package: StorePackage) async throws -> Bool {
        if storeProducts.isEmpty { await loadProducts() }
        guard let product = storeProducts.first(where: { $0.id == package.id }) else {
            throw StoreError.productUnavailable
        }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await refreshEntitlements()
            await transaction.finish()   // içeriği teslim ettiğimizi StoreKit'e bildiriyoruz
            return true
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }

    func restore() async {
        // StoreKit 2 yetkileri çoğunlukla kendiliğinden eşitler; "Geri Yükle" düğmesi
        // esasen bir senkron tetikler.
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    /// Kullanıcının ŞU AN sahip olduğu hak(lar)dan Pro durumunu türetir.
    /// "isPro"u biz kalıcı saklamıyoruz; her zaman StoreKit'ten okuyoruz — en sağlam yol.
    func refreshEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            let isOurProduct = StoreProduct(rawValue: transaction.productID) != nil
            if isOurProduct, transaction.revocationDate == nil {
                active = true   // bizim ürünümüz ve iade/iptal edilmemiş
            }
        }
        entitlementActive = active
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard let transaction = try? checkVerified(result) else { return }
        await refreshEntitlements()
        await transaction.finish()
    }

    /// StoreKit işlemleri kriptografik olarak doğrular. Doğrulanmamış bir işleme asla güvenmiyoruz.
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):  return safe
        case .unverified:          throw StoreError.failedVerification
        }
    }
}
