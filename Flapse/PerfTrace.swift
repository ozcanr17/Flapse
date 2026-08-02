import Foundation
import os

/// Uygulamanın herhangi bir bölümünü ölçmek için genel amaçlı iz kaydı.
///
/// `CameraLaunchTrace` kamera açılışına özeldi ve darboğazı tek adıma indirmemizi
/// sağladı; bu ise aynı yöntemi diğer akışlara (sekme geçişleri, proje açma, dışa
/// aktarma sayfası…) taşır. Aynı anda birden çok akış ölçülebilsin diye izler ada
/// göre ayrı tutulur.
///
/// Okumak için Xcode konsolunda **`PERFTRACE`** ile filtrele, ya da:
/// `log stream --predicate 'subsystem == "rozcan.Flapse" AND category == "perf"'`
enum PerfTrace {

    private static let log = Logger(subsystem: "rozcan.Flapse", category: "perf")
    private static let signposter = OSSignposter(subsystem: "rozcan.Flapse", category: "perf")

    private struct Entry {
        let startedAt: CFAbsoluteTime
        var lastAt: CFAbsoluteTime
        let state: OSSignpostIntervalState
    }

    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    private static let lock = NSLock()

    static func begin(_ name: String, detail: String = "") {
        let now = CFAbsoluteTimeGetCurrent()
        let state = signposter.beginInterval("perf", id: signposter.makeSignpostID())
        lock.lock()
        entries[name] = Entry(startedAt: now, lastAt: now, state: state)
        lock.unlock()
        let suffix = detail.isEmpty ? "" : " (\(detail))"
        log.notice("PERFTRACE [\(name, privacy: .public)] ── begin\(suffix, privacy: .public)")
    }

    static func mark(_ name: String, _ label: String) {
        lock.lock()
        guard var entry = entries[name] else { lock.unlock(); return }
        let now = CFAbsoluteTimeGetCurrent()
        let total = (now - entry.startedAt) * 1000
        let delta = (now - entry.lastAt) * 1000
        entry.lastAt = now
        entries[name] = entry
        lock.unlock()
        log.notice("PERFTRACE [\(name, privacy: .public)] \(label, privacy: .public): +\(delta, format: .fixed(precision: 1))ms (toplam \(total, format: .fixed(precision: 1))ms)")
    }

    static func end(_ name: String, _ label: String = "end") {
        mark(name, label)
        lock.lock()
        let entry = entries.removeValue(forKey: name)
        lock.unlock()
        if let entry {
            signposter.endInterval("perf", entry.state)
        }
    }

    /// Tek seferlik bir bloğun süresini ölçer.
    @discardableResult
    static func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            log.notice("PERFTRACE [\(name, privacy: .public)] \(ms, format: .fixed(precision: 1))ms")
        }
        return try work()
    }
}
