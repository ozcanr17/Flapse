import Foundation

struct PhotoImportItem: Equatable {
    let assetIdentifier: String
    let creationDate: Date?
    let selectionIndex: Int
}

struct ResolvedImport: Equatable {
    let assetIdentifier: String
    let date: Date
}

enum PhotoImportPlan {

    static func resolvedOrder(
        _ items: [PhotoImportItem],
        now: Date = Date(),
        fallbackInterval: TimeInterval = 86_400
    ) -> [ResolvedImport] {
        guard !items.isEmpty else { return [] }

        let ordered = items.sorted { $0.selectionIndex < $1.selectionIndex }
        var dates = [Date?](repeating: nil, count: ordered.count)
        for (index, item) in ordered.enumerated() {
            dates[index] = item.creationDate
        }

        let datedIndices = dates.indices.filter { dates[$0] != nil }

        if datedIndices.isEmpty {
            let last = ordered.count - 1
            for index in ordered.indices {
                dates[index] = now.addingTimeInterval(-Double(last - index) * fallbackInterval)
            }
            return zip(ordered, dates).compactMap { item, date in
                date.map { ResolvedImport(assetIdentifier: item.assetIdentifier, date: $0) }
            }
        }

        if let first = datedIndices.first, first > 0, let anchor = dates[first] {
            for index in 0..<first {
                dates[index] = anchor.addingTimeInterval(-Double(first - index) * fallbackInterval)
            }
        }

        if let last = datedIndices.last, last < ordered.count - 1, let anchor = dates[last] {
            for index in (last + 1)..<ordered.count {
                dates[index] = anchor.addingTimeInterval(Double(index - last) * fallbackInterval)
            }
        }

        for pair in zip(datedIndices, datedIndices.dropFirst()) {
            let (start, end) = pair
            let gap = end - start
            guard gap > 1 else { continue }
            guard let startDate = dates[start], let endDate = dates[end] else { continue }
            let step = (endDate.timeIntervalSince(startDate)) / Double(gap)
            for offset in 1..<gap {
                dates[start + offset] = startDate.addingTimeInterval(step * Double(offset))
            }
        }

        return zip(ordered, dates)
            .compactMap { item, date in
                date.map { ResolvedImport(assetIdentifier: item.assetIdentifier, date: $0) }
            }
            .sorted { $0.date < $1.date }
    }
}
