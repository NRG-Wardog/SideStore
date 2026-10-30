#!/usr/bin/env python3
"""Project current source bytes into offline remote-identity regressions, never execute Swift."""
import argparse
import hashlib
import json
import re
from pathlib import Path

PACKAGE = "SideStore/.ci/remote-identity-reuse"
SOURCE_PATHS = {
    "diagnostic_policy": "SideStore/SideStore/Core/Anisette/V3DiagnosticProviderSequence.swift",
    "keychain": "SideStore/AltStore/Core/Components/Keychain.swift",
    "provider": "SideStore/SideStore/Core/Anisette/AnisetteProvider.swift",
    "auth": "SideStore/SideStore/Core/Auth/AuthManager.swift",
    "proxy": "SideStore/SideStore/Core/Auth/DeveloperPortalProxy.swift",
    "signin": "SideStore/SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift",
    "pipeline": "SideStore/SideStore/Core/Operations/PipelineRunner.swift",
    "coalescer": "SideStore/SideStore/Utils/concurrency/TaskChainCoalescer.swift",
    "remote": "SideStore/Dependencies/SideSign/Sources/Anisette/ILoaderRemoteAnisette.swift",
    "portal": "SideStore/Dependencies/SideSign/Sources/DeveloperPortal/DeveloperPortalAPI.swift",
    "service": "SideStore/AltStore/AppDelegate.swift",
    "profiles": "SideStore/SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift",
    "appids": "SideStore/SideStore/Core/Operations/StandaloneOperations/SyncAppIDsOperation.swift",
    "appmanager": "SideStore/AltStore/Managing Apps/AppManager.swift",
    "background": "SideStore/SideStore/Core/Operations/StandaloneOperations/BackgroundRefreshAppsOperation.swift",
}
CANDIDATE_ONLY_SOURCES = frozenset({"diagnostic_policy"})
SUPPORT_PATHS = ("generate_fixture.py", "BoundaryDoubles.swift", "CoreCases.swift", "RuntimeDoubles.swift",
                 "RuntimeCases.swift", "run.sh", "README.md", "test_generator.py")


def sha256(raw):
    return hashlib.sha256(raw).hexdigest()


def read(root, relative):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("Input root must be a real directory")
    current = root
    for part in Path(relative).parts:
        current /= part
        if current.is_symlink():
            raise ValueError("Symlink input refused: " + relative)
    if not current.is_file():
        raise ValueError("Missing input: " + relative)
    return current.read_bytes()


def extract(text, anchor):
    """Balanced declaration; do not count braces inside comments or quoted strings."""
    if text.count(anchor) != 1:
        raise ValueError("Expected unique source declaration: " + anchor)
    start = text.index(anchor)
    index = text.index("{", start)
    depth, block, quote, line = 0, 0, None, False
    while index < len(text):
        if line:
            if text[index] == "\n":
                line = False
        elif block:
            if text.startswith("/*", index):
                block += 1
                index += 1
            elif text.startswith("*/", index):
                block -= 1
                index += 1
        elif quote:
            if text[index] == "\\":
                index += 1
            elif text.startswith(quote, index):
                index += len(quote) - 1
                quote = None
        elif text.startswith("//", index):
            line = True
            index += 1
        elif text.startswith("/*", index):
            block = 1
            index += 1
        elif text.startswith('"""', index):
            quote = '"""'
            index += 2
        elif text[index] == '"':
            quote = '"'
        elif text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
        index += 1
    raise ValueError("Unterminated source declaration: " + anchor)


def marked(text, name):
    begin, end = "// " + name + "_BEGIN", "// " + name + "_END"
    if text.count(begin) != 1 or text.count(end) != 1:
        raise ValueError("Missing/duplicate source span: " + name)
    first = text.index(begin)
    last = text.index(end, first) + len(end)
    return text[first:last]


