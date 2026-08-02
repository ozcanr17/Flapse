import XCTest
@testable import Flapse   // ← kendi hedef (target) adınla değiştir

/// CaptureCadence'in saf (pure) mantığını test ediyoruz. Bu kod SwiftData'ya veya
/// herhangi bir Apple framework'üne bağlı olmadığı için testler hızlı ve güvenilir çalışır.
final class CaptureCadenceTests: XCTestCase {

    // Deterministik testler için sabit, UTC tabanlı bir takvim kullanıyoruz.
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func test_hicCekimYoksa_zamanGelmistir() {
        XCTAssertTrue(
            CaptureCadence.daily.isCaptureDue(lastCapture: nil, now: date(2026, 6, 29), calendar: calendar)
        )
    }

    func test_gunluk_ayniGun_henuzGelmedi() {
        let last = date(2026, 6, 29)
        let now  = date(2026, 6, 29)
        XCTAssertFalse(
            CaptureCadence.daily.isCaptureDue(lastCapture: last, now: now, calendar: calendar)
        )
    }

    func test_gunluk_ertesiGun_geldi() {
        let last = date(2026, 6, 29)
        let now  = date(2026, 6, 30)
        XCTAssertTrue(
            CaptureCadence.daily.isCaptureDue(lastCapture: last, now: now, calendar: calendar)
        )
    }

    func test_haftalik_3gunSonra_henuzGelmedi() {
        let last = date(2026, 6, 1)
        let now  = date(2026, 6, 4)
        XCTAssertFalse(
            CaptureCadence.weekly.isCaptureDue(lastCapture: last, now: now, calendar: calendar)
        )
    }

    func test_haftalik_7gunSonra_geldi() {
        let last = date(2026, 6, 1)
        let now  = date(2026, 6, 8)
        XCTAssertTrue(
            CaptureCadence.weekly.isCaptureDue(lastCapture: last, now: now, calendar: calendar)
        )
    }

    func test_aylik_20gunSonra_henuzGelmedi() {
        let last = date(2026, 6, 1)
        let now  = date(2026, 6, 21)
        XCTAssertFalse(
            CaptureCadence.monthly.isCaptureDue(lastCapture: last, now: now, calendar: calendar)
        )
    }

    func test_aylik_takvimAyiTamamlaninca_geldi() {
        let last = date(2026, 6, 1)
        let now  = date(2026, 7, 1)
        XCTAssertTrue(
            CaptureCadence.monthly.isCaptureDue(lastCapture: last, now: now, calendar: calendar)
        )
    }

    func test_aylik_subatGibiKisaAydaDaDogruHesaplar() {
        // 31 Ocak + 1 ay = takvim kuralına göre 28 Şubat (2026 artık yıl değil).
        let last = date(2026, 1, 31)
        XCTAssertEqual(
            CaptureCadence.monthly.nextDueDate(after: last, calendar: calendar),
            date(2026, 2, 28)
        )
    }
}
