import Foundation

struct ProjectSignatureSet: Equatable {
    let projectID: UUID
    let kind: SubjectKind
    let vectors: [[Float]]
}

struct ProjectMatch: Equatable {
    let projectID: UUID
    let distance: Float
}

enum ProjectMatcher {

    static let autoAssignDistance: Float = 0.65
    static let suggestDistance: Float = 0.95
    static let ambiguityMargin: Float = 0.08

    enum Decision: Equatable {
        case autoAssign(UUID)
        case suggest(UUID)
        case chooseManually
    }

    static func score(for signature: SubjectSignature, in set: ProjectSignatureSet) -> Float? {
        guard kindCompatible(signature.kind, set.kind), !set.vectors.isEmpty else { return nil }
        let distances = set.vectors
            .map { FeatureVector.distance(signature.vector, $0) }
            .sorted()
        let k = min(3, distances.count)
        return distances.prefix(k).reduce(0, +) / Float(k)
    }

    static func nearest(for signature: SubjectSignature, among sets: [ProjectSignatureSet]) -> ProjectMatch? {
        guard !signature.isEmpty else { return nil }
        var best: ProjectMatch?
        for set in sets {
            guard let score = score(for: signature, in: set) else { continue }
            if best.map({ score < $0.distance }) ?? true {
                best = ProjectMatch(projectID: set.projectID, distance: score)
            }
        }
        return best
    }

    static func decide(for signature: SubjectSignature, among sets: [ProjectSignatureSet]) -> Decision {
        guard let match = nearest(for: signature, among: sets) else { return .chooseManually }
        if match.distance <= autoAssignDistance,
           signature.kind != .unknown,
           isUnambiguous(match, for: signature, among: sets) {
            return .autoAssign(match.projectID)
        }
        if match.distance <= suggestDistance { return .suggest(match.projectID) }
        return .chooseManually
    }

    static func isUnambiguous(_ match: ProjectMatch, for signature: SubjectSignature, among sets: [ProjectSignatureSet]) -> Bool {
        let runnerUp = sets
            .filter { $0.projectID != match.projectID }
            .compactMap { score(for: signature, in: $0) }
            .min()
        guard let runnerUp else { return true }
        return runnerUp - match.distance >= ambiguityMargin
    }

    static func kindCompatible(_ a: SubjectKind, _ b: SubjectKind) -> Bool {
        if a == .unknown || b == .unknown { return true }
        return a == b
    }
}
