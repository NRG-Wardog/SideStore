#!/usr/bin/env python3
"""Project real onboarding/queue method bodies onto offline owned boundaries. Never runs Swift."""
from pathlib import Path
import argparse
import hashlib
import json
import re

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUTPUTS = ("CandidateOnboarding.swift", "BoundaryDoubles.swift", "RuntimeTests.swift")
SOURCE_PATHS = (
    "SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift",
    "SideStore/Core/Auth/AuthManager.swift",
    "SideStore/Core/Auth/DeveloperPortalProxy.swift",
    "SideStore/Core/Anisette/AnisetteProvider.swift",
    "SideStore/Utils/concurrency/TaskChainCoalescer.swift",
    "AltStore/AppDelegate.swift",
)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def extract(text, anchor):
    """Balanced Swift declaration extraction; strings/comments do not supply braces."""
    assert text.count(anchor) == 1, (anchor, text.count(anchor))
    start = text.index(anchor)
    brace = text.index("{", start)
    depth, i, quote, block, line_comment = 0, brace, None, 0, False
    while i < len(text):
        if line_comment:
            if text[i] == "\n": line_comment = False
        elif block:
            if text.startswith("/*", i): block += 1; i += 1
            elif text.startswith("*/", i): block -= 1; i += 1
        elif quote:
            if text[i] == "\\": i += 1
            elif text.startswith(quote, i): i += len(quote) - 1; quote = None
        elif text.startswith("//", i): line_comment = True; i += 1
        elif text.startswith("/*", i): block = 1; i += 1
        elif text.startswith('"""', i): quote = '"""'; i += 2
        elif text[i] == '"': quote = '"'
        elif text[i] == "{": depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0: return text[start:i + 1]
        i += 1
    raise AssertionError("Unclosed declaration: " + anchor)

