#!/usr/bin/env python3
"""Generate one source-owned Foundation/CryptoKit cache-policy fixture, without executing it."""
import argparse
import hashlib
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
PRODUCTION = {
    "fingerprint": "SideStore/Utils/common/AppBundleFingerprint.swift",
    "cache": "SideStore/Core/Operations/PipelineOperations/CacheAppOperation.swift",
    "host": "SideStore/Core/Operations/PipelineRunner.swift",
    "copy": "AltStore/Extensions/FileManager+URLs.swift",
    "installed": "AltStore/Core/Model/InstalledApp.swift",
}
PINNED = {
    "host": "4e139e9d643f59fb6990fdc246ecfa9aaa32acbc4595ea839b38bd9c4199522e",
    "copy": "14c835a0a4d49069baa17b2dcfd3e489879c8880385748aa00acf27c22177bf0",
    "installed": "728fcd4e0708d632317e0f786bf63165490cf3203ec2fcbf91b609c9f205ad05",
}
STRICT_FINGERPRINT_SHA256 = "c73ec2bfa43d56be919dac7fb824c0dc62a46f1830569d2b42697b52cd64ff67"
ORIGINAL_PINS = {
    "BeforeCanonicalAnchorCacheAppOperation.swift": "c64a34702920a946be4995be713f8c02f929fffcbfc4a196a245be2610b4417b",
    "OriginalAppBundleFingerprint.swift": "215f5c16cd4d2a5ecddd8a1983e22e3a9851908159b1fb272260c1eb8cfed2e6",
    "OriginalCacheAppOperation.swift": "c1b7b1b0c3a08f1c5501461561a299b5dc1570e54c241c3c847c64c992b418da",
}
CACHE_START = "    @discardableResult\n    static func cachePayload("
TARGET_ANCHOR = '''        // Resolve the trusted, existing Apps root once. A missing descendant
        // cannot reliably resolve aliases in that root on its own.
        let appsDirectoryURL = InstalledApp.appsDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let targetFileURL = appsDirectoryURL.appendingPathComponent("Payloads")
            .appendingPathComponent(signature).appendingPathComponent("App.app")
'''
GUARD = '''        // Retain containment and no-overwrite copy boundaries while restoring
        // upstream cache key/reuse behavior. Caches are not reset or pruned.
        // Resolving a nonexistent App.app may leave an existing symlink ancestor
        // unresolved. Inspect only the three cache components below Apps, in
        // order, without following their final entry (including dangling links).
        let cachePathComponents = [
            targetFileURL.deletingLastPathComponent().deletingLastPathComponent(),
            targetFileURL.deletingLastPathComponent(),
            targetFileURL
        ]
        for componentURL in cachePathComponents {
            var fileStatus = stat()
            let status = componentURL.path.withCString { lstat($0, &fileStatus) }
            if status == 0 {
                guard (fileStatus.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) else {
                    throw OperationError.invalidApp(reason: "The cache destination contains a symbolic link. Existing caches were preserved.")
                }
            } else {
                let errorCode = errno
                guard errorCode == ENOENT else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode), userInfo: nil)
                }
            }
        }
        let rootPath = appsDirectoryURL.path + "/"
        guard targetFileURL.standardizedFileURL.path.hasPrefix(rootPath) else {
            throw OperationError.invalidApp(reason: "The cache destination is outside the app cache. Existing caches were preserved.")
        }
'''

def digest(data):
    return hashlib.sha256(data).hexdigest()

def extract(text, marker):
    assert text.count(marker) == 1, marker
    start = text.index(marker)
    end = text.index("{", start) + 1
    depth = 1
    # These pinned source functions contain no literal/comment braces.
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

# The original reviewed host change is the opt-in ReuseMain registry guard.
# A separately hash-bound exact cold-VPN delta is projected before this proof.
# Remove this exact insertion, then retain the original whole-file fingerprint.
REVIEWED_REUSE_MAIN_INSERTION = '            context.validatedReuseMain = app.useMainProfile && V3ValidatedReuseMainRegistry.contains(\n                original: app.bundleIdentifier, resigned: app.resignedBundleIdentifier,\n                profileUUID: context.targetAppBundle?.provisioningProfile?.uuid,\n                generation: context.targetAppBundle?.infoPlist[V3ValidatedReuseMainRegistry.generationKey] as? String)\n            if app.useMainProfile && !context.validatedReuseMain &&\n                V3ValidatedReuseMainRegistry.hasAssociation(original: app.bundleIdentifier, resigned: app.resignedBundleIdentifier) {\n                throw OperationError.invalidParameters("The cached app no longer matches its validated ReuseMain installation. Reinstall interactively instead of silently switching signing strategies.")\n            }\n'
REVIEWED_REUSE_MAIN_SHA256 = 'cd11ece003588f8aeac44bab28c1d3797c11dfb5e23e9facd7a947c8a7057af6'


REVIEWED_COLD_VPN_DELTA_SHA256 = '7c10bae55feec2ebaf8f70eddc1c0a470804a5e5d0bb6cf3442c91ec890ff7e9'


