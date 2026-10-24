import Foundation

enum DeveloperPortalError: Error {
    case incorrectCredentials
    case appSpecificPasswordRequired
    case incorrectVerificationCode
    case tooManyAttempts
    case invalidAnisetteData
    case accountRepairRequired
    case userCancelled
}

enum ServerError: Error {
    case badServerResponse(reason: String, jsonPayload: String)
    case invalidResponseFormat(rawPayload: String)
    case missingKey(key: String, jsonPayload: String)
    case underlyingError(code: Int, message: String)
}

enum SideSign {
    enum Archive {
        enum Error: Swift.Error {
            case fileNotFound(URL), corruptArchive(URL), readFailed(URL), writeFailed(URL), missingAppBundle(URL)
        }
    }
    enum AnisetteError: Error {
        case noServersConfigured
        case allServersFailed
        case badServerResponse(statusCode: Int, payload: String)
    }
}

enum AnisetteKit {
    enum AnisetteError: Error {
        case invalidArgument, loaderFailed(reason: String), symbolMissing(name: String), readFailure
        case invalidResponse(reason: String), adiError(code: Int32, description: String)
        case librariesNotFound(reason: String), httpError(statusCode: Int, message: String)
    }
}

