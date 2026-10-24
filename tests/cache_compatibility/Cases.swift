// Synthetic source-owned macOS tests. Foundation and CryptoKit are real; the
// InstalledApp root is inert. No IPA, credentials, app group, network or device.
enum FixtureFailure: Error { case assertion(String) }
let fm = FileManager.default
func require(_ condition: Bool, _ description: String) throws {
    if !condition { throw FixtureFailure.assertion(description) }
}
func write(_ data: String, _ url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(data.utf8).write(to: url)
}
func bundle(_ root: URL) throws -> URL {
    let app = root.appendingPathComponent("Source.app")
    try write("ABCD", app.appendingPathComponent("Executable"))
    try write("synthetic-info", app.appendingPathComponent("Info.plist"))
    return app
}
func legacy(_ app: URL) throws -> String {
    let original = OriginalAppBundleFingerprint.compute(for: app)
    let compatibility = AppBundleFingerprint.computeOriginalCacheKey(for: app)
    try require(original != nil && original == compatibility, "Original and compatibility key differ")
    return compatibility!
}
// URL equality can include a directory hint that changes after creation.
// Cache reuse concerns the key, canonical filesystem location and retained bytes.
func filesystemPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}
func copied(_ source: URL, _ target: URL) throws {
    let before = AppBundleFingerprint.compute(for: source)
    try require(before != nil, "Synthetic source not strictly readable")
    try require(AppBundleFingerprint.compute(for: target) == before, "Foundation copy changed payload")
}
func cached(_ app: URL, _ root: URL, original: Bool) throws -> (signature: String, targetFileURL: URL) {
    InstalledApp.appsDirectoryURL = root
    if original { return try OriginalCacheAppOperation.cachePayload(for: app) }
    return try CacheAppOperation.cachePayload(for: app)
}
func cacheThrows(_ app: URL, _ root: URL, original: Bool) -> Bool {
    do { _ = try cached(app, root, original: original); return false } catch { return true }
}
func requireCacheLinkRejection(_ app: URL, _ apps: URL) throws {
    do {
        _ = try cached(app, apps, original: false)
        throw FixtureFailure.assertion("Symbolic cache component accepted")
    } catch let error as OperationError {
        try require(error == .invalidApp(reason: "The cache destination contains a symbolic link. Existing caches were preserved."), "Cache link rejection changed")
    }
}
func ignoredChange(_ root: URL, path: String) throws {
    let app = try bundle(root)
    let before = try legacy(app)
    try write("ignored-metadata", app.appendingPathComponent(path))
    try require(try legacy(app) == before, "Upstream ignored metadata changed key")
}
let cases: [(String, (URL) throws -> Void)] = [
    ("original_key_plain_tree", { root in
        let key = try legacy(bundle(root))
        try require(key.count == 64 && key.allSatisfy { "0123456789abcdef".contains($0) }, "Legacy key format")
    }),
    ("original_key_nested_tree", { root in
        let app = try bundle(root)
        try write("nested", app.appendingPathComponent("Frameworks/Synthetic.framework/Binary"))
        try fm.createDirectory(at: app.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        _ = try legacy(app)
    }),
    ("original_key_ignores_hidden", { root in
        try ignoredChange(root, path: ".hidden")
        try ignoredChange(root.appendingPathComponent("second"), path: ".DS_Store")
    }),
    ("original_key_ignores_signature", { root in
        try ignoredChange(root, path: "_CodeSignature/CodeResources")
    }),
    ("original_key_ignores_profile", { root in
        try ignoredChange(root, path: "embedded.mobileprovision")
    }),
    ("original_key_ignores_macosx", { root in
        try ignoredChange(root, path: "__MACOSX/Metadata")
    }),
    ("same_size_bytes_keep_legacy_key", { root in
        let app = try bundle(root)
        let before = try legacy(app)
        try write("WXYZ", app.appendingPathComponent("Executable"))
        try require(try legacy(app) == before, "Legacy algorithm unexpectedly verifies bytes")
    }),
    ("strict_compute_detects_same_size_bytes", { root in
        let app = try bundle(root)
        let before = AppBundleFingerprint.compute(for: app)
        try write("WXYZ", app.appendingPathComponent("Executable"))
        let after = AppBundleFingerprint.compute(for: app)
        try require(before != nil && after != nil && before != after, "Strict byte proof weakened")
    }),
    ("mode_change_keeps_legacy_key", { root in
        let app = try bundle(root)
        let file = app.appendingPathComponent("Executable")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let before = try legacy(app)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        try require(try legacy(app) == before, "Legacy algorithm unexpectedly verifies modes")
    }),
    ("strict_compute_detects_mode_change", { root in
        let app = try bundle(root)
        let file = app.appendingPathComponent("Executable")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let before = AppBundleFingerprint.compute(for: app)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let after = AppBundleFingerprint.compute(for: app)
        try require(before != nil && after != nil && before != after, "Strict mode proof weakened")
    }),
    ("new_payload_matches_original_copy", { root in
        let app = try bundle(root)
        let original = try cached(app, root.appendingPathComponent("OriginalApps"), original: true)
        let compatibility = try cached(app, root.appendingPathComponent("CompatibleApps"), original: false)
        try require(original.signature == compatibility.signature, "Cache signatures differ")
        try require(compatibility.targetFileURL.lastPathComponent == "App.app", "Payload path changed")
        try copied(app, original.targetFileURL)
        try copied(app, compatibility.targetFileURL)
    }),
    ("same_size_existing_legacy_cache_reused", { root in
        let app = try bundle(root)
        let originalRoot = root.appendingPathComponent("OriginalApps")
        let compatibilityRoot = root.appendingPathComponent("CompatibleApps")
        let original = try cached(app, originalRoot, original: true)
        let compatibility = try cached(app, compatibilityRoot, original: false)
        try write("WXYZ", app.appendingPathComponent("Executable"))
        let originalAgain = try cached(app, originalRoot, original: true)
        let compatibilityAgain = try cached(app, compatibilityRoot, original: false)
        try require(originalAgain.signature == original.signature, "Original legacy key changed")
        try require(compatibilityAgain.signature == compatibility.signature, "Compatibility legacy key changed")
        try require(originalAgain.signature == compatibilityAgain.signature, "Original and compatibility keys differ")
        try require(filesystemPath(originalAgain.targetFileURL) == filesystemPath(original.targetFileURL), "Original cache location changed")
        try require(filesystemPath(compatibilityAgain.targetFileURL) == filesystemPath(compatibility.targetFileURL), "Legacy cache location changed")
        for target in [original.targetFileURL, compatibility.targetFileURL] {
            try require(try Data(contentsOf: target.appendingPathComponent("Executable")) == Data("ABCD".utf8), "Existing bytes replaced")
            try require(AppBundleFingerprint.compute(for: target) != AppBundleFingerprint.compute(for: app), "Collision not exercised")
        }
    }),
    ("existing_partial_legacy_cache_reused", { root in
        let app = try bundle(root)
        let key = try legacy(app)
        for original in [true, false] {
            let apps = root.appendingPathComponent(original ? "OriginalApps" : "CompatibleApps")
            InstalledApp.appsDirectoryURL = apps
            let target = InstalledApp.payloadURL(forSignature: key)
            try write("retained", target.appendingPathComponent("PartialSentinel"))
            let result = try cached(app, apps, original: original)
            try require(result.signature == key, "Existing partial cache key changed")
            try require(filesystemPath(result.targetFileURL) == filesystemPath(target), "Existing partial cache location changed")
            try require(!fm.fileExists(atPath: target.appendingPathComponent("Executable").path), "Partial cache replaced")
        }
    }),
    ("prior_content_v1_cache_retained", { root in
        let app = try bundle(root)
        let strictKey = AppBundleFingerprint.compute(for: app)!
        let apps = root.appendingPathComponent("Apps")
        InstalledApp.appsDirectoryURL = apps
        let oldTarget = InstalledApp.payloadURL(forSignature: strictKey)
        try write("retained-old-cache", oldTarget.appendingPathComponent("Sentinel"))
        let before = AppBundleFingerprint.compute(for: oldTarget)
        let result = try cached(app, apps, original: false)
        try require(result.signature != strictKey && !result.signature.hasPrefix("content-v1-"), "Legacy namespace not restored")
        try require(AppBundleFingerprint.compute(for: oldTarget) == before, "Old content cache changed")
        try copied(app, result.targetFileURL)
    }),
    ("strict_host_copy_proof_preserved", { root in
        let host = try bundle(root)
        let copy = root.appendingPathComponent("HostCopy.app")
        let initial = AppBundleFingerprint.compute(for: host)
        let legacyBefore = try legacy(host)
        try fm.copyItem(at: host, to: copy)
        try require(initial != nil && AppBundleFingerprint.compute(for: copy) == initial, "Strict host copy proof failed")
        try write("WXYZ", host.appendingPathComponent("Executable"))
        try require(try legacy(host) == legacyBefore, "Same-size host mutation not exercised")
        try require(AppBundleFingerprint.compute(for: host) != initial, "Strict host mutation guard weakened")
        try require(AppBundleFingerprint.compute(for: copy) == initial, "Original copy changed")
    }),
    ("missing_source_matches_original_error", { root in
        let missing = root.appendingPathComponent("Missing.app")
        try require(OriginalAppBundleFingerprint.compute(for: missing) == nil, "Original accepts missing source")
        try require(AppBundleFingerprint.computeOriginalCacheKey(for: missing) == nil, "Compatibility accepts missing source")
        for original in [true, false] {
            do {
                _ = try cached(missing, root.appendingPathComponent(original ? "OriginalApps" : "CompatibleApps"), original: original)
                throw FixtureFailure.assertion("Missing source accepted")
            } catch let error as OperationError {
                try require(error == .invalidApp(reason: "Failed to compute app bundle fingerprint for 'Missing.app'"), "Original failure changed")
            }
        }
    }),
    ("foundation_copy_failure_propagates", { root in
        let app = try bundle(root)
        for original in [true, false] {
            let blocked = root.appendingPathComponent(original ? "OriginalBlocked" : "CompatibleBlocked")
            try write("not-a-directory", blocked)
            try require(cacheThrows(app, blocked, original: original), "Foundation error swallowed")
            try require(try Data(contentsOf: blocked) == Data("not-a-directory".utf8), "Blocked destination changed")
        }
    }),
    ("strict_compute_rejects_symbolic_link", { root in
        let app = try bundle(root)
        try fm.createSymbolicLink(atPath: app.appendingPathComponent("Link").path, withDestinationPath: "Executable")
        try require(AppBundleFingerprint.compute(for: app) == nil, "Strict link guard weakened")
    }),
    ("compatibility_copies_source_link_like_original", { root in
        let app = try bundle(root)
        try fm.createSymbolicLink(atPath: app.appendingPathComponent("Link").path, withDestinationPath: "Executable")
        _ = try legacy(app)
        for original in [true, false] {
            let result = try cached(app, root.appendingPathComponent(original ? "OriginalApps" : "CompatibleApps"), original: original)
            let link = result.targetFileURL.appendingPathComponent("Link")
            try require(try fm.destinationOfSymbolicLink(atPath: link.path) == "Executable", "Foundation link copy differs")
        }
    }),
    ("destination_escape_rejected", { root in
        let app = try bundle(root)
        let apps = root.appendingPathComponent("Apps")
        let outside = root.appendingPathComponent("OutsideApps")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: apps.appendingPathComponent("Payloads"), withDestinationURL: outside)
        do {
            _ = try cached(app, apps, original: false)
            throw FixtureFailure.assertion("Escaping cache path accepted")
        } catch let error as OperationError {
            try require(error == .invalidApp(reason: "The cache destination contains a symbolic link. Existing caches were preserved."), "Containment rejection changed")
        }
        try require(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "Containment check wrote outside Apps")
        // The retained guard is an intentional difference from original, scoped
        // entirely to this owned synthetic tree, not a system path.
        let original = try cached(app, apps, original: true)
        try require(filesystemPath(original.targetFileURL).hasPrefix(filesystemPath(outside) + "/"), "Escape fixture not exercised")
    }),
    ("destination_signature_symlink_rejected", { root in
        let app = try bundle(root)
        let apps = root.appendingPathComponent("Apps")
        let payloads = apps.appendingPathComponent("Payloads")
        let outside = root.appendingPathComponent("OutsideApps")
        try fm.createDirectory(at: payloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let key = try legacy(app)
        try fm.createSymbolicLink(at: payloads.appendingPathComponent(key), withDestinationURL: outside)
        try requireCacheLinkRejection(app, apps)
        try require(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "Signature ancestor wrote outside Apps")
    }),
    ("destination_dangling_symlink_rejected", { root in
        let app = try bundle(root)
        let apps = root.appendingPathComponent("Apps")
        let missing = root.appendingPathComponent("MissingOutsideApps")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let link = apps.appendingPathComponent("Payloads")
        try fm.createSymbolicLink(at: link, withDestinationURL: missing)
        try requireCacheLinkRejection(app, apps)
        try require(!fm.fileExists(atPath: missing.path), "Dangling cache link target was created")
        try require(try fm.destinationOfSymbolicLink(atPath: link.path) == missing.path, "Dangling cache link changed")
    }),
    ("destination_existing_symlink_rejected", { root in
        let app = try bundle(root)
        let apps = root.appendingPathComponent("Apps")
        let outside = root.appendingPathComponent("OutsideApps")
        try write("KEEP", outside.appendingPathComponent("Sentinel"))
        let before = AppBundleFingerprint.compute(for: outside)
        InstalledApp.appsDirectoryURL = apps
        let target = InstalledApp.payloadURL(forSignature: try legacy(app))
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: target, withDestinationURL: outside)
        try requireCacheLinkRejection(app, apps)
        try require(before != nil && AppBundleFingerprint.compute(for: outside) == before, "Existing target link payload changed")
    }),
    ("copy_helper_refuses_existing_destination", { root in
        let app = try bundle(root)
        let target = root.appendingPathComponent("Destination.app")
        // Model only the helper precondition: another destination already
        // exists when copy starts. This does not simulate a scheduled race.
        try write("KEEP", target.appendingPathComponent("Executable"))
        let before = AppBundleFingerprint.compute(for: target)
        let sourceBefore = AppBundleFingerprint.compute(for: app)
        var refused = false
        do { try fm.copyItem(at: app, to: target, shouldReplace: false) }
        catch { refused = true }
        try require(refused, "No-overwrite helper accepted an existing destination")
        try require(before != nil && AppBundleFingerprint.compute(for: target) == before, "Existing destination changed")
        try require(try Data(contentsOf: target.appendingPathComponent("Executable")) == Data("KEEP".utf8), "Existing bytes replaced")
        try require(sourceBefore != nil && AppBundleFingerprint.compute(for: app) == sourceBefore, "Source changed on refused copy")
    }),
    ("source_is_unchanged_after_cache_copy", { root in
        let app = try bundle(root)
        let before = AppBundleFingerprint.compute(for: app)
        let result = try cached(app, root.appendingPathComponent("Apps"), original: false)
        try require(before != nil && AppBundleFingerprint.compute(for: app) == before, "Source changed")
        try copied(app, result.targetFileURL)
    }),
]

