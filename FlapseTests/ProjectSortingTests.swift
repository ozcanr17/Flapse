import XCTest
import SwiftData
@testable import Flapse   // ← kendi hedef (target) adınla değiştir

/// Detay ekranı çekimleri sortedEntries sırasıyla gösterdiği için, bu sıralamanın
/// gerçekten kronolojik olduğunu (eklenme sırasından bağımsız) doğruluyoruz.
@MainActor
final class ProjectSortingTests: XCTestCase {

    private let container = AppModelContainer.makeInMemory()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func test_sortedEntries_eskidenYeniyeSiralanir() throws {
        let context = container.mainContext
        let project = Project(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        context.insert(project)

        // Bilerek KARIŞIK sırada ekliyoruz: 10 Haziran, 5 Haziran, 20 Haziran.
        let tarihler = [date(2026, 6, 10), date(2026, 6, 5), date(2026, 6, 20)]
        for t in tarihler {
            let entry = Entry(capturedAt: t)
            entry.project = project
            context.insert(entry)
        }
        try context.save()

        let sirali = project.sortedEntries.map(\.capturedAt)

        XCTAssertEqual(sirali, [date(2026, 6, 5), date(2026, 6, 10), date(2026, 6, 20)])
    }

    func testAllProjectsOrdersByLatestCaptureActivity() throws {
        let context = container.mainContext
        let olderProject = Project(
            title: "Older project",
            createdAt: date(2026, 6, 1)
        )
        let newerProject = Project(
            title: "Newer project",
            createdAt: date(2026, 6, 10)
        )
        context.insert(olderProject)
        context.insert(newerProject)

        let latestEntry = Entry(capturedAt: date(2026, 6, 20))
        latestEntry.project = olderProject
        context.insert(latestEntry)
        try context.save()

        let projects = try ProjectRepository(context: context).allProjects()

        XCTAssertEqual(projects.map(\.id), [olderProject.id, newerProject.id])
    }

    func testLastActivityDateFallsBackToCreationDate() {
        let creationDate = date(2026, 6, 10)
        let project = Project(title: "New project", createdAt: creationDate)

        XCTAssertEqual(project.lastActivityDate, creationDate)
    }
}
