//
//  AnisetteProvider.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign
import AnisetteKit

enum AnisetteProvider {
    static func fetch(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        // A latched attempt is authoritative, including after revocation: never fall back.
        if let remote = ILoaderRemoteAuthentication.current {
            _ = AuthenticationDiagnosticTrace.current?.beginProviderObservation(.selectedBranch(onDevice: false))
            return try await remote.fetch()
        }
        if V3DiagnosticProviderRoute.current == .onDevice ||
            (V3DiagnosticProviderRoute.current == nil && UserDefaults.standard.useOnDeviceAnisette) {
            _ = AuthenticationDiagnosticTrace.current?.beginProviderObservation(.selectedBranch(onDevice: true))
            debugLog("[AnisetteProvider] Fetching anisette via On-Device Anisette (ODA)...")
            return try await OnDeviceAnisetteManager.shared.fetchAnisetteData()
        } else {
            _ = AuthenticationDiagnosticTrace.current?.beginProviderObservation(.selectedBranch(onDevice: false))
            debugLog("[AnisetteProvider] Fetching anisette via remote server...")
            return try await v3LoginStage(.primaryProvider) { try await fetchRemote(handler: handler) }
        }
    }

    private static func fetchRemote(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        let serverUrlStrings = await AnisetteServersManager.shared.getActiveServerURLs()
        let servers = serverUrlStrings.compactMap { URL(string: $0) }
        guard !servers.isEmpty else {
            throw SideSign.AnisetteError.noServersConfigured
        }

        let lastServer = UserDefaults.standard.menuAnisetteURL
        let startIndex = servers.firstIndex(where: { $0.absoluteString == lastServer }) ?? 0

        let diagnostic = V3DiagnosticProviderRoute.current == .remoteServer
        if diagnostic { try Task.checkCancellation() }
        let provider = SideSign.AnisetteDataManager.shared
        // LC_ANISETTE_PAIR_PRECONDITION_V1
        let anisetteSnapshot = try await AnisetteConfigManager.shared.resolveAnisetteSnapshot()
        let existingBlob = anisetteSnapshot.adiBlob
        let identifier = anisetteSnapshot.identifier
        let headerSelection = await AnisetteConfigManager.shared.makeRequestHeaderSelection()
        let headers = headerSelection.headers

        let (anisetteData, newAdiBlob) = try await provider.fetchAnisetteDataWithFailover(
            servers: diagnostic || UserDefaults.standard.disableAnisetteRotation ? [servers[startIndex]] : servers,
            startIndex: diagnostic ? 0 : startIndex,
            identifier: identifier,
            existingAdiBlob: existingBlob,
            headers: headers,
            diagnosticClientInfoSource: headerSelection.clientInfoSource,
            onError: { error in
                if diagnostic { return false }
                if let anisetteError = error as? SideSign.AnisetteError,
                   case .outdatedV1Server(let serverURL, _) = anisetteError {
                    if UserDefaults.standard.defaultServerURL == serverURL.absoluteString {
                        return true
                    }
                    if let handler = handler {
                        let shouldContinue = try await handler.warnOutdatedAnisetteServer()
                        if shouldContinue {
                            UserDefaults.standard.defaultServerURL = serverURL.absoluteString
                        }
                        return shouldContinue
                    }
                }
                return false
            },
            onSuccess: { successfulServer in
                guard !diagnostic else { return }
                UserDefaults.standard.menuAnisetteURL = successfulServer.absoluteString
                debugLog("[AnisetteProvider] Successfully fetched Anisette data.")
            }
        )

        if diagnostic { try Task.checkCancellation() }
        if let freshBlob = newAdiBlob {
            try await AnisetteConfigManager.shared.commitAnisetteBlob(freshBlob, snapshot: anisetteSnapshot)
        } else {
            LoginDiagnosticTrace.current?.skip(.freshBlobCommit, reason: .notRequired)
        }
        LoginDiagnosticTrace.current?.skip(.recovery, reason: .notRequired)

        return anisetteData
    }
}

