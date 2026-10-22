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
        if UserDefaults.standard.useOnDeviceAnisette {
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

        let provider = SideSign.AnisetteDataManager.shared
        // LC_ANISETTE_PAIR_PRECONDITION_V1
        let anisetteSnapshot = try await AnisetteConfigManager.shared.resolveAnisetteSnapshot()
        let existingBlob = anisetteSnapshot.adiBlob
        let identifier = anisetteSnapshot.identifier
        let headerSelection = await AnisetteConfigManager.shared.makeRequestHeaderSelection()
        let headers = headerSelection.headers

        let (anisetteData, newAdiBlob) = try await provider.fetchAnisetteDataWithFailover(
            servers: UserDefaults.standard.disableAnisetteRotation ? [servers[startIndex]] : servers,
            startIndex: startIndex,
            identifier: identifier,
            existingAdiBlob: existingBlob,
            headers: headers,
            diagnosticClientInfoSource: headerSelection.clientInfoSource,
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

// One credentials Submit owns this experimental route. No defaults, Keychain,
// local ADI snapshot or disk provisioning record is read or written here.
func makeILoaderRemoteAuthenticationContext() throws -> ILoaderRemoteAuthenticationContext {
    let source = ILoaderAttemptAnisetteSource()
    return ILoaderRemoteAuthenticationContext(
        endpoint: .macJkcoxson,
        canceller: { source.invalidate() },
        fetcher: { sim in try await source.fetch(sim: sim) })
}

private actor ILoaderAttemptAnisetteSource {
    private nonisolated let client = ILoaderRemoteAnisetteClient(endpoint: .macJkcoxson)
    private var state: ILoaderRemoteState?
    private var fetching = false

    nonisolated func invalidate() { client.invalidate() }

    func fetch(sim: String?) async throws -> ALTAnisetteData {
        try await v3LoginStage(.primaryProvider) { try await self.fetchCore(sim: sim) }
    }

    private func fetchCore(sim: String?) async throws -> ALTAnisetteData {
        // Reject reentrant acquisitions instead of producing competing identities.
        guard !fetching else { throw SideSign.AnisetteError.providerNotReady("An acquisition is already in progress.") }
        fetching = true
        defer { fetching = false }
        try Task.checkCancellation()
        if state == nil {
            let profile = try await client.fetchProfile()
            try Task.checkCancellation()
            state = ILoaderRemoteState(profile: profile)
        }
        guard let current = state else { throw SideSign.AnisetteError.invalidAnisetteData }
        let (data, updated) = try await client.fetch(state: current, sim: sim)
        try Task.checkCancellation()
        state = updated
        return data
    }
}