def runtime_projection(sources, spans):
    def take(name, anchor=None, marker=None):
        text = sources[name].decode()
        value = extract(text, anchor) if anchor else marked(text, marker)
        spans.append({"source": SOURCE_PATHS[name], "anchor": anchor or marker,
                      "first_line": text[:text.index(value)].count("\n") + 1,
                      "sha256": sha256(value.encode())})
        return value

    parts = ["import Foundation\nimport CryptoKit\n"]
    for anchor in ["public enum ILoaderRemoteEndpoint:", "public enum ILoaderRemoteError:",
                   "public enum ILoaderRemoteAuthentication {", "public struct ILoaderRemoteProfile:",
                   "public struct ILoaderRemoteState:"]:
        parts.append(take("remote", anchor))
    context = take("remote", "public final class ILoaderRemoteAuthenticationContext:")
    if context.count("URLSession") != 1:
        raise ValueError("Remote session type injection changed")
    parts.append(context.replace("URLSession", "FixtureRemoteSession"))
    for anchor in ["enum V3DiagnosticProvider:", "enum V3DiagnosticProviderRoute {"]:
        parts.append(take("diagnostic_policy", anchor))
    parts.append(take("provider", marker="V3_REMOTE_IDENTITY_RUNTIME"))
    parts.append(take("provider", "private actor ILoaderAttemptAnisetteSource"))
    parts.append("enum AnisetteProvider {\n" + take("provider", "static func fetch(handler:") +
                 "\nprivate static func fetchRemote(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {\n" +
                 "throw FixtureFailure.nativeBoundary\n}\n}")
    for anchor in ["final class V3AuthIdentityStampState:", "enum V3AuthReadStampPolicy {",
                   "enum V3AuthSessionCoalescerKey {", "enum V3AuthIdentityBindingPolicy {"]:
        parts.append(take("service", anchor))
    parts.append(take("coalescer", "actor TaskChainCoalescer {"))
    auth_members = [take("auth", anchor) for anchor in [
        "var v3IdentityGeneration:", "var v3IdentityStamp:", "var v3IdentityIsStable:",
        "func v3BeginIdentityTransition()", "func v3CompleteIdentityTransition()",
        "func v3AdvanceIdentityGeneration()", "func v3InstallSessionIfCurrent(",
        "var authenticationSnapshot:", "public func getAuthenticatedSession()"]]
    parts.append("public final class AuthManager: @unchecked Sendable {\n" +
                 "public static let shared = AuthManager()\n" +
                 "private let v3IdentityStampState = V3AuthIdentityStampState()\n" +
                 "public var session: ALTAppleAPISession?\n" + "\n".join(auth_members) + "\n}")
    proxy_members = [take("proxy", anchor) for anchor in ["private struct BoundSession {",
        "private func getBoundSession()", "private func verifyCurrent(", "private func awaitBound<T>(",
        "private func getBoundTeam(", "public func fetchCertificates(team:"]]
    parts.append("public final class DeveloperPortalProxy: @unchecked Sendable {\n" +
        "public static let shared = DeveloperPortalProxy()\n" + "\n".join(proxy_members) +
        "\nprivate func owner(for team: ALTTeam, context: BoundSession) async throws -> String? { team.account?.appleID }\n}")
    parts.append("@MainActor final class FixturePortalDispatcher {\n" +
        take("service", "private func accountScopedRead(") +
        "\nfunc fetchCertificates() async throws -> [String: Any] {\n" +
        "try await accountScopedRead(\"certificates\") { try await DeveloperPortalProxy.shared.fetchCertificates(team: .fixture) }\n}\n}")
    pipeline_anchor = ("func performSingleOperation(_ operation: AppOperation,\n"
                       "                                handler: PipelineExecutionHandler,\n"
                       "                                context: StandaloneOperationContext,")
    queued = take("pipeline", pipeline_anchor)
    queue_anchor = "group.activeTask = Task.detached {\n"
    if queued.count(queue_anchor) != 1:
        raise ValueError("Actual detached boundary changed")
    queued = queued.replace(queue_anchor, queue_anchor + "            await FixturePipelineBoundary.waitIfConfigured()\n")
    parts.append("final class PipelineRunner: @unchecked Sendable {\n@discardableResult\n" +
        queued + "\n@discardableResult\n" +
        take("pipeline", "func perform(_ operations: [AppOperation],") +
        "\nprivate func performUsingAdmittedRoute(_ operations: [AppOperation], handler: PipelineExecutionHandler, group: RefreshGroup) async throws -> RefreshGroup {\n" +
        "let session = try await AuthManager.shared.getAuthenticatedSession()\n" +
        "_ = try await DeveloperPortalProxy.shared.fetchCertificates(team: .fixture)\n" +
        "group.results = [operations[0].bundleIdentifier: .success(InstalledApp(anisette: session.anisetteData))]\n" +
        "return group\n}\n}")
    outer = take("appmanager", "func refresh(_ installedApps:")
    outer_anchor = "actualGroup.activeTask = Task.detached {\n"
    if outer.count(outer_anchor) != 1:
        raise ValueError("Actual outer refresh detached boundary changed")
    outer = outer.replace(outer_anchor, outer_anchor + "            await FixturePipelineBoundary.waitIfConfigured()\n")
    parts.append("final class AppManager: @unchecked Sendable {\n" +
        "static let shared = AppManager()\nprivate let pipelineRunner = PipelineRunner()\n" +
        "func getValidDbContext(_ context: NSManagedObjectContext? = nil) -> NSManagedObjectContext { context ?? NSManagedObjectContext() }\n" +
        "func makePipelineHandler(presentingViewController: UIViewController?) -> PipelineExecutionHandler { PipelineExecutionHandler() }\n" +
        "@discardableResult\n" + outer + "\n}")
    parts.append("extension BackgroundRefreshAppsOperation {\n" +
        take("background", "private func refresh(_ apps:") +
        "\nfunc runFixture(_ apps: [InstalledApp]) async throws -> [String: Result<InstalledApp, Error>] { try await refresh(apps, runID: \"11111111-2222-3333-4444-555555555555\") }\n}")
    projected = "\n\n".join(parts)
    validate_diagnostic_policy_closure(projected, sources["diagnostic_policy"].decode())
    return projected.encode() + b"\n"


