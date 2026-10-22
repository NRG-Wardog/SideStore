// Framework/model shells do not perform any auth, device, or database work.
// Boundary mapping, annotation, AppOperation routing, AppManager mapping,
// NSError title wrapping, capture, and plist decode are production declarations.
import Foundation

protocol AppProtocol { var name: String { get } }
class FixtureManagedObjectContext {
    func performAndWait(_ operation: () -> Void) { operation() }
}
class NSManagedObject { var managedObjectContext: FixtureManagedObjectContext? = FixtureManagedObjectContext() }
final class InstalledApp: NSManagedObject, AppProtocol {
    let name: String
    let bundleIdentifier: String
    let refreshedDate = Date(timeIntervalSince1970: 1)
    let expirationDate = Date(timeIntervalSince1970: 2)
    init(bundleIdentifier: String = "com.fixture.refresh", name: String = "Fixture App") {
        self.bundleIdentifier = bundleIdentifier; self.name = name
    }
}
enum AlternateIconMode { case preserve }
protocol ALTLocalizedError: Error { var errorTitle: String? { get set } }
let ALTLocalizedTitleErrorKey = "ALTLocalizedTitle"
#if os(Linux)
let NSMultipleUnderlyingErrorsKey = "NSMultipleUnderlyingErrorsKey"
#endif
enum MinimuxerError: Error { case invalidPairing(Int, String) }
struct MinimuxerServiceError: Error { let error: Error }

enum DeveloperPortalError: Error {
    case maximumAppIDLimitReached, provisioningProfileDoesNotExist, certificateDoesNotExist
}
enum ServerError: Error {
    case underlyingError(code: Int, message: String)
    case badServerResponse, invalidResponseFormat, missingKey
}


// This older boundary fixture never emits a provider response. Keep the SDK
// observation interface inert here; the portal JSON-to-IPC fixture executes the
// exact SideSign observer, parser and finite-code filter with a fake dispatcher.
enum SideSignPortalDiagnostics {
    @TaskLocal static var responseObserver: (@Sendable (Int?, String?) -> Void)? = nil
    @TaskLocal static var resultCodeObserver: (@Sendable (Int) -> Void)? = nil
    static func safeProviderCode(_ value: String?) -> String? {
        precondition(value == nil, "Boundary-only fixture must not fabricate provider evidence")
        return nil
    }
}
