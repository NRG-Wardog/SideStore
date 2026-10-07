//
//  SceneDelegate.swift
//  AltStore
//
//  Created by Riley Testut on 7/6/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit


final class SceneDelegate: UIResponder, UIWindowSceneDelegate
{

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions)
    {
        debugLog("[SceneDelegate] scene(willConnectTo:) invoked")
        // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
        // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
        // V3_HEADLESS_SCENE_WINDOW_CAST_REMOVED_V1: service scenes have no window setup.
        
        if let context = connectionOptions.urlContexts.first
        {
            self.open(context)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene)
    {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to undo the changes made on entering the background.
        
        // applicationWillEnterForeground is _not_ called when launching app,
        // whereas sceneWillEnterForeground _is_ called when launching.
        // As a result, DatabaseManager might not be started yet, so just return if it isn't
        // (since all these methods are called separately during app startup).
        guard DatabaseManager.shared.isStarted else { return }
        
        Task {
            await AppManager.shared.reconcileInstalledApps()
            await WidgetDataManager.publishCurrentInstalledAppsIfNeeded(in: DatabaseManager.shared.viewContext)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene)
    {
        debugLog("[SceneDelegate] sceneDidBecomeActive() invoked")
        defer {
            // dump sidebackup logs if any
            Task.detached { await AppDelegate.dumpSideBackupLogsIfNeeded() }
        }
        
        if DatabaseManager.shared.isStarted {
            Task {
                await WidgetDataManager.publishCurrentInstalledAppsIfNeeded(in: DatabaseManager.shared.viewContext)
            }
        }
        
    }

    func sceneDidEnterBackground(_ scene: UIScene)
    {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
        
        guard UIApplication.shared.applicationState == .background else { return }
        
        // Make sure to update AppDelegate.applicationDidEnterBackground() as well.

        guard let oneMonthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date()) else { return }
        
        let midnightOneMonthAgo = Calendar.current.startOfDay(for: oneMonthAgo)
        Task.detached(priority: .background) {
            do
            {
                try await DatabaseManager.shared.purgeLoggedErrors(before: midnightOneMonthAgo)
            }
            catch
            {
                debugLog("[SideStore] Failed to purge logged errors before \(midnightOneMonthAgo). \(error)")
            }
        }
        
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>)
    {
        guard let context = URLContexts.first else { return }
        debugLog("[V3_URL] scene_request_received")
        self.open(context)
    }
}

private extension SceneDelegate
{
    func open(_ context: UIOpenURLContext)
    {
        // V3_HEADLESS_SCENE_URLS_V1: only the backup-result callback remains service-owned.
        guard !context.url.isFileURL else { return }
        _ = URLHandler.shared.handle(context.url)
    }
}




// V3_EXTERNAL_URL_LOG_REDACTION_V1: file URLs and pairing callback payloads are never logged.