// V3_REMOTE_IDENTITY_RUNTIME_BEGIN
struct V3RemoteIdentityHandoff: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "Remote identity handoff (redacted)" }
    var debugDescription: String { description }
    let previous: V3RemoteIdentityRecord?
    let identityID: String
    let state: ILoaderRemoteState
    let routeMarker: Data
}

// A manual attempt may advance only its own synchronous verified credential/session transitions.
// Other account changes revoke it; adopting a stamp never revives an invalidated context.
final class V3RemoteAttemptAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private let previous: V3RemoteIdentityRecord?
    private var stamp: String
    private var credentials: LCEmbeddedAuthenticationSnapshot?
    private var marker: Data?
    private var valid = true
    init(previous: V3RemoteIdentityRecord?) throws {
        self.previous = previous
        let auth = AuthManager.shared
        stamp = auth.v3IdentityStamp
        credentials = try Keychain.shared.authenticationSnapshot()
        marker = try Keychain.shared.remoteIdentityRouteBytes()
        guard auth.v3IdentityIsStable, auth.v3IdentityStamp == stamp else { throw V3RemoteIdentityError.stateChanged }
    }
    func isAuthorized() -> Bool {
        let expected = lock.withLock { (valid, stamp, credentials, marker) }
        let auth = AuthManager.shared
        guard expected.0, auth.v3IdentityIsStable, auth.v3IdentityStamp == expected.1 else { return false }
        do {
            return try Keychain.shared.authenticationSnapshot() == expected.2 &&
                Keychain.shared.remoteIdentityRouteBytes() == expected.3 &&
                Keychain.shared.remoteIdentityRecord() == previous
        } catch { return false }
    }
    func handoffRoute() throws -> Data {
        guard let route = lock.withLock({ valid ? marker : nil }) else { throw V3RemoteIdentityError.stateChanged }
        return route
    }
    func adoptOwnedTransition(appleID: String, dsid: String, token: String) {
        do {
            let auth = AuthManager.shared
            let nextStamp = auth.v3IdentityStamp
            let nextCredentials = try Keychain.shared.authenticationSnapshot()
            let nextMarker = try Keychain.shared.remoteIdentityRouteMarker()
            let expectedBinding = try V3RemoteIdentityRecord.credentialBinding(appleID: appleID, dsid: dsid, token: token)
            guard auth.v3IdentityIsStable, auth.v3IdentityStamp == nextStamp,
                  let nextCredentials, try V3RemoteIdentityContinuity.binding(nextCredentials) == expectedBinding,
                  nextMarker?.binding == expectedBinding, nextMarker?.mode != .local,
                  try Keychain.shared.remoteIdentityRecord() == previous else { throw V3RemoteIdentityError.stateChanged }
            lock.withLock { stamp = nextStamp; credentials = nextCredentials; marker = nextMarker?.encoded }
        } catch { lock.withLock { valid = false } }
    }
}

final class V3RemoteAnisetteAttempt: @unchecked Sendable {
    let previous: V3RemoteIdentityRecord?
    let identityID: String
    let context: ILoaderRemoteAuthenticationContext
    let authorization: V3RemoteAttemptAuthorization?
    private let registrationID: String?
    init(record: V3RemoteIdentityRecord?, mayProvision: Bool = true,
         authorization: V3RemoteAttemptAuthorization? = nil,
         isAuthorized: @escaping @Sendable () -> Bool = { true }) throws {
        try record?.validated()
        previous = record; identityID = record?.identityID ?? UUID().uuidString
        self.authorization = authorization
        let source = ILoaderAttemptAnisetteSource(record: record, mayProvision: mayProvision)
        context = ILoaderRemoteAuthenticationContext(endpoint: .macJkcoxson,
            canceller: { source.invalidate() },
            isAuthorized: { (authorization?.isAuthorized() ?? true) && isAuthorized() },
            stateSnapshot: { try await source.snapshot() },
            fetcher: { sim in try await source.fetch(sim: sim) })
        registrationID = authorization == nil ? nil : UUID().uuidString
        if let registrationID { V3RemoteRequestLeases.registerManual(context, id: registrationID) }
    }
    deinit { if let registrationID { V3RemoteRequestLeases.removeManual(registrationID) } }
    func handoff() async throws -> V3RemoteIdentityHandoff {
        let state = try await context.identityState()
        guard let authorization else { throw V3RemoteIdentityError.stateChanged }
        let marker = try authorization.handoffRoute()
        try context.checkActive()
        return V3RemoteIdentityHandoff(previous: previous, identityID: identityID, state: state, routeMarker: marker)
    }
}

