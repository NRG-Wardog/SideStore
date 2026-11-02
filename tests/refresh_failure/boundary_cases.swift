// Concrete finite native inputs traverse the maintained wrapper and AppManager
// mapper before the end-to-end fixture persists their refresh manifest.
func refreshBoundaryFixtureCases() -> [(name: String, error: Error, expectedStep: CombinedFailure.SourceStep)] {
    let app = InstalledApp(bundleIdentifier: "com.fixture.refresh", name: "Fixture App")
    let native = OperationError.invalidParameters("SECRET_PROVIDER_PAYLOAD_AND_PATH")
    return V3RefreshFailureBoundary.allCases.map { boundary in
        let marked = boundary.preserving(native)
        let outer = lcStructuredSigningFailure(marked, stage: "command", sourceStep: "refreshApplication")
        let mapped = getMappedError(for: .refresh(app), error: outer)
        return (name: "source_" + boundary.rawValue, error: mapped, expectedStep: boundary.sourceStep)
    }
}

// Exposed to composed SS-to-LC wire fixtures. These are actual typed errors,
// never guessed NSError domains/codes or hand-authored failure dictionaries.
func preservationPostDispatchFixtureCases() -> [(name: String, error: Error, expectedStep: CombinedFailure.SourceStep)] {
    let app = InstalledApp(bundleIdentifier: "com.fixture.preservation", name: "Fixture App")
    let cases: [(String, V3PreservationPostDispatchFailure)] = [
        ("preservation-postdispatch-unavailable", .verificationUnavailable),
        ("preservation-postdispatch-mismatch", .verificationMismatch)]
    return cases.map { name, error in
        let facts = lcRefreshFailureFacts(error, sourceStep: "refreshApplication")
        precondition(facts["local_precondition"] == nil)
        let marked = lcStructuredSigningFailure(error, stage: "command", sourceStep: "refreshApplication", facts: facts)
        let mapped = getMappedError(for: .refresh(app), error: marked)
        return (name: name, error: mapped, expectedStep: .refreshApplication)
    }
}
