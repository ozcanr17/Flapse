import SwiftUI
import SwiftData
import UIKit

private struct HomeMetrics {
    let latestEntryByProjectID: [UUID: Entry]
    let entryCountByProjectID: [UUID: Int]
    let longestStreak: Int
    let weekCount: Int
    let recentEntries: [Entry]
    let activityEntries: [Entry]

    init(entries: [Entry], now: Date = .now, calendar: Calendar = .current) {
        let weekCutoff = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let activityCutoff = calendar.date(byAdding: .day, value: -(15 * 7), to: now) ?? now
        var latest: [UUID: Entry] = [:]
        var datesByProject: [UUID: [Date]] = [:]
        var weekCount = 0
        var activityEntries: [Entry] = []
        activityEntries.reserveCapacity(min(entries.count, 256))

        // Query en yeniden eskiye sıralı. Tek geçişle ana ekranın bütün sayısal
        // özetlerini çıkarırız; ayrı ayrı group/filter/max taramaları yapmayız.
        for entry in entries {
            guard let projectID = entry.project?.id else { continue }
            if latest[projectID] == nil { latest[projectID] = entry }
            datesByProject[projectID, default: []].append(entry.capturedAt)
            if entry.capturedAt >= weekCutoff { weekCount += 1 }
            if entry.capturedAt >= activityCutoff { activityEntries.append(entry) }
        }

        self.latestEntryByProjectID = latest
        self.entryCountByProjectID = datesByProject.mapValues(\.count)
        self.longestStreak = datesByProject.values
            .lazy
            .map { ActivitySummary.streak(capturedDates: $0) }
            .max() ?? 0
        self.weekCount = weekCount
        self.recentEntries = Array(entries.prefix(10))
        self.activityEntries = activityEntries
    }
}

struct HomeView: View {

    let isActive: Bool
    let onCapture: (Project) -> Void
    let onCreateProject: () -> Void

    init(
        isActive: Bool = true,
        onCapture: @escaping (Project) -> Void = { _ in },
        onCreateProject: @escaping () -> Void = {}
    ) {
        self.isActive = isActive
        self.onCapture = onCapture
        self.onCreateProject = onCreateProject
    }

    @Query(filter: #Predicate<Project> { $0.deletedAt == nil }, sort: \Project.createdAt, order: .reverse)
    private var projects: [Project]
    @Query(
        filter: #Predicate<Entry> {
            $0.deletedAt == nil && $0.project?.deletedAt == nil && $0.project?.isHidden == false
        },
        sort: \Entry.capturedAt,
        order: .reverse
    ) private var liveEntries: [Entry]
    @Environment(\.theme) private var theme

    private var liveProjects: [Project] {
        projects.filter { !$0.isDeleted && $0.deletedAt == nil && !$0.isHidden }
    }

    private var dailyTip: LocalizedStringKey {
        Calendar.current.component(.day, from: Date()).isMultiple(of: 2)
            ? "Her gün aynı ışıkta çekersen geçişler daha pürüzsüz olur."
            : "Akıllı hizalama özneyi her karede aynı yerde tutar."
    }