def generate(output, sidestore_root=ROOT, sidesign_root=None):
    sidestore_root = Path(sidestore_root)
    sidesign_root = Path(sidesign_root or sidestore_root.parent / "SideSign")
    output.mkdir(parents=True, exist_ok=True)
    source = {p: (sidestore_root / p).read_text() for p in SOURCE_PATHS}
    remote_path = "Sources/Anisette/ILoaderRemoteAnisette.swift"
    source_remote = (sidesign_root / remote_path).read_text()
    extracts = []
    def take(path, anchor, text=None, prefix="SideStore"):
        original = text if text is not None else source[path]
        result = extract(original, anchor)
        start = original.index(result)
        extracts.append({"source": prefix + "/" + path, "anchor": anchor,
                         "first_line": original[:start].count("\n") + 1,
                         "sha256": digest(result.encode())})
        return result
    parts = ["import Foundation\n"]
    for anchor in ["public enum ILoaderRemoteEndpoint:", "public enum ILoaderRemoteError:",
                   "public enum ILoaderRemoteAuthentication {", "public final class ILoaderRemoteAuthenticationContext:"]:
        parts.append(re.sub(r"\bURLSession\b", "FakeSession", take(remote_path, anchor, source_remote, "SideSign")))
    service = "AltStore/AppDelegate.swift"
    for anchor in ["enum V3AuthReadStampPolicy {", "enum V3AuthSessionCoalescerKey {",
                   "final class V3AuthIdentityStampState:", "enum V3AuthIdentityBindingPolicy {"]:
        parts.append(take(service, anchor))
    parts.append(take("SideStore/Utils/concurrency/TaskChainCoalescer.swift", "actor TaskChainCoalescer {"))
    provider = take("SideStore/Core/Anisette/AnisetteProvider.swift", "static func fetch(handler:")
    parts.append("enum AnisetteProvider {\n" + provider + "\n" +
                 "private static func fetchRemote(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {\n" +
                 "  FixtureLog.shared.record(\"legacyRemoteFetch\"); return AnisetteData(route: \"legacyRemote\")\n}\n}")
    auth_path = "SideStore/Core/Auth/AuthManager.swift"
    members = []
    for anchor in ["var v3IdentityGeneration:", "var v3IdentityStamp:", "var v3IdentityIsStable:",
                   "func v3BeginIdentityTransition()", "func v3CompleteIdentityTransition()",
                   "func v3ReplaceSession(", "func v3InstallSessionIfCurrent(",
                   "func v3CachedSessionMatchesCurrentRoute(", "func v3AdvanceIdentityGeneration()",
                   "var authenticationSnapshot:", "public func getAuthenticatedSession()"]:
        members.append(take(auth_path, anchor))
    parts.append("public final class AuthManager: @unchecked Sendable {\n" +
                 "public static let shared = AuthManager()\nprivate let v3IdentityStampState = V3AuthIdentityStampState()\n" +
                 "public var session: ALTAppleAPISession? { didSet { FixtureLog.shared.record(\"sessionInstall\") } }\n" +
                 "\n".join(members) + "\n}")
    proxy_path = "SideStore/Core/Auth/DeveloperPortalProxy.swift"
    proxy = [take(proxy_path, a) for a in ["private struct BoundSession {", "private func getBoundSession()",
             "private func verifyCurrent(", "private func awaitBound<T>(", "public func fetchTeams(for account:"]]
    parts.append("public final class DeveloperPortalProxy: @unchecked Sendable {\n" +
                 "public static let shared = DeveloperPortalProxy()\n" + "\n".join(proxy) + "\n}")
    op_path = "SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift"
    parts.append(take(op_path, "struct SignInResult {"))
    operation = [take(op_path, a) for a in ["private func v3RemoteContextSnapshot()", "override func cancel()",
                 "override func execute(parentProgress:", "private func getAnisetteData()",
                 "private func signIn(appleID:", "private func provisioningLoop(account:",
                 "private func finalizeAuthentication(result:", "private func fetchTeam(for account:"]]
    parts.append("final class SignInOperation: FixtureOperationBase, @unchecked Sendable {\n" +
                 (HERE / "OperationBoundaries.swift").read_text() + "\n" + "\n".join(operation) + "\n}")
    contents = {"CandidateOnboarding.swift": "\n\n".join(parts) + "\n",
                "BoundaryDoubles.swift": (HERE / "BoundaryDoubles.swift").read_text(),
                "RuntimeTests.swift": (HERE / "RuntimeTests.swift").read_text()}
    for name, content in contents.items(): (output / name).write_text(content)
    inputs = {"SideStore/" + p: digest((sidestore_root / p).read_bytes()) for p in SOURCE_PATHS}
    inputs["SideSign/" + remote_path] = digest((sidesign_root / remote_path).read_bytes())
    for path in sorted(HERE.rglob("*")):
        if path.is_file() and "__pycache__" not in path.parts:
            inputs["SideStore/" + str(path.relative_to(ROOT))] = digest(path.read_bytes())
    evidence = {"schema": "iloader-onboarding-scope-source-evidence-v1", "inputs": inputs,
                "outputs": {name: digest((output / name).read_bytes()) for name in OUTPUTS},
                "output_closure": list(OUTPUTS), "production_extracts": extracts,
                "boundary_replacements": ["URLSession type -> inert FakeSession; no HTTP or native provider",
                    "Apple authentication and portal response -> synthetic in-memory boundary",
                    "Keychain, defaults and version lookup -> locked in-memory doubles",
                    "SignInOperation pipeline orchestration and certificate-finalization work -> minimal owned drivers; production phase wrappers, execute/cancel and fetchTeam retained",
                    "Diagnostic collectors -> inert typed boundary; diagnostic validators are not tested by this suite"],
                "network": False, "native_provider": False, "swift_executed": False}
    (output / "source-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    return evidence

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--sidestore-root", type=Path, default=ROOT)
    parser.add_argument("--sidesign-root", type=Path)
    args = parser.parse_args()
    evidence = generate(args.output_dir, args.sidestore_root, args.sidesign_root)
    print(json.dumps({"generated": len(evidence["outputs"]), "swift_executed": False}))
