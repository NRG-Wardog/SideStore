@main
struct InitializerDiagnosticHarness {
    static let id = "00000000-0000-0000-0000-000000000001"
    static let prefix = "Library constructor execution failed"
    static let traceSuffix = " [DEBUG_TEMPORARY_NATIVE_TRACE:vm.init.ok,library.load.ok,library.init.failed]"
    static let consumptionSuffix = " [DEBUG_TEMPORARY_ADI_CONSUMPTION:v2|0|0|0]"
    static let keys = ["native_init_kind", "native_init_reason", "native_init_engine", "native_init_library", "native_init_initializer"]
    static func message(_ kind: String, _ reason: String, _ engine: Int, _ library: Int, _ initializer: Int) -> String {
        "\(prefix) [v1;kind=\(kind);reason=\(reason);engine=\(engine);library=\(library);initializer=\(initializer)]"
    }
    static func main() throws {
        let enabled = CommandLine.arguments[1] == "enabled"
        // Every native kind/reason and the unavailable/upper-bound values.
        let tuples: [(String, String, Int, Int, Int)] = [
            ("dt_init", "engine_error", 13, 0, 0), ("dt_init", "engine_error", -1, -1, 0),
            ("dt_init", "unsupported_interrupt", 0, 1, 0), ("dt_init", "unexpected_return", 0, 65535, 0),
            ("dt_init_array", "engine_error", 255, 65535, 65535), ("dt_init_array", "engine_error", -1, -1, -1),
            ("dt_init_array", "unsupported_interrupt", -1, -1, -1), ("dt_init_array", "unsupported_interrupt", 255, 0, 1),
            ("dt_init_array", "unexpected_return", 0, 2, 3), ("dt_init_array", "unexpected_return", 0, -1, -1),
            ("array_entry_read", "entry_read", 6, 2, 4), ("array_entry_read", "entry_read", -1, -1, -1),
            ("array_entry_read", "entry_read", 255, 65535, 65535),
            ("unknown", "unknown", -1, -1, -1), ("unknown", "invalid_vm", -1, -1, -1),
            ("unknown", "previously_failed", -1, -1, -1)]
        let canonical = message("dt_init", "engine_error", 13, 0, 0)
        // Cross-language boundary: these bytes come from the actual maintained
        // C++ formatter, including normalization of unavailable/invalid inputs.
        let produced = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
            .split(separator: "\n").map(String.init)
        precondition(produced.count == 21)
        for description in produced {
            let observed = V3AnisetteNativeEvidence.capture(code: -2,
                description: description + traceSuffix + consumptionSuffix)
            precondition(observed.phase == .setupConstructors && observed.subcode == nil)
            let fields = observed.constructorFailure!.diagnosticFields
            let reconstructed = message(fields["native_init_kind"]!, fields["native_init_reason"]!,
                Int(fields["native_init_engine"]!)!, Int(fields["native_init_library"]!)!, Int(fields["native_init_initializer"]!)!)
            precondition(reconstructed == description)
            let error = V3AccountOperationError(step: .anisetteFetch, kind: .anisetteKitADIError,
                underlying: NSError(domain: "redacted", code: -2), serverCode: nil, nativeEvidence: observed)
            let failure = error.failure(operation: "signIn", id: id)
            let decoded = CombinedFailure.fromEncodedString(failure.encodedString, expectedID: id)!
            for (key, value) in fields { precondition(decoded.signingContext[key] == value) }
        }
        for (kind, reason, engine, library, initializer) in tuples {
            let expected = Dictionary(uniqueKeysWithValues: zip(keys, [kind, reason, String(engine), String(library), String(initializer)]))
            for suffix in ["", traceSuffix, consumptionSuffix, traceSuffix + consumptionSuffix] {
                let description = message(kind, reason, engine, library, initializer) + suffix
                let native = V3AnisetteNativeEvidence.capture(code: -2, description: description)
                precondition(native.phase == .setupConstructors && native.subcode == nil)
                precondition(native.constructorFailure?.diagnosticFields == expected)
                precondition((native.consumption != nil) == (enabled && suffix.contains("ADI_CONSUMPTION")))
                var trace = V3TemporaryAnisetteTrace()
                trace.appendNative(errorDescription: description, scope: .primary)
                let probe = V3AnisetteNativeEvidence.capture(code: -45061,
                    description: "ADIOTPRequest failed (Device not provisioned (-45061)): -45061")
                let attempt = V3AnisetteAttemptContext(blobState: .existing, recovery: .automaticRecoveryDisabled,
                    probeEvidence: probe, trace: trace)
                let underlying = AnisetteKit.AnisetteError.adiError(code: -2, description: description)
                let error = V3AnisetteAttemptError(underlying: underlying, context: attempt)
                let failure = v3CaptureAuthFailure(V3AuthenticationPhaseError(step: .anisetteFetch, underlying: error),
                    operation: "signIn", stage: .authentication, id: id)
                precondition(failure.stage == .authentication && failure.sourceStep == .anisetteFetch)
                precondition(failure.signingContext["typed_error"] == "anisetteKitADIError")
                precondition(failure.signingContext["native_code"] == "-2")
                precondition(failure.signingContext["native_phase"] == "setupConstructors")
                precondition(failure.signingContext["native_subcode"] == "unknown")
                precondition(failure.signingContext["probe_native_code"] == "-45061")
                precondition(failure.signingContext["anisette_recovery"] == "automaticRecoveryDisabled")
                for (key, value) in expected { precondition(failure.signingContext[key] == value) }
                let data = try PropertyListSerialization.data(fromPropertyList: failure.wire, format: .binary, options: 0)
                precondition(data.count <= 4096 && failure.signingContext.count <= 20)
                let roundtrip = CombinedFailure.fromEncodedString(failure.encodedString, expectedID: id)!
                precondition(roundtrip.signingContext == failure.signingContext)
                precondition(CombinedFailure.fromEncodedString(failure.encodedString, expectedID: UUID().uuidString) == nil)
                var wire = roundtrip.wire; wire["kind"] = "anisette"
                let rendered = V3AuthFailureDiagnosticsPolicy.render(wire, underlyingCode: -2, retryableValue: nil)
                for (key, value) in expected {
                    precondition(roundtrip.technicalDetails.contains("\(key)=\(value)"))
                    precondition(rendered.contains("\(key)=\(value)"))
                }
                precondition(!rendered.contains(prefix) && !roundtrip.technicalDetails.contains(prefix))
                if description == canonical + traceSuffix + consumptionSuffix {
                    try failure.encodedString.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
                    var full = failure.signingContext
                    // The maximum current account/attempt/probe/trace tuple is18.
                    precondition(full.count == (enabled ? 18 : 16))
                    for key in ["account_binding", "team_binding"] { full[key] = "verified" }
                    if !enabled {
                        full["preferred_parent_id_match"] = "true"
                        full["signing_certificate_present"] = "true"
                    }
                    precondition(full.count == 20 && CombinedFailure.validatedSigningContext(full) != nil)
                    full["session_generation"] = "1"
                    precondition(CombinedFailure.validatedSigningContext(full) == nil)
                    for key in keys {
                        var incomplete = failure.signingContext; incomplete.removeValue(forKey: key)
                        precondition(CombinedFailure.validatedSigningContext(incomplete) == nil)
                    }
                    for (key, value) in [("native_code", "-3"), ("native_phase", "nativeOTP"),
                        ("native_subcode", "13"), ("typed_error", "anisetteFailure"),
                        ("native_init_kind", "unknown"), ("native_init_reason", "entry_read"),
                        ("native_init_engine", "0"), ("native_init_library", "65536"),
                        ("native_init_initializer", "1"), ("native_init_engine", "013")] {
                        var forged = failure.signingContext; forged[key] = value
                        precondition(CombinedFailure.validatedSigningContext(forged) == nil)
                        var badWire = failure.wire; badWire["signingContext"] = forged
                        precondition(CombinedFailure.decode(badWire, expectedID: id) == nil)
                    }
                }
            }
        }
        for (text, phase) in [(prefix, V3AnisetteNativeEvidence.Phase.setupConstructors),
            ("VM initialization failed", .setupVM),
            ("VM initialization previously failed; restart required", .setupVMPreviouslyFailed)] {
            for suffix in ["", traceSuffix + consumptionSuffix] {
                let observed = V3AnisetteNativeEvidence.capture(code: -2, description: text + suffix)
                precondition(observed.phase == phase && observed.constructorFailure == nil && observed.subcode == nil)
            }
            precondition(V3AnisetteNativeEvidence.capture(code: -1, description: text).phase == .unknown)
            precondition(V3AnisetteNativeEvidence.capture(code: -2, description: text + " ").phase == .unknown)
        }
        for code in [-45061, -6, -3, -1, 0, 1, 13] as [Int32] {
            let observed = V3AnisetteNativeEvidence.capture(code: code, description: canonical)
            precondition(observed.phase == .unknown && observed.constructorFailure == nil)
        }
        var malformed = [canonical + "\n", " " + canonical, canonical + "EXTRA", canonical + canonical,
            canonical.replacingOccurrences(of: "[v1;", with: "[v2;"), canonical.replacingOccurrences(of: ";engine=13", with: "; engine=13"),
            canonical.replacingOccurrences(of: ";engine=13", with: ";engine=13;engine=13"),
            canonical.replacingOccurrences(of: ";engine=13", with: ";pointer=13;engine=13"),
            canonical.replacingOccurrences(of: ";engine=13;library=0", with: ";library=0;engine=13"),
            canonical.replacingOccurrences(of: "kind=dt_init", with: "kind=DT_INIT"),
            canonical.replacingOccurrences(of: "reason=engine_error", with: "reason=SECRET"),
            canonical.replacingOccurrences(of: "reason=engine_error", with: "reason=unknown"),
            canonical.replacingOccurrences(of: "reason=engine_error", with: "reason=entry_read"),
            message("dt_init", "unexpected_return", 13, 0, 0), message("dt_init", "unexpected_return", -1, 0, 0),
            message("dt_init", "invalid_vm", -1, -1, 0), message("dt_init", "engine_error", 13, 0, -1),
            message("dt_init", "engine_error", 13, 0, 1), message("array_entry_read", "entry_read", 0, 0, 0),
            message("array_entry_read", "engine_error", 13, 0, 0), message("unknown", "unknown", 13, -1, -1),
            message("unknown", "previously_failed", -1, 0, -1), message("unknown", "invalid_vm", -1, -1, 0),
            canonical + traceSuffix + traceSuffix, canonical + consumptionSuffix + consumptionSuffix,
            canonical + " [DEBUG_TEMPORARY_NATIVE_TRACE:SECRET]", String(repeating: "SECRET", count: 2000)]
        for value in ["", "0", "+13", "013", "-0", "-2", "256", "9999999999999999999999999999", "١٣", "13 "] {
            malformed.append(canonical.replacingOccurrences(of: "engine=13", with: "engine=" + value))
        }
        for value in ["+0", "00", "-0", "-2", "65536", "9999999999999999999999999999"] {
            malformed.append(canonical.replacingOccurrences(of: "library=0", with: "library=" + value))
            malformed.append(canonical.replacingOccurrences(of: "initializer=0", with: "initializer=" + value))
        }
        for description in malformed {
            let observed = V3AnisetteNativeEvidence.capture(code: -2, description: description)
            precondition(observed.phase == .unknown && observed.constructorFailure == nil && observed.subcode == nil)
        }
        let probeOnly = V3AnisetteNativeEvidence.capture(code: -2,
            description: message("array_entry_read", "entry_read", 6, 2, 4))
        let probeContext = V3AnisetteAttemptContext(blobState: .existing, recovery: .automaticRecoveryDisabled,
            probeEvidence: probeOnly).diagnosticFields
        precondition(probeContext["probe_native_phase"] == "setupConstructors")
        precondition(probeContext.keys.allSatisfy { !$0.hasPrefix("native_init_") && !$0.hasPrefix("probe_native_init_") })
        // Preserve existing handling of invalid optional ADI metadata: strip the
        // one terminal owned suffix, omit it, and retain the exact base failure.
        let badOptional = V3AnisetteNativeEvidence.capture(code: -2,
            description: canonical + traceSuffix + " [DEBUG_TEMPORARY_ADI_CONSUMPTION:SECRET]")
        precondition(badOptional.phase == .setupConstructors && badOptional.constructorFailure != nil)
        precondition(badOptional.consumption == nil)
        let legacy = v3AccountOperationFailure(AnisetteKit.AnisetteError.adiError(code: -2, description: prefix),
            step: .anisetteFetch).failure(operation: "signIn", id: id)
        precondition(legacy.signingContext["native_phase"] == "setupConstructors")
        precondition(keys.allSatisfy { legacy.signingContext[$0] == nil })
        precondition(CombinedFailure.fromEncodedString(legacy.encodedString, expectedID: id) != nil)
        let unrelated = V3AnisetteNativeEvidence.capture(code: -2, description: "ADILoadLibraryWithPath failed: -45061")
        precondition(unrelated.phase == .setupLoadLibrary && unrelated.subcode == -45061 && unrelated.constructorFailure == nil)
        print("INITIALIZER_CONSUMER_PIPELINE_PASS " + (enabled ? "enabled" : "disabled"))
    }
}
