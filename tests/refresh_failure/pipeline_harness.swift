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

