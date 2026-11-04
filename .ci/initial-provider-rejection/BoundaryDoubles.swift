// Only unrelated framework/error categorization boundaries are doubled.
// The source-owned marker, authentication, wrapping, retry mapper and sequence are real.
enum CombinedFailure {
    enum SourceStep { case appleAuthentication }
    static func isURLCancellation(domain: String, code: Int) -> Bool { domain == NSURLErrorDomain && code == NSURLErrorCancelled }
}
struct V3AnisetteAttemptContext: Sendable {}
struct V3AccountOperationError: Error { let underlying: Error }
enum AnisetteKit { enum AnisetteError: Error { case adiError(Int) } }
enum SideSign { enum AnisetteError: Error { case noServersConfigured } }
enum FixtureAuthKind { case anisette, network, unknown }
func v3ClassifyAuthError(_ error: Error) -> FixtureAuthKind? {
    let error = v3AccountUnderlyingError(error)
    if (error as NSError).domain == NSURLErrorDomain { return .network }
    if error is ILoaderRemoteError || error is AnisetteKit.AnisetteError || error is SideSign.AnisetteError { return .anisette }
    return .unknown
}