func makeILoaderRemoteAuthenticationContext() throws -> ILoaderRemoteAuthenticationContext {
    try V3RemoteIdentityContinuity.manualAttempt().context
}

enum V3RemoteIdentityContinuity {
    static func binding(_ credentials: LCEmbeddedAuthenticationSnapshot) throws -> Data {
        try V3RemoteIdentityRecord.credentialBinding(appleID: credentials.appleIDEmailAddress,
            dsid: credentials.appleIDAdsid, token: credentials.appleIDXcodeToken)
    }
    static func manualAttempt() throws -> V3RemoteAnisetteAttempt {
        let previous = try Keychain.shared.remoteIdentityRecord()
        return try V3RemoteAnisetteAttempt(record: previous,
            authorization: V3RemoteAttemptAuthorization(previous: previous))
    }
    static func admittedRecord() throws -> V3RemoteIdentityRecord? {
        guard let marker = try Keychain.shared.remoteIdentityRouteMarker() else {
            // Delivered temporary-remote and native tokens have no reliable route provenance.
            // An existing local pair does not prove which provider issued those tokens.
            if try Keychain.shared.authenticationSnapshot()?.hasTokenCredentials == true {
                throw V3RemoteIdentityError.manualSignInRequired
            }
            if try Keychain.shared.remoteIdentityRecord()?.routeBinding != nil {
                throw V3RemoteIdentityError.manualSignInRequired
            }
            return nil
        }
        guard let credentials = try Keychain.shared.authenticationSnapshot(),
              marker.binding == (try binding(credentials)) else { throw V3RemoteIdentityError.manualSignInRequired }
        if marker.mode == .local { return nil }
        guard marker.mode == .readyRemote, let record = try Keychain.shared.remoteIdentityRecord(),
              record.routeBinding == marker.binding else { throw V3RemoteIdentityError.manualSignInRequired }
        return record
    }
    static func continuationAttempt() throws -> V3RemoteAnisetteAttempt? {
        guard let record = try admittedRecord() else { return nil }
        return try V3RemoteAnisetteAttempt(record: record, mayProvision: false,
            authorization: V3RemoteAttemptAuthorization(previous: record))
    }
    static func commit(_ handoff: V3RemoteIdentityHandoff?, credentials: LCEmbeddedAuthenticationSnapshot) throws {
        guard let handoff else { return } // Local route was recorded atomically with its verified credentials.
        guard handoff.state.profile.endpoint == .macJkcoxson,
              let blob = handoff.state.adiPB else { throw V3RemoteIdentityError.invalidRecord }
        let record = V3RemoteIdentityRecord(schemaVersion: 1, identityID: handoff.identityID,
            endpoint: handoff.state.profile.endpoint.rawValue, identity: handoff.state.identity,
            adiPB: blob, routeBinding: try binding(credentials))
        try Keychain.shared.commitRemoteIdentity(record, replacing: handoff.previous, credentials: credentials,
            expectedRoute: handoff.routeMarker)
    }
    static func resetExplicitly() throws {
        AuthManager.shared.v3BeginIdentityTransition()
        defer { AuthManager.shared.v3CompleteIdentityTransition() }
        V3RemoteRequestLeases.invalidateManualAttempts()
        try Keychain.shared.resetRemoteIdentity()
    }
}

