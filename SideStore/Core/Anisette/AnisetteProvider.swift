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
        // PR1835 remote permission is scoped to this explicit operation, never a global mode.
        if let attempt = WindowsAnisetteAuthentication.current {
            return try await v3LoginStage(.primaryProvider) { try await attempt.fetch() }
        }
        if UserDefaults.standard.useOnDeviceAnisette {
            debugLog("[AnisetteProvider] Fetching anisette via On-Device Anisette (ODA)...")
            return try await OnDeviceAnisetteManager.shared.fetchAnisetteData()
        } else {
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

        let provider = SideSign.AnisetteDataManager.shared
        // LC_ANISETTE_PAIR_PRECONDITION_V1
        let anisetteSnapshot = try await AnisetteConfigManager.shared.resolveAnisetteSnapshot()
        let existingBlob = anisetteSnapshot.adiBlob
        let identifier = anisetteSnapshot.identifier
        let headers = await AnisetteConfigManager.shared.makeRequestHeaders()

        let (anisetteData, newAdiBlob) = try await provider.fetchAnisetteDataWithFailover(
            servers: UserDefaults.standard.disableAnisetteRotation ? [servers[startIndex]] : servers,
            startIndex: startIndex,
            identifier: identifier,
            existingAdiBlob: existingBlob,
            headers: headers,
            onError: { error in
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
                UserDefaults.standard.menuAnisetteURL = successfulServer.absoluteString
                debugLog("[AnisetteProvider] Successfully fetched Anisette data.")
            }
        )

        if let freshBlob = newAdiBlob {
            try await AnisetteConfigManager.shared.commitAnisetteBlob(freshBlob, snapshot: anisetteSnapshot)
        } else {
            LoginDiagnosticTrace.current?.skip(.freshBlobCommit, reason: .notRequired)
        }
        LoginDiagnosticTrace.current?.skip(.recovery, reason: .notRequired)

        return anisetteData
    }
}


// Separate provider-scoped state; never reads or migrates identifier/adiPb.
private actor WindowsAnisetteOperation {
    private let client: WindowsRemoteAnisetteClient
    private var profile: WindowsAnisetteProfile?
    private var state: WindowsAnisetteState?
    private var fetching = false

    init(endpoint: WindowsAnisetteEndpoint) { client = WindowsRemoteAnisetteClient(endpoint: endpoint) }
    nonisolated func invalidate() { client.invalidate() }

    func fetch(sim: String?) async throws -> ALTAnisetteData {
        // Actor reentrancy must not provision two identities or interleave resync.
        guard !fetching else { throw WindowsAnisetteError.stateChanged }
        fetching = true
        defer { fetching = false }
        try Task.checkCancellation()
        let selected: WindowsAnisetteProfile
        if let profile { selected = profile }
        else {
            selected = try await client.fetchProfile()
            profile = selected
        }
        let original = try Keychain.shared.windowsAnisetteRecord(key: selected.storageKey)
        let candidate: WindowsAnisetteState
        if let state {
            guard let original, try JSONDecoder().decode(WindowsAnisetteState.self, from: original) == state else {
                throw WindowsAnisetteError.stateChanged
            }
            candidate = state
        } else if let original {
            do { candidate = try JSONDecoder().decode(WindowsAnisetteState.self, from: original) }
            catch { throw WindowsAnisetteError.invalidState }
        } else {
            guard sim == nil else { throw WindowsAnisetteError.resyncUnavailable }
            candidate = WindowsAnisetteState(profile: selected)
        }
        try candidate.validated(for: selected)
        if original != nil && candidate.adiPB == nil { throw WindowsAnisetteError.invalidState }
        let (data, updated) = try await client.fetch(state: candidate, sim: sim)
        try Task.checkCancellation()
        let encoded = try JSONEncoder().encode(updated)
        try Keychain.shared.commitWindowsAnisetteRecord(encoded, key: selected.storageKey, replacing: original)
        state = updated
        return data
    }
}

func makeWindowsAnisetteContext(endpoint: String?, consentAttemptID: UUID?) throws -> WindowsAnisetteAuthenticationContext? {
    if endpoint == nil && consentAttemptID == nil { return nil }
    guard consentAttemptID != nil, let endpoint, let selected = WindowsAnisetteEndpoint(rawValue: endpoint) else {
        throw WindowsAnisetteError.consentRequired
    }
    let operation = WindowsAnisetteOperation(endpoint: selected)
    return WindowsAnisetteAuthenticationContext(endpoint: selected, canceller: { operation.invalidate() }) { sim in
        try await operation.fetch(sim: sim)
    }
}
