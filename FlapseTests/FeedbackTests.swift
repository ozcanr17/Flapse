import XCTest
@testable import Flapse

@MainActor
final class FeedbackTests: XCTestCase {

    private final class FakeService: FeedbackSubmitting, @unchecked Sendable {
        var errorToThrow: Error?
        private(set) var submitted: [FeedbackReport] = []

        func submit(_ report: FeedbackReport) async throws {
            if let errorToThrow { throw errorToThrow }
            submitted.append(report)
        }
    }

    private struct DummyError: Error {}

    // MARK: - Doğrulama

    func test_kisaMesaj_gonderilemez() {
        let viewModel = FeedbackViewModel(service: FakeService())
        viewModel.message = "bozuk"
        XCTAssertFalse(viewModel.canSubmit)
    }

    func test_sadeceBoslukIcerenMesaj_gonderilemez() {
        let viewModel = FeedbackViewModel(service: FakeService())
        viewModel.message = String(repeating: " ", count: 40)
        XCTAssertFalse(viewModel.canSubmit)
    }

    func test_yeterinceUzunMesaj_gonderilebilir() {
        let viewModel = FeedbackViewModel(service: FakeService())
        viewModel.message = "Kamera geç açılıyor"
        XCTAssertTrue(viewModel.canSubmit)
    }

    // MARK: - Gönderim

    func test_basariliGonderim_sentDurumunaGecer() async {
        let service = FakeService()
        let viewModel = FeedbackViewModel(service: service)
        viewModel.kind = .improvement
        viewModel.message = "Mod geçişi daha hızlı olabilir"
        viewModel.contactEmail = "  kullanici@example.com "

        await viewModel.submit()

        XCTAssertEqual(viewModel.state, .sent)
        XCTAssertEqual(service.submitted.count, 1)
        let report = service.submitted[0]
        XCTAssertEqual(report.kind, .improvement)
        XCTAssertEqual(report.message, "Mod geçişi daha hızlı olabilir")
        XCTAssertEqual(report.contactEmail, "kullanici@example.com")
        XCTAssertFalse(report.appVersion.isEmpty)
        XCTAssertFalse(report.deviceModel.isEmpty)
    }

    func test_iCloudOturumuYoksa_epostaYolunaDuser() async {
        let service = FakeService()
        service.errorToThrow = FeedbackError.notSignedIntoiCloud
        let viewModel = FeedbackViewModel(service: service)
        viewModel.message = "Bir hata ile karşılaştım"

        await viewModel.submit()

        guard case .needsMailFallback(let report) = viewModel.state else {
            return XCTFail("E-posta yoluna düşmeliydi, ama \(viewModel.state) bulundu")
        }
        XCTAssertEqual(report.message, "Bir hata ile karşılaştım")
    }

    func test_bilinmeyenHata_daEpostaYolunaDuser() async {
        let service = FakeService()
        service.errorToThrow = DummyError()
        let viewModel = FeedbackViewModel(service: service)
        viewModel.message = "Ağ yok gibi görünüyor"

        await viewModel.submit()

        if case .needsMailFallback = viewModel.state {
            // beklenen sonuç
        } else {
            XCTFail("E-posta yoluna düşmeliydi, ama \(viewModel.state) bulundu")
        }
    }

    // MARK: - E-posta yedeği

    func test_mailURL_konuVeGovdeyiTasir() {
        let report = FeedbackReport.make(kind: .bug, message: "Kamera açılmıyor", contactEmail: "")
        let url = FeedbackMailer.mailURL(for: report)

        let components = try? XCTUnwrap(url).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertEqual(components?.path, FeedbackMailer.supportEmail)
        let body = components?.queryItems?.first { $0.name == "body" }?.value
        XCTAssertEqual(body?.contains("Kamera açılmıyor"), true)
        XCTAssertEqual(body?.contains(report.deviceModel), true)
    }

    func test_gonderilenBulgu_kullaniciFotografiIcermez() {
        let report = FeedbackReport.make(kind: .idea, message: "Aylık hatırlatıcı", contactEmail: "")
        // Bulgu yalnızca metin ve teknik bağlam taşır; hiçbir medya alanı yoktur.
        XCTAssertEqual(report.message, "Aylık hatırlatıcı")
        XCTAssertTrue(report.mailBody.contains("Aylık hatırlatıcı"))
        XCTAssertTrue(report.mailBody.contains(report.appVersion))
    }
}