def validate_diagnostic_policy_closure(projected, production):
    # Production provider dispatch now references these policy types. Require
    # their exact declarations once, never an ad-hoc fixture replacement.
    for anchor in ["enum V3DiagnosticProvider:", "enum V3DiagnosticProviderRoute {"]:
        if extract(projected, anchor) != extract(production, anchor):
            raise ValueError("Diagnostic policy declaration differs from production: " + anchor)
    required = set(re.findall(r"\bV3Diagnostic\w+", projected))
    if required != {"V3DiagnosticProvider", "V3DiagnosticProviderRoute"}:
        raise ValueError("Unresolved diagnostic policy dependency: " + repr(sorted(required)))


def generate(candidate, baseline, output):
    candidate, baseline, output = map(Path, (candidate, baseline, output))
    source = {name: read(candidate, path) for name, path in SOURCE_PATHS.items()}
    previous = {name: read(baseline, path) for name, path in SOURCE_PATHS.items()
                if name not in CANDIDATE_ONLY_SOURCES}
    support = {path: read(candidate, PACKAGE + "/" + path) for path in SUPPORT_PATHS}
    keychain = source["keychain"].decode()
    spans = []
    # Complement runtime projections with narrow wiring assertions. These are explicitly
    # source checks, not claims that the full onboarding/headless pipeline ran.
    texts = {name: raw.decode() for name, raw in source.items()}
    terminal = extract(texts["service"], "private func runLoginPipeline(id: String)")
    deferred = terminal.index("if operation.v3DidDeferDeviceSetup")
    commit = "try V3RemoteIdentityContinuity.commit(result.v3RemoteIdentityHandoff, credentials: credentials)"
    wiring = {
        "signin_returns_actual_attempt_handoff": "result.v3RemoteIdentityHandoff = try await attempt.handoff()" in texts["signin"],
        "signin_credential_transactions_record_selected_route": texts["signin"].count("remoteProvider: self.v3RemoteContextSnapshot() != nil") == 3,
        "both_verified_terminal_paths_commit_identity": terminal.count(commit) == 2 and
            deferred < terminal.index(commit) < terminal.index('"outcome": "setupDeferred"') < terminal.rindex(commit),
        "full_terminal_commit_precedes_journal_persist": terminal.index("beforePersist:") < terminal.rindex(commit),
        "headless_admission_captured_before_driver": "let driver = try await admission.withScope { try await makeDriver" in texts["service"] and
            "let admission = try V3RemoteRequestLeases.capture(id: id)" in texts["service"] and
            "try await admission.withScope { try await driver.run() }" in texts["service"],
        "profile_coalescers_use_scoped_admission": texts["profiles"].count("V3RemoteRequestLeases.coalesce(key:") == 3 and
            "TaskChainCoalescer.shared.coalesce" not in texts["profiles"],
        "app_id_coalescer_uses_scoped_admission": "V3RemoteRequestLeases.coalesce(key:" in texts["appids"] and
            "TaskChainCoalescer.shared.coalesce" not in texts["appids"],
        "portal_transport_checks_scoped_context": texts["portal"].count("let scopedRemote = ILoaderRemoteAuthentication.current") == 2 and
            texts["portal"].count("try scopedRemote?.checkActive()") >= 2,
    }
    if not all(wiring.values()):
        raise ValueError("Candidate integration wiring changed: " + ", ".join(name for name, passed in wiring.items() if not passed))
    for name, anchor in [("sync_app_ids", "func syncAppIDs(completionHandler:"),
                         ("refresh", "func refresh(_ installedApps:"),
                         ("background_refresh", "func backgroundRefresh(_ installedApps:")]:
        method = extract(texts["appmanager"], anchor)
        wiring["outer_" + name + "_captures_before_detached"] = (
            method.index("V3RemoteRequestLeases.capture()") < method.index("Task.detached") <
            method.index("admission.withScope") and "admission.close()" in method)
    background = extract(texts["background"], "private func refresh(_ apps:")
    wiring["background_callback_installed_before_enqueue_and_cancellation_checked"] = (
        background.index("group.completionHandler =") < background.index("AppManager.shared.refresh(") <
        background.index("if self.isCancelled { group.cancel() }"))
    for name, method in [("app_manager", extract(texts["appmanager"], "func refresh(_ installedApps:")),
                         ("pipeline", extract(texts["pipeline"],
                            "func performSingleOperation(_ operation: AppOperation,\n"
                            "                                handler: PipelineExecutionHandler,\n"
                            "                                context: StandaloneOperationContext,"))]:
        wiring[name + "_completion_after_successful_admission_scope"] = (
            method.index(".withScope") < method.rindex(".close()") <
            method.index(".completionHandler?(") and
            method.count(".completionHandler?(") == (2 if name == "app_manager" else 1))
    heavy = extract(texts["pipeline"], "private func performUsingAdmittedRoute(")
    wiring["heavy_pipeline_does_not_publish_terminal_callback"] = ".completionHandler?(" not in heavy
    if not all(wiring.values()):
        raise ValueError("Candidate outer queue wiring changed")

    def take(anchor=None, marker=None):
        raw = extract(keychain, anchor) if anchor else marked(keychain, marker)
        spans.append({"source": SOURCE_PATHS["keychain"], "anchor": anchor or marker,
                      "first_line": keychain[:keychain.index(raw)].count("\n") + 1,
                      "sha256": sha256(raw.encode())})
        return raw

    security = take(marker="V3_PENDING_CERTIFICATE_SECURITY_CLIENT")
    needle = "var calls = V3PendingCertificateKeychainCalls()"
    if security.count(needle) != 1:
        raise ValueError("Security injection anchor changed")
    security = security.replace(needle, "var calls = FixtureSecurity.makeCalls()")
    parts = ["import Foundation\nimport Security\nimport CryptoKit\n",
             take(anchor="enum V3PendingCertificateCreationError:"),
             take(anchor="struct LCEmbeddedAuthenticationSnapshot:"),
             take(anchor="struct LCEmbeddedAuthenticationCandidate:"),
             take(marker="V3_REMOTE_IDENTITY_RECORD_CORE"), security,
             take(marker="V3_REMOTE_IDENTITY_KEYCHAIN_ADAPTER"),
             "extension LCEmbeddedSharedKeychain {\n" +
             take(anchor="private static func withSharedTransaction<T>") + "\n" +
             take(anchor="static func clearSignInInfoChecked(_ client:") + "\n" +
             take(anchor="static func writeAuthenticationCredentials(appleID: String, password: String?,") + "\n" +
             take(anchor="private static func saveTransactionJournal(") + "\n" +
             take(anchor="private static func clearTransactionJournal(") + "\n}",
             "extension Keychain {\n" +
             take(anchor="func writeAuthenticationCredentials(appleID: String, password: String,") + "\n}"]
    # These exact migration constants are part of the sign-out path under test.
    constants = []
    for name in ("marker", "ready", "signedOut", "pending", "authKeys"):
        matches = [line.strip() for line in keychain.splitlines()
                   if line.strip().startswith("static let " + name + " =")]
        if len(matches) != 1:
            raise ValueError("Migration constant changed: " + name)
        constants.extend(matches)
    parts.append("enum LCSharedKeychainMigration {\n" + "\n".join(constants) + "\n" +
                 take(anchor="static func complete(_ values:") + "\n" +
                 take(anchor="static func readAuthenticationValues(read:") + "\n}")
    journal = [line.strip() for line in keychain.splitlines()
               if line.strip().startswith('private static let authenticationJournal =')]
    if len(journal) != 1:
        raise ValueError("Credential journal anchor changed")
    parts.append("extension LCEmbeddedSharedKeychain {\n" + journal[0] + "\n}")
    outputs = {"CandidateCore.swift": "\n\n".join(parts).encode() + b"\n",
               "BoundaryDoubles.swift": support["BoundaryDoubles.swift"],
               "CoreCases.swift": support["CoreCases.swift"],
               "CandidateRuntime.swift": runtime_projection(source, spans),
               "RuntimeDoubles.swift": support["RuntimeDoubles.swift"],
               "RuntimeCases.swift": support["RuntimeCases.swift"]}
    # Do not invent a baseline implementation for a feature absent from that revision.
    baseline_gaps = {
        "protected_identity_record_absent": "V3_REMOTE_IDENTITY_RECORD_CORE_BEGIN" not in previous["keychain"].decode(),
        "protected_identity_adapter_absent": "V3_REMOTE_IDENTITY_KEYCHAIN_ADAPTER_BEGIN" not in previous["keychain"].decode(),
        "attempt_identity_only": "private actor ILoaderAttemptAnisetteSource" in previous["provider"].decode(),
    }
    if not all(baseline_gaps.values()):
        raise ValueError("Expected delivered baseline changed; inspect provenance before adjusting")
    output.mkdir(parents=True, exist_ok=True)
    for name, raw in outputs.items():
        (output / name).write_bytes(raw)
    receipt = {
        "schema": "remote-identity-reuse-source-evidence-v1",
        "status": "GENERATED_NOT_COMPILED_NOT_RUN", "swift_executed": False,
        "network_executed": False, "native_provider_executed": False, "native_keychain_executed": False,
        "inputs_sha256": {SOURCE_PATHS[name]: sha256(raw) for name, raw in source.items()},
        "baseline_inputs_sha256": {SOURCE_PATHS[name]: sha256(raw) for name, raw in previous.items()},
        "support_inputs_sha256": {PACKAGE + "/" + name: sha256(raw) for name, raw in support.items()},
        "outputs_sha256": {name: sha256(raw) for name, raw in outputs.items()},
        "production_extracts": spans,
        "baseline_source_gaps": baseline_gaps,
        "candidate_source_wiring": wiring,
        "expected_case_names": re.findall(r'try (?:await )?test\("([a-z0-9_]+)"',
            support["CoreCases.swift"].decode() + support["RuntimeCases.swift"].decode()),
        "projection_changes": ["The extracted Security client default calls initializer is replaced with FixtureSecurity.makeCalls(). Production query, getData, set, remove, record IO, adapter, sign-out and transaction bodies are unchanged.",
            "The extracted remote authentication context URLSession type is replaced with FixtureRemoteSession. Context method bodies are unchanged.",
            "One synthetic wait is inserted immediately inside the original Task.detached body, before its original statements, to control enqueue/account-change races. Task.detached itself and all candidate queue/admission logic remain unchanged.",
            "The same synthetic queue wait is inserted inside actual AppManager.refresh Task.detached. Its capture, dispatch and completion logic remain unchanged. The BackgroundRefreshAppsOperation.refresh callback/continuation method is unchanged.",
            "The real provider dispatch method is used; the unrelated old-remote network helper always throws, while local dispatch records an inert boundary hit."],
        "inert_boundaries": ["All Security calls use an injected in-memory fake. No live Keychain operation.",
            "Existing account credential snapshot and KeychainAccess wrapper use synthetic values.",
            "Actual withSharedTransaction runs with its existing transactionOverride under an in-memory recursive lock. Native file lock always throws.",
            "Pipeline heavy work is inert; actual performSingleOperation Task.detached and perform authorization wrapper dispatch through actual AuthManager/coalescer and DeveloperPortalProxy methods.",
            "Portal API, team database ownership, legacy local provider and profile/OTP fetch are synthetic boundaries. Actual accountScopedRead, bound-session acquisition, team authorization, awaitBound and certificate dispatch methods are preserved.",
            "This fixture does not authenticate, contact providers, parse real credentials or provision a device."],
        "limitations": ["Source generation is not compilation or runtime evidence.",
            "Baseline lacks the new persistence feature; baseline gaps are source assertions, not fabricated baseline runtime failures.",
            "In-memory ordering does not prove cross-process Keychain/flock behavior."],
    }
    (output / "source-evidence.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-root", type=Path, required=True)
    parser.add_argument("--baseline-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    generate(args.candidate_root, args.baseline_root, args.output)
    print("REMOTE_IDENTITY_FIXTURE_GENERATED_NOT_COMPILED_NOT_RUN")
