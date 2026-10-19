extension InitializerDiagnosticHarness {
    static let faultKey = V3ConstructorFaultDiagnostic.contextKey
    static let faultWire = "v1;p0_fault_diag1;1;8;2;0;100;1;000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f;fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0efeeedecebeae9e8e7e6e5e4e3e2e1e0"
    static func faultSuffix(_ wire: String) -> String { " [DEBUG_TEMPORARY_CONSTRUCTOR_FAULT:\(wire)]" }
    static func verifyFaultDiagnostics(enabled: Bool, nativePath: String, outputPath: String) throws {
        let canonical = message("dt_init", "engine_error", 13, 0, 0)
        let produced = try String(contentsOfFile: nativePath, encoding: .utf8).split(separator: "\n").map(String.init)
        precondition(produced.count == 12 && produced[1] == faultWire)
        for raw in produced {
            // Actual C++ encoder -> actual AK Swift suffix -> actual consumer.
            let suffix = TemporaryConstructorFaultTrace.suffix(raw)
            precondition(suffix == faultSuffix(raw))
            precondition(V3ConstructorFaultDiagnostic(encoded: raw)?.encoded == raw)
            for trace in ["", traceSuffix, consumptionSuffix, traceSuffix + consumptionSuffix] {
                let description = canonical + suffix + trace
                let native = V3AnisetteNativeEvidence.capture(code: -2, description: description)
                precondition(native.phase == .setupConstructors && native.subcode == nil)
                precondition(native.constructorFault?.encoded == raw)
                precondition(native.constructorFailure?.diagnosticFields["native_init_engine"] == "13")
                precondition((native.consumption != nil) == (enabled && trace.contains("ADI_CONSUMPTION")))
                var observedTrace = V3TemporaryAnisetteTrace()
                observedTrace.appendNative(errorDescription: description, scope: .primary)
                let probe = V3AnisetteNativeEvidence.capture(code: -45061,
                    description: "ADIOTPRequest failed (Device not provisioned (-45061)): -45061")
                let attempt = V3AnisetteAttemptContext(blobState: .existing, recovery: .automaticRecoveryDisabled,
                    probeEvidence: probe, trace: observedTrace)
                let underlying = AnisetteKit.AnisetteError.adiError(code: -2, description: description)
                let error = V3AnisetteAttemptError(underlying: underlying, context: attempt)
                let failure = v3CaptureAuthFailure(V3AuthenticationPhaseError(step: .anisetteFetch, underlying: error),
                    operation: "signIn", stage: .authentication, id: id)
                precondition(failure.stage == .authentication && failure.sourceStep == .anisetteFetch)
                precondition(failure.signingContext[faultKey] == raw)
                precondition(failure.signingContext["native_subcode"] == "unknown")
                precondition(failure.signingContext["anisette_recovery"] == "automaticRecoveryDisabled")
                let data = try PropertyListSerialization.data(fromPropertyList: failure.wire, format: .binary, options: 0)
                precondition(data.count <= 4096 && failure.signingContext.count <= 20)
                let decoded = CombinedFailure.fromEncodedString(failure.encodedString, expectedID: id)!
                precondition(decoded.signingContext == failure.signingContext)
                var wire = decoded.wire; wire["kind"] = "anisette"
                let rendered = V3AuthFailureDiagnosticsPolicy.render(wire, underlyingCode: -2, retryableValue: nil)
                let details = V3ConstructorFaultDiagnostic(encoded: raw)!.technicalDetails
                precondition(decoded.technicalDetails.contains(details) && rendered.contains(details))
                precondition(!rendered.contains("p0_fault_diag1") && !rendered.contains("DEBUG_TEMPORARY_CONSTRUCTOR_FAULT"))
                if raw == faultWire && trace == traceSuffix + consumptionSuffix {
                    try failure.encodedString.write(toFile: outputPath, atomically: true, encoding: .utf8)
                    precondition(failure.signingContext.count == (enabled ? 19 : 17))
                    var full = failure.signingContext
                    full["account_binding"] = "verified"
                    if !enabled { full["team_binding"] = "verified"; full["signing_certificate_present"] = "true" }
                    precondition(full.count == 20 && CombinedFailure.validatedSigningContext(full) == full)
                    full["session_generation"] = "1"
                    let trimmed = CombinedFailure.validatedSigningContext(full)!
                    precondition(trimmed.count == 20)
                    precondition(trimmed[faultKey] == (enabled ? raw : nil))
                    precondition(trimmed[V3TemporaryADIConsumption.contextKey] == nil)
                    for key in keys { precondition(trimmed[key] == failure.signingContext[key]) }
                    if enabled {
                        full["team_binding"] = "verified"
                        let noOptional = CombinedFailure.validatedSigningContext(full)!
                        precondition(noOptional.count == 20 && noOptional[faultKey] == nil)
                        for key in keys { precondition(noOptional[key] == failure.signingContext[key]) }
                    }
                    full["capability_count"] = "0"
                    precondition(CombinedFailure.validatedSigningContext(full) == nil)
                    // Validate invalid metadata/provenance even if optional capacity is exhausted.
                    for (key, value) in [(faultKey, "SECRET"), ("typed_error", "anisetteFailure"),
                        ("native_code", "-3"), ("native_phase", "nativeOTP"), ("native_subcode", "13")] {
                        var forged = failure.signingContext; forged[key] = value
                        precondition(CombinedFailure.validatedSigningContext(forged) == nil)
                        var badWire = failure.wire; badWire["signingContext"] = forged
                        precondition(CombinedFailure.decode(badWire, expectedID: id) == nil)
                    }
                    for key in keys {
                        var missing = failure.signingContext; missing.removeValue(forKey: key)
                        precondition(CombinedFailure.validatedSigningContext(missing) == nil)
                    }
                    var crowdedMalformed = full
                    crowdedMalformed.removeValue(forKey: "capability_count")
                    precondition(crowdedMalformed.count == (enabled ? 22 : 21))
                    precondition(CombinedFailure.validatedSigningContext(crowdedMalformed)?.count == 20)
                    crowdedMalformed[faultKey] = "SECRET"
                    precondition(crowdedMalformed.count > 20)
                    precondition(CombinedFailure.validatedSigningContext(crowdedMalformed) == nil)
                    var crowdedOrphaned = full
                    crowdedOrphaned.removeValue(forKey: "native_init_engine")
                    precondition(crowdedOrphaned.count > 20)
                    precondition(CombinedFailure.validatedSigningContext(crowdedOrphaned) == nil)
                    var orphaned = failure.signingContext
                    for key in keys { orphaned.removeValue(forKey: key) }
                    precondition(CombinedFailure.validatedSigningContext(orphaned) == nil)
                    // The bounded wire helper preserves all other content when optional bytes yield.
                    var crowded = failure.wire; crowded["synthetic_padding"] = String(repeating: "x", count: 4096)
                    let bounded = V3ConstructorFaultDiagnostic.boundingWire(crowded)
                    let boundedFields = bounded["signingContext"] as! [String: String]
                    precondition(boundedFields[faultKey] == nil)
                    for key in keys { precondition(boundedFields[key] == failure.signingContext[key]) }
                    precondition(bounded["synthetic_padding"] as? String == crowded["synthetic_padding"] as? String)
                    let oversize = try PropertyListSerialization.data(fromPropertyList: bounded, format: .binary, options: 0)
                    precondition(oversize.count > 4096)
                    precondition(CombinedFailure.fromEncodedString("LCFAILURE1:" + oversize.base64EncodedString(), expectedID: id) == nil)
                }
            }
        }
        let parts = faultWire.components(separatedBy: ";")
        var malformed = ["", "SECRET", faultWire + ";extra", faultWire + "\n", " " + faultWire,
            faultWire.replacingOccurrences(of: "v1;", with: "v2;"), faultWire.replacingOccurrences(of: "p0_fault_diag1", with: "p0_fault_diag2"),
            String(repeating: "x", count: 256), faultWire + faultWire]
        for (index, values) in [(2, ["-1", "4", "01", "+1", "١", "1 "]),
            (3, ["0", "257", "-2", "08", "+8", "99999999999999999999999"]),
            (4, ["-1", "8", "02"]), (5, ["-2", "65536", "+0", "00"]),
            (6, ["-2", "805306368", "0100", "0x64"]), (7, ["-1", "3", "01"]),
            (8, ["", "SECRET", String(repeating: "A", count: 64), String(repeating: "0", count: 63), String(repeating: "g", count: 64)]),
            (9, ["", String(repeating: "0", count: 65)])] {
            for value in values { var changed = parts; changed[index] = value; malformed.append(changed.joined(separator: ";")) }
        }
        for changes in [[2: "0"], [3: "-1"], [5: "-1"], [6: "-1"]] {
            var changed = parts; for (index, value) in changes { changed[index] = value }
            malformed.append(changed.joined(separator: ";"))
        }
        for raw in malformed {
            precondition(TemporaryConstructorFaultTrace.suffix(raw).isEmpty)
            precondition(V3ConstructorFaultDiagnostic(encoded: raw) == nil)
            for trace in ["", traceSuffix + consumptionSuffix] {
                let rejected = V3AnisetteNativeEvidence.capture(code: -2, description: canonical + faultSuffix(raw) + trace)
                precondition(rejected.phase == .unknown && rejected.constructorFailure == nil && rejected.constructorFault == nil)
            }
        }
        let suffix = faultSuffix(faultWire)
        for description in [canonical + suffix + suffix, canonical + traceSuffix + suffix,
            canonical + consumptionSuffix + suffix, canonical + suffix + "EXTRA", suffix + canonical,
            canonical + suffix + " ", prefix + suffix, "VM initialization failed" + suffix,
            "ADILoadLibraryWithPath failed: -45061" + suffix,
            "ADIOTPRequest failed (ELF Loader failed to map dependencies): -2" + suffix] {
            let rejected = V3AnisetteNativeEvidence.capture(code: -2, description: description)
            precondition(rejected.phase == .unknown && rejected.constructorFailure == nil && rejected.constructorFault == nil)
        }
        for code in [-45061, -6, -3, -1, 0, 1, 13] as [Int32] {
            let rejected = V3AnisetteNativeEvidence.capture(code: code, description: canonical + suffix)
            precondition(rejected.phase == .unknown && rejected.constructorFault == nil)
        }
        let probe = V3AnisetteNativeEvidence.capture(code: -2, description: canonical + suffix)
        let probeFields = V3AnisetteAttemptContext(blobState: .existing, recovery: .automaticRecoveryDisabled, probeEvidence: probe).diagnosticFields
        precondition(probeFields[faultKey] == nil && probeFields.keys.allSatisfy { !$0.hasPrefix("native_fault_") })
        precondition(TemporaryConstructorFaultTrace.suffix(nil).isEmpty)
        precondition(V3AnisetteNativeEvidence.capture(code: -2, description: canonical).constructorFault == nil)
        print("CONSTRUCTOR_FAULT_CONSUMER_PIPELINE_PASS " + (enabled ? "enabled" : "disabled"))
    }
}
