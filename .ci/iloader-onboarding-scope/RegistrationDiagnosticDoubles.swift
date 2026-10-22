import Foundation
// Onboarding fixture only. Wire fixture uses the actual account wrapper/mapper.
struct V3AccountOperationError: Error { let underlying: Error }
struct V3AuthenticationPhaseError: Error { let underlying: Error }
struct V3AnisetteAttemptError: Error { let underlying: Error }
enum CombinedFailure {
    static func isURLCancellation(domain: String, code: Int) -> Bool {
        domain == NSURLErrorDomain && code == NSURLErrorCancelled
    }
}
