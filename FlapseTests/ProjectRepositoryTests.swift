import XCTest
import SwiftData
@testable import Flapse   // ← kendi hedef (target) adınla değiştir

/// ProjectRepository'yi GERÇEK SwiftData ile, ama bellek içi (disksiz, Cloud'suz) bir
/// container üzerinde test ediyoruz. Böylece testler hem hızlı hem birbirinden tamamen
/// izole; biri ötekinin verisini görmez.
///
/// `@MainActor`: repository ana aktöre bağlı olduğu için test sınıfı da öyle olmalı.
@MainActor
final class ProjectRepositoryTests: XCTestCase {

    private let container = AppModelContainer.makeInMemory()
    private lazy var repository = ProjectRepository(context: container.mainContext)

    func test_olusturulanProje_listedeGorunur() throws {
        _ = try repository.createProject(title: "Sakal", category: .hairAndBeard, cadence: .daily)

        let projects = try repository.allProjects()

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.title, "Sakal")
        XCTAssertEqual(projects.first?.category, .hairAndBeard)
    }

    func test_cekimEklenince_projeyeBaglanir() throws {
        let project = try repository.createProject(title: "Limon fidanı", category: .plant, cadence: .weekly)

        try repository.addEntry(Entry(), to: project)
        try repository.addEntry(Entry(), to: project)

        // İlişki iki yönlü kuruldu mu?
        XCTAssertEqual(project.entries?.count, 2)
        XCTAssertEqual(project.sortedEntries.first?.project?.id, project.id)
    }

    func test_fotografDegistirilince_yeniVeriYazilir_kareSayisiDegismez() throws {
        let project = try repository.createProject(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        let entry = Entry(imageData: Data([0x01]))
        try repository.addEntry(entry, to: project)

        try repository.replaceImage(for: entry, with: Data([0x02]))

        XCTAssertEqual(entry.imageData, Data([0x02]))
        XCTAssertEqual(entry.imageRevision, 1)
        XCTAssertNotNil(entry.sharedUpdatedAt)
        XCTAssertEqual(entry.sharedImageUpdatedAt, entry.sharedUpdatedAt)
        let entryCount = try container.mainContext.fetchCount(FetchDescriptor<Entry>())
        XCTAssertEqual(entryCount, 1)
    }

    func test_projeDuzenlenince_paylasimDegisiklikZamaniGuncellenir() throws {
        let project = try repository.createProject(title: "Sakal", category: .hairAndBeard, cadence: .daily)

        try repository.updateProject(project, title: "Yeni Başlık", category: .person, cadence: .weekly)

        XCTAssertEqual(project.title, "Yeni Başlık")
        XCTAssertEqual(project.category, .person)
        XCTAssertEqual(project.cadence, .weekly)
        XCTAssertNotNil(project.sharedUpdatedAt)
    }

    func test_projeGizlenipYenidenGosterilebilir() throws {
        let project = try repository.createProject(title: "Gizli", category: .person, cadence: .daily)

        try repository.setHidden(true, for: project)
        XCTAssertTrue(project.isHidden)

        try repository.setHidden(false, for: project)
        XCTAssertFalse(project.isHidden)
    }

    func test_kaydedilenTimelapseGizlenipYenidenGosterilebilir() throws {
        let item = SavedTimelapse(title: "Video", fileName: "video.mp4", duration: 3, posterData: nil)
        container.mainContext.insert(item)
        try container.mainContext.save()

        TimelapseLibrary.setHidden(true, for: item, context: container.mainContext)
        XCTAssertTrue(item.isHidden)

        TimelapseLibrary.setHidden(false, for: item, context: container.mainContext)
        XCTAssertFalse(item.isHidden)
    }

    func test_cekimTarihiDegisince_zamanCizelgesiYenidenSiralanir() throws {
        let project = try repository.createProject(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        let first = Entry(capturedAt: Date(timeIntervalSince1970: 200))
        let second = Entry(capturedAt: Date(timeIntervalSince1970: 300))
        try repository.addEntries([first, second], to: project)

        try repository.updateCapturedAt(for: second, to: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(project.sortedEntries.map(\.id), [second.id, first.id])
    }

    func test_topluTarihDegisikligi_gunuDegistiripSaatleriKorur() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = Entry(capturedAt: calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 9, minute: 15))!)
        let second = Entry(capturedAt: calendar.date(from: DateComponents(year: 2026, month: 1, day: 3, hour: 18, minute: 45))!)
        let target = calendar.date(from: DateComponents(year: 2026, month: 7, day: 19, hour: 12))!

        try repository.updateCapturedAt(for: [first, second], to: target, preservingTime: true, calendar: calendar)

        let firstComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: first.capturedAt)
        let secondComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: second.capturedAt)
        XCTAssertEqual(firstComponents, DateComponents(year: 2026, month: 7, day: 19, hour: 9, minute: 15))
        XCTAssertEqual(secondComponents, DateComponents(year: 2026, month: 7, day: 19, hour: 18, minute: 45))
    }

    func test_topluKonumDegisikligi_tumSecimeUygulanirVeKaldirilir() throws {
        let first = Entry()
        let second = Entry()

        try repository.updateLocation(
            for: [first, second],
            latitude: 41.0082,
            longitude: 28.9784,
            placeName: "İstanbul"
        )

        XCTAssertEqual(first.latitude, 41.0082)
        XCTAssertEqual(second.longitude, 28.9784)
        XCTAssertEqual(first.placeName, "İstanbul")

        try repository.updateLocation(for: [first, second], latitude: nil, longitude: nil, placeName: nil)

        XCTAssertNil(first.latitude)
        XCTAssertNil(second.longitude)
        XCTAssertNil(first.placeName)
    }

    func test_cekimSilinince_sonSilinenlereTasinir() throws {
        let project = try repository.createProject(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        let entry = Entry()
        try repository.addEntry(entry, to: project)

        try repository.deleteEntry(entry)

        XCTAssertTrue(project.sortedEntries.isEmpty)
        XCTAssertNotNil(entry.deletedAt)
        XCTAssertNotNil(entry.sharedUpdatedAt)
        let remainingEntries = try container.mainContext.fetchCount(FetchDescriptor<Entry>())
        XCTAssertEqual(remainingEntries, 1)
    }

    func test_silinenCekim_geriAlinir() throws {
        let project = try repository.createProject(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        let entry = Entry()
        try repository.addEntry(entry, to: project)
        try repository.deleteEntry(entry)

        try repository.restoreEntry(entry)

        XCTAssertNil(entry.deletedAt)
        XCTAssertEqual(project.sortedEntries.map(\.id), [entry.id])
    }

    func test_silinenCekim_kaliciSilinir() throws {
        let project = try repository.createProject(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        let entry = Entry()
        try repository.addEntry(entry, to: project)
        try repository.deleteEntry(entry)

        try repository.permanentlyDeleteEntry(entry)

        let remainingEntries = try container.mainContext.fetchCount(FetchDescriptor<Entry>())
        XCTAssertEqual(remainingEntries, 0)
    }

    func test_ortakProjedeKaliciSilinenCekim_yenidenEsitlenmez() throws {
        let project = try repository.createProject(title: "Biz", category: .person, cadence: .daily)
        project.isCollaborative = true
        let entry = Entry()
        try repository.addEntry(entry, to: project)

        try repository.permanentlyDeleteEntry(entry)

        XCTAssertTrue(project.cloudPurgedEntryIDs.contains(entry.id))
        XCTAssertNotNil(project.sharedUpdatedAt)
    }

    func test_ayniKimlikliCekimler_acilistaTekillestirilir() throws {
        let project = try repository.createProject(title: "Biz", category: .person, cadence: .daily)
        let id = UUID()
        let older = Entry(id: id, capturedAt: Date(timeIntervalSince1970: 100), imageData: Data([0x01]))
        let newer = Entry(id: id, capturedAt: Date(timeIntervalSince1970: 200), imageData: Data([0x02]))
        try repository.addEntries([older, newer], to: project)
        older.sharedUpdatedAt = Date(timeIntervalSince1970: 100)
        newer.sharedUpdatedAt = Date(timeIntervalSince1970: 200)
        try repository.saveIfNeeded()

        try repository.repairDuplicateEntryIDs()

        let remaining = try container.mainContext.fetch(FetchDescriptor<Entry>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.imageData, Data([0x02]))
    }

    func test_birdenFazlaSilinenCekim_birlikteKaliciSilinir() throws {
        let project = try repository.createProject(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        let first = Entry()
        let second = Entry()
        try repository.addEntries([first, second], to: project)
        try repository.deleteEntry(first)
        try repository.deleteEntry(second)

        try repository.permanentlyDeleteEntries([first, second])

        let remainingEntries = try container.mainContext.fetchCount(FetchDescriptor<Entry>())
        XCTAssertEqual(remainingEntries, 0)
    }

    func test_suresiDolanSilinmisCekim_temizlenir() throws {
        let project = try repository.createProject(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        let entry = Entry()
        try repository.addEntry(entry, to: project)
        try repository.deleteEntry(entry)
        entry.deletedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try repository.saveIfNeeded()

        try repository.purgeExpiredEntries(
            retentionDays: 30,
            now: Date(timeIntervalSince1970: 1_700_000_000 + 31 * 86_400)
        )

        let remainingEntries = try container.mainContext.fetchCount(FetchDescriptor<Entry>())
        XCTAssertEqual(remainingEntries, 0)
    }

    func test_projeSilinince_cekimleriDeSilinir() throws {
        let project = try repository.createProject(title: "Saç", category: .hairAndBeard, cadence: .daily)
        try repository.addEntry(Entry(), to: project)

        try repository.deleteProject(project)
        try repository.saveIfNeeded()

        // Proje gitti mi?
        XCTAssertTrue(try repository.allProjects().isEmpty)
        // .cascade gerçekten çalıştı mı? Hiç Entry kalmamalı.
        let remainingEntries = try container.mainContext.fetchCount(FetchDescriptor<Entry>())
        XCTAssertEqual(remainingEntries, 0)
    }

    func test_videoCekimiKaliciSilinince_dosyaDaSilinir() throws {
        let project = try repository.createProject(title: "Video", category: .video, cadence: .daily)
        let fileName = VideoEntryStorage.fileName(for: UUID())
        let fileURL = VideoEntryStorage.directory.appendingPathComponent(fileName)
        try Data([0x01]).write(to: fileURL)
        let entry = Entry(videoFileName: fileName)
        try repository.addEntry(entry, to: project)

        try repository.permanentlyDeleteEntry(entry)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
