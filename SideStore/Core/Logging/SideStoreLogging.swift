//
//  SideStoreLogging.swift
//  SideStore
//
//  Created by Magesh K on 8/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//
import Foundation

public enum SideStoreLogging {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var rawLoggingEnabled: Bool = false

    public static var isLoggingEnabled: Bool {
        lock.withLock { rawLoggingEnabled }
    }

    public static func setLogging(_ enabled: Bool) {
        lock.withLock { rawLoggingEnabled = enabled }
    }
}

private func getFastTimestamp() -> String {
    let now = Date()
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: now)
    let ms = (comps.nanosecond ?? 0) / 1_000_000
    return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d",
                  comps.year ?? 0, comps.month ?? 0, comps.day ?? 0,
                  comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0,
                  ms)
}

private func getTag(level: String) -> String {
    let timestamp = getFastTimestamp()
    return "\(timestamp) \(level): "
}

// SIDESTORE_TRANSITIVE_ERROR_LOG_PRIVACY_V1
// SideSign errors can carry raw GrandSlam/portal/Anisette payloads. Omit those
// lines before they enter Copy Logs; bounded v3 diagnostics carry safe codes.
func shouldOmitUserCopyableSideStoreLog(_ message: String) -> Bool {
    let lowercased = message.lowercased()
    let markers = ["error", "failed", "failure", "cause", "response", "payload", "header",
                   "authorization", "cookie", "dsid", "phone", "pairing", "2fa", "verification",
                   "verification-code", "security code", "security-code", "password", "apple id",
                   "appleid", "token", "anisette", "private key", "certificate der",
                   "mobileprovision", "provisioning profile", "grandslam", "grand slam"]
    // Certificate serials are sensitive identifiers even on successful paths.
    // SideStore emits them from CertificateManager, SignInOperation, and its
    // OCSP verifier without an error/payload marker, so omit the whole line.
    // Match compound labels such as certSerial, targetSerial, serialNumber,
    // serialHex, and serial_number without matching words such as "serialize".
    let certificateSerial = lowercased.range(
        of: #"\b[a-z0-9_]*serial(?:[_-]?(?:number|hex|dec))?\b"#,
        options: .regularExpression
    ) != nil
    // The pinned code also emits unlabelled serials in certificate context,
    // including "certificate (<serial>)", "certificate '<serial>'",
    // "deleteCertificate: <serial>", and OCSP status lines.
    let certificateValue = lowercased.range(
        of: #"(?:\bcertificate\s+(?:0x)?[0-9a-f]{2,}\b|\bcertificate\s*[\(\['"]+\s*(?:0x)?[a-z0-9:-]{2,}\b|\b[a-z]*certificate\s*:\s*(?:0x)?[a-z0-9:-]{2,}\b)"#,
        options: .regularExpression
    ) != nil
    let ocspValue = lowercased.range(
        of: #"\bocsp\b[^\n]*\bfor\s+(?:0x)?[0-9a-f]{2,}\b"#,
        options: .regularExpression
    ) != nil
    return certificateSerial || certificateValue || ocspValue || markers.contains { lowercased.contains($0) }
}

public func debugLog(_ text: @autoclosure () -> String) {
    let rawMessage = text()
    guard !shouldOmitUserCopyableSideStoreLog(rawMessage) else { return }
    let message = formatLogMessage(rawMessage)
    if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
        print(message, terminator: "")
    } else {
        print("\(getTag(level: "[D]"))\(message)")
    }
}

public func verboseLog(_ text: @autoclosure () -> String) {
    guard SideStoreLogging.isLoggingEnabled else { return }
    let rawMessage = text()
    guard !shouldOmitUserCopyableSideStoreLog(rawMessage) else { return }
    let message = formatLogMessage(rawMessage)
    if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
        print(message, terminator: "")
    } else {
        print("\(getTag(level: "[V]"))\(message)")
    }
}

public func formatLogMessage(_ message: String) -> String {
    // V3_SAFE_LOG_FORMAT_V1: user-copyable logs never contain credentials,
    // provider bodies, identifiers, URLs, or device/container paths.
    let providerErrorMarkers = ["UserInfo=", "NSErrorFailingURL", "NSURLErrorDomain",
        "Error Domain=", "ServerError.badServerResponse", "invalidResponseFormat"]
    let codePattern = #"(?i)\bCode=(-?\d+)"#
    var suppressProviderDetails = false
    var suppressSideBackupDetails = false
    var output: [String] = []
    for line in message.components(separatedBy: .newlines) {
        if suppressProviderDetails {
            if line.contains("}") { suppressProviderDetails = false }
            continue
        }
        if providerErrorMarkers.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
            if let range = line.range(of: codePattern, options: .regularExpression) {
                let code = String(line[range]).replacingOccurrences(of: #"(?i)^Code="#, with: "",
                    options: .regularExpression)
                output.append("[V3_LOG_REDACTED] native_code=\(code)")
            } else {
                output.append("[V3_LOG_REDACTED]")
            }
            suppressProviderDetails = line.contains("UserInfo={") && !line.contains("}")
            continue
        }
        if suppressSideBackupDetails {
            if line.contains("[SideBackup Logs End]") { suppressSideBackupDetails = false }
            continue
        }
        if line.localizedCaseInsensitiveContains("SideBackup") {
            output.append("[V3_LOG_REDACTED] side_backup")
            suppressSideBackupDetails = line.contains("[SideBackup Logs") && !line.contains("[SideBackup Logs End]")
            continue
        }
        var safe = line
        safe = safe.replacingOccurrences(of: #"(?i)\b(?:https?|file)://[^\s]+"#,
            with: "[redacted URL]", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"(?i)(?:/private)?/(?:var|Users|tmp|Library|System|Applications|Volumes)/[^\s,;]+"#,
            with: "[redacted path]", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"(?i)\b(?:proxy-authorization|authorization)\s*[:=]\s*(?:bearer|basic)\s+[^\s,;]+"#,
            with: "authorization=[redacted credential]", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"(?i)(["']?(?:UDID|DSID|phone(?:ID|Number)|deviceEndpointIp|bundlePath|bundleIdentifier|bundleID|app(?:\s*ID|Identifier)|team(?:\s*ID|Identifier)|downloadURL|callbackURL|accessToken|refreshToken|sessionToken|authorization|cookie|password|verificationCode|securityCode|private[_ ]?key|certificateDER|provisioningProfile|token|path|session(?:_id)?|request_id|correlationID|authToken|xcodeToken|secret|credential)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)"#,
            with: "$1[redacted]", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"(?i)\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b"#,
            with: "[redacted UUID]", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            with: "[redacted email]", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"(?i)\b(?:[a-z0-9-]{1,63}\.)+[a-z][a-z0-9-]{1,63}\b"#,
            with: "[redacted identifier]", options: .regularExpression)
        output.append(safe)
    }
    return output.joined(separator: "\n")
}
