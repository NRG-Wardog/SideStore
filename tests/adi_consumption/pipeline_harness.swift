@main
struct ADIConsumerPipelineHarness {
    static func main() throws {
        let raw = CommandLine.arguments[1]
        let enabled = CommandLine.arguments[2] == "enabled"
        let id = "00000000-0000-0000-0000-000000000001"
        let key = V3TemporaryADIConsumption.contextKey
        let base = "ADIOTPRequest failed (Device not provisioned (-45061)): -45061"
        let old = " [DEBUG_TEMPORARY_NATIVE_TRACE:arguments.ok,file.rename.ok,native.otp.failed]"
        let suffix = TemporaryADIConsumptionTrace.suffix(raw)
        precondition(!suffix.isEmpty)
        let native = V3AnisetteNativeEvidence.capture(code: -45061, description: base + old + suffix)
        precondition(native.code == -45061 && native.phase == .nativeOTP)
        precondition((native.consumption != nil) == enabled)
        var trace = V3TemporaryAnisetteTrace()
        trace.appendNative(errorDescription: base + old + suffix, scope: .primary)
        if enabled { precondition(trace.failedStep == "primary.native.otp") }
        trace.record(step: .legacyIdentifierDifferent, outcome: .succeeded)
        trace.record(step: .legacyBlobMissing, outcome: .succeeded)
        let underlying = AnisetteKit.AnisetteError.adiError(code: -45061, description: base + old + suffix)
        let attempt = V3AnisetteAttemptError(underlying: underlying,
            context: V3AnisetteAttemptContext(blobState: .existing, recovery: .automaticRecoveryDisabled, trace: trace))
        let failure = v3CaptureAuthFailure(V3AuthenticationPhaseError(step: .anisetteFetch, underlying: attempt),
            operation: "signIn", stage: .authentication, id: id)
        precondition(failure.code == .failed && failure.stage == .authentication)
        precondition(failure.sourceStep == .anisetteFetch)
        precondition(failure.signingContext["native_code"] == "-45061")
        precondition(failure.signingContext["native_phase"] == "nativeOTP")
        precondition((failure.signingContext[key] != nil) == enabled)
        let decoded = CombinedFailure.fromEncodedString(failure.encodedString, expectedID: id)!
        precondition(decoded.diagnosticCode == failure.diagnosticCode)
        precondition(decoded.signingContext["native_code"] == "-45061")
        precondition(CombinedFailure.fromEncodedString(failure.encodedString, expectedID: UUID().uuidString) == nil)
        let copy = decoded.technicalDetails
        precondition(copy.contains("DEBUG TEMPORARY adi_consumption=") == enabled)
        precondition(!copy.contains("SECRET"))
        precondition(copy.contains("swift.legacyIdentifierDifferent.succeeded") == enabled)
        precondition(copy.contains("swift.legacyBlobMissing.succeeded") == enabled)
        try failure.encodedString.write(toFile: CommandLine.arguments[3], atomically: true, encoding: .utf8)

        // Both versions survive exact SDK -> app -> wire -> host parsing.
        let observedRows = "|5,0,1,1,0,0,0,-1|5,1,1,1,0,639,639,0"
        for prefix in ["v1|0", "v2|0|0|0", "v2|0|1|0", "v2|0|1|1", "v2|0|2|0", "v2|1|1|1"] {
            let value = prefix + observedRows
            precondition(V3TemporaryADIConsumption(encoded: value)?.encoded == value)
            precondition(!TemporaryADIConsumptionTrace.suffix(value).isEmpty)
            let evidence = V3AnisetteNativeEvidence.capture(code: -45061,
                description: base + old + TemporaryADIConsumptionTrace.suffix(value))
            precondition(evidence.phase == .nativeOTP)
            precondition((evidence.consumption != nil) == enabled)
        }
        let malformed = ["SECRET_PASSWORD", "v1|0|5,1,4,-1,5,4,0,SECRET_TOKEN", "v1|0|05,0,1,1,0,0,0,-1",
            "v1|0|6,0,1,1,0,0,0,-1", "v1|0|5,2,1,1,0,0,0,-1", "v1|0|5,0,5,1,0,0,0,-1",
            "v1|0|5,0,1,1,4096,0,0,-1", "v1|0|5,0,1,1,0,1048578,0,-1", "v1|0|5,0,1,1,0,0,0,33",
            "v1|2", "v1|0|", "v2|0", "v2|0|1", "v2|0|3|0", "v2|0|01|0",
            "v2|0|0|1", "v2|0|2|1", "v2|0|1|2", "v2|0|1|01", "v2|0|SECRET|0",
            "v2|0|1|1" + String(repeating: "|5,0,1,1,0,0,0,-1", count: 33), raw + "\n", String(repeating: "7", count: 2049),
            "v1|0" + String(repeating: "|5,0,1,1,0,0,0,-1", count: 33)]
        for body in malformed {
            precondition(V3TemporaryADIConsumption(encoded: body) == nil)
            precondition(TemporaryADIConsumptionTrace.suffix(body).isEmpty)
            let description = base + old + " [DEBUG_TEMPORARY_ADI_CONSUMPTION:" + body + "]"
            let observed = V3AnisetteNativeEvidence.capture(code: -45061, description: description)
            precondition(observed.phase == .nativeOTP && observed.consumption == nil)
            var context = failure.signingContext
            context[key] = body
            let safe = CombinedFailure.validatedSigningContext(context)!
            precondition(safe[key] == nil && safe["native_code"] == "-45061")
        }
        let oversized = V3AnisetteNativeEvidence.capture(code: -45061,
            description: base + " [DEBUG_TEMPORARY_ADI_CONSUMPTION:" + String(repeating: "SECRET", count: 2000) + "]")
        precondition(oversized.code == -45061 && oversized.phase == .unknown && oversized.consumption == nil)
        let duplicate = V3AnisetteNativeEvidence.capture(code: -45061, description: base + suffix + suffix)
        precondition(duplicate.phase == .unknown && duplicate.consumption == nil)
        precondition(V3TemporaryADIConsumption(encoded: "v1|0|5,1,4,-1,5,4,0,-1") != nil)

        // Cap the actual binary-plist transport by trimming only optional rows.
        let long = "v1|0" + String(repeating: "|5,1,4,-1,4095,1048577,1048577,32", count: 32)
        precondition(V3TemporaryADIConsumption(encoded: long) != nil)
        let envelope: [String: Any] = ["operation": "signIn", "code": "failed", "mainFailure": String(repeating: "M", count: 3200),
            "signingContext": ["native_code": "-45061", key: long]]
        let bounded = V3TemporaryADIConsumption.boundingWire(envelope)
        precondition(bounded["mainFailure"] as? String == envelope["mainFailure"] as? String)
        let boundedData = try PropertyListSerialization.data(fromPropertyList: bounded, format: .binary, options: 0)
        precondition(boundedData.count <= 4096)
        let boundedFields = bounded["signingContext"] as! [String: String]
        precondition(boundedFields["native_code"] == "-45061")
        if enabled { precondition(boundedFields[key]?.hasPrefix("v1|1") == true) }
        else { precondition(boundedFields[key] == nil) }
        let v2Long = "v2|0|1|1" + String(repeating: "|5,1,4,-1,4095,1048577,1048577,32", count: 32)
        var v2Envelope = envelope
        v2Envelope["signingContext"] = ["native_code": "-45061", key: v2Long]
        let v2Bounded = V3TemporaryADIConsumption.boundingWire(v2Envelope)
        let v2Fields = v2Bounded["signingContext"] as! [String: String]
        precondition(v2Bounded["mainFailure"] as? String == envelope["mainFailure"] as? String)
        precondition(v2Fields["native_code"] == "-45061")
        let v2Data = try PropertyListSerialization.data(fromPropertyList: v2Bounded, format: .binary, options: 0)
        precondition(v2Data.count <= 4096)
        if enabled { precondition(v2Fields[key]?.hasPrefix("v2|1|1|1") == true) }
        else { precondition(v2Fields[key] == nil) }
        let cancellation = V3AuthenticationPhaseError(step: .anisetteFetch, underlying: CancellationError())
        precondition(v3IsAuthCancellation(cancellation))
        let network = v3CaptureAuthFailure(V3AuthenticationPhaseError(step: .anisetteFetch, underlying: URLError(.timedOut)),
            operation: "signIn", stage: .authentication, id: UUID().uuidString)
        precondition(network.signingContext[key] == nil)
        precondition(network.signingContext["typed_error"] == "transportFailure")
        precondition(!network.technicalDetails.contains("adi_consumption="))
        print("ADI_CONSUMER_PIPELINE_PASS")
    }
}