let ownedRoot = fm.temporaryDirectory.appendingPathComponent("cache-compatibility-fixture-" + UUID().uuidString)
var results: [[String: Any]] = []
var failed: String?
do {
    try require(CommandLine.arguments.count == 2, "Usage: fixture output.json")
    try fm.createDirectory(at: ownedRoot, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: ownedRoot) } // Only this invocation's synthetic files.
    for (name, body) in cases {
        let root = ownedRoot.appendingPathComponent(name)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            try body(root)
            results.append(["name": name, "status": "pass"])
        } catch {
            // Cases own separate roots; report every case, then fail the suite.
            let failure = String(describing: error)
            results.append(["name": name, "status": "fail", "failure": failure])
            if failed == nil { failed = failure }
        }
    }
} catch { failed = String(describing: error) }
var report: [String: Any] = [
    "schema": "cache-compatibility-cases-v1", "status": failed == nil ? "pass" : "fail",
    "case_count": results.count, "cases": results.map { $0["name"] as! String },
    "case_results": results, "fake_only": true,
    "network_executed": false, "native_provider_executed": false,
    "foundation_crypto_real": true,
]
if let failure = failed { report["failure"] = failure }
do {
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    if CommandLine.arguments.count == 2 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
} catch { failed = "Unable to write runtime result" }
if failed != nil { print("CACHE_COMPATIBILITY_CASES_FAIL"); exit(1) }
print("CACHE_COMPATIBILITY_CASES_PASS")
