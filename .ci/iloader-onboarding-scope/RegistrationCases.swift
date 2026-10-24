import Foundation

func registrationFixtureCases() async throws -> [(name: String, error: Error, expected: [String])] {
    let team = ALTTeam(account: ALTAccount(appleID: "fixture@example.invalid"), route: "registration")
    let session = syntheticSession("registration")
    let operation = RegistrationFixtureOperation()
    var cases: [(name: String, error: Error, expected: [String])] = []
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "RegistrationFixtureAssertion", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    func run(_ state: V3RegistrationFixture) async throws -> ALTDevice {
        try await V3RegistrationFixture.$current.withValue(state) {
            try await operation.fixtureRegister(team: team, session: session)
        }
    }
    func failed(_ name: String, _ state: V3RegistrationFixture, expected: [String]) async throws -> Error {
        do { _ = try await run(state) }
        catch {
            guard let wrapper = error as? V3ProvisioningCauseError,
                  let safe = V3ProvisioningCauseDiagnostic(encoded: wrapper.provisioningCause) else {
                throw NSError(domain: "RegistrationFixtureAssertion", code: 2)
            }
            try check(safe.encoded.utf8.count <= 1024 && safe.rows.count <= 4, "strict output bounds")
            try check(!safe.encoded.contains("SECRET_"), "no secret canary in pc1")
            for token in expected { try check(safe.encoded.contains(token), name + " missing " + token) }
            cases.append((name, error, expected))
            return wrapper.underlying
        }
        throw NSError(domain: "RegistrationFixtureAssertion", code: 3)
    }
    let cached = V3RegistrationFixture()
    _ = try await run(cached)
    try check(cached.log == ["cellOff", "live", "cellOn:2.0", "list:255"], "existing device order; no unnecessary register")
    let new = V3RegistrationFixture(); new.devices = .success([])
    _ = try await run(new)
    try check(new.log == ["cellOff", "live", "cellOn:2.0", "list:255", "register"], "conditional registration and exact payload")
    let recovered = V3RegistrationFixture(); recovered.live = .failure(MinimuxerError.notStarted("SECRET_PAIRING_CANARY"))
    _ = try await run(recovered)
    try check(recovered.log == ["cellOff", "live", "cellOn:2.0", "fallback:true", "list:255"], "fallback recovery unchanged")

    let first = V3RegistrationFixture()
    first.live = .failure(MinimuxerError.createLockdown("SECRET_PAIRING_CANARY"))
    first.fallback = .failure(OperationError.notAuthenticated)
    let selected = try await failed("registration-live-and-fallback-preserve-first", first,
        expected: ["pc1|missingVerifiedID|", "liveUDID,minimuxer,createLockdown", "fallbackUDID,operation,notAuthenticated", "missingVerifiedID,state,unverifiedIdentifier"])
    guard let selected = selected as? MinimuxerError, case .createLockdown = selected else { throw NSError(domain: "RegistrationFixtureAssertion", code: 4) }
    try check(!first.log.contains("list:255"), "no dispatch without verified identifier")

    let wrapped = V3RegistrationFixture()
    wrapped.live = .failure(MinimuxerServiceError(error: MinimuxerError.getLockdownValue("SECRET_PAIRING_CANARY")))
    wrapped.fallback = .success(nil)
    _ = try await failed("registration-wrapped-minimuxer-cause", wrapped,
        expected: ["liveUDID,wrapper,minimuxerService", "liveUDID,minimuxer,getLockdownValue"])

    let fallback = V3RegistrationFixture(); fallback.live = .success("XXXXX-XXXX-XXXXX-XXXX")
    fallback.fallback = .failure(MinimuxerError.noConnection("SECRET_TOKEN_CANARY"))
    _ = try await failed("registration-fallback-error-without-first-error", fallback,
        expected: ["liveUDID,state,unverifiedIdentifier", "fallbackUDID,minimuxer,noConnection"])
    let absent = V3RegistrationFixture(); absent.live = .success(""); absent.fallback = .success(nil)
    let missing = try await failed("registration-missing-verified-identifier", absent,
        expected: ["liveUDID,state,unverifiedIdentifier", "fallbackUDID,state,unverifiedIdentifier", "missingVerifiedID,state,unverifiedIdentifier"])
    guard let missing = missing as? OperationError, case .unknownUDID = missing else { throw NSError(domain: "RegistrationFixtureAssertion", code: 5) }

    let preflight = V3RegistrationFixture(); preflight.devices = .failure(OperationError.notAuthenticated)
    _ = try await failed("registration-local-list-auth-before-response", preflight,
        expected: ["pc1|listDevices|", "listDevices,operation,notAuthenticated,-,-,-"])
    let afterResponse = V3RegistrationFixture(); afterResponse.listHTTP = 200; afterResponse.listResult = 0
    afterResponse.devices = .failure(OperationError.notAuthenticated)
    _ = try await failed("registration-local-list-auth-after-http200", afterResponse,
        expected: ["listDevices,operation,notAuthenticated,-,0,200"])

    let list = V3RegistrationFixture(); list.listHTTP = 503
    list.devices = .failure(ServerError.badServerResponse(reason: "SECRET_REASON_CANARY", jsonPayload: "{\"SECRET_TOKEN_CANARY\":\"SECRET_ACCOUNT_CANARY\"}"))
    _ = try await failed("registration-list-parser-response", list,
        expected: ["listDevices,server,badServerResponse,-,-,503", "jsonDictionary,unavailable,1to256"])
    let registration = V3RegistrationFixture(); registration.devices = .success([])
    registration.registerHTTP = 409; registration.registerResult = 35; registration.provider = "ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE"
    registration.registered = .failure(DeveloperPortalError.deviceAlreadyRegistered(cause: "SECRET_UDID_CANARY"))
    _ = try await failed("registration-conditional-register-portal-error", registration,
        expected: ["pc1|registerDevice|", "registerDevice,portal,deviceAlreadyRegistered,-,35,409,ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE"])

    let cancellation = V3RegistrationFixture(); cancellation.live = .failure(CancellationError()); cancellation.fallback = .success(nil)
    do { _ = try await run(cancellation); throw NSError(domain: "RegistrationFixtureAssertion", code: 6) }
    catch is CancellationError {}
    try check(cancellation.log == ["cellOff", "live", "cellOn:2.0", "fallback:true"], "cancellation fetch order unchanged")
    let cancelledList = V3RegistrationFixture(); cancelledList.devices = .failure(URLError(.cancelled))
    do { _ = try await run(cancelledList); throw NSError(domain: "RegistrationFixtureAssertion", code: 7) }
    catch let error as URLError { try check(error.code == .cancelled, "URL cancellation remains original") }

    let cycle = V3CycleError(); cycle.next = cycle
    let cycleValue = v3UnobservedProvisioningCause(cycle)
    cycle.next = nil
    try check(cycleValue.hasPrefix("pc1|unobserved|0|1|1|"), "causal cycle detected and bounded")
    cases.append(("registration-unknown-cycle", V3ProvisioningCauseError(underlying: NSError(domain: "SECRET_DOMAIN_CANARY", code: 777), provisioningCause: cycleValue), ["pc1|unobserved|0|1|1|"]))
    var deep: Error = NSError(domain: NSPOSIXErrorDomain, code: 61)
    for _ in 0..<8 { deep = NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSUnderlyingErrorKey: deep, "SECRET_KEY_CANARY": "SECRET_TOKEN_CANARY"]) }
    let deepValue = v3UnobservedProvisioningCause(deep)
    try check(deepValue.hasPrefix("pc1|unobserved|1|0|0|"), "deep chain explicitly truncated")
    cases.append(("registration-deep-chain-truncated", V3ProvisioningCauseError(underlying: deep, provisioningCause: deepValue), ["pc1|unobserved|1|0|0|"]))
    let decode = DecodingError.typeMismatch(String.self, .init(codingPath: [V3FixtureCodingKey("SECRET_CODING_PATH_CANARY")], debugDescription: "SECRET_PASSWORD_CANARY"))
    let decodeValue = v3UnobservedProvisioningCause(decode)
    try check(decodeValue.contains("decoding,typeMismatch") && decodeValue.contains(",string,other,0"), "finite decoder case/type/key")
    cases.append(("registration-decoder-unknown-key", V3ProvisioningCauseError(underlying: decode, provisioningCause: decodeValue), ["decoding,typeMismatch", ",string,other,0"]))
    let oversized = ServerError.invalidResponseFormat(rawPayload: String(repeating: "SECRET_TOKEN_CANARY", count: 600), responseContext: nil)
    let oversizedValue = v3UnobservedProvisioningCause(oversized)
    try check(oversizedValue.contains("unobserved,unavailable,over4096"), "oversize payload never parsed or exported")
    cases.append(("registration-oversize-payload", V3ProvisioningCauseError(underlying: oversized, provisioningCause: oversizedValue), ["unobserved,unavailable,over4096"]))
    let wrappedNative = ALTWrappedError(error: NSError(domain: NSPOSIXErrorDomain, code: 61,
        userInfo: [NSLocalizedDescriptionKey: "SECRET_DESCRIPTION_CANARY"]), userInfo: ["SECRET_KEY_CANARY": "SECRET_TOKEN_CANARY"])
    let wrappedValue = v3UnobservedProvisioningCause(wrappedNative)
    try check(wrappedValue.contains("unobserved,wrapper,altWrapped") && wrappedValue.contains("unobserved,native,posix,61"), "known native wrapper preserves safe underlying code")
    cases.append(("registration-wrapped-native-cause", V3ProvisioningCauseError(underlying: wrappedNative, provisioningCause: wrappedValue), ["unobserved,wrapper,altWrapped", "unobserved,native,posix,61"]))
    let previous = V3RegistrationFixture()
    let observerLog = V3RegistrationFixture()
    previous.devices = .failure(OperationError.notAuthenticated); previous.listHTTP = 200; previous.listResult = 0
    try await SideSignPortalDiagnostics.$responseObserver.withValue({ _, _ in observerLog.record("response") }) {
        try await SideSignPortalDiagnostics.$resultCodeObserver.withValue({ _ in observerLog.record("result") }) {
            _ = try await failed("registration-preserves-existing-observers", previous, expected: ["notAuthenticated,-,0,200"])
        }
    }
    try check(observerLog.log == ["response", "result"], "prior observers forwarded exactly once")
    try check(SideSignPortalDiagnostics.responseObserver == nil && SideSignPortalDiagnostics.resultCodeObserver == nil, "observer scopes restored")
    for row in cases {
        let context = v3ProvisioningCauseContext(row.error) ?? ""
        try check(!context.contains("SECRET_") && V3ProvisioningCauseDiagnostic.validated(context) != nil, "full export safe")
    }
    return cases
}