    private var greeting: LocalizedStringKey {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  "Günaydın"
        case 12..<18: "İyi günler"
        case 18..<23: "İyi akşamlar"
        default:      "İyi geceler"
        }
    }

    var body: some View {
        let live = liveProjects
        let metrics = HomeMetrics(entries: liveEntries)
        let due = live.filter {
            $0.cadence.isCaptureDue(lastCapture: metrics.latestEntryByProjectID[$0.id]?.capturedAt)
        }
        return ZStack {
            theme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if live.isEmpty {
                        emptyState
                    } else {
                        if let firstDueProject = due.first {
                            DailyCaptureCard(
                                project: firstDueProject,
                                latestEntry: metrics.latestEntryByProjectID[firstDueProject.id]
                            ) {
                                onCapture(firstDueProject)
                            }
                        }
                        ActivityHeroCard(
                            totalCaptures: liveEntries.count,
                            dueCount: due.count,
                            entries: metrics.activityEntries,
                            isActive: isActive
                        )
                        if due.count > 1 {
                            dueSection(
                                due,
                                latestEntries: metrics.latestEntryByProjectID,
                                entryCounts: metrics.entryCountByProjectID
                            )
                        }
                        statsGrid(liveProjectCount: live.count, metrics: metrics)
                        tipCard
                        if !metrics.recentEntries.isEmpty {
                            recentSection(metrics.recentEntries)
                        }
                    }
                }
                .padding(20)
            }
        }
        .overlay(alignment: .top) { ScrollEdgeFade(height: 72) }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.largeTitle.bold())
                .foregroundStyle(theme.ink)
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.currentLocale)))
                .font(.subheadline)
                .foregroundStyle(theme.inkMuted)
        }
    }

    private func statsGrid(liveProjectCount: Int, metrics: HomeMetrics) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            StatTile(icon: "square.grid.2x2", value: liveProjectCount, label: "Aktif proje")
            StatTile(icon: "photo.stack", value: liveEntries.count, label: "Toplam kare")
            StatTile(icon: "flame", value: metrics.longestStreak, label: "En uzun seri")
            StatTile(icon: "calendar", value: metrics.weekCount, label: "Bu hafta")
        }
    }

    private var tipCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb")
                .font(.headline)
                .foregroundStyle(theme.accent)
                .frame(width: 36, height: 36)
                .background(theme.accent.opacity(0.1), in: Circle())
            Text(dailyTip)
                .font(.subheadline)
                .foregroundStyle(theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .cardStyle()
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(theme.accent)
                .frame(width: 72, height: 72)
                .background(theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(spacing: 8) {
                Text("İlk hikayeni başlat")
                    .font(.title2.bold())
                    .foregroundStyle(theme.ink)
                Text("Günde bir kare çek; zamanla değişimin\nkendiliğinden bir timelapse'e dönüşsün.")
                    .font(.body)
                    .foregroundStyle(theme.inkMuted)
                    .multilineTextAlignment(.center)
            }

            Button("Yeni Proje", action: onCreateProject)
                .buttonStyle(.flapsePrimary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func dueSection(
        _ due: [Project],
        latestEntries: [UUID: Entry],
        entryCounts: [UUID: Int]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bugün çekim zamanı")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.inkMuted)
            ForEach(due.dropFirst()) { project in
                Button {
                    onCapture(project)
                } label: {
                    dueRow(
                        project,
                        latestEntry: latestEntries[project.id],
                        entryCount: entryCounts[project.id] ?? 0
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func dueRow(_ project: Project, latestEntry: Entry?, entryCount: Int) -> some View {
        HStack(spacing: 12) {
            DueRowThumb(project: project, latestEntry: latestEntry)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .font(Theme.headline(15))
                    .foregroundStyle(theme.ink)
                Text("\(entryCount) kare · \(project.cadence.displayName)")
                    .font(Theme.caption(12))
                    .foregroundStyle(theme.inkMuted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.inkMuted)
        }
        .padding(12)
        .liquidGlassStyle()
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func recentSection(_ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Son kareler")
                .font(Theme.caption(13))
                .foregroundStyle(theme.inkMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(entries) { entry in
                        RecentEntryThumb(entry: entry)
                    }
                }
            }
        }
    }
}

private struct StatTile: View {
    let icon: String
    let value: Int
    let label: LocalizedStringKey

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(theme.accent)
            Text("\(value)")
                .font(.title.bold())
                .monospacedDigit()
                .foregroundStyle(theme.ink)
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.inkMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .cardStyle()
    }
}

private struct DailyCaptureCard: View {
    let project: Project
    let latestEntry: Entry?
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var photo: UIImage?

    var body: some View {
        let last = latestEntry
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    if let photo {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Theme.accent(for: project.category).opacity(0.14)
                        Image(systemName: Theme.icon(for: project.category))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.accent(for: project.category))
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Bugün çekim zamanı")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.accent)
                    Text(project.title)
                        .font(.headline)
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(project.category.isVideoMode ? "Video çek" : "Kare çek")
                        .font(.subheadline)
                        .foregroundStyle(theme.inkMuted)
                }
                Spacer()
                Image(systemName: project.category.isVideoMode ? "video.fill" : "camera.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(theme.accent, in: Circle())
            }
            .padding(14)
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .cardStyle()
        .task(id: last?.imageCacheKey) {
            guard let last else { return }
            photo = await ImageDownsampler.cachedImage(key: "daily-\(last.imageCacheKey)", maxPixelSize: 240) { last.imageData }
        }
    }
}

private struct DueRowThumb: View {
    let project: Project
    let latestEntry: Entry?

    @State private var photo: UIImage?

    private var accent: Color { Theme.accent(for: project.category) }
    var body: some View {
        let last = latestEntry
        ZStack {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                accent.opacity(0.14)
                Image(systemName: Theme.icon(for: project.category))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(Circle())
        .task(id: last?.imageCacheKey) {
            guard let last else { return }
            photo = await ImageDownsampler.cachedImage(key: "due-\(last.imageCacheKey)", maxPixelSize: 150) { last.imageData }
        }
    }
}

private struct RecentEntryThumb: View {
    let entry: Entry

    @Environment(\.theme) private var theme
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: 84, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: entry.imageCacheKey) {
            image = await ImageDownsampler.cachedImage(key: "home-\(entry.imageCacheKey)", maxPixelSize: 300) { entry.imageData }
        }
    }
}

struct ActivityHeroCard: View {
    let totalCaptures: Int
    let dueCount: Int
    let entries: [Entry]
    let isActive: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("AKTİVİTE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.inkMuted)
                    .tracking(1.2)
                Spacer()
                (
                    Text("\(totalCaptures)")
                        .font(.title3.bold())
                        .monospacedDigit()
                        .foregroundStyle(theme.ink)
                    +
                    Text(" kare")
                        .font(.caption)
                        .foregroundStyle(theme.inkMuted)
                )
            }

            ContributionGrid(entries: entries, accent: theme.accent, isActive: isActive)

            if dueCount > 0 {
                Label("Bugün \(dueCount) projede çekim zamanı", systemImage: "bell.fill")
                    .font(Theme.caption(12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.accent, in: Capsule())
            } else {
                Label("Bugün için her şey tamam", systemImage: "checkmark.circle.fill")
                    .font(Theme.caption(12))
                    .foregroundStyle(theme.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct ContributionGrid: View {
    let entries: [Entry]
    let accent: Color
    let isActive: Bool

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnails: [Date: GridThumbnail] = [:]

    private let weeks = 15
    private let cell: CGFloat = 11
    private let gap: CGFloat = 3

    private struct GridThumbnail {
        let cacheKey: String
        let image: UIImage
    }

    private var countsByDay: [Date: Int] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let earliest = calendar.date(byAdding: .day, value: -(weeks * 7), to: today) ?? today
        var counts: [Date: Int] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.capturedAt)
            if day < earliest { break }
            if day <= today {
                counts[day, default: 0] += 1
            }
        }
        return counts
    }

    private var thumbnailRevisionKey: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let earliest = calendar.date(byAdding: .day, value: -(weeks * 7), to: today) ?? today
        var hasher = Hasher()
        hasher.combine(isActive)
        for entry in entries {
            if entry.capturedAt < earliest { break }
            hasher.combine(entry.id)
            hasher.combine(entry.imageRevision)
            hasher.combine(entry.capturedAt)
        }
        return hasher.finalize()
    }

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekdayIndex = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        let counts = countsByDay
        HStack(spacing: gap) {
            ForEach(0..<weeks, id: \.self) { column in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        let offset = (weeks - 1 - column) * 7 + (weekdayIndex - row)
                        square(offset: offset, today: today, calendar: calendar, counts: counts)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: thumbnailRevisionKey) {
            guard isActive else { return }
            await loadThumbnails()
        }
    }

    @ViewBuilder
    private func square(offset: Int, today: Date, calendar: Calendar, counts: [Date: Int]) -> some View {
        if offset < 0 {
            Color.clear.frame(width: cell, height: cell)
        } else {
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            if let thumbnail = thumbnails[date] {
                Image(uiImage: thumbnail.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cell, height: cell)
                    .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(fill(for: counts[date] ?? 0))
                    .frame(width: cell, height: cell)
            }
        }
    }

    private func fill(for count: Int) -> Color {
        switch count {
        case 0:  theme.inkMuted.opacity(0.12)
        case 1:  accent.opacity(0.4)
        case 2:  accent.opacity(0.7)
        default: accent
        }
    }

    private func loadThumbnails() async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let earliest = calendar.date(byAdding: .day, value: -(weeks * 7), to: today) else { return }

        var latestByDay: [Date: Entry] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.capturedAt)
            if day < earliest { break }
            guard day <= today else { continue }
            if let current = latestByDay[day], current.capturedAt >= entry.capturedAt { continue }
            latestByDay[day] = entry
        }

        let expectedKeys = latestByDay.mapValues(\.imageCacheKey)
        var next = thumbnails.filter { day, thumbnail in
            expectedKeys[day] == thumbnail.cacheKey
        }
        let targets = latestByDay.sorted { $0.key > $1.key }
        let pixelSize = max(44, ceil(cell * displayScale * 1.5))
        var pendingChanges = 0

        for (day, entry) in targets {
            guard !Task.isCancelled else { return }
            let cacheKey = entry.imageCacheKey
            guard next[day]?.cacheKey != cacheKey else { continue }
            guard let image = await ImageDownsampler.cachedImage(
                key: "grid-\(cacheKey)",
                maxPixelSize: pixelSize,
                priority: .utility,
                load: { entry.imageData }
            ) else { continue }
            guard !Task.isCancelled else { return }
            next[day] = GridThumbnail(cacheKey: cacheKey, image: image)
            pendingChanges += 1

            // Her karede body'yi yenilemek yerine küçük partiler halinde göster.
            if pendingChanges.isMultiple(of: 8) {
                thumbnails = next
                await Task.yield()
            }
        }

        guard !Task.isCancelled else { return }
        thumbnails = next
    }
}

#Preview {
    NavigationStack {
        HomeView()
    }
    .modelContainer(AppModelContainer.makeInMemory())
    .environment(StoreService())
}