def project_reviewed_cold_vpn(text):
    """Reverse only exact, uniquely occurring reviewed hunks, never arbitrary code."""
    raw = (HERE / 'reviewed-cold-vpn-host-delta.json').read_bytes()
    assert digest(raw) == REVIEWED_COLD_VPN_DELTA_SHA256, 'Reviewed cold-VPN delta changed'
    receipt = json.loads(raw)
    if '// V3_OWNED_REFRESH_READINESS_WAIT_V1:' not in text:
        return text, False
    for hunk in receipt['hunks']:
        assert text.count(hunk['after']) == 1, 'Changed, absent or duplicate cold-VPN hunk'
        text = text.replace(hunk['after'], hunk['before'], 1)
    assert digest(text.encode()) == receipt['before_sha256'], 'Changes outside reviewed cold-VPN hunks'
    return text, True


def verify_host_preservation(text):
    text, cold_vpn = project_reviewed_cold_vpn(text)
    if digest(text.encode()) == PINNED['host']:
        return {'host_pipeline_byte_identical': True}
    assert text.count(REVIEWED_REUSE_MAIN_INSERTION) == 1, 'Unreviewed host pipeline insertion'
    normalized = text.replace(REVIEWED_REUSE_MAIN_INSERTION, '', 1)
    assert digest(normalized.encode()) == PINNED['host'], 'Host pipeline changed beyond reviewed ReuseMain guard'
    if cold_vpn:
        return {'host_pipeline_byte_identical': False,
                'host_pipeline_except_reviewed_cold_vpn_and_reuse_main_byte_identical': True,
                'reviewed_cold_vpn_delta_sha256': REVIEWED_COLD_VPN_DELTA_SHA256,
                'reviewed_reuse_main_insertion_sha256': REVIEWED_REUSE_MAIN_SHA256}
    return {'host_pipeline_byte_identical': False,
            'host_pipeline_except_reviewed_reuse_main_byte_identical': True,
            'reviewed_reuse_main_insertion_sha256': REVIEWED_REUSE_MAIN_SHA256}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    source = {key: (args.candidate_root / path).read_text() for key, path in PRODUCTION.items()}
    host_proof = verify_host_preservation(source['host'])
    for key, expected in PINNED.items():
        if key == 'host':
            continue
        assert digest(source[key].encode()) == expected, "Changed retained input: " + key
    references = {name: (HERE / name).read_text() for name in ORIGINAL_PINS}
    for name, expected in ORIGINAL_PINS.items():
        assert digest(references[name].encode()) == expected, "Changed upstream reference: " + name

    original_fp = references["OriginalAppBundleFingerprint.swift"]
    original_method = extract(original_fp, "    public static func compute(for bundleURL: URL) -> String?")
    compatibility_method = extract(source["fingerprint"], "    public static func computeOriginalCacheKey(for bundleURL: URL) -> String?")
    assert compatibility_method.replace("func computeOriginalCacheKey(", "func compute(", 1) == original_method
    begin = source["fingerprint"].index("\n    // ORIGINAL_CACHE_COMPATIBILITY_BEGIN")
    end = source["fingerprint"].index("    // ORIGINAL_CACHE_COMPATIBILITY_END\n") + len("    // ORIGINAL_CACHE_COMPATIBILITY_END\n")
    strict_original = source["fingerprint"][:begin] + source["fingerprint"][end:]
    assert digest(strict_original.encode()) == STRICT_FINGERPRINT_SHA256, "Strict host verifier changed"

    original_cache = extract(references["OriginalCacheAppOperation.swift"], CACHE_START)
    compatibility_cache = extract(source["cache"], CACHE_START)
    assert compatibility_cache.count(GUARD) == 1, "Destination containment missing/changed"
    expected_cache = original_cache.replace("AppBundleFingerprint.compute(", "AppBundleFingerprint.computeOriginalCacheKey(")
    expected_cache = "\n".join(line for line in expected_cache.splitlines() if "SideStore.debugLog(" not in line)
    expected_cache = expected_cache.replace("to: targetFileURL, shouldReplace: true)", "to: targetFileURL, shouldReplace: false)")
    expected_cache = expected_cache.replace("        let targetFileURL = InstalledApp.payloadURL(forSignature: signature)\n", TARGET_ANCHOR)
    assert compatibility_cache.count("InstalledApp.appsDirectoryURL") == 1
    assert compatibility_cache.count("resolvingSymlinksInPath()") == 1
    assert compatibility_cache.replace(GUARD, "") == expected_cache, "Non-approved cache-flow deviation"
    # Pin everything outside cachePayload, especially execute and disabled payload pruning.
    assert source["cache"].count("import Foundation\nimport Darwin\n") == 1, "Production Darwin import missing"
    untouched_cache = source["cache"].replace("import Foundation\nimport Darwin\n", "import Foundation\n", 1).replace(compatibility_cache, "<CACHE_PAYLOAD>")
    assert digest(untouched_cache.encode()) == "ce90052574e4198c71cae64ee0d93ac76adcf3e3cab561eed3960d8cb21a1f53", "Execute/pruning changed"
    assert "AppBundleFingerprint.computeOriginalCacheKey" not in source["host"]
    assert source["host"].count("AppBundleFingerprint.compute(for:") == 5
    actual_calls = []
    for path in (args.candidate_root / "SideStore").rglob("*.swift"):
        if "AppBundleFingerprint.computeOriginalCacheKey(" in path.read_text():
            actual_calls.append(path.relative_to(args.candidate_root).as_posix())
    assert actual_calls == [PRODUCTION["cache"]], "Cache-only helper escaped its intended caller"

    copy_method = extract(source["copy"], "    func copyItem(at sourceURL: URL, to destinationURL: URL, shouldReplace: Bool) throws")
    payload_directory = extract(source["installed"], "    class func payloadDirectoryURL(forSignature signature: String) -> URL")
    payload_url = extract(source["installed"], "    class func payloadURL(forSignature signature: String) -> URL")
    production_root_getter = extract(source["installed"], "    class var appsDirectoryURL: URL")
    before_cache = extract(references["BeforeCanonicalAnchorCacheAppOperation.swift"], CACHE_START)
    boundary = '''import Foundation
import CryptoKit
import Darwin
// Inert boundary only: no CoreData, app group, credentials, device or network provider.
enum OperationError: Error, Equatable { case invalidApp(reason: String) }
func debugLog(_ message: String) {}
enum SideStore { static func debugLog(_ message: String) {} }
enum AliasFixtureBoundary {
    static var baseDirectoryURL = URL(fileURLWithPath: "/unused-fixture-base")
}
extension FileManager {
    var altstoreSharedDirectory: URL? { AliasFixtureBoundary.baseDirectoryURL }
    var applicationSupportDirectory: URL { AliasFixtureBoundary.baseDirectoryURL }
}
class ProductionShapeInstalledApp {
''' + production_root_getter + '''
}
class InstalledApp {
    static var fixtureRootOverride: URL? = URL(fileURLWithPath: "/unused-fixture-root")
    class var appsDirectoryURL: URL {
        get { fixtureRootOverride ?? ProductionShapeInstalledApp.appsDirectoryURL }
        set { fixtureRootOverride = newValue }
    }
'''
    generated = "\n\n".join([
        boundary + payload_directory + "\n" + payload_url + "\n}",
        "extension FileManager {\n" + copy_method + "\n}",
        source["fingerprint"],
        original_fp.replace("public enum AppBundleFingerprint", "public enum OriginalAppBundleFingerprint", 1),
        "enum CacheAppOperation {\n" + compatibility_cache + "\n}",
        "enum BeforeCanonicalAnchorCacheAppOperation {\n" + before_cache + "\n}",
        "enum OriginalCacheAppOperation {\n" + original_cache.replace("AppBundleFingerprint.compute(", "OriginalAppBundleFingerprint.compute(") + "\n}",
        (HERE / "Cases.swift").read_text(),
    ]) + "\n"
    cases = re.findall(r'^    \("([a-z0-9_]+)", \{', (HERE / "Cases.swift").read_text(), re.M)
    assert len(cases) == 26 and len(set(cases)) == len(cases), cases
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "cache-compatibility.swift").write_text(generated)
    receipt = {
        "schema": "cache-compatibility-source-v1",
        "status": "STATIC_PASS_GENERATED_NOT_COMPILED_NOT_RUN",
        "swift_compiled": False, "swift_executed": False,
        "native_provider_executed": False, "network_executed": False,
        "inputs_sha256": {"SideStore/" + path: digest(source[key].encode()) for key, path in PRODUCTION.items()},
        "fixture_inputs_sha256": {name: digest((HERE / name).read_bytes()) for name in ["generate_fixture.py", "reviewed-cold-vpn-host-delta.json", "Cases.swift", *ORIGINAL_PINS]},
        "generated_sha256": digest(generated.encode()),
        "expected_case_names": cases, "expected_case_count": len(cases),
        "strict_compute_byte_identical": True, **host_proof,
        "execute_and_pruning_byte_identical": True, "original_cache_key_byte_identical_except_symbol": True,
        "original_cache_flow_except_retained_safety_boundaries_symbol_and_logs": True,
        "copy_helper_overwrite_disabled": True,
        "cache_components_lstat_no_follow": True, "production_darwin_import_present": True,
        "trusted_apps_root_canonicalized_once": True, "alias_regression_uses_production_getter": True,
        "alias_before_reference_byte_identical": True,
        "production_apps_getter_sha256": digest(production_root_getter.encode()),
        "limitations": ["Synthetic real-Foundation macOS fixture, not an iOS/device result.",
                       "Legacy cache reuse intentionally does not establish payload content integrity.",
                       "No concurrency, permission-restriction, storage-exhaustion or real IPA install success claimed."],
    }
    (args.output / "sources.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print("CACHE_COMPATIBILITY_SOURCE_PASS_GENERATED_NOT_RUN")

if __name__ == "__main__":
    main()