// V3_REMOTE_REQUEST_LEASES_BEGIN
// A nil remote context is still an admitted local route. Retain its exact owner through queues.
final class V3RemoteRequestAdmission: @unchecked Sendable {
    let context: ILoaderRemoteAuthenticationContext?
    let stamp: String
    private let credentials: LCEmbeddedAuthenticationSnapshot?
    private let marker: Data?
    private let ownedLease: V3RemoteRequestLease?
    init(id: String) throws {
        try V3RemoteRequestLeases.admitted?.check()
        let auth = AuthManager.shared
        stamp = auth.v3IdentityStamp
        credentials = try Keychain.shared.authenticationSnapshot()
        marker = try Keychain.shared.remoteIdentityRouteBytes()
        ownedLease = ILoaderRemoteAuthentication.current == nil ? try V3RemoteRequestLeases.makeLease(id: id) : nil
        context = ILoaderRemoteAuthentication.current ?? ownedLease?.context
        try check()
    }
    func close() { ownedLease?.close() }
    func check() throws {
        try Task.checkCancellation()
        let auth = AuthManager.shared
        guard auth.v3IdentityIsStable, auth.v3IdentityStamp == stamp,
              try Keychain.shared.authenticationSnapshot() == credentials,
              try Keychain.shared.remoteIdentityRouteBytes() == marker else { throw V3RemoteIdentityError.stateChanged }
        do { try context?.checkActive() }
        catch is CancellationError { throw CancellationError() }
        catch ILoaderRemoteError.consentRequired { throw V3RemoteIdentityError.stateChanged }
    }
    func withScope<T>(_ operation: () async throws -> T) async throws -> T {
        try check()
        do {
            return try await withTaskCancellationHandler {
                try await V3RemoteRequestLeases.$admitted.withValue(self) {
                    try await ILoaderRemoteAuthentication.$current.withValue(context) {
                        try check()
                        let result = try await operation()
                        try check()
                        return result
                    }
                }
            } onCancel: { self.context?.invalidate() }
        } catch ILoaderRemoteError.consentRequired {
            if Task.isCancelled { throw CancellationError() }
            throw V3RemoteIdentityError.stateChanged
        }
    }
}
final class V3RemoteRequestLease: @unchecked Sendable {
    let id: String
    let context: ILoaderRemoteAuthenticationContext
    init(id: String, context: ILoaderRemoteAuthenticationContext) { self.id = id; self.context = context }
    func close() { V3RemoteRequestLeases.close(id, expected: context) }
    deinit { close() }
}
// Leases use existing account authorization, including configured background refresh. They do not
// start a scheduler, choose a new provider, provision a new identity, or extend a cancelled context.
enum V3RemoteRequestLeases {
    @TaskLocal static var admitted: V3RemoteRequestAdmission?
    static func capture(id: String = UUID().uuidString) throws -> V3RemoteRequestAdmission {
        try V3RemoteRequestAdmission(id: id)
    }
    private static let lock = NSLock()
    private static var active: [String: ILoaderRemoteAuthenticationContext] = [:]
    private static var manual: [String: ILoaderRemoteAuthenticationContext] = [:]
    static func registerManual(_ context: ILoaderRemoteAuthenticationContext, id: String) {
        lock.withLock { manual[id] = context }
    }
    static func removeManual(_ id: String) { _ = lock.withLock { manual.removeValue(forKey: id) } }
    static func invalidateManualAttempts() {
        let contexts = lock.withLock { () -> [ILoaderRemoteAuthenticationContext] in
            let result = Array(manual.values); manual.removeAll(); return result
        }
        contexts.forEach { $0.invalidate() }
    }
    static func close(_ id: String, expected: ILoaderRemoteAuthenticationContext) {
        lock.withLock { if active[id] === expected { active.removeValue(forKey: id) } }
        expected.invalidate()
    }
    static func invalidate(_ id: String) {
        let context = lock.withLock { active.removeValue(forKey: id) }
        context?.invalidate()
    }
    static func invalidateAll() {
        let contexts = lock.withLock { () -> [ILoaderRemoteAuthenticationContext] in
            let result = Array(active.values); active.removeAll(); return result
        }
        contexts.forEach { $0.invalidate() }
    }
    static func coalescerKey(_ key: String) -> String {
        ILoaderRemoteAuthentication.current.map { key + ".remoteLease.\(ObjectIdentifier($0))" } ?? key
    }
    static func coalesce<T: Sendable>(key: String,
        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let admission = try admitted ?? capture()
        let scopedKey = admission.context.map { key + ".remoteLease.\(ObjectIdentifier($0))" } ?? key
        let key = scopedKey + ".identity." + admission.stamp
        let result = try await TaskChainCoalescer.shared.coalesce(key: key) {
            try await admission.withScope(operation)
        }
        try admission.check()
        return result
    }
    static func makeLease(id: String = UUID().uuidString) throws -> V3RemoteRequestLease? {
        let auth = AuthManager.shared
        let stamp = auth.v3IdentityStamp
        guard auth.v3IdentityIsStable else { throw V3RemoteIdentityError.stateChanged }
        guard let record = try V3RemoteIdentityContinuity.admittedRecord() else { return nil }
        guard let credentials = try Keychain.shared.authenticationSnapshot(),
              auth.v3IdentityIsStable, auth.v3IdentityStamp == stamp,
              record.routeBinding == (try V3RemoteIdentityContinuity.binding(credentials)) else {
            throw V3RemoteIdentityError.manualSignInRequired
        }
        let marker = try Keychain.shared.remoteIdentityRouteMarker()
        let attempt = try V3RemoteAnisetteAttempt(record: record, mayProvision: false, isAuthorized: {
            guard auth.v3IdentityIsStable, auth.v3IdentityStamp == stamp else { return false }
            do {
                return try Keychain.shared.authenticationSnapshot() == credentials &&
                    Keychain.shared.remoteIdentityRecord() == record &&
                    Keychain.shared.remoteIdentityRouteMarker() == marker
            } catch { return false }
        })
        let context = attempt.context
        try context.checkActive()
        try lock.withLock {
            guard active[id] == nil else { throw V3RemoteIdentityError.stateChanged }
            active[id] = context
        }
        return V3RemoteRequestLease(id: id, context: context)
    }
    static func withAuthorizedRoute<T>(id: String = UUID().uuidString,
                                       operation: () async throws -> T) async throws -> T {
        let admission = try admitted ?? capture(id: id)
        return try await admission.withScope(operation)
    }
}
// V3_REMOTE_REQUEST_LEASES_END
// V3_REMOTE_IDENTITY_RUNTIME_END

