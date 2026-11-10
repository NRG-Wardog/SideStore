// Only SDK/error annotation edges are doubled. The actual request observer and
// wrapper are extracted from PipelineExecutor.swift by generate_fixture.py.
enum DeveloperPortalError: Error { case maximumAppIDLimitReached }
enum ServerError: Error { case rejected }
enum SideSignPortalDiagnostics {
    @TaskLocal static var responseObserver: (@Sendable (Int?, String?) -> Void)? = nil
    @TaskLocal static var resultCodeObserver: (@Sendable (Int) -> Void)? = nil
    static func safeProviderCode(_ value: String?) -> String? { nil }
}
func lcStructuredSigningFailure(_ error: Error, stage: String, sourceStep: String?,
                                facts: [String: String], portalResponse: Bool) -> NSError {
    fatalError("Typed App-ID lookup error must not be annotated as a generic portal failure")
}
