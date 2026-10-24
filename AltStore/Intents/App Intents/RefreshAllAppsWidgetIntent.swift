//
//  RefreshAllAppsWidgetIntent.swift
//  AltStore
//
//  Created by Riley Testut on 8/18/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import AppIntents
// V3_SHORTCUT_WIDGET_BACKEND_FORWARD_V1: retain the upstream guest-to-backend adapter.

@available(iOS 17, tvOS 17, *)
struct RefreshAllAppsWidgetIntent: AppIntent, ProgressReportingIntent
{
    static var title: LocalizedStringResource { "Refresh Apps via Widget" }
    static var isDiscoverable: Bool { false } // Don't show in Shortcuts or Spotlight.
    
    #if !WIDGET_EXTENSION
    private let intent = RefreshAllAppsIntent(presentsNotifications: true)
    #endif
    
    func perform() async throws -> some IntentResult
    {
    #if !WIDGET_EXTENSION
        do
        {
            _ = try await self.intent.perform()
        }
        catch
        {
            // V3_WIDGET_REFRESH_FAILURE_PRIVACY_V1: never log a raw provider error.
            debugLog("[V3_WIDGET_REFRESH] failed")
            throw error
        }
    #endif
        
        return .result()
    }
}

// To ensure this intent is handled by the app itself (and not widget extension)
// we need to conform to either `ForegroundContinuableIntent` or `AudioPlaybackIntent`.
// https://mastodon.social/@mgorbach/110812347476671807
//
// Unfortunately `ForegroundContinuableIntent` is marked as unavailable in app extensions,
// so we "conform" RefreshAllAppsWidgetIntent to it in an `unavailable` extension ¯\_(ツ)_/¯
@available(iOS, unavailable)
@available(tvOS, unavailable)
extension RefreshAllAppsWidgetIntent: ForegroundContinuableIntent {}
