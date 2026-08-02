import Foundation
import Observation

@MainActor
@Observable
final class FeedbackViewModel {

    enum State: Equatable {
        case editing
        case sending
        case sent
        /// CloudKit'e ulaşılamadı; kullanıcıya e-posta ile gönderme seçeneği sunulur.
        case needsMailFallback(FeedbackReport)
        case failed(String)
    }

    var kind: FeedbackKind = .bug
    var message: String = ""
    var contactEmail: String = ""
    private(set) var state: State = .editing

    private let service: FeedbackSubmitting

    init(service: FeedbackSubmitting = CloudKitFeedbackService()) {
        self.service = service
    }

    var canSubmit: Bool {
        FeedbackReport.isValid(message: message) && state != .sending
    }

    var remainingCharacters: Int {
        max(0, FeedbackReport.minimumMessageLength - message.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }

    func submit() async {
        guard canSubmit else { return }
        let report = FeedbackReport.make(kind: kind, message: message, contactEmail: contactEmail)
        state = .sending
        do {
            try await service.submit(report)
            state = .sent
        } catch FeedbackError.notSignedIntoiCloud, FeedbackError.unavailable {
            state = .needsMailFallback(report)
        } catch {
            state = .needsMailFallback(report)
        }
    }

    func resetToEditing() {
        state = .editing
    }
}
