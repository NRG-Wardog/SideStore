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
    "OriginalAppBundleFingerprint.swift": "215f5c16cd4d2a5ecddd8a1983e22e3a9851908159b1fb272260c1eb8cfed2e6",
    "OriginalCacheAppOperation.swift": "c1b7b1b0c3a08f1c5501461561a299b5dc1570e54c241c3c847c64c992b418da",
}
CACHE_START = "    @discardableResult\n    static func cachePayload("
GUARD = '''        // Retain containment and no-overwrite copy boundaries while restoring
        // upstream cache key/reuse behavior. Caches are not reset or pruned.
        let rootPath = InstalledApp.appsDirectoryURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard targetFileURL.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(rootPath) else {
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

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    source = {key: (args.candidate_root / path).read_text() for key, path in PRODUCTION.items()}
    for key, expected in PINNED.items():
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
    assert compatibility_cache.replace(GUARD, "") == expected_cache, "Non-approved cache-flow deviation"
    # Pin everything outside cachePayload, especially execute and disabled payload pruning.
    untouched_cache = source["cache"].replace(compatibility_cache, "<CACHE_PAYLOAD>")
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
    boundary = '''import Foundation
import CryptoKit
import Darwin
// Inert boundary only: no CoreData, app group, credentials, device or network provider.
enum OperationError: Error, Equatable { case invalidApp(reason: String) }
func debugLog(_ message: String) {}
enum SideStore { static func debugLog(_ message: String) {} }
class InstalledApp {
    static var appsDirectoryURL = URL(fileURLWithPath: "/unused-fixture-root")
'''
    generated = "\n\n".join([
        boundary + payload_directory + "\n" + payload_url + "\n}",
        "extension FileManager {\n" + copy_method + "\n}",
        source["fingerprint"],
        original_fp.replace("public enum AppBundleFingerprint", "public enum OriginalAppBundleFingerprint", 1),
        "enum CacheAppOperation {\n" + compatibility_cache + "\n}",
        "enum OriginalCacheAppOperation {\n" + original_cache.replace("AppBundleFingerprint.compute(", "OriginalAppBundleFingerprint.compute(") + "\n}",
        (HERE / "Cases.swift").read_text(),
    ]) + "\n"
    cases = re.findall(r'^    \("([a-z0-9_]+)", \{', (HERE / "Cases.swift").read_text(), re.M)
    assert len(cases) == 22 and len(set(cases)) == len(cases), cases
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "cache-compatibility.swift").write_text(generated)
    receipt = {
        "schema": "cache-compatibility-source-v1",
        "status": "STATIC_PASS_GENERATED_NOT_COMPILED_NOT_RUN",
        "swift_compiled": False, "swift_executed": False,
        "native_provider_executed": False, "network_executed": False,
        "inputs_sha256": {"SideStore/" + path: digest(source[key].encode()) for key, path in PRODUCTION.items()},
        "fixture_inputs_sha256": {name: digest((HERE / name).read_bytes()) for name in ["generate_fixture.py", "Cases.swift", *ORIGINAL_PINS]},
        "generated_sha256": digest(generated.encode()),
        "expected_case_names": cases, "expected_case_count": len(cases),
        "strict_compute_byte_identical": True, "host_pipeline_byte_identical": True,
        "execute_and_pruning_byte_identical": True, "original_cache_key_byte_identical_except_symbol": True,
        "original_cache_flow_except_retained_safety_boundaries_symbol_and_logs": True,
        "copy_helper_overwrite_disabled": True,
        "limitations": ["Synthetic real-Foundation macOS fixture, not an iOS/device result.",
                       "Legacy cache reuse intentionally does not establish payload content integrity.",
                       "No concurrency, permission-restriction, storage-exhaustion or real IPA install success claimed."],
    }
    (args.output / "sources.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print("CACHE_COMPATIBILITY_SOURCE_PASS_GENERATED_NOT_RUN")

if __name__ == "__main__":
    main()