private actor ILoaderAttemptAnisetteSource {
    private nonisolated let client = ILoaderRemoteAnisetteClient(endpoint: .macJkcoxson)
    private let record: V3RemoteIdentityRecord?
    private let mayProvision: Bool
    private var state: ILoaderRemoteState?
    private var fetching = false

    init(record: V3RemoteIdentityRecord?, mayProvision: Bool) {
        self.record = record; self.mayProvision = mayProvision
    }
    nonisolated func invalidate() { client.invalidate() }
    func snapshot() throws -> ILoaderRemoteState {
        guard !fetching, let state, state.adiPB != nil else { throw ILoaderRemoteError.invalidState }
        return state
    }
    func fetch(sim: String?) async throws -> ALTAnisetteData {
        try await v3LoginStage(.primaryProvider) { try await self.fetchCore(sim: sim) }
    }
    private func fetchCore(sim: String?) async throws -> ALTAnisetteData {
        guard !fetching else { throw SideSign.AnisetteError.providerNotReady("An acquisition is already in progress.") }
        fetching = true
        defer { fetching = false }
        try Task.checkCancellation()
        if state == nil {
            let profile = try await client.fetchProfile()
            try Task.checkCancellation()
            if let record {
                guard profile.endpoint.rawValue == record.endpoint else { throw ILoaderRemoteError.invalidProvider }
                state = try ILoaderRemoteState(restoring: profile, identity: record.identity, adiPB: record.adiPB)
            } else {
                guard mayProvision else { throw V3RemoteIdentityError.manualSignInRequired }
                state = ILoaderRemoteState(profile: profile)
            }
        }
        guard let current = state else { throw ILoaderRemoteError.invalidState }
        let (data, updated) = try await client.fetch(state: current, sim: sim)
        try Task.checkCancellation()
        state = updated
        return data
    }
}
