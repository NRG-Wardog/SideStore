//
//  AppDelegate.swift
//  AltStore
//
//  Created by Riley Testut on 5/9/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import UserNotifications
import AVFoundation
import Intents
import SideSign
import CoreData
import Nuke

extension AppDelegate
{
    nonisolated static let openPatreonSettingsDeepLinkNotification = Notification.Name(Bundle.Info.appbundleIdentifier + ".OpenPatreonSettingsDeepLinkNotification")
    nonisolated static let importAppDeepLinkNotification = Notification.Name(Bundle.Info.appbundleIdentifier + ".ImportAppDeepLinkNotification")
    nonisolated static let addSourceDeepLinkNotification = Notification.Name(Bundle.Info.appbundleIdentifier + ".AddSourceDeepLinkNotification")
    
    nonisolated static let appBackupDidFinish = Notification.Name(Bundle.Info.appbundleIdentifier + ".AppBackupDidFinish")
    
    nonisolated static let importAppDeepLinkURLKey = "fileURL"
    nonisolated static let appBackupResultKey = "result"
    nonisolated static let addSourceDeepLinkURLKey = "sourceURL"
    
    static func dumpSideBackupLogsIfNeeded() async {
        await Task.detached {
            for appGroup in Bundle.main.appGroups {
                guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { continue }
                let logFileURL = containerURL.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("SideBackup.log")
                debugLog("[AppDelegate] Checking for SideBackup log in group '\(appGroup)' at: \(logFileURL.path)")
                if FileManager.default.fileExists(atPath: logFileURL.path) {
                    debugLog("[AppDelegate] Found SideBackup log file in group '\(appGroup)'.")
                    do {
                        let logContents = try String(contentsOf: logFileURL, encoding: .utf8)
                        if logContents.isEmpty {
                            debugLog("[AppDelegate] SideBackup log file in group '\(appGroup)' is empty.")
                        } else {
                            debugLog("""
                            [SideBackup Logs (\(appGroup))]
                            
                            \(logContents.trimmingCharacters(in: .whitespacesAndNewlines))
                            
                            [SideBackup Logs End]
                            """)
                        }
                        try FileManager.default.removeItem(at: logFileURL)
                    } catch {
                        debugLog("[AppDelegate] Failed to read or delete SideBackup log file in group '\(appGroup)': \(error)")
                    }
                }
            }

        }.value
    }
}

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    
    #if !os(tvOS)
    private let intentHandler = IntentHandler()
    private let viewAppIntentHandler = ViewAppIntentHandler()
    #endif
    
    public let consoleLog = ConsoleLog()

    // Holds an imported .ipa URL when the app isn't active yet (cold launch),
    // so the import notification can be posted once the app becomes active.
    private var pendingImportIPAURL: URL?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        // navigation bar buttons spacing is too much (so hack it to use minimal spacing)
        // this is swift-5 specific behavior and might change
        // https://stackoverflow.com/a/64988363/11971304
        //
        // Warning: this affects all screens through out the app, and basically overrides storyboard
        let stackViewAppearance = UIStackView.appearance(whenContainedInInstancesOf: [UINavigationBar.self])
        stackViewAppearance.spacing = -8        // adjust as needed
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium
        let dateString = dateFormatter.string(from: Date())
        let versionString = Bundle.Info.activeBundleVersion

        func centerInBanner(_ text: String, width: Int = 49) -> String {
            let padding = max(0, width - text.count)
            let left = String(repeating: " ", count: padding / 2)
            let right = String(repeating: " ", count: padding - left.count)
            return "|\(left)\(text)\(right)|"
        }

        // register console logging and start capturing
        let suffixFormat: SuffixFormat = UserDefaults.standard.isRotateLogsOnStartupEnabled ? .timestamp : .none
        consoleLog.updateConfiguration(baseName: "console", suffixFormat: suffixFormat, policy: .subsequent)
        consoleLog.startCapturing()

        // register crash handler
        setupCrashHandler()
        
        UNUserNotificationCenter.current().delegate = self
        
        debugLog("===================================================")
        debugLog("|               App is Starting up                |")
        debugLog("===================================================")
        debugLog("| Console Logger started capturing output streams |")
        debugLog("===================================================")
        debugLog(centerInBanner(versionString))
        debugLog("===================================================")
        debugLog(centerInBanner(dateString))
        debugLog("===================================================")
        debugLog("\n")

        
        #if DEBUG
        UserDefaults.enableGlobalLogging()
//        UserDefaults.dumpAllSettingsOnBoot()
        #endif
        
        // Register default settings before doing anything else.
        UserDefaults.registerDefaults()
        syncMinimuxerBackendFromUserDefaults()

        SideStoreLogging.setLogging(UserDefaults.standard.isSideStoreVerboseLoggingEnabled)
        AltSign.setLogging(UserDefaults.standard.isAltSignVerboseLoggingEnabled)
        minimuxerSetLogging(UserDefaults.standard.isMinimuxerVerboseLoggingEnabled)
        SideSignConfigManager.shared.applyConfigToDeveloperPortal()

        // Override point for customization after application launch.
//        UserDefaults.standard.setValue(true, forKey: "com.apple.CoreData.MigrationDebug")
//        UserDefaults.standard.setValue(true, forKey: "com.apple.CoreData.SQLDebug")
        

        // Trigger daily boot sync for Anisette servers if needed
        if !UserDefaults.standard.useOnDeviceAnisette{
            Task.detached {
                await AnisetteServersManager.shared.performDailySyncIfNeeded()
            }
        }

        // Recreate Database if requested
        // NOTE: Userdefaults are local to the SideStore.app sandbox and are not shared
        if UserDefaults.standard.recreateDatabaseOnNextStart{
            // reset the state
            UserDefaults.standard.recreateDatabaseOnNextStart = false
            
            // re-create database
            DatabaseManager.recreateDatabase()
        }
        
        
        Task.detached {
            debugLog("[AppDelegate] Boot sequence starting...")
            await AppBootManager.shared.performBootSequence()
            debugLog("[AppDelegate] Boot sequence completed.")
        }
        
        
        let isFirstLaunch = (UserDefaults.standard.firstLaunch == nil)
        if isFirstLaunch
        {
            UserDefaults.standard.firstLaunch = Date()
        }
        
        Task.detached(priority: .userInitiated) {
            do
            {
                debugLog("Starting DatabaseManager...")
                try await DatabaseManager.shared.start()
                debugLog("Started DatabaseManager.")
                
                debugLog("Reconciling any staged drafts started...")
                await Self.reconcileSelfReinstallationIfNeeded()
                debugLog("Reconcile any staged drafts completed.")
                
                await WidgetDataManager.publishCurrentInstalledAppsIfNeeded(in: DatabaseManager.shared.viewContext)
                
                if isFirstLaunch
                {
                    AuthManager.shared.signOut()
                }

                // Perform one-time maintenance tasks after database is started
                MaintenanceManager.shared.performMaintenanceIfNeeded()
            }
            catch
            {
                debugLog("Failed to start DatabaseManager. Error: \(error)")
            }
        }
        
        self.setTintColor()
        self.prepareImageCache()

        SecureValueTransformer.register()        
        
        UserDefaults.standard.preferredServerID = Bundle.main.object(forInfoDictionaryKey: Bundle.Info.serverID) as? String
        
        #if DEBUG && targetEnvironment(simulator)
        UserDefaults.standard.isDebugModeEnabled = true
        #endif
        
        self.prepareForBackgroundFetch()
        
        return true
    }
    
    func applicationDidEnterBackground(_ application: UIApplication)
    {
        // Make sure to update SceneDelegate.sceneDidEnterBackground() as well.
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

    func applicationWillEnterForeground(_ application: UIApplication)
    {
        Task.detached {
            await AppManager.shared.reconcileInstalledApps()
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication)
    {
        // Flush any .ipa import that arrived before the app was active (cold launch).
        guard let url = self.pendingImportIPAURL else { return }
        self.pendingImportIPAURL = nil
        NotificationCenter.default.post(name: AppDelegate.importAppDeepLinkNotification, object: nil, userInfo: [AppDelegate.importAppDeepLinkURLKey: url])
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any]) -> Bool
    {
        return self.open(url)
    }
    
    #if !os(tvOS)
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any?
    {
        switch intent
        {
        case is RefreshAllIntent: return self.intentHandler
        case is ViewAppIntent: return self.viewAppIntentHandler
        default: return nil
        }
    }
    #endif
    
    func applicationWillTerminate(_ application: UIApplication) {
        // Stop console logging and clean up resources
        debugLog("\n ")
        debugLog("===================================================")
        debugLog("| Console Logger stopped capturing output streams |")
        debugLog("===================================================")
        debugLog("|           App is being terminated               |")
        debugLog("===================================================")
        consoleLog.stopCapturing()
    }
}

extension AppDelegate
{
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration
    {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
    
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>)
    {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }
}

private extension AppDelegate
{
    func setTintColor()
    {
        self.window?.tintColor = .altPrimary
    }
    
    func prepareImageCache()
    {
        // Avoid caching responses twice.
        DataLoader.sharedUrlCache.diskCapacity = 0
        
        let pipeline = ImagePipeline { configuration in
            do
            {
                let dataCache = try DataCache(name: "io.sidestore.Nuke")
                dataCache.sizeLimit = 512 * 1024 * 1024 // 512MB
                
                configuration.dataCache = dataCache
            }
            catch
            {
                debugLog("[AppDelegate] Failed to create image disk cache. Falling back to URL cache. \(error.localizedDescription)")
            }
        }
        
        ImagePipeline.shared = pipeline
        
        if let dataCache = ImagePipeline.shared.configuration.dataCache as? DataCache
        {
            debugLog("[AppDelegate] Current image cache size: \(dataCache.totalSize.formatted(.byteCount(style: .file)))")
        }
    }
    
    func open(_ url: URL) -> Bool
    {
        if url.isFileURL
        {
            guard url.pathExtension.lowercased() == "ipa" else { return false }

            // Copy the shared .ipa out of its security-scoped location into a
            // temporary directory we own, so it stays readable while signing.
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing { url.stopAccessingSecurityScopedResource() }
            }

            let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
            do {
                try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                debugLog("[AppDelegate] Failed to create temp directory for imported IPA: \(error)")
                return false
            }

            let ipaURL = temporaryDirectory.appendingPathComponent(url.lastPathComponent)

            do {
                try FileManager.default.copyItem(at: url, to: ipaURL)
            } catch {
                debugLog("[AppDelegate] Failed to copy imported IPA: \(error)")
                return false
            }

            if UIApplication.shared.applicationState == .active {
                NotificationCenter.default.post(name: AppDelegate.importAppDeepLinkNotification, object: nil, userInfo: [AppDelegate.importAppDeepLinkURLKey: ipaURL])
            } else {
                // Defer until the app is active (cold launch) — see applicationDidBecomeActive.
                self.pendingImportIPAURL = ipaURL
            }

            return true
        }
        else
        {
            return URLHandler.shared.handle(url)
        }
    }
}

extension AppDelegate
{
    private func prepareForBackgroundFetch()
    {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { (success, error) in
            // no-op
        }
        
        #if DEBUG && targetEnvironment(simulator)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data)
    {
        let tokenParts = deviceToken.map { data -> String in
            return String(format: "%02.2hhx", data)
        }
        
        let token = tokenParts.joined()
        #if DEBUG
        debugLog("[AppDelegate] Apple Push Notification(APN) Token: \(token)")
        #endif
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void)
    {
        self.application(application, performFetchWithCompletionHandler: completionHandler)
    }
    
    func application(_ application: UIApplication, performFetchWithCompletionHandler backgroundFetchCompletionHandler: @escaping (UIBackgroundFetchResult) -> Void)
    {
        #if !os(tvOS)
        if UserDefaults.standard.isBackgroundRefreshEnabled && !UserDefaults.standard.presentedLaunchReminderNotification
        {
            let threeHours: TimeInterval = 3 * 60 * 60
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: threeHours, repeats: false)
            
            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("App Refresh Tip", comment: "")
            content.body = NSLocalizedString("The more you open SideStore, the more chances it's given to refresh apps in the background.", comment: "")
            
            let request = UNNotificationRequest(identifier: "background-refresh-reminder5", content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request)
            
            UserDefaults.standard.presentedLaunchReminderNotification = true
        }
        #endif
        
        BackgroundTaskManager.shared.performExtendedBackgroundTask { (taskResult, taskCompletionHandler) in
            if let error = taskResult.error
            {
                debugLog("Error starting extended background task. Aborting. \(error)")
                backgroundFetchCompletionHandler(.failed)
                taskCompletionHandler()
                return
            }
            
            Task.detached(priority: .userInitiated) {
                do
                {
                    try await DatabaseManager.shared.start()
                    self.performBackgroundFetch { (backgroundFetchResult) in
                        backgroundFetchCompletionHandler(backgroundFetchResult)
                    } refreshAppsCompletionHandler: { (refreshAppsResult) in
                        taskCompletionHandler()
                    }
                }
                catch
                {
                    backgroundFetchCompletionHandler(.failed)
                    taskCompletionHandler()
                }
            }
        }
    }
    
    func performBackgroundFetch(backgroundFetchCompletionHandler: @escaping (UIBackgroundFetchResult) -> Void,
                                refreshAppsCompletionHandler: @escaping (Result<[String: Result<InstalledApp, Error>], Error>) -> Void)
    {
        self.fetchSources { (result) in
            switch result
            {
            case .failure: backgroundFetchCompletionHandler(.failed)
            case .success: backgroundFetchCompletionHandler(.newData)
            }
            
            if !UserDefaults.standard.isBackgroundRefreshEnabled
            {
                refreshAppsCompletionHandler(.success([:]))
            }
        }
        
        guard UserDefaults.standard.isBackgroundRefreshEnabled else { return }
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let installedApps = InstalledApp.fetchAppsForBackgroundRefresh(in: context)
        _ = try? AppManager.shared.backgroundRefresh(installedApps, completionHandler: refreshAppsCompletionHandler)
    }
}

private extension AppDelegate
{
    func fetchSources(completionHandler: @escaping (Result<Set<Source>, Error>) -> Void)
    {
        AppManager.shared.fetchSources() { (result) in
            do
            {
                let (sources, context) = try result.get()
                
                let previousUpdatesFetchRequest = InstalledApp.supportedUpdatesFetchRequest() as! NSFetchRequest<NSFetchRequestResult>
                previousUpdatesFetchRequest.includesPendingChanges = false
                previousUpdatesFetchRequest.resultType = .dictionaryResultType
                previousUpdatesFetchRequest.propertiesToFetch = [#keyPath(InstalledApp.bundleIdentifier),
                                                                 #keyPath(InstalledApp.storeApp.latestSupportedVersion.version),
                                                                 #keyPath(InstalledApp.storeApp.latestSupportedVersion._buildVersion)]
                
                let previousNewsItemsFetchRequest = NewsItem.fetchRequest() as NSFetchRequest<NSFetchRequestResult>
                previousNewsItemsFetchRequest.includesPendingChanges = false
                previousNewsItemsFetchRequest.resultType = .dictionaryResultType
                previousNewsItemsFetchRequest.propertiesToFetch = [#keyPath(NewsItem.identifier)]
                
                let previousUpdates = try context.fetch(previousUpdatesFetchRequest) as! [[String: String]]
                let previousNewsItems = try context.fetch(previousNewsItemsFetchRequest) as! [[String: String]]
                
                try context.save()
                
                
                
                let updatesFetchRequest = InstalledApp.supportedUpdatesFetchRequest()
                let newsItemsFetchRequest = NewsItem.fetchRequest() as NSFetchRequest<NewsItem>
                
                let updates = try context.fetch(updatesFetchRequest)
                let newsItems = try context.fetch(newsItemsFetchRequest)
                
                #if !os(tvOS)
                for update in updates
                {
                    guard let storeApp = update.storeApp, let latestSupportedVersion = storeApp.latestSupportedVersion, latestSupportedVersion.isSupported else { continue }
                    
                    if let previousUpdate = previousUpdates.first(where: { $0[#keyPath(InstalledApp.bundleIdentifier)] == update.bundleIdentifier })
                    {
                        // An update for this app was already available, so check whether the version or build version is different.
                        guard let previousVersion = previousUpdate[#keyPath(InstalledApp.storeApp.latestSupportedVersion.version)] else { continue }
                        
                        // previousUpdate might not contain buildVersion, but if it does then map empty string to nil to match AppVersion.
                        let previousBuildVersion = previousUpdate[#keyPath(InstalledApp.storeApp.latestSupportedVersion._buildVersion)].map { $0.isEmpty ? nil : "" }
                        
                        // Only show notification if previous latestSupportedVersion does not _exactly_ match current latestSupportedVersion.
                        guard previousVersion != latestSupportedVersion.version || previousBuildVersion != latestSupportedVersion.buildVersion  else { continue }
                    }
                    
                    let content = UNMutableNotificationContent()
                    content.title = NSLocalizedString("New Update Available", comment: "")
                    content.body = String(format: NSLocalizedString("%@ %@ is now available for download.", comment: ""), update.name, latestSupportedVersion.localizedVersion)
                    content.sound = .default
                    
                    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                    UNUserNotificationCenter.current().add(request)
                }
                
                for newsItem in newsItems
                {
                    guard !previousNewsItems.contains(where: { $0[#keyPath(NewsItem.identifier)] == newsItem.identifier }) else { continue }
                    guard !newsItem.isSilent else { continue }
                    
                    let content = UNMutableNotificationContent()
                    
                    if let app = newsItem.storeApp
                    {
                        content.title = String(format: NSLocalizedString("%@ News", comment: ""), app.name)
                    }
                    else
                    {
                        content.title = NSLocalizedString("SideStore News", comment: "")
                    }
                    
                    content.body = newsItem.title
                    content.sound = .default
                    
                    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                    UNUserNotificationCenter.current().add(request)
                }
                #else
                DispatchQueue.main.async {
                    if UIApplication.shared.applicationState == .active {
                        if !updates.isEmpty, let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) }).first {
                            let toastView = ToastView(text: "New Update Available", detailText: "\(updates.count) update(s) available")
                            toastView.show(in: window)
                        }
                    } else {
                        NotificationCenter.default.post(name: NSNotification.Name("TVTopShelfItemsDidChangeNotification"), object: nil)
                    }
                }
                #endif

                DispatchQueue.main.async {
                    UIApplication.shared.applicationIconBadgeNumber = updates.count
                }
                
                completionHandler(.success(sources))
            }
            catch
            {
                debugLog("Error fetching apps: \(error)")
                completionHandler(.failure(error))
            }
        }
    }
}

private extension AppDelegate {
    func setupCrashHandler() {
        NSSetUncaughtExceptionHandler { exception in
            // Clear handler immediately so execution can never recurse under any circumstance
            NSSetUncaughtExceptionHandler(nil)
            
            let stackTrace = exception.callStackSymbols.joined(separator: "\n")
            let message = """
            \n===================================================
            |           UNCAUGHT NSEXCEPTION CRASH            |
            ===================================================
              • Name: \(exception.name.rawValue)
              • Reason: \(exception.reason ?? "Unknown")
            
            Call Stack:
            \(stackTrace)
            ===================================================\n
            """
            
            debugLog(message)
            
            // Write directly to stderr to bypass Swift formatting/logger abstractions
            fputs(message, stderr)
            fflush(stderr)
            
            // Also write to NSLog (Apple System Log)
            NSLog("%@", message)
        }
        
        let fatalSignals = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
        for sig in fatalSignals {
            signal(sig) { signalNumber in
                signal(signalNumber, SIG_DFL)
                
                let signalName: String
                switch signalNumber {
                case SIGABRT: signalName = "SIGABRT (Abort/Assertion Failure)"
                case SIGSEGV: signalName = "SIGSEGV (Segmentation Fault)"
                case SIGBUS: signalName = "SIGBUS (Bus Error)"
                case SIGILL: signalName = "SIGILL (Illegal Instruction)"
                case SIGFPE: signalName = "SIGFPE (Floating Point Exception)"
                case SIGTRAP: signalName = "SIGTRAP (Trace Trap)"
                default: signalName = "Signal \(signalNumber)"
                }
                
                let stackTrace = Thread.callStackSymbols.joined(separator: "\n")
                let message = """
                \n===================================================
                |             UNCAUGHT FATAL SIGNAL               |
                ===================================================
                  • Signal: \(signalName)
                
                Call Stack:
                \(stackTrace)
                ===================================================\n
                """
                
                debugLog(message)
                fputs(message, stderr)
                fflush(stderr)
                NSLog("%@", message)
                
                raise(signalNumber)
            }
        }
    }
    
    static func reconcileSelfReinstallationIfNeeded() {
        guard let appGroup = Bundle.main.altstoreAppGroup,
              let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            debugLog("[AppDelegate] reconcileSelfReinstallation: Failed to get App Group container.")
            return
        }
        
        let jsonURL = containerURL.appendingPathComponent("StagedSelfReinstall.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            debugLog("[AppDelegate] reconcileSelfReinstallation: No staged self-reinstall metadata file found at \(jsonURL.path).")
            return
        }
        
        defer {
            try? FileManager.default.removeItem(at: jsonURL)
        }
        
        guard let jsonData = try? Data(contentsOf: jsonURL),
              let stagedData = (try? JSONSerialization.jsonObject(with: jsonData, options: [])) as? [String: Any] else {
            debugLog("[AppDelegate] reconcileSelfReinstallation: Failed to read StagedSelfReinstall.json.")
            return
        }
        
        let lastBundlePath = stagedData["lastBundlePath"] as? String
        let currBundlePath = Bundle.main.bundlePath
        debugLog("[AppDelegate] reconcileSelfReinstallation: Current BundlePath: '\(currBundlePath)', Last BundlePath: '\(lastBundlePath ?? "nil")'")
        
        if let lastBundlePath, currBundlePath != lastBundlePath {
            debugLog("[AppDelegate] reconcileSelfReinstallation: App reinstallation confirmed (BundlePath changed)! Applying staged updates to SideStore app in database.")
            let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            
            var didSave = false
            context.performAndWait {
                do {
                    if let _ = InstalledApp.deserialize(from: jsonData, format: .json, context: context) {
                        if context.hasChanges {
                            try context.save()
                            didSave = true
                            debugLog("[AppDelegate] reconcileSelfReinstallation: Database successfully updated and saved.")
                        }
                    } else {
                        debugLog("[AppDelegate] reconcileSelfReinstallation: Failed to restore InstalledApp from staged JSON data.")
                    }
                } catch {
                    debugLog("[AppDelegate] reconcileSelfReinstallation: CoreData error during save: \(error)")
                }
            }
            
            if didSave {
                Task {
                    await WidgetDataManager.publishCurrentInstalledApps(in: context)
                }
            }
        } else {
            debugLog("[AppDelegate] reconcileSelfReinstallation: BundlePath matched pre-installation path. Reinstallation was not completed or failed.")
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
public struct V3AuthServiceSnapshot: Equatable {
    public let authenticated: Bool
    public let credentialRoutePresent: Bool
    public let provisioningIncomplete: Bool
    public let provisioningRetryAvailable: Bool
    public let authenticationActive: Bool
    public let authenticationSessionID: String?
    public let identityStamp: String?
    public let identityStable: Bool

    public init(authenticated: Bool, provisioningIncomplete: Bool,
                provisioningRetryAvailable: Bool, authenticationActive: Bool,
                authenticationSessionID: String?, credentialRoutePresent: Bool = false,
                identityStamp: String? = nil, identityStable: Bool = true) {
        self.authenticated = authenticated
        self.credentialRoutePresent = credentialRoutePresent
        self.provisioningIncomplete = provisioningIncomplete
        self.provisioningRetryAvailable = provisioningRetryAvailable
        self.authenticationActive = authenticationActive
        self.authenticationSessionID = authenticationSessionID
        self.identityStamp = identityStamp
        self.identityStable = identityStable
    }
}

import CoreFoundation

/// The lock protects only this small in-memory stamp state. Callers hold no
/// lock while network requests, authentication prompts, or provisioning run.
final class V3AuthIdentityStampState: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let stamp: String
        let generation: UInt64
        let stable: Bool
    }

    private let lock = NSLock()
    private let processNonce = UUID().uuidString
    private var revision: UInt64 = 0
    private var transitionDepth = 0

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(stamp: processNonce + ":\(revision)",
            generation: revision, stable: transitionDepth == 0)
    }

    func beginTransition() {
        lock.lock()
        revision &+= 1
        transitionDepth += 1
        lock.unlock()
    }

    func completeTransition() {
        lock.lock()
        revision &+= 1
        if transitionDepth > 0 { transitionDepth -= 1 }
        lock.unlock()
    }

    func advanceGeneration() {
        lock.lock()
        revision &+= 1
        lock.unlock()
    }

    /// Performs a short in-memory commit only while the captured identity is
    /// still current. The closure must not suspend or perform I/O.
    func runIfCurrent(_ capturedStamp: String, commit: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard transitionDepth == 0, processNonce + ":\(revision)" == capturedStamp else {
            return false
        }
        commit()
        return true
    }
}

enum V3TwoFactorStep: String, Equatable {
    case chooseDeliveryMethod
    case choosePhoneNumber
    case deliveryRequested
    case enterVerificationCode
    case verifyingCode
    case completed
    case failed
    case cancelled

    var progressLabel: String? {
        switch self {
        case .choosePhoneNumber: return "Choose a phone number for this verification request..."
        case .deliveryRequested: return "Requesting verification..."
        case .verifyingCode: return "Verifying code..."
        default: return nil
        }
    }

    static func afterDeliveryChoice(_ method: String, phoneCount: Int) -> Self? {
        guard ["trustedDevice", "sms", "voice"].contains(method) else { return nil }
        return method == "sms" || method == "voice" ? (phoneCount > 1 ? .choosePhoneNumber : .deliveryRequested) : .deliveryRequested
    }

    static func afterDelivery(_ method: String) -> Self? {
        ["trustedDevice", "sms", "voice"].contains(method) ? .enterVerificationCode : nil
    }

    static func afterVerification(accepted: Bool) -> Self {
        accepted ? .completed : .enterVerificationCode
    }

    static var afterChangeMethod: Self { .chooseDeliveryMethod }
}

enum V3AuthTerminalPolicy {
    static func resolve(authenticationSucceeded: Bool, authoritativeAccountMatches: Bool,
                        provisioningFailed: Bool, cancelled: Bool) -> String {
        if authenticationSucceeded || authoritativeAccountMatches {
            return provisioningFailed || cancelled ? "authenticatedProvisioningIncomplete" : "completed"
        }
        return cancelled ? "cancelled" : "failed"
    }
}

struct V3AuthPostAuthenticationFailurePresentation: Equatable {
    let stage: CombinedFailure.Stage
    let message: String
}

enum V3AuthPostAuthenticationFailurePolicy {
    static func resolve(cancelled: Bool, savedSessionUnavailable: Bool)
        -> V3AuthPostAuthenticationFailurePresentation {
        let message: String
        if savedSessionUnavailable {
            message = "Signed in successfully, but SideStore could not reuse the saved Apple session to retry provisioning. Sign in again with this Apple ID before retrying setup."
        } else if cancelled {
            message = "Signed in successfully. Provisioning was cancelled before setup finished."
        } else {
            message = "Signed in successfully, but provisioning could not be completed."
        }
        return V3AuthPostAuthenticationFailurePresentation(stage: .provisioning, message: message)
    }
}

enum V3AuthAttemptAuthenticationPolicy {
    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    static func confirms(authenticationCallbackSeen: Bool, submittedAppleID: String?,
                         activeAppleID: String?, accountAppleIDAtStart: String?) -> Bool {
        if authenticationCallbackSeen { return true }
        guard let submitted = normalized(submittedAppleID),
              normalized(activeAppleID) == submitted else { return false }
        return normalized(accountAppleIDAtStart) != submitted
    }
}

enum V3AuthPromptFailurePolicy {
    static func applying(reply: [String: Any], current: [String: Any]?) -> [String: Any]? {
        (reply["previousFailure"] as? [String: Any]) ?? current
    }

    static func isVisible(_ failure: [String: Any]?, promptKind: String?) -> Bool {
        failure != nil && promptKind == "credentials"
    }

    static func clearingAfterSubmission(_ failure: [String: Any]?, promptKind: String?) -> [String: Any]? {
        promptKind == "credentials" ? nil : failure
    }

    static func clearingOnDismiss(_ failure: [String: Any]?) -> [String: Any]? { nil }
}

// A picker selection survives dismissal and any in-flight snapshot reload.
// The picker and operation occupy one host-owned cover, so SwiftUI never has to
// race two unrelated root presentations.
enum V3AuthSessionResponsePolicy {
    static func mayRespond(terminalIsEmpty: Bool, cancellationRequested: Bool,
                           promptMatches: Bool) -> Bool {
        terminalIsEmpty && !cancellationRequested && promptMatches
    }

    static func mayApplyReply(currentSessionID: String?, replySessionID: String,
                              cancellationInProgress: Bool,
                              submittedPromptID: String? = nil,
                              currentPromptID: String? = nil,
                              currentRevision: Int? = nil,
                              replyRevision: Int? = nil) -> Bool {
        guard !cancellationInProgress, currentSessionID == replySessionID else { return false }
        if let currentRevision {
            guard let replyRevision, replyRevision >= currentRevision else { return false }
        }
        guard let submittedPromptID else { return true }
        return currentPromptID == submittedPromptID
    }

    static func mayAcceptStartedSession(expectedSessionID: String, replySessionID: String?,
                                        currentSessionID: String?, cancellationInProgress: Bool) -> Bool {
        !cancellationInProgress && replySessionID == expectedSessionID &&
            currentSessionID == expectedSessionID
    }

    static func mayLaunchCreatedSession(sessionID: String, activeSessionID: String?,
                                        cancellationRequested: Bool, terminalIsEmpty: Bool,
                                        requestCancelled: Bool = false) -> Bool {
        activeSessionID == sessionID && !cancellationRequested && !requestCancelled && terminalIsEmpty
    }
}

enum V3AuthPollResponsePolicy {
    static func mayApply(currentSessionID: String?, replySessionID: String,
                         cancellationInProgress: Bool, currentRevision: Int,
                         replyRevision: Int?, currentPromptID: String?,
                         replyPromptID: String?) -> Bool {
        guard !cancellationInProgress, currentSessionID == replySessionID,
              let replyRevision, replyRevision >= currentRevision else { return false }
        if replyRevision == currentRevision, let currentPromptID,
           replyPromptID != currentPromptID { return false }
        return true
    }
}

enum V3AuthPromptSubmissionPolicy {
    static func mayShowFailure(currentSessionID: String?, submittedSessionID: String,
                               currentPromptID: String?, submittedPromptID: String,
                               cancellationInProgress: Bool) -> Bool {
        !cancellationInProgress && currentSessionID == submittedSessionID &&
            currentPromptID == submittedPromptID
    }
}

enum V3AuthPromptResponsePolicy {
    static func maySubmit(state: String, currentPromptID: String?, submittedPromptID: String,
                          isSubmitting: Bool, cancellationInProgress: Bool) -> Bool {
        state == "awaitingPrompt" && currentPromptID == submittedPromptID &&
            !isSubmitting && !cancellationInProgress
    }

    static func shouldClearSubmissionFailure(oldPromptID: String?, newPromptID: String?,
                                             state: String) -> Bool {
        state == "awaitingPrompt" && oldPromptID != newPromptID
    }

    static func failureMessage(_ error: Error) -> String {
        if let failure = error as? CombinedFailure {
            return "\(failure.safeMessage) \(failure.recovery)"
        }
        return "The verification response could not be confirmed. The exact underlying cause could not be safely identified. Check the sign-in status before trying again.\nError ID: SS-AUTH-C11"
    }

    static func diagnostics(_ error: Error) -> String {
        if let failure = error as? CombinedFailure { return failure.technicalDetails }
        return "schema=1 diagnostic_code=SS-AUTH-C11 builder_commit=\(V3DiagnosticBuild.commit) operation=authRespond stage=command code=failed correlation=unavailable underlying_domain=redacted underlying_code=redacted retryable=unknown"
    }

    static func blocksResubmission(_ error: Error) -> Bool {
        (error as? CombinedFailure)?.retryable == false
    }
}

enum V3TwoFactorRetryPolicy {
    static func shouldReuseCredentialsForCodeRetry(authFailureKind: String?) -> Bool {
        authFailureKind == "invalidCode"
    }

    static func recoveryMessage(authFailureKind: String?) -> String? {
        guard shouldReuseCredentialsForCodeRetry(authFailureKind: authFailureKind) else { return nil }
        return "The verification code was not accepted. Enter a new code and try again."
    }
}

struct V3AuthStartCancellationRegistry {
    private var cancelled: [String: Date] = [:]

    mutating func cancelBeforeStart(_ id: String, now: Date = Date()) -> Bool {
        guard let parsed = UUID(uuidString: id), parsed.uuidString == id else { return false }
        prune(now: now)
        cancelled[id] = now.addingTimeInterval(600)
        prune(now: now)
        return true
    }

    mutating func consume(_ id: String, now: Date = Date()) -> Bool {
        prune(now: now)
        return cancelled.removeValue(forKey: id) != nil
    }

    func contains(_ id: String, now: Date = Date()) -> Bool {
        guard let expiry = cancelled[id] else { return false }
        return expiry > now
    }

    mutating func prune(now: Date = Date()) {
        cancelled = cancelled.filter { $0.value > now }
        guard cancelled.count > 256 else { return }
        let oldest = cancelled.sorted { $0.value < $1.value }
        for (id, _) in oldest.prefix(cancelled.count - 256) { cancelled.removeValue(forKey: id) }
    }
}

// V3_SIGNOUT_AUTHORITATIVE_POSTCONDITION_V1: upstream signOut can return after
// swallowing a Core Data deactivation save failure. The host therefore reports
// success only when the returned authoritative snapshot explicitly confirms all
// three sign-out facts. Missing facts remain unknown; they are never coerced to
// false for the success decision.
enum V3SignOutOutcome: Equatable {
    case confirmed
    case accountStateRemains
    case authenticationRemains
    case snapshotIncomplete
}

enum V3SignOutOutcomePolicy {
    static func resolve(authenticated: Bool?, activeAccountPresent: Bool?,
                        activeTeamPresent: Bool?) -> V3SignOutOutcome {
        guard let authenticated, let activeAccount = activeAccountPresent,
              let activeTeam = activeTeamPresent else {
            return .snapshotIncomplete
        }
        if authenticated { return .authenticationRemains }
        if activeAccount || activeTeam { return .accountStateRemains }
        return .confirmed
    }

    static func successNotice(for outcome: V3SignOutOutcome) -> String? {
        outcome == .confirmed ? "Signed out successfully." : nil
    }

    static func whatHappened(for outcome: V3SignOutOutcome) -> String? {
        switch outcome {
        case .confirmed: return nil
        case .accountStateRemains:
            return "Sign-in credentials were cleared, but SideStore still reports an active account or team." + "\nError ID: SS-AUTH-D094"
        case .authenticationRemains:
            return "SideStore still reports an active sign-in. Sign-out is not confirmed." + "\nError ID: SS-AUTH-D095"
        case .snapshotIncomplete:
            return "SideStore did not return enough account state to confirm sign-out." + "\nError ID: SS-AUTH-D060"
        }
    }

    static func whatToDo(for outcome: V3SignOutOutcome) -> String? {
        guard outcome != .confirmed else { return nil }
        switch outcome {
        case .confirmed: return nil
        case .accountStateRemains:
            return "Reload status. If the account or team remains active, try Sign Out again."
        case .authenticationRemains:
            return "Reload status to check the current account state, then try Sign Out again if it remains signed in."
        case .snapshotIncomplete:
            return "Reload status before continuing. If SideStore still reports a signed-in account, try Sign Out again."
        }
    }
}

struct V3AuthSessionOwnership {
    private(set) var deadlines: [String: Date] = [:]
    private static let terminalStates: Set<String> = [
        "completed", "authenticatedProvisioningIncomplete", "cancelled", "timedOut", "failed"
    ]

    mutating func register(sessionID: String, deadline: Date, now: Date = Date()) {
        prune(now: now)
        guard let parsed = UUID(uuidString: sessionID), parsed.uuidString == sessionID,
              deadline > now else { return }
        deadlines[sessionID] = deadline
        if deadlines.count > 256 {
            let oldest = deadlines.sorted { $0.value < $1.value }
            for (id, _) in oldest.prefix(deadlines.count - 256) { deadlines.removeValue(forKey: id) }
        }
    }

    mutating func observe(operation: String, sessionID: String, replySessionID: String?,
                          state: String?, now: Date = Date()) {
        prune(now: now)
        guard replySessionID == sessionID, let state, deadlines[sessionID] != nil else { return }
        if Self.terminalStates.contains(state) {
            deadlines.removeValue(forKey: sessionID)
        } else if ["authBegin", "authRetryProvisioning"].contains(operation),
                  ["working", "awaitingPrompt"].contains(state) {
            // A successful new begin returns only after the previous auth task
            // has unwound, so that response supersedes older host ownership.
            deadlines = deadlines.filter { $0.key == sessionID }
        }
    }

    mutating func prune(now: Date = Date()) {
        deadlines = deadlines.filter { $0.value > now }
    }

    mutating func clear(sessionID: String) {
        deadlines.removeValue(forKey: sessionID)
    }

    mutating func reconcile(sessionID: String, authenticationActive: Bool) {
        guard !authenticationActive else { return }
        clear(sessionID: sessionID)
    }

    mutating func clearAll() {
        deadlines.removeAll()
    }

    mutating func hasActiveSession(now: Date = Date()) -> Bool {
        prune(now: now)
        return !deadlines.isEmpty
    }

    func owns(_ sessionID: String, now: Date = Date()) -> Bool {
        deadlines[sessionID].map { $0 > now } == true
    }
}

enum V3ProvisioningResumeAvailabilityPolicy {
    static func canResume(authenticated: Bool, currentAppleID: String?, resumableAppleID: String?,
                          hasSession: Bool = true, hasTeamAccount: Bool = true,
                          teamAccountAppleID: String? = nil) -> Bool {
        guard authenticated, hasSession, hasTeamAccount,
              let currentAppleID, let resumableAppleID else { return false }
        guard let current = V3AuthIdentityBindingPolicy.normalizedOwner(currentAppleID),
              let resumable = V3AuthIdentityBindingPolicy.normalizedOwner(resumableAppleID),
              let teamOwner = V3AuthIdentityBindingPolicy.normalizedOwner(teamAccountAppleID) else { return false }
        return current == resumable && current == teamOwner
    }
}

// V3_AUTH_IDENTITY_BINDING_V1: the stored route remains an upstream fact;
// developer-portal readiness requires a coherent DSID/token session and the
// exact account owner associated with the team being sent to Apple.
enum V3AuthIdentityBindingPolicy {
    static func normalizedOwner(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    static func hasTokenBackedRoute(credentialRoutePresent: Bool,
                                    dsid: String?, xcodeToken: String?) -> Bool {
        credentialRoutePresent && dsid?.isEmpty == false && xcodeToken?.isEmpty == false
    }

    static func hasUsableSession(credentialRoutePresent: Bool, dsid: String?,
                                 xcodeToken: String?, sessionDSID: String?,
                                 sessionXcodeToken: String?,
                                 generationBefore: UInt64, generationAfter: UInt64) -> Bool {
        guard hasTokenBackedRoute(credentialRoutePresent: credentialRoutePresent,
                dsid: dsid, xcodeToken: xcodeToken), generationBefore == generationAfter,
              let dsid, let xcodeToken,
              let sessionDSID, !sessionDSID.isEmpty,
              let sessionXcodeToken, !sessionXcodeToken.isEmpty else { return false }
        return dsid == sessionDSID && xcodeToken == sessionXcodeToken
    }

    static func sameCredentialRoute(appleIDBefore: String?, appleIDAfter: String?,
                                    dsidBefore: String?, dsidAfter: String?,
                                    tokenBefore: String?, tokenAfter: String?) -> Bool {
        normalizedOwner(appleIDBefore) == normalizedOwner(appleIDAfter) &&
            dsidBefore == dsidAfter && tokenBefore == tokenAfter
    }

    static func mayUseTeam(sessionOwner: String?, teamOwner: String?) -> Bool {
        guard let sessionOwner = normalizedOwner(sessionOwner),
              let teamOwner = normalizedOwner(teamOwner) else { return false }
        return sessionOwner == teamOwner
    }

    static func resolveColdTeamOwner(storedTeamOwners: [String],
                                     activeTeamIdentifier: String?, requestedTeamIdentifier: String,
                                     activeAccountOwner: String?, sessionOwner: String?) -> String? {
        let activeTeamMatches = activeTeamIdentifier == requestedTeamIdentifier
        if activeTeamMatches, mayUseTeam(sessionOwner: sessionOwner, teamOwner: activeAccountOwner) {
            return normalizedOwner(sessionOwner)
        }
        let owners = Set(storedTeamOwners.compactMap(normalizedOwner))
        return owners.count == 1 ? owners.first : nil
    }

    static func mayFetchTeams(sessionOwner: String?, requestedOwner: String?,
                              generationBefore: UInt64, generationAfter: UInt64,
                              cancelled: Bool = false) -> Bool {
        mayDispatchTeamRequest(sessionOwner: sessionOwner, teamOwner: requestedOwner,
            generationBefore: generationBefore, generationAfter: generationAfter,
            cancelled: cancelled)
    }

    static func mayDispatchTeamRequest(sessionOwner: String?, teamOwner: String?,
                                       generationBefore: UInt64, generationAfter: UInt64,
                                       cancelled: Bool = false) -> Bool {
        mayDispatch(generationBefore: generationBefore, generationAfter: generationAfter,
                    cancelled: cancelled) &&
            mayUseTeam(sessionOwner: sessionOwner, teamOwner: teamOwner)
    }

    static func mayDispatch(generationBefore: UInt64, generationAfter: UInt64,
                            cancelled: Bool = false) -> Bool {
        !cancelled && generationBefore == generationAfter
    }

    static func mayProjectIdentity(generationBefore: UInt64, generationAfter: UInt64) -> Bool {
        generationBefore == generationAfter
    }
}

enum V3ProvisioningResumeIdentityPolicy {
    static func select(authenticatedSessionAppleID: String?, submittedAppleID: String?,
                       activeAppleID: String?) -> String? {
        for candidate in [authenticatedSessionAppleID, submittedAppleID, activeAppleID] {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !value.isEmpty else { continue }
            return value
        }
        return nil
    }
}

enum V3ProvisioningResumeExecutionPolicy {
    static func mayUseCachedSignIn(forceProvisioningRetry: Bool,
                                   requireFullProvisioning: Bool = false) -> Bool {
        !forceProvisioningRetry && !requireFullProvisioning
    }

    static func mayPromptForCredentials(forceProvisioningRetry: Bool) -> Bool {
        !forceProvisioningRetry
    }
}

// Completion is evidence from a full SignInOperation, never a database row.
// The journal is invalidated durably BEFORE a new attempt can mutate anything.
// A process restart may reuse verified completion only for the exact hashed
// credential route, team, certificate and device binding, never row presence.
struct V3ProvisioningCompletionState {
    private static let journalKey = "V3VerifiedProvisioningCompletionV1"
    private let defaults: UserDefaults
    private(set) var attemptID: String?
    private var owner: String?
    private var identityStamp: String?
    private var completed = false
    private var completedBinding: String?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func persist(_ record: [String: Any]) -> Bool {
        defaults.set(record, forKey: Self.journalKey)
        return defaults.synchronize() &&
            defaults.dictionary(forKey: Self.journalKey).map { NSDictionary(dictionary: $0).isEqual(to: record) } == true
    }

    @discardableResult
    mutating func begin(attemptID: String, owner: String?, identityStamp: String) -> Bool {
        guard persist(["version": 1, "state": "incomplete", "attemptID": attemptID,
                       "identityStamp": identityStamp]) else { return false }
        self.attemptID = attemptID
        self.owner = V3AuthIdentityBindingPolicy.normalizedOwner(owner)
        self.identityStamp = identityStamp
        completed = false
        completedBinding = nil
        return true
    }

    mutating func authenticated(attemptID: String, owner: String?, identityStamp: String) {
        guard self.attemptID == attemptID else { return }
        self.owner = V3AuthIdentityBindingPolicy.normalizedOwner(owner)
        self.identityStamp = identityStamp
        completed = false
    }

    @discardableResult
    mutating func complete(attemptID: String, owner: String?, identityStamp: String,
                           identityStable: Bool, fullProvisioningCompleted: Bool,
                           activeAccountMatches: Bool, activeTeamMatches: Bool,
                           activeCertificateMatches: Bool, binding: String?) -> Bool {
        guard self.attemptID == attemptID,
              self.owner != nil, self.owner == V3AuthIdentityBindingPolicy.normalizedOwner(owner),
              self.identityStamp == identityStamp, identityStable,
              fullProvisioningCompleted, activeAccountMatches, activeTeamMatches,
              activeCertificateMatches, let binding, !binding.isEmpty,
              persist(["version": 1, "state": "complete", "attemptID": attemptID,
                       "identityStamp": identityStamp, "binding": binding]) else { return false }
        completed = true
        completedBinding = binding
        return true
    }

    func status(owner: String?, identityStamp: String, identityStable: Bool,
                activeAccountPresent: Bool, activeTeamPresent: Bool,
                activeCertificatePresent: Bool, binding: String?) -> String {
        guard identityStable, let owner = V3AuthIdentityBindingPolicy.normalizedOwner(owner) else { return "unknown" }
        let prerequisitesPresent = activeAccountPresent && activeTeamPresent && activeCertificatePresent
        if attemptID != nil {
            guard self.owner == owner, self.identityStamp == identityStamp else { return "unknown" }
            return completed && prerequisitesPresent && binding == completedBinding ? "complete" : "incomplete"
        }
        guard let record = defaults.dictionary(forKey: Self.journalKey),
              record["version"] as? Int == 1, let binding, !binding.isEmpty,
              record["state"] as? String == "complete", record["binding"] as? String == binding else {
            return "unknown"
        }
        return prerequisitesPresent ? "complete" : "incomplete"
    }
}

enum V3ProvisioningReauthenticationIdentityPolicy {
    static func mayAuthenticate(expectedOwner: String, submittedOwner: String?,
                                currentOwner: String?, capturedStamp: String,
                                currentStamp: String, identityStable: Bool) -> Bool {
        guard let expected = V3AuthIdentityBindingPolicy.normalizedOwner(expectedOwner) else { return false }
        return expected == V3AuthIdentityBindingPolicy.normalizedOwner(submittedOwner) &&
            expected == V3AuthIdentityBindingPolicy.normalizedOwner(currentOwner) &&
            V3AuthReadStampPolicy.mayReturn(capturedStamp: capturedStamp,
                currentStamp: currentStamp, stable: identityStable)
    }
}

enum V3ProvisioningRetryRecoveryPolicy {
    static func availabilityAfterFailure(snapshotConfirmed: Bool,
                                         snapshotAllowsRetry: Bool,
                                         previouslyConfirmedAvailable: Bool) -> Bool {
        snapshotConfirmed ? snapshotAllowsRetry : previouslyConfirmedAvailable
    }
}

enum V3AuthTimeoutReconciliationPolicy {
    static func shouldReconcileAfterTerminal(_ state: String) -> Bool {
        ["timedOut", "failed", "cancelled", "resultUnknown", "promptExpired"].contains(state) ||
            state == "authenticatedProvisioningIncomplete"
    }
}

struct V3AuthReconciliationPresentation: Equatable {
    let state: String
    let message: String
}

enum V3AuthReconciliationPresentationPolicy {
    static func shouldPreserveActivePrompt(reportedState: String, hasPrompt: Bool,
                                           activeSessionMatches: Bool,
                                           cancellationInProgress: Bool) -> Bool {
        hasPrompt && activeSessionMatches && !cancellationInProgress &&
            ["working", "awaitingPrompt"].contains(reportedState)
    }

    static func resolve(reportedState: String, authenticated: Bool,
                        provisioningIncomplete: Bool,
                        previousFailureMessage: String? = nil,
                        authenticationActive: Bool = false) -> V3AuthReconciliationPresentation {
        guard authenticated else {
            switch reportedState {
            case "timedOut":
                return .init(state: "timedOut", message: "Sign-in timed out. SideStore reports that no account is currently signed in." + "\nError ID: SS-AUTH-D069")
            case "cancelled":
                return .init(state: "cancelled", message: "Sign-in was cancelled. SideStore reports that no account is currently signed in.")
            default:
                return .init(state: reportedState, message: "")
            }
        }
        if authenticationActive {
            return .init(state: "authenticatedProvisioningIncomplete",
                message: "Apple ID signed in successfully. SideStore is still finishing provisioning.")
        }
        switch reportedState {
        case "failed":
            var message = provisioningIncomplete
                ? "The sign-in attempt did not complete. SideStore reports authentication, but device provisioning is incomplete." + "\nError ID: SS-AUTH-D070"
                : "The sign-in attempt did not complete. SideStore currently reports an account as signed in." + "\nError ID: SS-AUTH-D071"
            if let previousFailureMessage { message += " " + previousFailureMessage }
            return .init(state: "failed", message: message)
        case "timedOut":
            return .init(state: "timedOut", message: provisioningIncomplete
                ? "The sign-in attempt timed out. SideStore reports authentication, but device provisioning is incomplete." + "\nError ID: SS-AUTH-D072"
                : "The sign-in attempt timed out. SideStore currently reports an account as signed in." + "\nError ID: SS-AUTH-D073")
        case "cancelled":
            return .init(state: "cancelled", message: provisioningIncomplete
                ? "The sign-in attempt was cancelled. SideStore reports authentication, but device provisioning is incomplete."
                : "The sign-in attempt was cancelled. SideStore currently reports an account as signed in.")
        case "resultUnknown":
            return .init(state: "resultUnknown", message: provisioningIncomplete
                ? "The sign-in result remains unconfirmed. SideStore reports authentication, but device provisioning is incomplete." + "\nError ID: SS-AUTH-D074"
                : "The sign-in result remains unconfirmed. SideStore currently reports an account as signed in." + "\nError ID: SS-AUTH-D075")
        case "promptExpired":
            return .init(state: "promptExpired", message: provisioningIncomplete
                ? "The verification session expired. SideStore reports authentication, but device provisioning is incomplete." + "\nError ID: SS-AUTH-D076"
                : "The verification session expired. SideStore currently reports an account as signed in." + "\nError ID: SS-AUTH-D077")
        default:
            return provisioningIncomplete
                ? .init(state: "authenticatedProvisioningIncomplete", message: "Apple ID signed in successfully.")
                : .init(state: "completed", message: "")
        }
    }
}

enum V3AuthInactiveSessionResolutionPolicy {
    static func resolve(reportedState: String, authenticated: Bool,
                        authenticationActive: Bool,
                        anotherSessionActive: Bool = false) -> V3AuthReconciliationPresentation? {
        if anotherSessionActive && !authenticated &&
           ["working", "awaitingPrompt", "resultUnknown"].contains(reportedState) {
            return .init(state: "resultUnknown",
                message: "Another Apple sign-in session is active. This request could not be matched to it. Wait for it to finish, then reload status." + "\nError ID: SS-AUTH-D078")
        }
        guard !authenticated, !authenticationActive,
              ["working", "awaitingPrompt", "resultUnknown"].contains(reportedState) else { return nil }
        return .init(state: "failed",
            message: "SideStore confirmed that no account is currently signed in. You can start a new sign-in.")
    }
}

struct V3AuthOtherSessionPresentation: Equatable {
    let state: String
    let message: String
    let clearPrompt: Bool
}

enum V3AuthOtherSessionReconciliationPolicy {
    static func resolve(reportedState: String, authenticated: Bool,
                        anotherSessionActive: Bool) -> V3AuthOtherSessionPresentation? {
        guard anotherSessionActive,
              ["idle", "working", "awaitingPrompt", "resultUnknown",
               "authenticatedProvisioningIncomplete"].contains(reportedState) else { return nil }
        let accountState = authenticated ? "Apple ID is signed in, but " : ""
        return .init(state: "resultUnknown",
            message: accountState + "another sign-in session is active. This request could not be matched to it. Wait for it to finish, then reload status.",
            clearPrompt: true)
    }
}

struct V3AuthReconciliationTicket: Equatable {
    let generation: UInt64
    let sessionID: String?
    let state: String
    let revision: Int
}

struct V3AuthReconciliationGate {
    private(set) var generation: UInt64 = 0

    mutating func invalidate() {
        generation &+= 1
    }

    mutating func begin(sessionID: String?, state: String, revision: Int) -> V3AuthReconciliationTicket {
        generation &+= 1
        return V3AuthReconciliationTicket(generation: generation, sessionID: sessionID,
            state: state, revision: revision)
    }

    func mayApply(_ ticket: V3AuthReconciliationTicket, sessionID: String?,
                  state: String, revision: Int) -> Bool {
        ticket.generation == generation && ticket.sessionID == sessionID &&
            ticket.state == state && ticket.revision == revision
    }

    func ownsSingleReconciliation(after priorGeneration: UInt64) -> Bool {
        generation == (priorGeneration &+ 1)
    }
}

enum V3AuthReconciliationSessionPolicy {
    static func mayStart(expectedSessionID: String?, currentSessionID: String?) -> Bool {
        expectedSessionID == nil || expectedSessionID == currentSessionID
    }
}

enum V3AuthSessionCorrelationPolicy {
    static func isActive(sessionID: String?, authenticationActive: Bool,
                         activeSessionID: String?) -> Bool {
        guard authenticationActive, let sessionID, let activeSessionID else { return false }
        return sessionID == activeSessionID
    }

    static func hasOtherActiveSession(sessionID: String?, authenticationActive: Bool,
                                      activeSessionID: String?) -> Bool {
        guard authenticationActive, let activeSessionID else { return false }
        guard let sessionID else { return true }
        return sessionID != activeSessionID
    }
}

enum V3AuthSnapshotAuthorityPolicy {
    struct Facts: Equatable {
        let authenticated: Bool
        let credentialRoutePresent: Bool
        let provisioningIncomplete: Bool
        let provisioningRetryAvailable: Bool
        let authenticationActive: Bool
        let authenticationSessionID: String?
    }

    static func facts(_ snapshot: V3AuthServiceSnapshot) -> Facts {
        Facts(authenticated: snapshot.identityStable && snapshot.authenticated,
              credentialRoutePresent: snapshot.identityStable && snapshot.credentialRoutePresent,
              provisioningIncomplete: snapshot.identityStable && snapshot.provisioningIncomplete,
              provisioningRetryAvailable: snapshot.identityStable && snapshot.provisioningRetryAvailable,
              authenticationActive: snapshot.authenticationActive,
              authenticationSessionID: snapshot.authenticationSessionID)
    }

    static func isAuthenticated(_ snapshot: [String: Bool]) -> Bool {
        snapshot["authenticated"] == true
    }

    static func needsSignIn(authenticated: Bool) -> Bool { !authenticated }
}

struct V3AccountSessionPresentation: Equatable {
    let showSignIn: Bool
    let showSavedAppleID: Bool
    let showUnverifiedSavedState: Bool
    let showRetainedCertificateGuidance: Bool
    let showSignOut: Bool
}

enum V3AccountSessionPresentationPolicy {
    static func resolve(authenticated: Bool, activeAccountPresent: Bool,
                        activeTeamPresent: Bool, activeCertificatePresent: Bool) -> V3AccountSessionPresentation {
        let hasSavedAccountState = activeAccountPresent || activeTeamPresent
        return V3AccountSessionPresentation(
            showSignIn: !authenticated,
            showSavedAppleID: activeAccountPresent,
            showUnverifiedSavedState: !authenticated && hasSavedAccountState,
            showRetainedCertificateGuidance: !authenticated && activeCertificatePresent,
            // Sign Out clears the saved account/team session, but deliberately
            // retains signing certificates. A certificate alone cannot justify
            // presenting Sign Out as a way to remove stale local state.
            showSignOut: authenticated || hasSavedAccountState)
    }
}

enum V3DeveloperDataActionAvailabilityPolicy {
    static func isEnabled(authenticated: Bool, isLoading: Bool) -> Bool {
        authenticated && !isLoading
    }
}

struct V3AuthSessionUnavailablePresentation: Equatable {
    let state: String
    let message: String
    let provisioningMessage: String?
    let cancellationConfirmed: Bool
}

enum V3AuthSessionUnavailablePolicy {
    static func shouldRetireOwnership(sessionID: String, currentSessionID: String?,
                                      failure: CombinedFailure) -> Bool {
        currentSessionID == sessionID && failure.operation == "signIn" &&
            failure.stage == .authentication && failure.safeCause == .authSessionUnavailable
    }

    static func resolve(authenticated: Bool, provisioningIncomplete: Bool,
                        snapshotConfirmed: Bool, safeMessage: String,
                        recovery: String, anotherSessionActive: Bool = false) -> V3AuthSessionUnavailablePresentation {
        guard snapshotConfirmed else {
            return V3AuthSessionUnavailablePresentation(
                state: "resultUnknown",
                message: "SideStore no longer has the active sign-in session. The current account and provisioning state could not be confirmed. Reload status before continuing." + "\nError ID: SS-AUTH-D079",
                provisioningMessage: nil,
                cancellationConfirmed: false)
        }
        if anotherSessionActive {
            return V3AuthSessionUnavailablePresentation(
                state: "resultUnknown",
                message: "Another Apple sign-in session is active. This request could not be matched to it. Wait for it to finish, then reload status." + "\nError ID: SS-AUTH-D078",
                provisioningMessage: nil,
                cancellationConfirmed: true)
        }
        if authenticated && provisioningIncomplete {
            return V3AuthSessionUnavailablePresentation(
                state: "authenticatedProvisioningIncomplete",
                message: "Apple ID signed in successfully.",
                provisioningMessage: "The saved provisioning session is no longer available. Open Account & Signing to sign in again before retrying setup." + "\nError ID: SS-AUTH-D080",
                cancellationConfirmed: true)
        }
        if authenticated {
            return V3AuthSessionUnavailablePresentation(
                state: "completed",
                message: "SideStore confirmed that the account is signed in.",
                provisioningMessage: nil,
                cancellationConfirmed: true)
        }
        let message = snapshotConfirmed
            ? safeMessage + " " + recovery
            : "SideStore no longer has the active sign-in session and could not confirm the account state. Reload status before starting a new sign-in." + "\nError ID: SS-AUTH-D081"
        return V3AuthSessionUnavailablePresentation(
            state: "failed", message: message, provisioningMessage: nil,
            cancellationConfirmed: true)
    }
}

enum V3AuthPollRecoveryPolicy {
    static func isTransientTransportFailure(_ failure: CombinedFailure) -> Bool {
        if failure.safeCause == .authSessionUnavailable { return false }
        let networkTransportCause = failure.safeCause.map {
            [.networkConnectionLost, .networkTimedOut, .networkUnavailable].contains($0)
        } ?? false
        if networkTransportCause {
            return failure.stage == .xpcConnection
        }
        return failure.code == .timedOut ||
            failure.code == .interrupted && failure.stage == .xpcConnection
    }

    static func shouldRetry(_ failure: CombinedFailure, now: Date = Date(),
                            sessionDeadline: Date) -> Bool {
        now < sessionDeadline && isTransientTransportFailure(failure)
    }

    static func shouldFinishTimedOut(_ failure: CombinedFailure, now: Date = Date(),
                                     sessionDeadline: Date) -> Bool {
        now >= sessionDeadline && isTransientTransportFailure(failure)
    }

    static func retryDelay(attempt: Int) -> TimeInterval {
        let backoff: [TimeInterval] = [1, 2, 5, 10]
        return backoff[min(max(0, attempt), backoff.count - 1)]
    }

    static func retryDelay(attempt: Int, remaining: TimeInterval) -> TimeInterval {
        guard remaining.isFinite, remaining > 0 else { return 0 }
        return min(retryDelay(attempt: attempt), remaining)
    }
}

enum V3AuthPollFailureRacePolicy {
    static func shouldIgnore(requestedSessionID: String, currentSessionID: String?,
                             requestedRevision: Int, currentRevision: Int,
                             requestedPromptResponseGeneration: UInt64,
                             currentPromptResponseGeneration: UInt64,
                             promptSubmissionInProgress: Bool) -> Bool {
        currentSessionID == requestedSessionID &&
            (requestedRevision != currentRevision ||
             requestedPromptResponseGeneration != currentPromptResponseGeneration ||
             promptSubmissionInProgress)
    }
}

enum V3AuthPollMonitorRecoveryPolicy {
    static func shouldResumeAfterAmbiguousStart(requestedSessionID: String,
                                                currentSessionID: String?,
                                                activeSessionID: String?,
                                                cancellationInProgress: Bool,
                                                taskCancelled: Bool) -> Bool {
        currentSessionID == requestedSessionID && activeSessionID == requestedSessionID &&
            !cancellationInProgress && !taskCancelled
    }

    static func shouldResume(requestedSessionID: String, currentSessionID: String?,
                             failedPromptRevision: Int,
                             currentPromptRevision: Int,
                             failedPromptResponseGeneration: UInt64,
                             currentPromptResponseGeneration: UInt64,
                             state: String, promptSubmissionInProgress: Bool,
                             activeSessionID: String? = nil,
                             pollFailureIsTransient: Bool = false,
                             cancellationInProgress: Bool, taskCancelled: Bool,
                             reconciliationWasSuperseded: Bool = false,
                             now: Date = Date(), sessionDeadline: Date) -> Bool {
        let authenticationActive = activeSessionID == requestedSessionID
        let anotherSessionActive = activeSessionID != nil && !authenticationActive
        guard currentSessionID == requestedSessionID,
              !anotherSessionActive,
              !cancellationInProgress, !taskCancelled,
              (["working", "awaitingPrompt"].contains(state) ||
                (authenticationActive && ["completed", "authenticatedProvisioningIncomplete"].contains(state))) else { return false }
        _ = now
        _ = sessionDeadline // PollLoop owns deadline terminalization on resume.
        return failedPromptRevision != currentPromptRevision ||
            failedPromptResponseGeneration != currentPromptResponseGeneration ||
            promptSubmissionInProgress || pollFailureIsTransient || reconciliationWasSuperseded ||
            authenticationActive
    }
}

public struct V3ShortcutRefreshRequest: Equatable {
    public let requestID: String
    public let origin: String

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              let value = userInfo["requestID"] as? String,
              let uuid = UUID(uuidString: value), uuid.uuidString == value,
              let origin = userInfo["origin"] as? String,
              V3RefreshRunCorrelation.allowedManualOrigins.contains(origin) else { return nil }
        self.requestID = uuid.uuidString
        self.origin = origin
    }

    public static func make() -> V3ShortcutRefreshRequest {
        V3ShortcutRefreshRequest(requestID: UUID().uuidString, origin: "manualUnknown")
    }

    private init(requestID: String, origin: String) {
        self.requestID = requestID
        self.origin = origin
    }

    public var userInfo: [AnyHashable: Any] {
        ["requestID": requestID, "origin": origin]
    }
}

public struct V3RefreshRunCorrelation: Equatable {
    public static let allowedManualOrigins: Set<String> = [
        "home", "refreshManager", "setupAssistant", "deadlineAlarm", "vpnReturn", "manualUnknown"
    ]

    public let runID: String
    public let requestID: String?
    public let origin: String

    public static func make(source: String, manual: Bool, requestID: String?,
                            manualOrigin: String?, runID: UUID) -> V3RefreshRunCorrelation {
        guard manual else {
            return V3RefreshRunCorrelation(runID: runID.uuidString, requestID: nil, origin: source)
        }
        let canonicalRequest: String
        if let requestID, let parsed = UUID(uuidString: requestID) {
            canonicalRequest = parsed.uuidString
        } else {
            canonicalRequest = UUID().uuidString
        }
        let canonicalOrigin: String
        if let manualOrigin, allowedManualOrigins.contains(manualOrigin) {
            canonicalOrigin = manualOrigin
        } else if source == "alarm_action" {
            canonicalOrigin = "deadlineAlarm"
        } else if source == "vpn_return" {
            canonicalOrigin = "vpnReturn"
        } else {
            canonicalOrigin = "manualUnknown"
        }
        return V3RefreshRunCorrelation(runID: runID.uuidString, requestID: canonicalRequest,
                                       origin: canonicalOrigin)
    }

    private init(runID: String, requestID: String?, origin: String) {
        self.runID = runID
        self.requestID = requestID
        self.origin = origin
    }
}

enum V3RefreshIntentStartPolicy {
    static func create<T>(_ factory: () throws -> T,
                          continuation: CheckedContinuation<Void, Error>,
                          classify: (Error) -> Error = { $0 }) -> T? {
        do {
            return try factory()
        } catch {
            continuation.resume(throwing: classify(error))
            return nil
        }
    }
}

enum V3ServiceReadinessRetryPolicy {
    static func retryable(operation: String, stage: CombinedFailure.Stage,
                          code: CombinedFailure.Code, typedNotReady: Bool) -> Bool? {
        guard typedNotReady, operation == "snapshot", stage == .serviceReadiness,
              code == .notReady else { return nil }
        return true
    }
}

enum V3PairingImportFailurePolicy {
    static func shouldOfferFileRetry(operation: String, stage: String, safeCause: String?) -> Bool {
        operation == "pairingImportData" &&
            ((stage == "pairing" && safeCause == "invalidPairingFile") ||
             (stage == "filePreparation" && safeCause == "pairingFilePreparationFailed"))
    }
}

enum V3SetupTestAttemptPolicy {
    static func mayApply(capturedAttemptID: String, currentAttemptID: String?,
                         taskCancelled: Bool) -> Bool {
        !taskCancelled && currentAttemptID == capturedAttemptID
    }
}

enum V3SetupTestRequestDisposition: Equatable {
    case startNew
    case resumeExisting(String)
    case waitForActiveRun
}

enum V3SetupTestRequestPolicy {
    static let startGracePeriod: TimeInterval = 30

    static func select(pendingRequestID: String?, pendingAge: TimeInterval,
                       pendingState: String?, activeRunID: String?,
                       activeRunRequestID: String?) -> V3SetupTestRequestDisposition {
        // A terminal correlated request is read-only to consume. Resolve it
        // before considering a different run that began after it completed.
        if let pendingRequestID, ["completed", "failed"].contains(pendingState ?? "") {
            return .resumeExisting(pendingRequestID)
        }
        if let pendingRequestID, let activeRunID, !activeRunID.isEmpty,
           activeRunRequestID != pendingRequestID {
            return .waitForActiveRun
        }
        if let pendingRequestID {
            if pendingState != nil {
                return .resumeExisting(pendingRequestID)
            }
            if let activeRunID, !activeRunID.isEmpty {
                return activeRunRequestID == pendingRequestID
                    ? .resumeExisting(pendingRequestID) : .waitForActiveRun
            }
            return pendingAge < startGracePeriod
                ? .resumeExisting(pendingRequestID) : .startNew
        }
        return (activeRunID?.isEmpty == false) ? .waitForActiveRun : .startNew
    }
}

struct V3AuthPollFailure: Error {
    let underlying: Error
    let sessionID: String
    let promptResponseGeneration: UInt64
    let promptRevision: Int
}

enum V3AuthAttemptFailureCommitPolicy {
    static func mayCommit(requestedSessionID: String, currentSessionID: String?,
                          capturedPromptResponseGeneration: UInt64,
                          currentPromptResponseGeneration: UInt64,
                          reconciliationGenerationBefore: UInt64,
                          currentReconciliationGeneration: UInt64,
                          cancellationInProgress: Bool, taskCancelled: Bool) -> Bool {
        !cancellationInProgress && !taskCancelled &&
            currentSessionID == requestedSessionID &&
            currentPromptResponseGeneration == capturedPromptResponseGeneration &&
            currentReconciliationGeneration == (reconciliationGenerationBefore &+ 1)
    }

    static func shouldPreserveAuthoritativeAccountState(snapshotConfirmed: Bool,
                                                        authenticated: Bool,
                                                        state: String) -> Bool {
        snapshotConfirmed && authenticated &&
            ["completed", "authenticatedProvisioningIncomplete"].contains(state)
    }

    static func shouldCommitConfirmedSignedOutFailure(snapshotConfirmed: Bool,
                                                       authenticated: Bool,
                                                       hasSession: Bool,
                                                       cancellationConfirmed: Bool,
                                                       state: String) -> Bool {
        snapshotConfirmed && !authenticated && !hasSession && cancellationConfirmed && state == "failed"
    }
}

enum V3AuthCancellationRetryPolicy {
    static func canRetry(isCancelling: Bool, cancellationConfirmed: Bool,
                         hasSession: Bool) -> Bool {
        !isCancelling && !cancellationConfirmed && hasSession
    }
}

enum V3AuthUnknownResultRecoveryAction: Equatable {
    case cancelSession
    case reloadStatus
    case none
}

enum V3AuthUnknownResultRecoveryPolicy {
    static func action(isCancelling: Bool, cancellationConfirmed: Bool,
                       hasSession: Bool) -> V3AuthUnknownResultRecoveryAction {
        guard !isCancelling else { return .none }
        if !hasSession { return .reloadStatus }
        return cancellationConfirmed ? .none : .cancelSession
    }
}

enum V3AuthUnknownResultReconciliationPolicy {
    static func reportedState(originalState: String, hasSession: Bool,
                              authenticated: Bool) -> String {
        originalState == "resultUnknown" && !hasSession && !authenticated
            ? "working" : originalState
    }
}

enum V3AuthSessionAdmissionPolicy {
    static func mayStartNewSession(hasActiveSession: Bool) -> Bool {
        !hasActiveSession
    }
}

struct V3AuthProvisioningRecoveryPresentation: Equatable {
    let showCancellationInstruction: Bool
    let showRetryProvisioning: Bool
    let showReauthenticateProvisioning: Bool
    let showFinishLater: Bool
    let blockedByActiveSession: Bool
}

enum V3AuthProvisioningRecoveryPolicy {
    static func resolve(state: String, hasSession: Bool, signedIn: Bool,
                        provisioningRetryAvailable: Bool, isCancelling: Bool,
                        cancellationConfirmed: Bool,
                        authenticationActive: Bool = false,
                        reauthenticationAvailable: Bool = false,
                        identityStateBlocked: Bool = false) -> V3AuthProvisioningRecoveryPresentation {
        let noSessionResumeIsSafe = state == "resultUnknown" && !hasSession && signedIn &&
            provisioningRetryAvailable && !authenticationActive
        let retryAllowed = !identityStateBlocked && !isCancelling && cancellationConfirmed && provisioningRetryAvailable &&
            !authenticationActive &&
            (state != "resultUnknown" || noSessionResumeIsSafe)
        return V3AuthProvisioningRecoveryPresentation(
            showCancellationInstruction: state == "resultUnknown" && hasSession,
            showRetryProvisioning: retryAllowed,
            showReauthenticateProvisioning: !identityStateBlocked && signedIn && !hasSession &&
                reauthenticationAvailable && !authenticationActive &&
                !isCancelling && cancellationConfirmed &&
                !["working", "awaitingPrompt"].contains(state),
            showFinishLater: signedIn && (!hasSession || state != "resultUnknown"),
            blockedByActiveSession: authenticationActive)
    }
}

enum V3AuthCancellationFeedbackPolicy {
    static func statusLabel(isCancelling: Bool, normalLabel: String) -> String {
        isCancelling ? "Cancelling..." : normalLabel
    }

    static func message(isCancelling: Bool) -> String? {
        isCancelling ? "Cancellation requested. Waiting for SideStore to confirm the sign-in stopped." : nil
    }
}

enum V3AuthStatusTextPolicy {
    static func label(state: String, isSignedIn: Bool,
                      provisioningFinishedLater: Bool) -> String {
        switch state {
        case "completed": return "Signed in"
        case "authenticatedProvisioningIncomplete":
            return "Signed in, provisioning needs attention"
        case "awaitingPrompt": return "Needs your input"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        case "timedOut": return "Timed out"
        case "promptExpired": return "Verification expired"
        case "resultUnknown": return "Result not confirmed"
        case "working": return isSignedIn ? "Finishing provisioning..." : "Working..."
        default: return "Not started"
        }
    }

    static func accountLabel(state: String, isSignedIn: Bool) -> String {
        if state == "resultUnknown" {
            return isSignedIn
                ? "Last confirmed account status: signed in"
                : "Current account status is unconfirmed"
        }
        guard isSignedIn else { return "" }
        if state == "completed" || state == "authenticatedProvisioningIncomplete" {
            return "Signed in successfully"
        }
        return "Account currently signed in"
    }
}

enum V3AuthFailureDiagnosticsPolicy {
    static func provisioning(reply: [String: Any], message: String, technical: String) -> (message: String, technical: String) {
        var evidence = (reply["failure"] as? [String: Any]) ?? ["stage": "provisioning", "code": "failed"]
        if let kind = reply["failureKind"] as? String { evidence["kind"] = kind }
        let canonical = "diagnostic_code=\(diagnosticCode(for: evidence)) builder_commit=\(V3DiagnosticBuild.commit)"
        // Preserve existing safe technical evidence, explicitly naming its
        // structured category separately from the presentation category.
        let underlying = technical.replacingOccurrences(of: "diagnostic_code=", with: "underlying_diagnostic_code=")
            .replacingOccurrences(of: "builder_commit=", with: "underlying_builder_commit=")
        return (display(message, failure: evidence), canonical + (underlying.isEmpty ? "" : "\n" + underlying))
    }

    static func display(_ message: String, failure: [String: Any]) -> String {
        // Replace our previous decoration only. Never inspect prose to infer a
        // cause; the canonical ID comes solely from the finite envelope fields.
        let prose = message.components(separatedBy: "\n").compactMap { line -> String? in
            let prefix = "Error ID: "
            guard line.hasPrefix(prefix + "SS-") else { return line }
            // Older call sites may append recovery prose after the ID token.
            // Remove only the decoration token, never the recovery instructions.
            let trailing = line.dropFirst(prefix.count).drop(while: { !$0.isWhitespace })
                .trimmingCharacters(in: .whitespaces)
            return trailing.isEmpty ? nil : trailing
        }.joined(separator: "\n")
        let fields = (failure["signingContext"] as? [String: String]).flatMap(CombinedFailure.validatedSigningContext) ?? [:]
        let trace = fields[V3TemporaryAnisetteTrace.contextKey].flatMap(V3TemporaryAnisetteTrace.init(encoded:))
        let failedStep = trace?.failedStep.map { "\nDEBUG TEMPORARY failed step: " + $0 } ?? ""
        let cleanProse = prose.components(separatedBy: "\n").filter {
            !$0.hasPrefix("DEBUG TEMPORARY failed step: ")
        }.joined(separator: "\n")
        return cleanProse + failedStep + "\nError ID: " + diagnosticCode(for: failure)
    }

    static func diagnosticCode(for failure: [String: Any]) -> String {
        let stage = (failure["stage"] as? String).flatMap(CombinedFailure.Stage.init(rawValue:)) ?? .authentication
        let code = (failure["code"] as? String).flatMap(CombinedFailure.Code.init(rawValue:)) ?? .failed
        let step = (failure["sourceStep"] as? String).flatMap(CombinedFailure.SourceStep.init(rawValue:))
        let cause = (failure["safeCause"] as? String).flatMap(CombinedFailure.SafeCause.init(rawValue:))
        let fields = (failure["signingContext"] as? [String: String]).flatMap(CombinedFailure.validatedSigningContext) ?? [:]
        let failureCode = CombinedFailure(operation: "signIn", stage: stage, code: code,
            id: "00000000-0000-0000-0000-000000000000", safeCause: cause, sourceStep: step,
            signingContext: fields).diagnosticCode
        let kind = failure["kind"] as? String ?? failure["code"] as? String ?? "unknown"
        let kindToken: String
        switch kind {
        case "unknown": kindToken = "A00"
        case "invalidCredentials": kindToken = "A01"
        case "appSpecificPasswordRequired": kindToken = "A02"
        case "invalidCode": kindToken = "A03"
        case "rateLimited": kindToken = "A04"
        case "serviceUnavailable": kindToken = "A05"
        case "anisetteFailure", "anisette": kindToken = "A06"
        case "networkFailure", "network": kindToken = "A07"
        case "accountRepairRequired": kindToken = "A08"
        case "credentialStorage": kindToken = "A09"
        case "credentialStorageUncertain": kindToken = "A10"
        case "accountIdentityMismatch": kindToken = "A11"
        case "anisetteIdentityStateInvalid": kindToken = "A12"
        default: kindToken = "A00"
        }
        return failureCode + "-" + kindToken
    }
    static func shouldShowTerminalDetails(state: String, hasPrompt: Bool,
                                          hasFailure: Bool) -> Bool {
        hasFailure && !hasPrompt && ["failed", "timedOut", "promptExpired", "resultUnknown"]
            .contains(state)
    }

    static func render(_ failure: [String: Any], underlyingCode: Int?,
                       retryableValue: Bool?) -> String {
        let kind = failure["kind"] as? String ?? ""
        let stage = failure["stage"] as? String ?? ""
        let code = failure["code"] as? String ?? ""
        let correlation = failure["correlationID"] as? String ?? ""
        let underlyingDomain = failure["underlyingDomain"] as? String ?? ""
        let codeText = underlyingCode.map(String.init) ?? "unknown"
        let retryableText = retryableValue.map { $0 ? "yes" : "no" } ?? "unknown"
        let step = (failure["sourceStep"] as? String).flatMap(CombinedFailure.SourceStep.init(rawValue:))?.rawValue ?? "unknown"
        let fields = (failure["signingContext"] as? [String: String]).flatMap(CombinedFailure.validatedSigningContext) ?? [:]
        let accountDetails = " source_step=\(step) typed_error=\(fields["typed_error"] ?? "unknown") server_code=\(fields["server_code"] ?? "unknown") http_status=\(fields["http_status"] ?? "unavailable")"
        let nativeDetails = fields["typed_error"] == "anisetteKitADIError"
            ? " native_code=\(fields["native_code"] ?? "unknown") native_phase=\(fields["native_phase"] ?? "unknown") native_subcode=\(fields["native_subcode"] ?? "unknown")" : ""
        let attemptDetails = fields["anisette_blob_state"].map {
            " anisette_blob_state=\($0) anisette_recovery=\(fields["anisette_recovery"] ?? "notAttempted")"
        } ?? ""
        let probeDetails = fields["probe_native_code"].map {
            " probe_native_code=\($0) probe_native_phase=\(fields["probe_native_phase"] ?? "unknown") probe_native_subcode=\(fields["probe_native_subcode"] ?? "unknown")"
        } ?? ""
        return "diagnostic_code=\(diagnosticCode(for: failure)) builder_commit=\(V3DiagnosticBuild.commit) kind=\(kind) stage=\(stage) code=\(code) correlation=\(correlation) underlying=\(underlyingDomain)/\(codeText) retryable=\(retryableText)" + accountDetails + nativeDetails + attemptDetails + probeDetails +
            (fields[V3TemporaryAnisetteTrace.contextKey].flatMap(V3TemporaryAnisetteTrace.init(encoded:))?.technicalDetails ?? "")
    }
}

enum V3SignInFailureRoutingPolicy {
    static func shouldOpenSignIn(stage: CombinedFailure.Stage,
                                 safeCause: CombinedFailure.SafeCause?) -> Bool {
        stage == .authentication && safeCause != .keychainSignOutFailed
    }
}

enum V3AuthTerminalFailureAction: Equatable {
    case beginNewSignIn(title: String)
    case repairAppleAccount
    case useAppSpecificPassword
    case blocked
}

enum V3AuthTerminalFailureActionPolicy {
    static func resolve(kind: String?, retryable: Bool?) -> V3AuthTerminalFailureAction {
        switch kind {
        case "credentialStorage", "credentialStorageUncertain", "anisetteIdentityStateInvalid": return .blocked
        case "accountIdentityMismatch": return .beginNewSignIn(title: "Use Saved Apple ID")
        case "accountRepairRequired": return .repairAppleAccount
        case "appSpecificPasswordRequired": return .useAppSpecificPassword
        default: break
        }
        if retryable == false { return .blocked }
        switch kind {
        case "rateLimited": return .beginNewSignIn(title: "Start New Sign-In")
        case "invalidCredentials": return .beginNewSignIn(title: "Check Password and Start New Sign-In")
        case "invalidCode": return .beginNewSignIn(title: "Start New Sign-In to Enter a New Code")
        case "serviceUnavailable", "anisette", "anisetteFailure", "network", "networkFailure":
            return .beginNewSignIn(title: "Start New Sign-In")
        default: break
        }
        if retryable == nil || kind == "unknown" { return .beginNewSignIn(title: "Start New Sign-In") }
        return .beginNewSignIn(title: "Try Sign-In Again")
    }

    static func guidance(kind: String?, retryable: Bool?) -> String? {
        if kind == "anisetteIdentityStateInvalid" { return LCAnisettePairError.recovery }
        if kind == "accountIdentityMismatch" {
            return "Reload status, then sign in with the saved Apple ID to finish setup."
        }
        switch resolve(kind: kind, retryable: retryable) {
        case .repairAppleAccount:
            return "Resolve the account issue shown by Apple, then begin a new sign-in."
        case .useAppSpecificPassword:
            return "Create an app-specific password for this authentication path, then enter it in the password prompt."
        case .blocked:
            return "This failure is not marked safe to retry. Resolve the displayed prerequisite and review Diagnostics."
        case .beginNewSignIn(_) where kind == "rateLimited":
            return "Apple is limiting sign-in attempts. Wait before starting a new sign-in."
        case .beginNewSignIn(_) where kind == "invalidCode":
            return "This sign-in attempt ended. Start a new sign-in; Apple will request a fresh verification code after credentials are accepted."
        case .beginNewSignIn(_) where kind == "serviceUnavailable":
            return "Apple's authentication service is temporarily unavailable. Wait for it to recover, then start a new sign-in."
        case .beginNewSignIn(_) where kind == "anisette" || kind == "anisetteFailure":
            return "SideStore could not obtain Anisette data. Check Anisette Servers in Settings, then start a new sign-in."
        case .beginNewSignIn(_) where kind == "network" || kind == "networkFailure":
            return "The connection to Apple's authentication service failed. Check your internet connection, then start a new sign-in."
        case .beginNewSignIn(_) where kind == "unknown" || (kind == nil && retryable == nil):
            return "The exact cause or retry safety could not be confirmed. Starting again creates a new attempt and may not resolve the previous failure."
        case .beginNewSignIn(_):
            return nil
        }
    }
}

enum V3AuthRepairURLPolicy {
    static let safeMessage = "Apple needs account attention before sign-in can continue."

    static func promptField(url: String) -> [String: String] {
        ["key": "url", "label": "Open Apple Account Repair",
         "secure": "false", "value": url]
    }

    static func openableURL(_ rawValue: String) -> URL? {
        guard rawValue.count <= 2_048,
              let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host == "apple.com" || host.hasSuffix(".apple.com"),
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }
}

struct V3AuthAttemptFailureNotice: Equatable {
    private(set) var message = ""
    private(set) var technicalDetails = ""

    mutating func record(snapshotConfirmed: Bool, authenticated: Bool,
                         failureMessage: String, technicalDetails: String) {
        guard !failureMessage.isEmpty else { return }
        if authenticated {
            message = "The sign-in attempt could not be confirmed. SideStore currently reports an account as signed in. \(failureMessage)"
        } else if snapshotConfirmed {
            message = "The sign-in attempt could not be confirmed. SideStore confirms no account is currently signed in. \(failureMessage)"
        } else {
            message = "The sign-in attempt could not be confirmed. SideStore could not confirm whether sign-in completed. \(failureMessage)"
        }
        self.technicalDetails = technicalDetails
    }

    mutating func clear() {
        message = ""
        technicalDetails = ""
    }
}

enum V3AuthAttemptStartFailurePolicy {
    static func confirmedNotDispatched(_ failure: CombinedFailure,
                                       operation: String = "authBegin") -> CombinedFailure {
        let underlying: NSError? = failure.underlyingDomain == "none" && failure.underlyingCode == 0
            ? nil : NSError(domain: failure.underlyingDomain, code: failure.underlyingCode)
        let cause: CombinedFailure.SafeCause
        if failure.safeCause == .responseCapacityUnavailable {
            cause = .authResponseCapacityUnavailable
        } else if failure.safeCause == .operationInProgress {
            cause = .operationInProgress
        } else {
            cause = operation == "authRetryProvisioning"
                ? .authProvisioningRetryNotDispatched : .authAttemptNotDispatched
        }
        return CombinedFailure(operation: "signIn", stage: failure.stage, code: failure.code,
            id: failure.correlationID, underlying: underlying,
            retryable: true, safeCause: cause)
    }

    static func isConfirmedNotDispatched(_ failure: CombinedFailure) -> Bool {
        failure.safeCause == .authAttemptNotDispatched ||
            failure.safeCause == .authProvisioningRetryNotDispatched ||
            failure.safeCause == .authResponseCapacityUnavailable ||
            failure.safeCause == .operationInProgress
    }
}

enum V3AuthProvisioningRetryDispatchPolicy {
    static func isConfirmedNotDispatched(_ failure: CombinedFailure) -> Bool {
        failure.safeCause == .authProvisioningRetryNotDispatched ||
            failure.safeCause == .authResponseCapacityUnavailable ||
            failure.safeCause == .operationInProgress
    }

    static func whatHappened(_ failure: CombinedFailure) -> String {
        if failure.safeCause == .authResponseCapacityUnavailable {
            return "SideStore could not start the provisioning retry because it could not reserve a safe response slot." + "\nError ID: SS-AUTH-D082"
        }
        if failure.safeCause == .operationInProgress {
            return "Another sign-in or provisioning attempt is already active."
        }
        return failure.safeMessage
    }
}

enum V3AuthSessionExpiryPolicy {
    static func response(authenticated: Bool, resumable: Bool = false) -> [String: Any] {
        if authenticated {
            return ["state": "authenticatedProvisioningIncomplete", "authenticated": true,
                    "resumable": resumable,
                    "message": "Apple ID sign-in succeeded, but provisioning did not finish before the session timed out." + "\nError ID: SS-AUTH-D083"]
        }
        return ["state": "timedOut", "authenticated": false,
                "message": "Sign-in timed out. Start a new sign-in when you are ready." + "\nError ID: SS-AUTH-D040"]
    }
}

// A backup callback is a one-shot capability for one external SideBackup step.
// The session owns the device mutation throughout the round trip; this control
// message must never create, release, or reconcile an operation owner.
enum V3SharedKeychainAccessGroupPolicy {
    static func sharedGroup(in entitledGroups: [String]) -> String? {
        entitledGroups.first(where: { $0.hasSuffix(".com.kdt.livecontainer.shared") })
    }

    static func sharedGroup(fromDefaultGroup group: String) -> String? {
        guard let prefix = group.split(separator: ".", maxSplits: 1).first,
              String(prefix).range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return "\(prefix).com.kdt.livecontainer.shared"
    }
}
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The one runtime App Group identity used by every cross-process reader,
/// writer and lock in the combined build: IPA staging, the secret handoff
/// Keychain transaction lock, the service Keychain migration lock, the
/// operation recovery journal, and the cross-process refresh store.
///
/// LiveProcess publishes the group it validated from the host launch payload
/// and the host publishes the same key for itself, so the host and the service
/// resolve one identifier without sharing a symbol across targets. A packaged
/// Info.plist entitlement is only the fallback for a launch that published
/// nothing at all.
///
/// LC_APP_GROUP_RULE_SET_V1 in scripts/templates/LCAppGroupIdentityRules.h is
/// the same rule set in plain C, so it can be executed by a behavioral harness
/// on any toolchain. The two implementations cannot share a header across
/// targets; tests/test_v3_shared_app_group.py executes the C rules and fails
/// when this file drifts from them. Change both together.
enum V3SharedAppGroup {
    /// LC_RULE_PACKAGED_FALLBACK_ONLY: the packaged SideStore group, including
    /// the team-suffixed variants a re-signer writes, ranks first when no
    /// runtime group was published.
    static let packagedGroup = "group.com.SideStore.SideStore"
    /// LiveProcess validates the host-selected group against its own sandbox
    /// and publishes it here. The host publishes the same key for itself.
    static let runtimeGroupEnvironmentKey = "LC_V3_INHERITED_APP_GROUP"
    /// LC_RULE_GROUP_BOUNDED_LENGTH
    static let maximumIdentifierLength = 255

    enum Source: String, Equatable {
        /// The caller passed its own selected group.
        case supplied
        /// The group published by the host for this process.
        case inherited
        /// No runtime group was published; a packaged entitlement was used.
        case packaged
    }

    struct Identity: Equatable {
        let identifier: String
        let containerRoot: URL
        let source: Source
    }

    /// A typed, recoverable failure. Shared state is never substituted with a
    /// process-local store to hide this. The description is a defined safe
    /// sentence, never a provider string and never a private path.
    enum Unavailable: Error, Equatable, LocalizedError {
        case sharedStore

        var isRecoverable: Bool { true }
        var errorDescription: String? {
            "LiveContainer could not open the shared store it uses with the embedded SideStore service."
        }
    }

    /// LC_RULE_GROUP_VISIBLE_ASCII, LC_RULE_GROUP_NO_SEPARATOR,
    /// LC_RULE_GROUP_NO_COLON, LC_RULE_GROUP_NO_TRAVERSAL,
    /// LC_RULE_GROUP_BOUNDED_LENGTH. An App Group identifier is never a path
    /// and never an unbounded string, whatever produced it.
    static func wellFormedIdentifier(_ candidate: String?) -> String? {
        guard let candidate, !candidate.isEmpty,
              candidate.utf8.count <= maximumIdentifierLength else { return nil }
        var previous: UInt8 = 0
        for byte in candidate.utf8 {
            guard byte >= 0x21, byte <= 0x7E,
                  byte != UInt8(ascii: "/"), byte != UInt8(ascii: "\\"),
                  byte != UInt8(ascii: ":") else { return nil }
            if previous == UInt8(ascii: ".") && byte == UInt8(ascii: ".") { return nil }
            previous = byte
        }
        return candidate.utf8.first == UInt8(ascii: ".") ? nil : candidate
    }

    static func isPackagedSideStoreGroup(_ group: String) -> Bool {
        // The plain packaged name ranks as itself. Without this early return the
        // suffix below would be taken from a string one character longer than
        // this one, and the exact name would rank as an ordinary entry, putting
        // a foreign group ahead of the packaged one.
        if group == packagedGroup { return true }
        guard group.hasPrefix(packagedGroup + ".") else { return false }
        let suffix = group.dropFirst(packagedGroup.count + 1)
        return !suffix.isEmpty && suffix.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) ||
                (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) ||
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
        }
    }

    static func environmentGroup() -> String? {
        #if canImport(Darwin)
        guard let value = getenv(runtimeGroupEnvironmentKey) else { return nil }
        return String(cString: value)
        #else
        return nil
        #endif
    }

    /// Publish this process's own selection so the embedded service resolves the
    /// identical group. Only a group this process can actually open is published:
    /// if the service could not open what the host published, it would clear the
    /// key and choose its own packaged fallback, which is the split this exists to
    /// prevent. Publishing nothing leaves both processes on their packaged
    /// fallback, which LCAppGroupOrderPackaged ranks identically and which the
    /// packaging verifier constrains to groups both processes are entitled for.
    static func publishRuntimeGroup(_ group: String?) {
        #if canImport(Darwin)
        unsetenv(runtimeGroupEnvironmentKey)
        guard let resolved = runtimeIdentity(selectedGroup: group)?.identifier,
              let bytes = resolved.cString(using: .utf8) else { return }
        setenv(runtimeGroupEnvironmentKey, bytes, 1)
        #endif
    }

    /// Resolve the one authoritative identity.
    ///
    /// LC_RULE_EXPLICIT_WINS: a supplied or inherited runtime group is
    /// authoritative for its own name. A legitimate AltStore-owned group that
    /// LiveContainer selected is accepted; it is not rejected for lacking the
    /// SideStore name.
    /// LC_RULE_EXPLICIT_FAIL_CLOSED: if that group is malformed or cannot be
    /// opened, this returns nil. Falling back to the packaged entitlement would
    /// move the shared store underneath the other process.
    /// LC_RULE_PACKAGED_FALLBACK_ONLY: with no runtime group at all, the
    /// packaged entitlement is the only fallback.
    /// The platform's own answer to "can this process open that group".
    /// Production leaves this at `.default`. The behavioral harnesses substitute
    /// one, because a macOS runner has no App Group entitlement and would
    /// otherwise resolve every group as unavailable and be unable to exercise
    /// any of the code that depends on the shared store actually existing.
    static var containerFileManager: FileManager = .default

    static func identity(selectedGroup: String? = nil,
                         inheritedGroup: String? = nil,
                         usesEnvironment: Bool = true,
                         bundleInfo: [String: Any],
                         resolveContainer: (String) -> URL?) -> Identity? {
        let supplied = selectedGroup.flatMap { $0.isEmpty ? nil : $0 }
        let inherited = inheritedGroup ?? (usesEnvironment ? environmentGroup() : nil)
        if let authoritative = supplied ?? inherited {
            guard let identifier = wellFormedIdentifier(authoritative),
                  let containerRoot = resolveContainer(identifier) else { return nil }
            return Identity(identifier: identifier, containerRoot: containerRoot,
                            source: supplied != nil ? .supplied : .inherited)
        }
        let configured = (bundleInfo["ALTAppGroups"] as? [String]) ??
            (bundleInfo["ALTAppGroups"] as? String).map { [$0] } ?? []
        let wellFormed = configured.compactMap(wellFormedIdentifier)
        // LC_RULE_PACKAGED_FALLBACK_ONLY, in the same two steps the C rule set
        // uses: the rule set's order, then the first entry this process can
        // actually open. A packaged list is a preference, not proof of
        // entitlement, so an unopenable top entry falls through to the next one.
        let ordered = wellFormed.filter(isPackagedSideStoreGroup) +
            wellFormed.filter { !isPackagedSideStoreGroup($0) }
        for identifier in ordered {
            if let containerRoot = resolveContainer(identifier) {
                return Identity(identifier: identifier, containerRoot: containerRoot, source: .packaged)
            }
        }
        return nil
    }

    static func runtimeIdentity(selectedGroup: String? = nil, bundle: Bundle = .main,
                                fileManager: FileManager? = nil) -> Identity? {
        let resolver = fileManager ?? containerFileManager
        return identity(selectedGroup: selectedGroup, bundleInfo: bundle.infoDictionary ?? [:]) {
            resolver.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    }

    /// The cross-process UserDefaults suite for this runtime group. Returns nil
    /// rather than a process-local store: a caller that needs shared state must
    /// produce a typed recoverable failure rather than silently writing to a
    /// private store the other process cannot read.
    static func sharedUserDefaults(selectedGroup: String? = nil, bundle: Bundle = .main) -> UserDefaults? {
        guard let identity = runtimeIdentity(selectedGroup: selectedGroup, bundle: bundle) else { return nil }
        return UserDefaults(suiteName: identity.identifier)
    }

    static func requireSharedUserDefaults(selectedGroup: String? = nil,
                                          bundle: Bundle = .main) throws -> UserDefaults {
        guard let shared = sharedUserDefaults(selectedGroup: selectedGroup, bundle: bundle) else {
            throw Unavailable.sharedStore
        }
        return shared
    }

    /// A private store used only when no shared store exists, so a failing launch
    /// can still render without its process-local values being mistaken for the
    /// cross-process state they stand in for. A unique suite name cannot collide
    /// with a real store and no other process can open it, so it is never an App
    /// Group suite. Callers must still refuse to run cross-process work while the
    /// shared store is unavailable, which is what `requireSharedStore` and
    /// `requireSharedUserDefaults` are for.
    ///
    /// The trailing `.standard` is an absolute last resort for the case where even
    /// a unique suite cannot be created. It is not a supported state and nothing
    /// treats it as a shared store.
    static func quarantinedUserDefaults() -> UserDefaults {
        let unique = "com.kdt.livecontainer.v3.quarantined-shared-store.\(UUID().uuidString)"
        return UserDefaults(suiteName: unique) ?? UserDefaults.standard
    }
}

/// The one cross-process refresh store: the host scheduler, the refresh settings
/// screen, the host Home banner and the Setup assistant all read and write these
/// keys, and the embedded service and the background run read and write the same
/// ones. It is deliberately not MainActor-isolated so SwiftUI property wrappers
/// can bind to it during view construction.
enum V3SharedRefreshStore {
    static let isAvailable = V3SharedAppGroup.sharedUserDefaults() != nil
    static let defaults: UserDefaults = V3SharedAppGroup.sharedUserDefaults()
        ?? V3SharedAppGroup.quarantinedUserDefaults()
    static let unavailableMessage = "LiveContainer could not open its shared refresh store, so scheduled refresh state is unavailable in this launch. Refresh All still works." + "\nError ID: SS-SAVE-D059"
}
import Foundation
import Security

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Advisory process-shared lock for operations that must coordinate between
/// the LiveContainer app and its embedded service process. NSLock is process local.
enum V3AppGroupProcessLock {
    static func withLock<T>(containerRoot: URL? = nil,
                            selectedGroup: String? = nil,
                            onFailure: ((String, String, Int) -> Void)? = nil,
                            diagnostics: V3SecretHandoffDiagnostics? = nil,
                            _ operation: () throws -> T) throws -> T {
        #if canImport(Darwin)
        let container: URL
        if let containerRoot { container = containerRoot }
        else {
            // This helper is compiled into the host, the SideStoreSupport
            // framework and the embedded service. Only Foundation is visible in
            // all three, so the group is injected: the host passes
            // LiveContainer's own selection, and the service resolves the group
            // LiveProcess validated and published. Both land on the same
            // V3SharedAppGroup identity IPA staging and the recovery journal
            // use, so the two processes take the same lock file.
            guard let shared = V3SharedAppGroup.runtimeIdentity(selectedGroup: selectedGroup) else {
                onFailure?("appGroup", "none", 0)
                throw V3SecretHandoffError.fail(.appGroupLockUnavailable, as: diagnostics, operation: "lock")
            }
            container = shared.containerRoot
        }

        #elseif canImport(Glibc)
        guard let containerRoot else {
            onFailure?("appGroup", "none", 0)
            throw V3SecretHandoffError.fail(.appGroupLockUnavailable, as: diagnostics, operation: "lock")
        }
        let container = containerRoot
        #else
        throw V3SecretHandoffError.fail(.appGroupLockUnavailable, as: diagnostics, operation: "lock")
        #endif
        let directory = ["Library", "Application Support", "LiveContainer"].reduce(
            container.standardizedFileURL) { $0.appendingPathComponent($1, isDirectory: true) }.standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  directory.resolvingSymlinksInPath().standardizedFileURL == directory else {
                throw V3SecretHandoffError.fail(.appGroupLockUnavailable, as: diagnostics, operation: "lock")
            }
        } catch {
            let native = error as NSError
            let safe = [NSCocoaErrorDomain, NSPOSIXErrorDomain].contains(native.domain)
            onFailure?("directory", safe ? native.domain : "redacted", safe ? native.code : 0)
            throw V3SecretHandoffError.fail(.appGroupLockUnavailable, as: diagnostics, operation: "lock",
                       osStatus: safe ? Int32(native.code) : 0)
        }
        let path = directory.appendingPathComponent("keychain-transaction.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            onFailure?("open", NSPOSIXErrorDomain, Int(errno))
            throw V3SecretHandoffError.fail(.appGroupLockUnavailable, as: diagnostics, operation: "lock",
                       osStatus: Int32(errno))
        }
        defer { _ = close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            onFailure?("permissions", NSPOSIXErrorDomain, Int(errno))
            throw V3SecretHandoffError.fail(.appGroupLockUnavailable, as: diagnostics, operation: "lock",
                       osStatus: Int32(errno))
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            onFailure?("flock", NSPOSIXErrorDomain, Int(errno))
            throw V3SecretHandoffError.fail(.appGroupLockUnavailable, as: diagnostics, operation: "lock",
                       osStatus: Int32(errno))
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

/// Why a secure handoff did not complete, at the granularity that tells an
/// engineer where to look without revealing anything sensitive.
///
/// Every case carries only an OSStatus integer, booleans, and a role. No case
/// carries an Apple ID, a password, a token, Keychain item data, or an access
/// group string, because this value reaches a device log.
public enum V3SecretHandoffFailure: String, Sendable {
    /// The process-shared App Group lock could not be taken, so the two
    /// processes could not serialize this transaction.
    case appGroupLockUnavailable
    /// This process could not read back which Keychain access group it owns, so
    /// the shared group could not be derived from its own entitlement.
    case keychainGroupDiscoveryFailed
    /// The derived shared group was refused by the Keychain: this process is not
    /// entitled to it. This is the shape a re-sign produces when the group is
    /// granted to the main app but not to its extensions.
    case keychainExplicitGroupUnauthorized
    /// The item was absent when it should have been present.
    case keychainItemNotFound
    /// Reading the item failed for a reason other than absence.
    case keychainReadFailed
    /// The one-time take could not delete the item after reading it.
    case keychainDeleteFailed
    /// The record existed but its lifetime had elapsed.
    case tokenExpired
    /// The record could not be decoded, or the token was not canonical.
    case tokenMalformed
    /// The outstanding-item budget was exhausted.
    case capacity
    /// The transaction lock is held but the shared group could not be resolved.
    case sharedGroupUnavailable
}

/// Privacy-safe evidence for one handoff step. Safe to log.
public struct V3SecretHandoffDiagnostics: Sendable, Equatable {
    /// "host" or "service".
    public var role: String
    public var operation: String
    public var failure: V3SecretHandoffFailure?
    /// Raw OSStatus, or 0 when the failure was not an OS call. Integer only.
    public var osStatus: Int32
    /// Whether this process could discover its own default access group.
    public var groupDiscovered: Bool
    /// Whether the token was a canonical UUID. Never the token itself.
    public var tokenWellFormed: Bool

    public init(role: String, operation: String, failure: V3SecretHandoffFailure? = nil,
                osStatus: Int32 = 0, groupDiscovered: Bool = false,
                tokenWellFormed: Bool = false) {
        self.role = role
        self.operation = operation
        self.failure = failure
        self.osStatus = osStatus
        self.groupDiscovered = groupDiscovered
        self.tokenWellFormed = tokenWellFormed
    }

    /// A single line with no secret material. Group names are deliberately
    /// absent: they embed the team identifier and were previously reported
    /// only as a boolean elsewhere.
    public var safeLine: String {
        var parts = ["handoff=1", "role=\(role)", "op=\(operation)"]
        parts.append("group_discovered=\(groupDiscovered)")
        parts.append("token_well_formed=\(tokenWellFormed)")
        if let failure { parts.append("cause=\(failure.rawValue)") }
        else { parts.append("cause=none") }
        parts.append("osstatus=\(osStatus)")
        return parts.joined(separator: " ")
    }
}

/// Emits one privacy-safe line per handoff step. Replaces the previous
/// `onFailure` callback, which carried an untyped domain string.
public enum V3SecretHandoffTrace {
    /// Set to false only by tests that assert on the absence of output.
    public static var isEnabled = true

    public static func emit(_ diagnostics: V3SecretHandoffDiagnostics) {
        guard isEnabled else { return }
        NSLog("[V3_SECRET_HANDOFF] %@", diagnostics.safeLine)
    }
}

/// Decides whether a thrown handoff error is reported as a secure-transport
/// failure rather than as whatever the surrounding operation was doing.
///
/// An authRespond that fails here never reached Apple. Reporting it as
/// signIn/authentication/failed tells the user their password was rejected,
/// which is false and sends them to change a password that never failed.
public enum V3SecretHandoffFailurePolicy {
    /// Operations whose payload crosses the secure channel first.
    public static let handoffCarryingOperations: Set<String> = [
        "authRespond", "opAnswer", "accountExport", "accountImport",
        "certCreate", "devPortalLogin"]

    public static func applies(to operation: String) -> Bool {
        handoffCarryingOperations.contains(operation)
    }

    /// The stage a handoff failure belongs to. Persistence, not authentication:
    /// the response is intact and the channel is what is broken.
    public static func stage(for operation: String) -> CombinedFailure.Stage { .persistence }

    /// Distinguishes a transient channel problem from one that needs a re-sign.
    public static func code(for failure: V3SecretHandoffFailure) -> CombinedFailure.Code {
        switch failure {
        case .appGroupLockUnavailable, .keychainReadFailed, .keychainDeleteFailed, .capacity:
            return .busy
        case .keychainGroupDiscoveryFailed, .keychainExplicitGroupUnauthorized,
             .keychainItemNotFound, .tokenExpired, .tokenMalformed, .sharedGroupUnavailable:
            return .unavailable
        }
    }

    /// Only a transient cause may be retried. Retrying cannot grant an access
    /// group or recreate an item the service is entitled to read.
    public static func isRetryable(_ failure: V3SecretHandoffFailure) -> Bool {
        switch failure {
        case .appGroupLockUnavailable, .keychainReadFailed, .keychainDeleteFailed, .capacity:
            return true
        case .keychainGroupDiscoveryFailed, .keychainExplicitGroupUnauthorized,
             .keychainItemNotFound, .tokenExpired, .tokenMalformed, .sharedGroupUnavailable:
            return false
        }
    }

    public static func failure(_ error: V3SecretHandoffError, operation: String,
                               id: String) -> CombinedFailure {
        let reason = error.failure
        // The OSStatus is evidence and is safe: an integer from the Keychain.
        // The group name is never included, because it embeds the team id.
        let underlying = NSError(domain: "V3SecretHandoff", code: Int(error.osStatusValue))
        return CombinedFailure(operation: operation, stage: stage(for: operation),
            code: code(for: reason), id: id, underlying: underlying,
            retryable: isRetryable(reason), safeCause: .secretHandoffUnavailable)
    }
}

/// Which side of the handoff is running. Injected so the same binary reports
/// honestly in the host, the SideStoreSupport framework and the service.
public enum V3SecretHandoffRole {
    public static let host = "host"
    public static let service = "service"
    /// The role of the running process, detected rather than declared. The host
    /// bundle identifier is the only one that is not the embedded service, and
    /// it is read from the process's own identity rather than passed in, so a
    /// call site cannot mislabel it.
    public static var current: String = resolve()

    static func resolve(bundle: Bundle = .main) -> String {
        bundle.bundleIdentifier?.hasSuffix(".LiveProcess") == true ? service : host
    }
}

public enum V3SecretHandoffError: Error, LocalizedError {
    case unavailable(V3SecretHandoffFailure, osStatus: Int32 = 0, groupDiscovered: Bool = false,
                     tokenWellFormed: Bool = false)
    case invalidToken
    case expired
    case malformed
    case capacity

    /// The OSStatus behind this error, or 0 when there was no OS call.
    public var osStatusValue: Int32 {
        if case .unavailable(_, let osStatus, _, _) = self { return osStatus }
        return 0
    }

    public var failure: V3SecretHandoffFailure {
        switch self {
        case .unavailable(let reason, _, _, _): return reason
        case .invalidToken: return .tokenMalformed
        case .expired: return .tokenExpired
        case .malformed: return .tokenMalformed
        case .capacity: return .capacity
        }
    }

    /// The safe line for this error, so every call site reports identically.
    public var diagnostics: V3SecretHandoffDiagnostics {
        switch self {
        case .unavailable(let reason, let osStatus, let groupDiscovered, let tokenWellFormed):
            return V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                operation: "consume", failure: reason, osStatus: osStatus,
                groupDiscovered: groupDiscovered, tokenWellFormed: tokenWellFormed)
        case .invalidToken:
            return V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                operation: "consume", failure: .tokenMalformed, tokenWellFormed: false)
        case .expired:
            return V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                operation: "consume", failure: .tokenExpired, tokenWellFormed: true)
        case .malformed:
            return V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                operation: "consume", failure: .tokenMalformed, tokenWellFormed: true)
        case .capacity:
            return V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                operation: "store", failure: .capacity)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason, _, _, _): return reason.userFacingMessage
        case .invalidToken: return "The secure response reference is invalid."
        case .expired: return "The secure response expired before SideStore received it."
        case .malformed: return "The secure response could not be read."
        case .capacity: return "Secure response storage is busy."
        }
    }
}

extension V3SecretHandoffFailure {
    /// What the user is told. This never implies Apple rejected anything: the
    /// response never reached Apple when the handoff failed.
    var userFacingMessage: String {
        switch self {
        case .appGroupLockUnavailable:
            return "The secure channel to the embedded service could not be locked. Try again."
        case .keychainGroupDiscoveryFailed:
            return "This build's secure storage group could not be identified. Reinstall or re-sign the app."
        case .keychainExplicitGroupUnauthorized:
            return "This build's secure storage group is not available to every part of the app, so the response could not be delivered. Re-sign the app so its extensions share the secure group."
        case .keychainItemNotFound:
            return "The secure response was already used or is no longer present. Enter it again."
        case .keychainReadFailed:
            return "The secure response could not be read from secure storage. Try again."
        case .keychainDeleteFailed:
            return "The secure response could not be cleared from secure storage. Try again."
        case .tokenExpired:
            return "The secure response expired before SideStore received it. Enter it again."
        case .tokenMalformed:
            return "The secure response could not be decoded. Enter it again."
        case .capacity:
            return "Secure response storage is busy. Try again."
        case .sharedGroupUnavailable:
            return "The shared App Group is unavailable, so the secure channel is unavailable."
        }
    }
}

/// Serializes the full shared-Keychain admission transaction across the host
/// and embedded service processes. The count/purge callback and SecItemAdd
/// callback must remain within this one lock scope.
enum V3SecretHandoffStoreAdmission {
    static func add<T>(containerRoot: URL? = nil, selectedGroup: String? = nil, maximumOutstandingItems: Int,
                       liveItemCount: () throws -> Int,
                       insert: () throws -> T) throws -> T {
        try V3AppGroupProcessLock.withLock(containerRoot: containerRoot, selectedGroup: selectedGroup) {
            guard try liveItemCount() < maximumOutstandingItems else {
                throw V3SecretHandoffError.capacity
            }
            return try insert()
        }
    }
}

extension V3SecretHandoffError {
    /// Builds a typed handoff failure and reports it once, so no call site has
    /// to remember to emit.
    static func fail(_ reason: V3SecretHandoffFailure,
                     as base: V3SecretHandoffDiagnostics?,
                     operation: String,
                     osStatus: Int32 = 0, groupDiscovered: Bool = false,
                     tokenWellFormed: Bool = false) -> V3SecretHandoffError {
        var resolved = base ?? V3SecretHandoffDiagnostics(
            role: V3SecretHandoffRole.current, operation: operation)
        resolved.operation = operation
        resolved.failure = reason
        resolved.osStatus = osStatus
        if groupDiscovered { resolved.groupDiscovered = true }
        if tokenWellFormed { resolved.tokenWellFormed = true }
        V3SecretHandoffTrace.emit(resolved)
        return .unavailable(reason, osStatus: osStatus,
                            groupDiscovered: resolved.groupDiscovered,
                            tokenWellFormed: resolved.tokenWellFormed)
    }
}

enum V3SecretHandoffRecord {
    static let lifetime: TimeInterval = 120
    static let maximumPayloadBytes = 64 * 1024
    private static let allowedKinds: Set<String> = ["string", "stringDictionary"]

    static func isStrictVersionOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        let type = String(cString: number.objCType)
        return ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) &&
            number.intValue == 1
    }

    static func encode(kind: String, payload: Data, createdAt: Date) -> Data? {
        guard allowedKinds.contains(kind), !payload.isEmpty, payload.count <= maximumPayloadBytes else { return nil }
        let expiresAt = createdAt.addingTimeInterval(lifetime)
        let value: [String: Any] = ["version": 1, "kind": kind, "createdAt": createdAt,
            "expiresAt": expiresAt, "payload": payload]
        return try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    static func decode(_ data: Data, expectedKind: String, now: Date) -> Data? {
        guard !data.isEmpty, data.count <= maximumPayloadBytes + 4096,
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              Set(value.keys) == Set(["version", "kind", "createdAt", "expiresAt", "payload"]),
              isStrictVersionOne(value["version"]),
              value["kind"] as? String == expectedKind, allowedKinds.contains(expectedKind),
              let createdAt = value["createdAt"] as? Date,
              let expiresAt = value["expiresAt"] as? Date,
              let payload = value["payload"] as? Data, !payload.isEmpty,
              payload.count <= maximumPayloadBytes,
              createdAt <= now, expiresAt > now,
              expiresAt.timeIntervalSince(createdAt) <= lifetime else { return nil }
        return payload
    }
}

enum V3SharedFileRecord {
    static let lifetime: TimeInterval = 60 * 60
    static let maximumPayloadBytes = 4_194_304
    static let maximumPendingFiles = 16
    static let maximumPendingStoredBytes = 16_777_216
    private static let directoryComponents = ["Library", "Application Support", "LiveContainer", "V3SharedFileStaging"]
    private static let allowedPurposes: Set<String> = ["pairing", "sidesign", "accountImport"]
    private static let transactionLock = NSLock()

    static func stagingDirectory(containerRoot: URL) -> URL {
        directoryComponents.reduce(containerRoot.standardizedFileURL) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.standardizedFileURL
    }

    static func stage(_ payload: Data, purpose: String, containerRoot: URL,
                      now: Date = Date(), fileManager: FileManager = .default) -> String? {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard allowedPurposes.contains(purpose), !payload.isEmpty,
              payload.count <= maximumPayloadBytes else { return nil }
        guard let directory = ensureDirectory(containerRoot: containerRoot, fileManager: fileManager) else { return nil }
        guard let record = encode(payload, purpose: purpose, createdAt: now) else { return nil }
        let current = sweep(directory: directory, now: now, fileManager: fileManager)
        guard current.count < maximumPendingFiles,
              current.storedBytes <= maximumPendingStoredBytes - record.count else { return nil }
        let token = UUID().uuidString
        guard let file = fileURL(token: token, directory: directory),
              !fileManager.fileExists(atPath: file.path) else { return nil }
        do {
            try record.write(to: file, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600, .modificationDate: now],
                                          ofItemAtPath: file.path)
            guard readRecordFile(file, directory: directory) != nil else {
                removeFile(file, directory: directory, fileManager: fileManager)
                return nil
            }
        } catch {
            removeFile(file, directory: directory, fileManager: fileManager)
            return nil
        }
        return token
    }

    static func consume(_ token: String, purpose: String, containerRoot: URL,
                        now: Date = Date(), fileManager: FileManager = .default) -> Data? {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard isCanonicalToken(token), allowedPurposes.contains(purpose),
              let directory = existingDirectory(containerRoot: containerRoot, fileManager: fileManager),
              let file = fileURL(token: token, directory: directory),
              let data = readRecordFile(file, directory: directory) else { return nil }
        guard let record = decodeRecord(data, now: now) else {
            removeFile(file, directory: directory, fileManager: fileManager)
            return nil
        }
        guard record.purpose == purpose else { return nil }
        removeFile(file, directory: directory, fileManager: fileManager)
        return record.payload
    }

    static func discard(_ token: String, containerRoot: URL,
                        fileManager: FileManager = .default) {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard isCanonicalToken(token),
              let directory = existingDirectory(containerRoot: containerRoot, fileManager: fileManager),
              let file = fileURL(token: token, directory: directory) else { return }
        removeFile(file, directory: directory, fileManager: fileManager)
    }

    static func removeLegacyDefaultsRecords(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("V3SharedFile.") {
            defaults.removeObject(forKey: key)
        }
    }

    @discardableResult
    static func sweep(containerRoot: URL, now: Date = Date(),
                      fileManager: FileManager = .default) -> (count: Int, storedBytes: Int) {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard let directory = existingDirectory(containerRoot: containerRoot, fileManager: fileManager) else {
            return (0, 0)
        }
        return sweep(directory: directory, now: now, fileManager: fileManager)
    }

    private static func sweep(directory: URL, now: Date,
                              fileManager: FileManager) -> (count: Int, storedBytes: Int) {
        var count = 0
        var storedBytes = 0
        guard let files = try? fileManager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return (0, 0) }
        for file in files {
            guard file.pathExtension == "bin",
                  isCanonicalToken(file.deletingPathExtension().lastPathComponent),
                  file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  file.resolvingSymlinksInPath().standardizedFileURL == file.standardizedFileURL else { continue }
            let size = values.fileSize ?? 0
            let modified = values.contentModificationDate ?? .distantPast
            guard size > 0, size <= maximumPayloadBytes + 4096,
                  modified <= now, now.timeIntervalSince(modified) <= lifetime else {
                removeFile(file, directory: directory, fileManager: fileManager)
                continue
            }
            count += 1
            storedBytes += size
        }
        return (count, storedBytes)
    }

    private static func ensureDirectory(containerRoot: URL, fileManager: FileManager) -> URL? {
        let root = containerRoot.resolvingSymlinksInPath().standardizedFileURL
        let directory = stagingDirectory(containerRoot: root)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  directory.resolvingSymlinksInPath().standardizedFileURL == directory else { return nil }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return directory
        } catch { return nil }
    }

    private static func existingDirectory(containerRoot: URL, fileManager: FileManager) -> URL? {
        let root = containerRoot.resolvingSymlinksInPath().standardizedFileURL
        let directory = stagingDirectory(containerRoot: root)
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              directory.resolvingSymlinksInPath().standardizedFileURL == directory else { return nil }
        return directory
    }

    private static func fileURL(token: String, directory: URL) -> URL? {
        guard isCanonicalToken(token) else { return nil }
        let file = directory.appendingPathComponent(token + ".bin", isDirectory: false).standardizedFileURL
        guard file.deletingLastPathComponent() == directory.standardizedFileURL,
              file.lastPathComponent == token + ".bin" else { return nil }
        return file
    }

    private static func readRecordFile(_ file: URL, directory: URL) -> Data? {
        guard file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0, (values.fileSize ?? 0) <= maximumPayloadBytes + 4096,
              file.resolvingSymlinksInPath().standardizedFileURL == file.standardizedFileURL else { return nil }
        guard let data = try? Data(contentsOf: file),
              data.count <= maximumPayloadBytes + 4096,
              file.resolvingSymlinksInPath().standardizedFileURL == file.standardizedFileURL else { return nil }
        return data
    }

    private static func removeFile(_ file: URL?, directory: URL, fileManager: FileManager) {
        guard let file, file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink != true,
              file.resolvingSymlinksInPath().standardizedFileURL == file.standardizedFileURL else { return }
        try? fileManager.removeItem(at: file)
    }

    private static func encode(_ payload: Data, purpose: String, createdAt: Date) -> Data? {
        guard allowedPurposes.contains(purpose), !payload.isEmpty,
              payload.count <= maximumPayloadBytes else { return nil }
        let value: [String: Any] = ["version": 1, "purpose": purpose, "createdAt": createdAt,
            "expiresAt": createdAt.addingTimeInterval(lifetime), "payload": payload]
        return try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private static func decodeRecord(_ data: Data, now: Date) -> (purpose: String, payload: Data)? {
        guard !data.isEmpty, data.count <= maximumPayloadBytes + 4096,
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              Set(value.keys) == Set(["version", "purpose", "createdAt", "expiresAt", "payload"]),
              V3SecretHandoffRecord.isStrictVersionOne(value["version"]),
              let purpose = value["purpose"] as? String, allowedPurposes.contains(purpose),
              let createdAt = value["createdAt"] as? Date,
              let expiresAt = value["expiresAt"] as? Date,
              let payload = value["payload"] as? Data, !payload.isEmpty,
              payload.count <= maximumPayloadBytes,
              createdAt <= now, expiresAt > now,
              expiresAt.timeIntervalSince(createdAt) <= lifetime else { return nil }
        return (purpose, payload)
    }

    private static func isCanonicalToken(_ token: String) -> Bool {
        guard let uuid = UUID(uuidString: token) else { return false }
        return uuid.uuidString == token
    }
}

enum V3SharedFileInputError: Error, LocalizedError {
    case unavailable
    case empty
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The selected file is unavailable. Choose an accessible file and try again."
        case .empty: return "The selected file is empty. Choose a valid export file and try again."
        case .tooLarge: return "The selected import file is larger than 4 MiB."
        }
    }
}

enum V3SharedFileInput {
    static let maximumBytes = V3SharedFileRecord.maximumPayloadBytes
    static let chunkBytes = 64 * 1024

    // Inspect the provider URL before reading, then enforce the same bound while
    // streaming so a replaced/growing file cannot allocate an unbounded Data.
    // Callers hold security-scoped access for the duration of this method.
    static func readBounded(_ url: URL) throws -> Data {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let fileSize = values.fileSize, fileSize > 0 else { throw V3SharedFileInputError.unavailable }
        guard fileSize <= maximumBytes else { throw V3SharedFileInputError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(fileSize)
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(chunkBytes, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
            if data.count > maximumBytes { throw V3SharedFileInputError.tooLarge }
        }
        guard !data.isEmpty else { throw V3SharedFileInputError.empty }
        return data
    }

    static func readBoundedAsync(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try V3SharedFileInput.readBounded(url)
        }.value
    }
}

enum V3SecretHandoff {
    private static let service = "com.kdt.livecontainer.v3-secret-handoff"
    private static let maximumOutstandingItems = 32

    static func isValidToken(_ token: String?) -> Bool {
        guard let token, let uuid = UUID(uuidString: token) else { return false }
        return uuid.uuidString == token
    }

    static func storeString(_ value: String, selectedGroup: String? = nil) throws -> String {
        guard value.utf8.count <= 8192 else { throw V3SecretHandoffError.malformed }
        return try store(Data(value.utf8), kind: "string", selectedGroup: selectedGroup)
    }

    static func consumeString(_ token: String, selectedGroup: String? = nil) throws -> String {
        let data = try consume(token, kind: "string", selectedGroup: selectedGroup)
        guard let value = String(data: data, encoding: .utf8), value.utf8.count <= 8192 else {
            throw V3SecretHandoffError.malformed
        }
        return value
    }

    static func storeStringDictionary(_ value: [String: String], selectedGroup: String? = nil) throws -> String {
        guard value.count <= 128,
              value.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.utf8.count <= 4096 }),
              let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0),
              data.count <= V3SecretHandoffRecord.maximumPayloadBytes else {
            throw V3SecretHandoffError.malformed
        }
        return try store(data, kind: "stringDictionary", selectedGroup: selectedGroup)
    }

    static func consumeStringDictionary(_ token: String, selectedGroup: String? = nil) throws -> [String: String] {
        let data = try consume(token, kind: "stringDictionary", selectedGroup: selectedGroup)
        guard let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              value.count <= 128,
              value.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.utf8.count <= 4096 }) else {
            throw V3SecretHandoffError.malformed
        }
        return value
    }

    static func discard(_ token: String, selectedGroup: String? = nil) {
        guard isValidToken(token), let group = try? sharedKeychainAccessGroup() else { return }
        _ = try? V3AppGroupProcessLock.withLock(selectedGroup: selectedGroup) {
            _ = SecItemDelete(itemQuery(token, group: group) as CFDictionary)
        }
    }

    static func cleanupExpiredItems(selectedGroup: String? = nil) {
        guard let group = try? sharedKeychainAccessGroup() else { return }
        _ = try? V3AppGroupProcessLock.withLock(selectedGroup: selectedGroup) {
            let rows = try listedItems(group: group)
            _ = try removeExpiredItems(group: group, rows: rows, now: Date())
        }
    }

    private static func store(_ payload: Data, kind: String, selectedGroup: String? = nil) throws -> String {
        guard payload.count <= V3SecretHandoffRecord.maximumPayloadBytes else {
            throw V3SecretHandoffError.malformed
        }
        let group = try sharedKeychainAccessGroup()
        return try V3SecretHandoffStoreAdmission.add(selectedGroup: selectedGroup,
            maximumOutstandingItems: maximumOutstandingItems,
            liveItemCount: {
                let rows = try listedItems(group: group)
                return try removeExpiredItems(group: group, rows: rows, now: Date())
            },
            insert: {
                // Start the lifetime only after this request owns the shared
                // transaction lock and has passed the capacity check.
                let now = Date()
                let token = UUID().uuidString
                guard let record = V3SecretHandoffRecord.encode(kind: kind, payload: payload, createdAt: now) else {
                    throw V3SecretHandoffError.malformed
                }
                var query = itemQuery(token, group: group)
                query[kSecValueData as String] = record
                query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let status = SecItemAdd(query as CFDictionary, nil)
                guard status == errSecSuccess else {
                    let reason: V3SecretHandoffFailure = status == errSecMissingEntitlement
                        ? .keychainExplicitGroupUnauthorized : .keychainReadFailed
                    throw V3SecretHandoffError.fail(reason,
                        as: V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                            operation: "secretStore", groupDiscovered: true, tokenWellFormed: true),
                        operation: "secretStore", osStatus: status,
                        groupDiscovered: true, tokenWellFormed: true)
                }
                V3SecretHandoffTrace.emit(V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                    operation: "secretStore", failure: nil, groupDiscovered: true, tokenWellFormed: true))
                return token
            })
    }

    private static func consume(_ token: String, kind: String, selectedGroup: String? = nil) throws -> Data {
        let wellFormed = isValidToken(token)
        guard wellFormed else {
            let error = V3SecretHandoffError.invalidToken
            V3SecretHandoffTrace.emit(error.diagnostics)
            throw error
        }
        // The process-shared advisory lock surrounds both copy and delete.
        // This makes competing patched processes serialize the one-time take;
        // NSLock alone cannot coordinate separate app/service processes.
        return try V3AppGroupProcessLock.withLock(selectedGroup: selectedGroup) {
            try consumeLocked(token, kind: kind)
        }
    }

    private static func consumeLocked(_ token: String, kind: String) throws -> Data {
        // Any failure below reports itself, so a caller that only logs the
        // returned error still gets the step that failed.
        let group = try sharedKeychainAccessGroup()
        var query = itemQuery(token, group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let record = result as? Data else {
            let reason: V3SecretHandoffFailure = status == errSecItemNotFound
                ? .keychainItemNotFound : (status == errSecMissingEntitlement
                  ? .keychainExplicitGroupUnauthorized : .keychainReadFailed)
            throw V3SecretHandoffError.fail(reason,
                as: V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                    operation: "secretLookup", groupDiscovered: true, tokenWellFormed: true),
                operation: "secretLookup", osStatus: status, groupDiscovered: true, tokenWellFormed: true)
        }
        let deleteStatus = SecItemDelete(itemQuery(token, group: group) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw V3SecretHandoffError.fail(.keychainDeleteFailed,
                as: V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                    operation: "secretLookup", groupDiscovered: true, tokenWellFormed: true),
                operation: "secretLookup", osStatus: Int32(deleteStatus),
                groupDiscovered: true, tokenWellFormed: true)
        }
        guard let payload = V3SecretHandoffRecord.decode(record, expectedKind: kind, now: Date()) else {
            let error = V3SecretHandoffError.expired
            V3SecretHandoffTrace.emit(V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                operation: "secretDecode", failure: .tokenExpired,
                groupDiscovered: true, tokenWellFormed: true))
            throw error
        }
        V3SecretHandoffTrace.emit(V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
            operation: "secretDecode", failure: nil, groupDiscovered: true, tokenWellFormed: true))
        return payload
    }

    static func sharedKeychainAccessGroup() throws -> String {
        // SecTask entitlement APIs are not exposed by the iOS SDK. Ask the
        // public Keychain API which default access group this signed process
        // owns, then verify the derived shared group with an explicit add.
        //
        // The two steps fail for different reasons and must stay distinguishable.
        // Discovery uses this process's own default group and therefore always
        // succeeds for a signed process. The explicit probe is the one that a
        // re-sign breaks when the shared group is granted to the main app but
        // not to its extensions, which is the shape of the reported failure.
        let defaultGroup: String
        do {
            defaultGroup = try probeAccessGroup()
        } catch let error as V3SecretHandoffError {
            throw V3SecretHandoffError.fail(.keychainGroupDiscoveryFailed, as: error.diagnostics,
                                            operation: "groupDiscovery", osStatus: error.osStatusValue)
        }
        guard let group = V3SharedKeychainAccessGroupPolicy.sharedGroup(fromDefaultGroup: defaultGroup) else {
            throw V3SecretHandoffError.fail(.keychainGroupDiscoveryFailed,
                as: V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                    operation: "groupDiscovery", groupDiscovered: true),
                operation: "groupDiscovery")
        }
        do {
            let verified = try probeAccessGroup(explicitGroup: group)
            guard verified == group else {
                throw V3SecretHandoffError.fail(.keychainExplicitGroupUnauthorized,
                    as: V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                        operation: "groupAuthorize", groupDiscovered: true),
                    operation: "groupAuthorize", osStatus: Int32(errSecParam))
            }
        } catch let error as V3SecretHandoffError {
            // errSecMissingEntitlement is the signature of a group this process
            // was never granted. Report it as such rather than as a generic
            // read failure, because the two need different fixes.
            let reason: V3SecretHandoffFailure =
                error.osStatusValue == errSecMissingEntitlement || error.osStatusValue == errSecNoAccessForItem
                ? .keychainExplicitGroupUnauthorized : .keychainGroupDiscoveryFailed
            throw V3SecretHandoffError.fail(reason, as: error.diagnostics,
                operation: "groupAuthorize", osStatus: error.osStatusValue, groupDiscovered: true)
        }
        return group
    }

    /// The one group name both processes would derive if they were entitled to
    /// the same group. Exposed so callers can report which scope they selected
    /// without ever logging the identifier itself.
    static var sharedKeychainGroupName: String {
        V3SharedKeychainAccessGroupPolicy.sharedGroup(fromDefaultGroup: "AAAAAAAAAA.x") ?? ""
    }

    /// This process's own default Keychain access group.
    ///
    /// A signer that re-signs this bundle grants the shared group to the root
    /// bundle only, so the service extension can never be entitled to it. The
    /// embedded SideStore runs in exactly one process, which makes its own
    /// default group a legitimate owner of its credentials rather than a
    /// fallback that leaks them.
    static func processDefaultKeychainAccessGroup() throws -> String {
        try probeAccessGroup()
    }

    private static func probeAccessGroup(explicitGroup: String? = nil) throws -> String {
        let service = "com.kdt.livecontainer.v3-access-group-probe"
        let account = UUID().uuidString
        var item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse,
            // Group discovery also runs during background refresh after the
            // first unlock, matching the credential client's accessibility.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data([0]),
            kSecReturnAttributes as String: true]
        var deletion: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse]
        if let explicitGroup {
            item[kSecAttrAccessGroup as String] = explicitGroup
            deletion[kSecAttrAccessGroup as String] = explicitGroup
        }
        var result: CFTypeRef?
        let status = SecItemAdd(item as CFDictionary, &result)
        guard status == errSecSuccess else {
            let reason: V3SecretHandoffFailure = explicitGroup != nil && status == errSecMissingEntitlement
                ? .keychainExplicitGroupUnauthorized
                : (explicitGroup == nil ? .keychainGroupDiscoveryFailed : .keychainReadFailed)
            throw V3SecretHandoffError.fail(reason,
                as: V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                    operation: "groupProbe", groupDiscovered: explicitGroup == nil),
                operation: "groupProbe", osStatus: status, groupDiscovered: explicitGroup == nil)
        }
        let group = (result as? [String: Any])?[kSecAttrAccessGroup as String] as? String
        let deleteStatus = SecItemDelete(deletion as CFDictionary)
        guard deleteStatus == errSecSuccess, let group else {
            throw V3SecretHandoffError.fail(.keychainDeleteFailed,
                as: V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                    operation: "groupProbe", groupDiscovered: true),
                operation: "groupProbe", osStatus: Int32(deleteStatus), groupDiscovered: true)
        }
        return group
    }

    private static func itemQuery(_ token: String, group: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: token,
         kSecAttrAccessGroup as String: group,
         kSecAttrSynchronizable as String: kCFBooleanFalse]
    }

    private static func listedItems(group: String) throws -> [[String: Any]] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: kCFBooleanFalse,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            let reason: V3SecretHandoffFailure = status == errSecMissingEntitlement
                ? .keychainExplicitGroupUnauthorized : .keychainReadFailed
            throw V3SecretHandoffError.fail(reason,
                as: V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                    operation: "secretList", groupDiscovered: true),
                operation: "secretList", osStatus: status, groupDiscovered: true)
        }
        if let rows = result as? [[String: Any]] { return rows }
        if let row = result as? [String: Any] { return [row] }
        throw V3SecretHandoffError.fail(.keychainReadFailed,
            as: V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                operation: "secretList", groupDiscovered: true),
            operation: "secretList", groupDiscovered: true)
    }

    private static func removeExpiredItems(group: String, rows: [[String: Any]], now: Date) throws -> Int {
        var retained = 0
        for row in rows {
            guard let token = row[kSecAttrAccount as String] as? String, isValidToken(token) else { continue }
            guard let createdAt = row[kSecAttrCreationDate as String] as? Date,
                  createdAt <= now, now.timeIntervalSince(createdAt) <= V3SecretHandoffRecord.lifetime else {
                let status = SecItemDelete(itemQuery(token, group: group) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw V3SecretHandoffError.fail(.keychainDeleteFailed,
                        as: V3SecretHandoffDiagnostics(role: V3SecretHandoffRole.current,
                            operation: "secretSweep", groupDiscovered: true, tokenWellFormed: true),
                        operation: "secretSweep", osStatus: Int32(status),
                        groupDiscovered: true, tokenWellFormed: true)
                }
                continue
            }
            retained += 1
        }
        return retained
    }
}
// MARK: - Authentication failure classification (typed, no string guessing)

// Privacy-safe display kind for the previous authentication attempt failure.
// Only the kind string plus CombinedFailure scalar fields cross the bridge.
// Never credentials, tokens, 2FA codes, DSID, headers, or response bodies.
enum V3AuthFailureKind: String, Equatable {
    case invalidCredentials
    case appSpecificPasswordRequired
    case invalidCode
    case rateLimited
    case serviceUnavailable
    case anisette
    case network
    case accountRepairRequired
    case credentialStorage, credentialStorageUncertain
    case accountIdentityMismatch
    case anisetteIdentityStateInvalid
    case unknown
}

struct V3ProvisioningReauthenticationIdentityError: Error {}

func v3AuthFailureStage(_ kind: V3AuthFailureKind) -> CombinedFailure.Stage {
    switch kind {
    // The wire stage enum intentionally keeps authentication failures under
    // authentication; failureKind preserves the precise Anisette meaning.
    case .anisette, .anisetteIdentityStateInvalid: return .authentication
    case .network: return .network
    case .credentialStorage, .credentialStorageUncertain: return .persistence
    case .unknown: return .provisioning
    case .invalidCredentials, .appSpecificPasswordRequired, .invalidCode,
         .rateLimited, .serviceUnavailable, .accountRepairRequired, .accountIdentityMismatch:
        return .authentication
    }
}

// Classifies the actual typed error from SignInOperation.authenticationLoop().
// Returns nil for cancellation-class results, which must clear any stored
// failure instead of being displayed. Evidence for each mapping is the pinned
// SideSign source (Sources/DeveloperPortal/Authentication.swift,
// Sources/Models/Errors.swift, Sources/Constants.swift):
// - incorrectCredentials: GrandSlam ec -22406
// - appSpecificPasswordRequired: GrandSlam ec -20101 / -20209
// - tooManyAttempts: GrandSlam ec -21668 / -20102 / -22411, or HTTP 429
// - incorrectVerificationCode: wrong 2FA code (returns to credentials prompt)
// - invalidAnisetteData: Anisette infrastructure failure
// - accountRepairRequired: Apple requires account attention
// - ServerError.badServerResponse / invalidResponseFormat / missingKey do not
//   establish an outage: they can describe an empty/unparseable response or a
//   missing field, but carry no safe typed HTTP status. Keep them unknown.
// - ServerError.underlyingError with a GrandSlam rate-limit code: rateLimited
// - known URL transport codes: network failure
// Anything else is honestly reported as unknown.
func v3IsAuthCancellation(_ error: Error) -> Bool {
    let error = v3AccountUnderlyingError(error)
    if error is CancellationError { return true }
    if let portal = error as? DeveloperPortalError, case .userCancelled = portal { return true }
    let native = error as NSError
    return CombinedFailure.isURLCancellation(domain: native.domain, code: native.code)
}

// Called only at our operation boundaries, before NSError bridging loses the
// associated ServerError code. Never choose a stage from provider text.
func v3AnisetteAttemptContext(_ error: Error) -> V3AnisetteAttemptContext? {
    var current = error
    for _ in 0..<5 {
        if let attempt = current as? V3AnisetteAttemptError { return attempt.context }
        if let phase = current as? V3AuthenticationPhaseError { current = phase.underlying }
        else if let account = current as? V3AccountOperationError { return account.anisetteAttempt }
        else { break }
    }
    return nil
}

func v3AccountOperationFailure(_ error: Error, step: CombinedFailure.SourceStep) -> V3AccountOperationError {
    if let known = error as? V3AccountOperationError { return known }
    let step = (error as? V3AuthenticationPhaseError)?.step ?? step
    let anisetteAttempt = v3AnisetteAttemptContext(error)
    let error = v3AccountUnderlyingError(error)
    let kind: V3AccountOperationError.Kind
    var httpStatus: Int?
    var serverCode: Int?
    var nativeEvidence: V3AnisetteNativeEvidence?
    if error is LCAnisettePairError { kind = .anisetteIdentityStateInvalid }
    else if error is V3AccountDatabaseOutcomeUnknownError { kind = .persistenceOutcomeUnknown }
    else if let server = error as? ServerError {
        switch server {
        case .underlyingError(let code, _): kind = .sideSignServerReportedError; serverCode = code
        case .badServerResponse: kind = .sideSignBadResponse
        case .invalidResponseFormat: kind = .sideSignInvalidResponse
        case .missingKey: kind = .sideSignMissingKey
        }
    } else if error is DeveloperPortalError { kind = .sideSignDeveloperPortalError }
    else if error is SideSign.AnisetteError { kind = .anisetteFailure }
    else if let anisette = error as? AnisetteKit.AnisetteError {
        switch anisette {
        case .invalidArgument: kind = .anisetteKitInvalidArgument
        case .loaderFailed: kind = .anisetteKitLoaderFailed
        case .symbolMissing: kind = .anisetteKitSymbolMissing
        case .readFailure: kind = .anisetteKitReadFailure
        case .invalidResponse: kind = .anisetteKitInvalidResponse
        case .adiError(let code, let description):
            kind = .anisetteKitADIError
            nativeEvidence = .capture(code: code, description: description)
        case .librariesNotFound: kind = .anisetteKitLibrariesNotFound
        case .httpError(let statusCode, _):
            kind = .anisetteKitHTTPError
            if (100...599).contains(statusCode) { httpStatus = statusCode }
        }
    } else if let archive = error as? SideSign.Archive.Error {
        switch archive {
        case .fileNotFound: kind = .archiveFileNotFound
        case .corruptArchive: kind = .archiveCorrupt
        case .readFailed: kind = .archiveReadFailed
        case .writeFailed: kind = .archiveWriteFailed
        case .missingAppBundle: kind = .archiveMissingApp
        }
    } else if let decoding = error as? DecodingError {
        switch decoding {
        case .typeMismatch: kind = .decodingTypeMismatch
        case .valueNotFound: kind = .decodingValueNotFound
        case .keyNotFound: kind = .decodingKeyNotFound
        case .dataCorrupted: kind = .decodingDataCorrupted
        @unknown default: kind = .unknownAccountFailure
        }
    }
    else {
        let native = error as NSError
        switch (native.domain, native.code) {
        case ("com.SideStore.Keychain", 1010): kind = .keychainOutcomeUnknown
        case ("com.SideStore.Keychain", 1009): kind = .keychainValidationFailed
        case ("com.SideStore.Keychain", _), (NSOSStatusErrorDomain, _): kind = .keychainWrite
        case ("LiveContainerRefresh.Configuration", 1008): kind = .legacyMigrationConflict
        default:
            if CombinedFailure.knownURLTransportCause(domain: native.domain, code: native.code) != nil {
                kind = .transportFailure
            } else if step == .saveAccount || step == .activateAccount { kind = .persistenceFailure }
            else { kind = .unknownAccountFailure }
        }
    }
    return V3AccountOperationError(step: kind == .anisetteIdentityStateInvalid ? .anisetteFetch : step,
        kind: kind, underlying: error, serverCode: serverCode, httpStatus: httpStatus, nativeEvidence: nativeEvidence, anisetteAttempt: anisetteAttempt)
}

// Both terminal routes (including cached/provisioning-resume paths that never
// call handleSignInResult) preserve the same owned phase evidence.
func v3CaptureAuthFailure(_ error: Error, operation: String,
                          stage: CombinedFailure.Stage, id: String,
                          retryable: Bool? = nil) -> CombinedFailure {
    let diagnostic: Error = error is V3AuthenticationPhaseError
        ? v3AccountOperationFailure(error, step: .authenticate) : error
    return CombinedFailure.capture(diagnostic, operation: operation, stage: stage,
                                   id: id, retryable: retryable)
}

func v3AccountUnderlyingError(_ error: Error) -> Error {
    var current = error
    // Unwrap only our own fixed wrapper, never arbitrary NSError.userInfo.
    for _ in 0..<5 {
        if let wrapped = current as? V3AccountOperationError { current = wrapped.underlying }
        else if let phase = current as? V3AuthenticationPhaseError { current = phase.underlying }
        else if let attempt = current as? V3AnisetteAttemptError { current = attempt.underlying }
        else { break }
    }
    return current
}

func v3ClassifyAuthError(_ error: Error) -> V3AuthFailureKind? {
    if v3AccountUnderlyingError(error) is LCAnisettePairError { return .anisetteIdentityStateInvalid }
    if let local = error as? V3AccountOperationError, local.credentialCommit {
        return local.kind == .keychainOutcomeUnknown ? .credentialStorageUncertain : .credentialStorage
    }
    if v3IsAuthCancellation(error) { return nil }
    let error = v3AccountUnderlyingError(error)
    if error is V3ProvisioningReauthenticationIdentityError { return .accountIdentityMismatch }
    if let portal = error as? DeveloperPortalError {
        switch portal {
        case .incorrectCredentials: return .invalidCredentials
        case .appSpecificPasswordRequired: return .appSpecificPasswordRequired
        case .tooManyAttempts: return .rateLimited
        case .incorrectVerificationCode: return .invalidCode
        case .invalidAnisetteData: return .anisette
        case .accountRepairRequired: return .accountRepairRequired
        case .userCancelled: return nil
        default: return .unknown
        }
    }
    // SideSign's own AnisetteProvider can throw AnisetteError directly before
    // DeveloperPortalError exists (for example, when no servers are configured
    // or every provider fails). Preserve that typed infrastructure category and
    // never forward its associated response/path text.
    if error is SideSign.AnisetteError || error is AnisetteKit.AnisetteError { return .anisette }
    if let server = error as? ServerError {
        switch server {
        // These response-shape cases have unsafe associated text/payload and
        // do not prove that Apple is unavailable. Only an explicit typed
        // outage should map to serviceUnavailable.
        case .badServerResponse, .invalidResponseFormat, .missingKey:
            return .unknown
        case .underlyingError(let code, _):
            // GrandSlam rate-limit codes (Sources/Constants.swift).
            if code == -22411 || code == -20102 || code == -21668 {
                return .rateLimited
            }
            return .unknown
        }
    }
    let native = error as NSError
    if CombinedFailure.knownURLTransportCause(domain: native.domain, code: native.code) != nil {
        return .network
    }
    return .unknown
}

func v3AccountDatabaseSnapshot() async throws -> [String] {
    let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
    return try await context.perform {
        try context.setQueryGenerationFrom(.current)
        let accounts = Account.fetchRequest() as NSFetchRequest<Account>
        accounts.predicate = NSPredicate(format: "%K == YES", #keyPath(Account.isActiveAccount))
        let teams = Team.fetchRequest() as NSFetchRequest<Team>
        teams.predicate = NSPredicate(format: "%K == YES", #keyPath(Team.isActiveTeam))
        return (try context.fetch(accounts).map { "account:" + $0.identifier } +
            context.fetch(teams).map { "team:" + $0.identifier }).sorted()
    }
}

func v3ReconcileAccountDatabaseStorage() async throws {
    guard V3AccountDatabaseRecovery.requiresReconciliation else { return }
    try V3AccountDatabaseRecovery.reconcile(observed: try await v3AccountDatabaseSnapshot())
}

// MARK: - Authentication state machine

// The journal contains only a digest, never credentials or private device IDs.
@MainActor
func v3ProvisioningCompletionBinding(credentials: LCEmbeddedAuthenticationSnapshot?,
                                    teamID: String?, certificateSerial: String?) -> String? {
    guard credentials?.isAuthenticated == true,
          let owner = V3AuthIdentityBindingPolicy.normalizedOwner(credentials?.appleIDEmailAddress),
          let dsid = credentials?.appleIDAdsid, !dsid.isEmpty,
          let token = credentials?.appleIDXcodeToken, !token.isEmpty,
          let teamID, !teamID.isEmpty, let certificateSerial, !certificateSerial.isEmpty,
          let device = UIDevice.current.identifierForVendor?.uuidString,
          let bytes = try? PropertyListSerialization.data(fromPropertyList:
            [owner, dsid, token, teamID, certificateSerial, device], format: .binary, options: 0) else { return nil }
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

struct V3ProvisioningResumeUnavailableError: Error {}

@MainActor
final class V3AuthCenter {
    // V3_PROVISIONING_RESUME_V1: how a begin request should be served.
    // .interactive asks for credentials and two-factor codes. .resumeProvisioning
    // reuses the already authenticated Apple session, so a retry after a
    // provisioning failure never repeats credentials or 2FA.
    enum BeginMode: String, Equatable {
        case interactive
        case resumeProvisioning
        case reauthenticateProvisioning
    }

    struct Session {
        var mode: BeginMode = .interactive
        var task: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var prompt: [String: Any]?
        var attempts = 0
        var revision = 0
        var terminal = V3TerminalResponse()
        var deadline = Date.distantFuture
        var previousFailure: [String: Any]?
        var rejectedPortalSessionFailure: CombinedFailure?
        var terminalAt: Date?
        var cancellationRequested = false
        var acceptedPromptIDs: [String] = []
        var submittedAppleID: String?
        var authenticatedAppleID: String?
        var accountAppleIDAtStart: String?
        var reauthenticationAppleID: String?
        var reauthenticationIdentityStamp: String?
    }

    // Privacy-safe record of a finished-but-incomplete provisioning attempt, so
    // Retry Provisioning can be served without credentials or 2FA. Only the
    // lowercased Apple ID and the typed stage are stored; never a token.
    var provisioningCompletion = V3ProvisioningCompletionState()
    // Both journals survive a service restart. A failed read is never permission
    // to mutate; only verified storage reconciliation can clear their holds.
    var provisioningRecoveryRequiresReconciliation: Bool {
        V3AccountDatabaseRecovery.requiresReconciliation ||
            ((try? Keychain.shared.storageRequiresReconciliation()) ?? true)
    }


    func reconcileStorage() async throws {
        let auth = AuthManager.shared
        auth.v3BeginIdentityTransition()
        defer {
            // Repaired storage may select the old or the intended route. Drop
            // only process-local caches; saved account/certificate data remain.
            auth.session = nil
            auth.team = nil
            auth.v3CompleteIdentityTransition()
        }
        try await v3ReconcileAccountDatabaseStorage()
        try Keychain.shared.reconcileStorage()
        try CertificateManager.shared.loadActiveCertificate()
    }

    func canReauthenticateProvisioning() -> Bool {
        let auth = AuthManager.shared
        let stamp = auth.v3IdentityStamp
        let credentials = auth.authenticationSnapshot
        return !provisioningRecoveryRequiresReconciliation &&
            !hasActiveSession && auth.v3IdentityIsStable && stamp == auth.v3IdentityStamp &&
            V3AuthIdentityBindingPolicy.normalizedOwner(credentials?.appleIDEmailAddress) != nil &&
            V3AuthIdentityBindingPolicy.hasTokenBackedRoute(
                credentialRoutePresent: credentials?.isAuthenticated == true,
                dsid: credentials?.appleIDAdsid, xcodeToken: credentials?.appleIDXcodeToken)
    }

    private(set) var resumableProvisioning: (appleID: String, stage: String)?

    func canResumeProvisioning() -> Bool {
        guard !provisioningRecoveryRequiresReconciliation else { return false }
        let auth = AuthManager.shared
        let generationAtStart = auth.v3IdentityGeneration
        let stampAtStart = auth.v3IdentityStamp
        let stableAtStart = auth.v3IdentityIsStable
        let credentials = auth.authenticationSnapshot
        let session = auth.session
        let teamOwner = auth.team?.account?.appleID
        let stableSession = stableAtStart && V3AuthReadStampPolicy.mayReturn(
            capturedStamp: stampAtStart, currentStamp: auth.v3IdentityStamp,
            stable: auth.v3IdentityIsStable) &&
            V3AuthIdentityBindingPolicy.hasUsableSession(
                credentialRoutePresent: credentials?.isAuthenticated == true,
                dsid: credentials?.appleIDAdsid, xcodeToken: credentials?.appleIDXcodeToken,
                sessionDSID: session?.dsid, sessionXcodeToken: session?.authToken,
                generationBefore: generationAtStart, generationAfter: auth.v3IdentityGeneration)
        return V3AuthSessionAdmissionPolicy.mayStartNewSession(hasActiveSession: hasActiveSession) &&
            V3ProvisioningResumeAvailabilityPolicy.canResume(
            authenticated: V3AuthIdentityBindingPolicy.hasTokenBackedRoute(
                credentialRoutePresent: credentials?.isAuthenticated == true,
                dsid: credentials?.appleIDAdsid, xcodeToken: credentials?.appleIDXcodeToken),
            currentAppleID: credentials?.appleIDEmailAddress,
            resumableAppleID: resumableProvisioning?.appleID,
            hasSession: stableSession,
            hasTeamAccount: teamOwner != nil,
            teamAccountAppleID: teamOwner)
    }

    var sessions: [String: Session] = [:]
    private var activeID: String?
    private var cancelledBeforeBegin = V3AuthStartCancellationRegistry()

    var hasActiveSession: Bool {
        guard let activeID, let session = sessions[activeID] else { return false }
        // A timed-out terminal cannot reopen mutation admission while its
        // cancelled SignInOperation is still unwinding.
        return session.terminal.isEmpty || session.task != nil
    }

    var activeSessionIDForSnapshot: String? {
        hasActiveSession ? activeID : nil
    }

    func ownsActiveSession(_ id: String) -> Bool {
        activeID == id && sessions[id]?.terminal.isEmpty == true
    }

    func begin(deadline: Date, mode: BeginMode = .interactive,
               requestDeadline: Date? = nil,
               sessionID requestedID: String? = nil) async -> [String: Any] {
        cleanupSessions()
        let id = requestedID ?? UUID().uuidString
        guard let parsedID = UUID(uuidString: id), parsedID.uuidString == id else {
            return ["session": id, "state": "failed", "authenticated": false,
                    "message": "The sign-in attempt identifier is invalid."]
        }
        if cancelledBeforeBegin.consume(id) {
            var session = Session(deadline: deadline)
            _ = session.terminal.setIfEmpty(["session": id, "state": "cancelled", "authenticated": false])
            session.terminalAt = Date()
            sessions[id] = session
            cleanupSessions()
            return poll(id: id) ?? ["session": id, "state": "cancelled", "authenticated": false]
        }
        let authCredentials = AuthManager.shared.authenticationSnapshot
        if mode == .reauthenticateProvisioning && !canReauthenticateProvisioning() {
            return ["session": id, "state": "failed", "authenticated": false,
                    "message": "Reload account status before signing in again to finish setup."]
        }
        if mode == .resumeProvisioning {
            // Refuse to claim a reusable session that cannot be reused. This is
            // the only place that decides whether a retry may skip credentials,
            // so it checks both the keychain session and that it belongs to the
            // account whose provisioning actually failed.
            let sessionAppleID = authCredentials?.appleIDEmailAddress?.lowercased()
            let resumable = resumableProvisioning
            let teamAppleID = AuthManager.shared.team?.account?.appleID
            guard V3AuthIdentityBindingPolicy.hasTokenBackedRoute(
                    credentialRoutePresent: authCredentials?.isAuthenticated == true,
                    dsid: authCredentials?.appleIDAdsid, xcodeToken: authCredentials?.appleIDXcodeToken),
                  let resumable, !resumable.appleID.isEmpty,
                  resumable.appleID == sessionAppleID,
                  V3AuthIdentityBindingPolicy.mayUseTeam(sessionOwner: sessionAppleID,
                    teamOwner: teamAppleID) else {
                let failure = CombinedFailure(operation: "signIn", stage: .authentication, code: .notReady,
                    id: id, retryable: false)
                let response: [String: Any] = ["session": id, "state": "failed", "authenticated": false,
                    "stage": failure.stage.rawValue, "code": failure.code.rawValue,
                    "message": "The saved Apple session is no longer valid. Sign in again with this Apple ID.",
                    "failure": failure.wire,
                    "technicalDetails": failure.technicalDetails]
                debugLog("[V3_AUTH] TERMINAL session=\(id) state=failed reason=provisioning_not_resumable")
                return response
            }
            debugLog("[V3_AUTH] PROVISIONING_RESUME authenticated=true previous_stage=\(resumable.stage)")
        }
        let previousID = activeID
        var newSession = Session(deadline: deadline)
        newSession.mode = mode
        if let activeAppleID = DatabaseManager.shared.activeAccount()?.appleID {
            newSession.accountAppleIDAtStart = activeAppleID
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if mode == .resumeProvisioning {
            newSession.authenticatedAppleID = authCredentials?.appleIDEmailAddress?.lowercased()
        }
        if mode == .reauthenticateProvisioning {
            newSession.reauthenticationAppleID = V3AuthIdentityBindingPolicy.normalizedOwner(authCredentials?.appleIDEmailAddress)
            newSession.reauthenticationIdentityStamp = AuthManager.shared.v3IdentityStamp
        }
        guard provisioningCompletion.begin(attemptID: id, owner: authCredentials?.appleIDEmailAddress,
            identityStamp: AuthManager.shared.v3IdentityStamp) else {
            return ["session": id, "state": "failed", "authenticated": false,
                    "message": "SideStore could not save the setup attempt safely. Reload status before continuing."]
        }
        sessions[id] = newSession
        activeID = id
        // Reserve ownership before the first suspension. A cancel or a newer
        // auth begin can now find this exact session while the previous task
        // unwinds, instead of recording a tombstone that the new begin misses.
        if let previousID, previousID != id {
            let oldTask = sessions[previousID]?.task
            _ = cancel(id: previousID)
            if let oldTask { await oldTask.value }
        }
        let requestExpired = Task.isCancelled || (requestDeadline.map { $0 <= Date() } ?? false)
        if requestExpired { _ = cancel(id: id) }
        guard let current = sessions[id],
              V3AuthSessionResponsePolicy.mayLaunchCreatedSession(sessionID: id,
                activeSessionID: activeID, cancellationRequested: current.cancellationRequested,
                terminalIsEmpty: current.terminal.isEmpty,
                requestCancelled: requestExpired) else {
            return poll(id: id) ?? ["session": id, "state": "cancelled", "authenticated": false]
        }
        sessions[id]?.task = Task { @MainActor in await V3HeadlessRuntime.shared.auth.run(id: id) }
        sessions[id]?.watchdog = Task { @MainActor in
            let interval = deadline.timeIntervalSinceNow
            if interval > 0 { try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
            V3HeadlessRuntime.shared.auth.expire(id: id)
        }
        debugLog("[V3_AUTH] BEGIN session=\(id) mode=\(mode.rawValue)")
        return ["session": id, "state": "working", "revision": sessions[id]?.revision ?? 0]
    }

    func run(id: String) async {
        defer {
            sessions[id]?.task = nil
            sessions[id]?.watchdog?.cancel()
            sessions[id]?.watchdog = nil
            if activeID == id { activeID = nil }
            cleanupSessions()
        }
        do {
            let background = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            let context = StandaloneOperationContext(steps: .signIn, dbBackgroundContext: background)
            let handler = V3HeadlessAuthHandler(sessionID: id)
            let forceProvisioningRetry = sessions[id]?.mode == .resumeProvisioning
            let operation = try SignInOperation(context: context, signInHandler: handler,
                anisetteServerHandler: handler, v3ForceProvisioningRetry: forceProvisioningRetry,
                v3RequireFullProvisioning: true,
                v3RequireInteractiveCredentials: sessions[id]?.mode == .interactive,
                v3ReauthenticateAppleID: sessions[id]?.reauthenticationAppleID,
                v3ReauthenticationIdentityStamp: sessions[id]?.reauthenticationIdentityStamp)
            let result = try await operation.execute()
            let account = result.team.account ?? ALTAccount(appleID: "", identifier: result.team.identifier)
            let identityGeneration = AuthManager.shared.v3IdentityGeneration
            let identityStamp = AuthManager.shared.v3IdentityStamp
            let credentials = AuthManager.shared.authenticationSnapshot
            guard V3AuthIdentityBindingPolicy.hasUsableSession(
                    credentialRoutePresent: credentials?.isAuthenticated == true,
                    dsid: credentials?.appleIDAdsid, xcodeToken: credentials?.appleIDXcodeToken,
                    sessionDSID: result.session.dsid, sessionXcodeToken: result.session.authToken,
                    generationBefore: identityGeneration,
                    generationAfter: AuthManager.shared.v3IdentityGeneration) else {
                throw OperationError.notAuthenticated
            }
            await handler.handleSignInResult(.success((account, result.session)))
            let activeAccount = DatabaseManager.shared.activeAccount()
            let activeTeam = DatabaseManager.shared.activeTeam()
            let activeCertificate = CertificateManager.shared.activeCertificate?.certificate
            guard ownsActiveSession(id), provisioningCompletion.complete(attemptID: id,
                owner: credentials?.appleIDEmailAddress, identityStamp: AuthManager.shared.v3IdentityStamp,
                identityStable: V3AuthReadStampPolicy.mayReturn(capturedStamp: identityStamp,
                    currentStamp: AuthManager.shared.v3IdentityStamp, stable: AuthManager.shared.v3IdentityIsStable),
                fullProvisioningCompleted: operation.v3DidCompleteProvisioning,
                activeAccountMatches: V3AuthIdentityBindingPolicy.mayUseTeam(
                    sessionOwner: credentials?.appleIDEmailAddress, teamOwner: activeAccount?.appleID),
                activeTeamMatches: activeTeam?.identifier == result.team.identifier &&
                    V3AuthIdentityBindingPolicy.mayUseTeam(sessionOwner: credentials?.appleIDEmailAddress,
                        teamOwner: activeTeam?.account?.appleID),
                activeCertificateMatches: result.certificate != nil && activeCertificate != nil &&
                    result.certificate?.serialNumber == activeCertificate?.serialNumber,
                binding: v3ProvisioningCompletionBinding(credentials: credentials,
                    teamID: activeTeam?.identifier, certificateSerial: activeCertificate?.serialNumber)) else {
                throw V3ProvisioningResumeUnavailableError()
            }
            sessions[id]?.prompt = nil
            resumableProvisioning = nil
            finish(id: id, response: ["state": "completed", "team": result.team.name,
                                      "teamID": result.team.identifier, "authenticated": true])
            debugLog("[V3_AUTH] TERMINAL session=\(id) state=completed")
        } catch {
            sessions[id]?.prompt = nil
            let session = sessions[id]
            let activeAppleID = DatabaseManager.shared.activeAccount()?.appleID
            let submitted = session?.submittedAppleID?.lowercased()
            let credentials = AuthManager.shared.authenticationSnapshot
            let tokenBackedRoute = V3AuthIdentityBindingPolicy.hasTokenBackedRoute(
                credentialRoutePresent: credentials?.isAuthenticated == true,
                dsid: credentials?.appleIDAdsid, xcodeToken: credentials?.appleIDXcodeToken)
            let authenticationSucceeded = tokenBackedRoute &&
                V3AuthIdentityBindingPolicy.mayUseTeam(
                    sessionOwner: session?.authenticatedAppleID ?? submitted,
                    teamOwner: credentials?.appleIDEmailAddress) && V3AuthAttemptAuthenticationPolicy.confirms(
                authenticationCallbackSeen: session?.authenticatedAppleID != nil,
                submittedAppleID: submitted, activeAppleID: activeAppleID,
                accountAppleIDAtStart: session?.accountAppleIDAtStart)
            let cancelled = v3IsAuthCancellation(error) || session?.cancellationRequested == true
            let authenticatedOutcome = V3AuthTerminalPolicy.resolve(
                authenticationSucceeded: authenticationSucceeded,
                authoritativeAccountMatches: false,
                provisioningFailed: !cancelled,
                cancelled: cancelled)

            if authenticatedOutcome == "authenticatedProvisioningIncomplete" {
                // V3_AUTH_PROVISIONING_TERMINAL_SHAPE_V1: one state, one wire
                // shape. A cancelled provisioning attempt and a failed one both
                // carry stage/code/failure/technicalDetails and an explicit
                // outcome discriminator, so the host never has to guess and can
                // never present a successful sign-in as a failed one.
                let resumeUnavailable = error is V3ProvisioningResumeUnavailableError
                let portalSessionRejected = (error as? V3AccountOperationError)?.portalSessionRejected == true
                if portalSessionRejected {
                    // Retire only the rejected process-local session. Preserve
                    // the saved account and certificates for explicit reauthentication.
                    AuthManager.shared.v3ReplaceSession(nil)
                }
                let postAuthentication = V3AuthPostAuthenticationFailurePolicy.resolve(
                    cancelled: cancelled, savedSessionUnavailable: resumeUnavailable)
                let failure: CombinedFailure
                if resumeUnavailable {
                    failure = CombinedFailure(operation: "signIn", stage: .provisioning, code: .notReady,
                                              id: id, retryable: false)
                } else {
                    failure = v3CaptureAuthFailure(error, operation: "signIn", stage: postAuthentication.stage,
                        id: id, retryable: cancelled)
                }
                var failureWire = failure.wire
                let anisetteIdentityStateInvalid = failure.signingContext["typed_error"] == "anisetteIdentityStateInvalid"
                if anisetteIdentityStateInvalid { failureWire["kind"] = "anisetteIdentityStateInvalid" }
                if resumeUnavailable || portalSessionRejected || provisioningRecoveryRequiresReconciliation || anisetteIdentityStateInvalid {
                    resumableProvisioning = nil
                } else if let resumableAppleID = V3ProvisioningResumeIdentityPolicy.select(
                    authenticatedSessionAppleID: session?.authenticatedAppleID,
                    submittedAppleID: submitted, activeAppleID: activeAppleID) {
                    resumableProvisioning = (resumableAppleID, failure.stage.rawValue)
                } else {
                    resumableProvisioning = nil
                }
                let message = anisetteIdentityStateInvalid
                    ? LCAnisettePairError.safeMessage + " " + LCAnisettePairError.recovery
                    : portalSessionRejected
                    ? "Apple rejected the developer-portal session while loading your teams (1100). Sign in again to finish setup."
                    : postAuthentication.message
                var response: [String: Any] = [
                    "state": authenticatedOutcome,
                    "authenticated": true,
                    "outcome": cancelled ? "provisioningCancelled" : "provisioningFailed",
                    "resumable": tokenBackedRoute && !resumeUnavailable && !portalSessionRejected && !provisioningRecoveryRequiresReconciliation && !anisetteIdentityStateInvalid,
                    "message": message,
                    "stage": failure.stage.rawValue,
                    "code": failure.code.rawValue,
                    "failure": failureWire,
                    "technicalDetails": failure.technicalDetails]
                finish(id: id, response: response)
                debugLog("[V3_AUTH] TERMINAL session=\(id) state=authenticatedProvisioningIncomplete outcome=\(cancelled ? "provisioningCancelled" : "provisioningFailed") stage=\(failure.stage.rawValue) code=\(failure.code.rawValue)")
            } else if cancelled {
                finish(id: id, response: ["state": "cancelled", "authenticated": false])
                debugLog("[V3_AUTH] TERMINAL session=\(id) state=cancelled")
            } else {
                let failure = v3CaptureAuthFailure(error, operation: "signIn", stage: .authentication, id: id)
                var wire = failure.wire
                if let kind = v3ClassifyAuthError(error) { wire["kind"] = kind.rawValue }
                let message = (wire["kind"] as? String).map { V3AuthFailureDisplay.message(for: $0) } ?? failure.safeMessage
                let response: [String: Any] = ["state": "failed", "stage": failure.stage.rawValue,
                    "code": failure.code.rawValue, "failure": wire, "message": message,
                    "technicalDetails": failure.technicalDetails]
                finish(id: id, response: response)
                debugLog("[V3_AUTH] TERMINAL session=\(id) state=failed stage=\(failure.stage.rawValue) code=\(failure.code.rawValue)")
            }
        }
    }

    func poll(id: String) -> [String: Any]? {
        cleanupSessions()
        guard let session = sessions[id] else {
            if cancelledBeforeBegin.contains(id) {
                return ["session": id, "state": "cancelled", "authenticated": false, "revision": 0]
            }
            return nil
        }
        if let terminal = session.terminal.value {
            var reply = terminal.merging(["session": id]) { current, _ in current }
            reply["revision"] = session.revision
            return reply
        }
        if let prompt = session.prompt, !session.cancellationRequested {
            var reply: [String: Any] = ["session": id, "state": "awaitingPrompt", "attempts": session.attempts,
                                        "revision": session.revision, "prompt": prompt]
            if let previousFailure = session.previousFailure {
                reply["previousFailure"] = previousFailure
            }
            return reply
        }
        return ["session": id, "state": "working", "attempts": session.attempts,
                "revision": session.revision,
                "cancellationRequested": session.cancellationRequested]
    }

    func respond(id: String, promptID: String, answer: [String: String]) -> [String: Any]? {
        guard let session = sessions[id] else { return nil }
        if V3PromptResponseStatePolicy.shouldReturnCurrentStateAfterAcceptedDuplicate(
            acceptedPromptID: nil, acceptedPromptIDs: session.acceptedPromptIDs,
            currentPromptID: session.prompt?["id"] as? String,
            submittedPromptID: promptID, sessionTerminal: !session.terminal.isEmpty,
            cancellationRequested: session.cancellationRequested) {
            return poll(id: id)
        }
        guard session.terminal.isEmpty, !session.cancellationRequested else { return nil }
        if let pending = V3PromptResponseStatePolicy.responsePending(.unavailable,
            acceptedPromptID: session.acceptedPromptIDs.last, promptID: promptID,
            sessionID: id, revision: session.revision, state: "awaitingPrompt", prompt: session.prompt) {
            return pending
        }
        guard session.prompt?["id"] as? String == promptID else { return nil }
        let disposition = V3HeadlessRuntime.shared.prompts.answer(promptID: promptID, answer: answer)
        if let pending = V3PromptResponseStatePolicy.responsePending(disposition,
            acceptedPromptID: session.acceptedPromptIDs.last, promptID: promptID,
            sessionID: id, revision: session.revision, state: "awaitingPrompt", prompt: session.prompt) {
            return pending
        }
        guard disposition == .accepted else {
            return ["session": id, "state": "promptExpired",
                    "revision": sessions[id]?.revision ?? session.revision]
        }
        if let current = sessions[id] {
            sessions[id]?.acceptedPromptIDs = V3PromptResponseStatePolicy.recordAcceptedPrompt(
                current.acceptedPromptIDs, promptID: promptID)
        }
        sessions[id]?.attempts += 1
        sessions[id]?.revision += 1
        // Clear previous failure on successful response to credentials prompt
        if let prompt = sessions[id]?.prompt,
           prompt["kind"] as? String == "credentials" {
            sessions[id]?.previousFailure = nil
        }
        return poll(id: id)
    }

    func expire(id: String) {
        guard var session = sessions[id], session.terminal.isEmpty else { return }
        let activeAppleID = DatabaseManager.shared.activeAccount()?.appleID
        let authenticationConfirmed = V3AuthAttemptAuthenticationPolicy.confirms(
            authenticationCallbackSeen: session.authenticatedAppleID != nil,
            submittedAppleID: session.submittedAppleID, activeAppleID: activeAppleID,
            accountAppleIDAtStart: session.accountAppleIDAtStart)
        let authCredentials = AuthManager.shared.authenticationSnapshot
        let authenticatedAppleID = (session.authenticatedAppleID ?? authCredentials?.appleIDEmailAddress)?.lowercased()
        let tokenBackedRoute = V3AuthIdentityBindingPolicy.hasTokenBackedRoute(
            credentialRoutePresent: authCredentials?.isAuthenticated == true,
            dsid: authCredentials?.appleIDAdsid, xcodeToken: authCredentials?.appleIDXcodeToken)
        let routeMatchesAttempt = V3AuthIdentityBindingPolicy.mayUseTeam(
            sessionOwner: authenticatedAppleID, teamOwner: authCredentials?.appleIDEmailAddress)
        let authenticated = authenticationConfirmed && tokenBackedRoute && routeMatchesAttempt
        if authenticated, tokenBackedRoute, session.rejectedPortalSessionFailure == nil,
           let authenticatedAppleID, !authenticatedAppleID.isEmpty,
           resumableProvisioning?.appleID != authenticatedAppleID {
            resumableProvisioning = (authenticatedAppleID, "sessionTimeout")
        }
        let resumable = authenticated && tokenBackedRoute && session.rejectedPortalSessionFailure == nil &&
            authenticatedAppleID.map { resumableProvisioning?.appleID == $0 } == true
        session.cancellationRequested = true
        session.task?.cancel()
        session.watchdog?.cancel()
        session.prompt = nil
        sessions[id] = session
        var response = V3AuthSessionExpiryPolicy.response(authenticated: authenticated,
                                                          resumable: resumable)
        if let failure = session.rejectedPortalSessionFailure {
            response["resumable"] = false
            response["failure"] = failure.wire
            response["stage"] = failure.stage.rawValue
            response["code"] = failure.code.rawValue
            response["technicalDetails"] = failure.technicalDetails
            response["message"] = "Apple rejected the developer-portal session while loading your teams (1100). Sign in again to finish setup."
        }
        _ = finish(id: id, response: response)
        if session.task == nil, activeID == id { activeID = nil }
        debugLog("[V3_AUTH] TERMINAL session=\(id) state=\(authenticated ? "authenticatedProvisioningIncomplete" : "timedOut")")
    }

    @discardableResult
    func cancel(id: String) -> Bool {
        guard var session = sessions[id] else { return false }
        if !session.terminal.isEmpty { return true }
        session.cancellationRequested = true
        session.task?.cancel()
        session.watchdog?.cancel()
        session.prompt = nil
        sessions[id] = session
        debugLog("[V3_AUTH] CANCEL session=\(id)")
        if session.task == nil {
            _ = finish(id: id, response: ["state": "cancelled", "authenticated": false])
            if activeID == id { activeID = nil }
        }
        return true
    }

    @discardableResult
    func cancelBeforeBegin(id: String) -> Bool {
        guard let parsed = UUID(uuidString: id), parsed.uuidString == id else { return false }
        if sessions[id] != nil { return cancel(id: id) }
        return cancelledBeforeBegin.cancelBeforeStart(id)
    }

    func cancelAndWait(id: String) async -> Bool {
        guard let parsed = UUID(uuidString: id), parsed.uuidString == id else { return false }
        guard let session = sessions[id] else { return cancelBeforeBegin(id: id) }
        let task = session.task
        guard cancel(id: id) else { return false }
        if let task { await task.value }
        return true
    }

    @discardableResult
    private func finish(id: String, response: [String: Any]) -> Bool {
        guard var session = sessions[id], session.terminal.setIfEmpty(response) else { return false }
        session.revision += 1
        session.terminalAt = Date()
        sessions[id] = session
        cleanupSessions()
        return true
    }

    private func cleanupSessions(now: Date = Date()) {
        cancelledBeforeBegin.prune(now: now)
        let expired = sessions.compactMap { id, session in
            session.task == nil && session.terminal.value != nil &&
                session.terminalAt.map { now.timeIntervalSince($0) > 600 } == true ? id : nil
        }
        for id in expired where id != activeID { sessions.removeValue(forKey: id) }
        let completed = sessions.filter { $0.value.task == nil && $0.value.terminal.value != nil && $0.key != activeID }
            .sorted { ($0.value.terminalAt ?? .distantPast) < ($1.value.terminalAt ?? .distantPast) }
        if completed.count > 256 {
            for (id, _) in completed.prefix(completed.count - 256) { sessions.removeValue(forKey: id) }
        }
    }

}

enum V3AuthFailureDisplay {
    static func message(for kind: String) -> String {
        switch kind {
        case "invalidCredentials": return "Apple did not accept the Apple ID or password. Check them and try again."
        case "appSpecificPasswordRequired": return "Apple requires an app-specific password for this authentication path."
        case "invalidCode": return "The verification code was not accepted. Enter a new code and try again."
        case "rateLimited": return "Too many authentication attempts. Apple is temporarily rate-limiting requests. Wait before trying again."
        case "serviceUnavailable": return "Apple's authentication service is temporarily unavailable. Try again later."
        case "anisetteIdentityStateInvalid": return LCAnisettePairError.safeMessage
        case "anisette": return "Authentication could not obtain valid Anisette data."
        case "network": return "Authentication could not reach the required Apple service. Check the connection and try again."
        case "accountRepairRequired": return "Apple requires attention on this account before signing in."
        case "accountIdentityMismatch": return "Use the same Apple ID as the saved account. Reload status if the account changed."
        default: return "Apple sign-in failed for an unknown typed reason."
        }
    }
}

enum V3TwoFactorPhoneSelectionPolicy {
    enum Decision: Equatable {
        case changeMethod
        case cancel
        case requestSMS(phoneID: String)
        case requestVoice(phoneID: String)
    }

    static func resolve(method: String, action: String?, phoneIDs: [String]) -> Decision {
        guard let action else { return .cancel }
        if action == "changeMethod" { return .changeMethod }
        guard action.hasPrefix("phone:") else { return .cancel }
        let phoneID = String(action.dropFirst("phone:".count))
        guard !phoneID.isEmpty, phoneIDs.contains(phoneID) else { return .cancel }
        switch method {
        case "sms": return .requestSMS(phoneID: phoneID)
        case "voice": return .requestVoice(phoneID: phoneID)
        default: return .cancel
        }
    }
}

@MainActor
final class V3HeadlessAuthHandler: SignInHandler, AnisetteServerHandler {
    let sessionID: String
    init(sessionID: String) { self.sessionID = sessionID }

    private func center() throws -> V3AuthCenter {
        let center = V3HeadlessRuntime.shared.auth
        guard let session = center.sessions[sessionID], session.terminal.isEmpty else { throw CancellationError() }
        return center
    }

    private func ask(kind: String, title: String, message: String,
                     fields: [[String: String]] = [], options: [[String: String]] = [],
                     destructive: Bool = false) async throws -> [String: String] {
        let center = try center()
        let prompt = v3Prompt(kind: kind, title: title, message: message,
                              fields: fields, options: options, destructive: destructive)
        guard let promptID = prompt["id"] as? String else { throw CancellationError() }
        defer {
            if center.sessions[sessionID]?.prompt?["id"] as? String == promptID {
                center.sessions[sessionID]?.prompt = nil
                center.sessions[sessionID]?.revision += 1
            }
        }
        return try await center.promptsParked(promptID: promptID) {
            guard center.sessions[self.sessionID]?.terminal.isEmpty == true else { return }
            if center.sessions[self.sessionID]?.prompt?["id"] as? String != promptID {
                center.sessions[self.sessionID]?.revision += 1
            }
            center.sessions[self.sessionID]?.prompt = prompt
            debugLog("[V3_AUTH] PROMPT session=\(self.sessionID) kind=\(kind) attempts=\(center.sessions[self.sessionID]?.attempts ?? 0)")
        }
    }

    func credentials() async throws -> (String, String) {
        let expectedOwner = V3HeadlessRuntime.shared.auth.sessions[sessionID]?.reauthenticationAppleID
        let answer = try await ask(kind: "credentials", title: "Apple ID Sign In",
                                   message: expectedOwner == nil ? "Enter the Apple ID and password used for signing."
                                    : "Sign in with the saved Apple ID to finish device provisioning. Your account and certificate are kept.",
                                   fields: [["key": "appleID", "label": "Apple ID", "secure": "false", "value": expectedOwner ?? ""],
                                            ["key": "password", "label": "Password", "secure": "true"]])
        guard let appleID = answer["appleID"], !appleID.isEmpty,
              let password = answer["password"], !password.isEmpty else { throw CancellationError() }
        V3HeadlessRuntime.shared.auth.sessions[sessionID]?.submittedAppleID = appleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (appleID, password)
    }

    func verificationCode(for request: TwoFactorRequest) async throws -> TwoFactorResponse {
        switch request {
        case .selectDeliveryMethod(let preferredMode, let phoneNumbers):
            _ = preferredMode
            return try await chooseDeliveryMethod(phoneNumbers: phoneNumbers)
        case .trustedDevice:
            return try await enterVerificationCode(mode: .trustedDevice, phoneNumbers: [], activeID: "",
                                                  failure: request.verificationFailure)
        case .sms(let phoneNumbers, let selectedID, _):
            return try await enterVerificationCode(mode: .sms, phoneNumbers: phoneNumbers, activeID: selectedID,
                                                  failure: request.verificationFailure)
        case .voice(let phoneNumbers, let selectedID, _):
            return try await enterVerificationCode(mode: .voice, phoneNumbers: phoneNumbers, activeID: selectedID,
                                                  failure: request.verificationFailure)
        }
    }

    private func chooseDeliveryMethod(phoneNumbers: [TrustedPhoneNumber]) async throws -> TwoFactorResponse {
        let methods: [[String: String]] = [
            ["id": "trustedDevice", "label": "Use Trusted Device"],
            ["id": "sms", "label": "Send SMS"],
            ["id": "voice", "label": "Request Voice Call"],
            ["id": "cancel", "label": "Cancel Sign In"]
        ]
        // Empty lists still support Apple's default phone target, as in the original handler.
        let priorKind = V3HeadlessRuntime.shared.auth.sessions[sessionID]?.previousFailure?["kind"] as? String
        let message = V3TwoFactorRetryPolicy.recoveryMessage(authFailureKind: priorKind)
            ?? "Choose how Apple should send your verification code."
        let answer = try await ask(kind: "twoFactor", title: "Choose Verification Method",
            message: message,
            fields: [["key": "step", "label": "step", "secure": "false", "value": V3TwoFactorStep.chooseDeliveryMethod.rawValue]],
            options: methods)
        switch answer["action"] {
        case "trustedDevice":
            debugLog("[V3_AUTH] 2FA_DELIVERY_REQUESTED mode=trustedDevice")
            return .requestTrustedDevice
        case "sms", "voice":
            let method = answer["action"] ?? "sms"
            var phoneID = phoneNumbers.first?.id ?? ""
            if phoneNumbers.count > 1 {
                let phoneChoices = phoneNumbers.map { ["id": "phone:\($0.id)", "label": $0.number] }
                    + [["id": "changeMethod", "label": "Change Verification Method"],
                       ["id": "cancel", "label": "Cancel Sign In"]]
                let selection = try await ask(kind: "twoFactor", title: "Choose Phone Number",
                    message: "Select where Apple should send the verification code.",
                    fields: [["key": "step", "label": "step", "secure": "false", "value": V3TwoFactorStep.afterDeliveryChoice(method, phoneCount: phoneNumbers.count)?.rawValue ?? V3TwoFactorStep.choosePhoneNumber.rawValue],
                             ["key": "mode", "label": "mode", "secure": "false", "value": method]],
                    options: phoneChoices)
                switch V3TwoFactorPhoneSelectionPolicy.resolve(
                    method: method, action: selection["action"], phoneIDs: phoneNumbers.map(\.id)) {
                case .changeMethod:
                    // The SideSign continuation has not received a delivery
                    // response yet. Re-open method selection before dispatch.
                    return try await chooseDeliveryMethod(phoneNumbers: phoneNumbers)
                case .cancel:
                    return .cancel
                case .requestSMS(let selectedPhoneID):
                    debugLog("[V3_AUTH] 2FA_DELIVERY_REQUESTED mode=sms")
                    return .requestSMS(phoneID: selectedPhoneID)
                case .requestVoice(let selectedPhoneID):
                    debugLog("[V3_AUTH] 2FA_DELIVERY_REQUESTED mode=voice")
                    return .requestVoice(phoneID: selectedPhoneID)
                }
            }
            debugLog("[V3_AUTH] 2FA_DELIVERY_REQUESTED mode=\(method)")
            return method == "sms" ? .requestSMS(phoneID: phoneID) : .requestVoice(phoneID: phoneID)
        default:
            return .cancel
        }
    }

    private func enterVerificationCode(mode: TwoFactorDeliveryMode, phoneNumbers: [TrustedPhoneNumber],
                                       activeID: String, failure: TwoFactorVerificationFailure?) async throws -> TwoFactorResponse {
        let acknowledgement: String
        switch mode {
        case .trustedDevice: acknowledgement = "Verification request sent to your trusted devices."
        case .sms: acknowledgement = "Verification code requested by SMS."
        case .voice: acknowledgement = "Verification call requested."
        }
        let priorKind = V3HeadlessRuntime.shared.auth.sessions[sessionID]?.previousFailure?["kind"] as? String
        let message = failure?.userMessage ?? V3TwoFactorRetryPolicy.recoveryMessage(authFailureKind: priorKind) ?? acknowledgement
        var options = [["id": "changeMethod", "label": "Change Verification Method"],
                       ["id": "cancel", "label": "Cancel Sign In"]]
        if mode != .trustedDevice {
            options.insert(["id": "resend", "label": mode == .sms ? "Resend SMS" : "Call Again"], at: 0)
        }
        let answer = try await ask(kind: "twoFactor", title: "Enter Verification Code", message: message,
            fields: [["key": "step", "label": "step", "secure": "false", "value": V3TwoFactorStep.afterDelivery(mode.rawValue)?.rawValue ?? V3TwoFactorStep.enterVerificationCode.rawValue],
                     ["key": "mode", "label": "mode", "secure": "false", "value": mode.rawValue],
                     ["key": "activeID", "label": "activeID", "secure": "false", "value": activeID],
                     ["key": "code", "label": "Verification code", "secure": "false"]],
            options: options)
        switch answer["action"] {
        case "code":
            guard let code = answer["code"], code.count == 6 else { return try await enterVerificationCode(
                mode: mode, phoneNumbers: phoneNumbers, activeID: activeID, failure: .unknown) }
            debugLog("[V3_AUTH] 2FA_CODE_SUBMITTED")
            return .verificationCode(code)
        case "resend":
            // Only this explicit answer requests another delivery, to the active target.
            switch mode {
            case .sms: return .requestSMS(phoneID: activeID)
            case .voice: return .requestVoice(phoneID: activeID)
            case .trustedDevice: return .cancel
            }
        case "changeMethod": return try await chooseDeliveryMethod(phoneNumbers: phoneNumbers)
        default: return .cancel
        }
    }

    func accountRepair(url: URL, message: String) async -> AccountRepairDecision {
        _ = message // Provider text may contain account-specific content; never send it to the host.
        // The repair URL is not a credential and the prompt descriptor already
        // reaches the host over the same command channel, so it travels in the
        // field value. `openableURL` re-validates it before anything opens it.
        let fields = [V3AuthRepairURLPolicy.promptField(url: url.absoluteString)]
        do {
            let answer = try await ask(kind: "accountRepair", title: "Account Attention Needed",
                                       message: V3AuthRepairURLPolicy.safeMessage,
                                       fields: fields,
                                       options: [["id": "proceed", "label": "Continue"], ["id": "cancel", "label": "Cancel"]])
            return answer["choice"] == "proceed" ? .proceed : .cancel
        } catch { return .cancel }
    }

    func handleSignInResult(_ result: Result<(ALTAccount, ALTAppleAPISession), Error>) async {
        guard V3HeadlessRuntime.shared.auth.sessions[sessionID]?.terminal.isEmpty == true else { return }
        switch result {
        case .success(let (account, _)):
            V3HeadlessRuntime.shared.auth.provisioningCompletion.authenticated(attemptID: sessionID,
                owner: account.appleID, identityStamp: AuthManager.shared.v3IdentityStamp)
            V3HeadlessRuntime.shared.auth.sessions[sessionID]?.previousFailure = nil
            V3HeadlessRuntime.shared.auth.sessions[sessionID]?.authenticatedAppleID =
                account.appleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case .failure(let error):
            guard let kind = v3ClassifyAuthError(error) else {
                V3HeadlessRuntime.shared.auth.sessions[sessionID]?.previousFailure = nil
                return
            }
            let diagnosed = v3AccountOperationFailure(error, step: .authenticate)
            let failure = CombinedFailure.capture(diagnosed, operation: "signIn", stage: .authentication, id: sessionID)
            var wire = failure.wire
            wire["kind"] = kind.rawValue
            V3HeadlessRuntime.shared.auth.sessions[sessionID]?.previousFailure = wire
            debugLog("[V3_AUTH] ATTEMPT_FAILED session=\(sessionID) kind=\(kind.rawValue) stage=\(failure.stage.rawValue) code=\(failure.code.rawValue) correlation=\(failure.correlationID)")
        }
    }

    func resolveTeam(_ teams: [ALTTeam]) async throws -> ALTTeam {
        let answer = try await ask(kind: "team", title: "Select Team", message: "Choose the development team used for signing.",
                                   options: teams.map { ["id": $0.identifier, "label": "\($0.name) (\($0.identifier))"] })
        guard let identifier = answer["choice"], let team = teams.first(where: { $0.identifier == identifier }) else {
            throw CancellationError()
        }
        return team
    }

    func resolveProvisioningError(_ error: Error) async -> ProvisioningErrorDecision {
        // Cancellation is terminal, never a prompt. Everything else is
        // classified from the actual typed error: the message comes from the
        // concrete DeveloperPortalError or SideStore.OperationError case; the
        // bridged domain/code travel only inside the separate technical
        // details. A numeric NSError code is never treated as a semantic API.
        let diagnosticError = v3AccountOperationFailure(error, step: .provisioningUnknown)
        let error = v3AccountUnderlyingError(error)
        if error is CancellationError { return .cancel }
        if v3IsAuthCancellation(error) { return .cancel }
        if diagnosticError.portalSessionRejected {
            if let center = try? center(), center.ownsActiveSession(sessionID) {
                // Preserve the typed rejection even if the prompt watchdog wins
                // before the operation unwinds. No credential/certificate deletion.
                center.sessions[sessionID]?.rejectedPortalSessionFailure =
                    diagnosticError.failure(operation: "signIn", id: sessionID)
                AuthManager.shared.v3ReplaceSession(nil)
            }
            return await askProvisioningRetry(
                message: "Apple rejected the developer-portal session while loading your teams (1100).",
                hint: "Choose Finish Later, then Sign In Again to Finish Setup. Retrying provisioning would reuse the rejected session. This happened before certificate setup.",
                error: diagnosticError, mayRetry: false)
        }
        if diagnosticError.requiresReconciliation {
            return await askProvisioningRetry(
                message: "Provisioning reached local storage, but the save result could not be confirmed.",
                hint: "Finish Later and reload Account & Signing to reconcile storage before continuing.",
                error: diagnosticError, mayRetry: false)
        }
        if [.keychainWrite, .keychainValidationFailed, .legacyMigrationConflict, .persistenceFailure].contains(diagnosticError.kind) {
            return await askProvisioningRetry(
                message: "Provisioning could not save the required account or signing state on this device.",
                hint: "Retry repeats this local storage step. If it keeps failing, Finish Later and review the safe diagnostics.",
                error: diagnosticError)
        }
        if let portal = error as? DeveloperPortalError {
            if case .userCancelled = portal { return .cancel }
            let guidance = v3ProvisioningGuidance(portal)
            return await askProvisioningRetry(message: guidance.message, hint: guidance.hint, error: diagnosticError)
        }
        if let operation = error as? OperationError {
            let guidance = v3OperationErrorGuidance(operation)
            return await askProvisioningRetry(message: guidance.message, hint: guidance.hint, error: diagnosticError)
        }
        return await askProvisioningRetry(
            message: "Provisioning could not be completed because of an unexpected failure.",
            hint: "You can retry; if it keeps failing, check the account, team, and certificates before trying again.",
            error: diagnosticError)
    }

    private func askProvisioningRetry(message: String, hint: String, error: Error, mayRetry: Bool = true) async -> ProvisioningErrorDecision {
        let technical = CombinedFailure.provisioningRetryTechnicalDetails(
            for: error, correlationID: sessionID)
        // V3_PROVISIONING_RECOVERY_LABELS_V1: authentication already succeeded.
        // "Cancel" would read as a failed sign-in, so the escape action is named
        // Finish Later and the retry is scoped to provisioning only.
        do {
            let answer = try await ask(kind: "provisioningError", title: "Provisioning Needs Attention",
                                       message: message + "\n\n" + hint,
                                       fields: [["key": "technical", "label": "Technical details", "secure": "false", "value": technical]],
                                       options: (mayRetry ? [["id": "retry", "label": "Retry Provisioning"]] : []) +
                                                 [["id": "cancel", "label": "Finish Later"]])
            return mayRetry && answer["choice"] == "retry" ? .retry : .cancel
        } catch { return .cancel }
    }

    func resolvePostAuth() async {
        _ = try? await ask(kind: "postAuth", title: "Almost Done",
                           message: "Authentication succeeded. Continue to finish provisioning this device.",
                           options: [["id": "continue", "label": "Continue"]])
    }

    func resolveRevocation(certificates: [ALTX509Certificate], teamType: ALTTeamType) async throws -> RevokeDecision {
        let answer = try await ask(kind: "revocation", title: "Certificates Need Attention",
                                   message: "The portal holds certificates that block provisioning for a \("\(teamType)") team. Keep the existing certificates or revoke the selected ones.",
                                   fields: [["key": "serials", "label": "serials", "secure": "false", "value": ""]],
                                   options: [["id": "keep", "label": "Keep Existing"]] +
                                       certificates.map { ["id": "revoke:\($0.serialNumber)", "label": "\($0.name) (\($0.serialNumber))"] })
        let selection = try V3PromptSelectionPolicy.revocation(
            choice: answer["choice"], submittedOptionIDs: answer["serials"],
            offeredSerials: certificates.map(\.serialNumber))
        if case .keepExisting = selection { return .keepExisting }
        guard case .revoke(let serials) = selection else { throw CancellationError() }
        let selected = certificates.filter { serials.contains($0.serialNumber) }
        guard selected.count == serials.count, !selected.isEmpty else { throw CancellationError() }
        return .revokeSelected(selected)
    }

    func resolveResign(mismatchReason: CodeSignValidationReason, context: StandaloneOperationContext) async throws -> Bool {
        let answer = try await ask(kind: "resign", title: "Host Refresh Needed",
                                   message: "The installed LiveContainer app needs to be refreshed with the active signing certificate (\(mismatchReason)). Finish sign-in, then run Refresh All or Test Refresh in Setup Assistant. Sign-in alone does not re-sign the installed app.",
                                   options: [["id": "continue", "label": "Finish Sign-In"]])
        guard answer["choice"] == "continue" else { throw CancellationError() }
        // Upstream consumes this result as didResign, not permission to resign.
        // Host replacement belongs to the separately verified refresh owner.
        return false
    }

    func complete() async {}

    func warnOutdatedAnisetteServer() async throws -> Bool {
        let answer = try await ask(kind: "anisetteOutdated", title: "Outdated Anisette Server",
                                   message: "The configured anisette server is outdated, which increases the risk of locking the account. Continue anyway?",
                                   options: [["id": "continue", "label": "Continue"], ["id": "cancel", "label": "Cancel"]],
                                   destructive: true)
        return answer["choice"] == "continue"
    }
}

extension V3AuthCenter {
    func promptsParked(promptID: String, onReady: @escaping @MainActor () -> Void) async throws -> [String: String] {
        try await V3HeadlessRuntime.shared.prompts.park(promptID: promptID, onReady: onReady)
    }
}

// LC_ANISETTE_PAIR_FAILURE_V1: finite preservation failures only. Never attach
// the identifier, provisioning blob, provider response, or Keychain bytes.
public enum LCAnisettePairError: Error, LocalizedError, Equatable {
    case orphanedBlob, invalidIdentifier, invalidBlob, migrationPairConflict, stateChanged

    public static let safeMessage = "Sign-in is blocked because the saved Anisette identity state could not be verified."
    public static let recovery = "Keep the existing Anisette and account data unchanged. Copy Diagnostics for review before another sign-in."
    public var errorDescription: String? { Self.safeMessage }
}

// V3_AUTHENTICATION_PHASE_EVIDENCE_V1: preserve the original error for retry,
// cancellation and typed matching; never store provider strings or payloads.
struct V3AuthenticationPhaseError: Error {
    let step: CombinedFailure.SourceStep
    let underlying: Error
}
func v3AuthenticationPhase<T>(_ step: CombinedFailure.SourceStep,
                              perform: () async throws -> T) async throws -> T {
    do { return try await perform() }
    catch {
        let native = error as NSError
        if error is CancellationError || CombinedFailure.isURLCancellation(domain: native.domain, code: native.code) { throw error }
        if error is V3AuthenticationPhaseError { throw error }
        throw V3AuthenticationPhaseError(step: step, underlying: error)
    }
}

// V3_TYPED_ACCOUNT_DIAGNOSTICS_V1: only operation-owned stage and fixed
// classifications cross the wire. Original errors stay inside the process for
// typed guidance; descriptions, userInfo and provider payloads never serialize.
struct V3AccountOperationError: Error, LocalizedError {
    enum Kind: String {
        case keychainWrite, keychainValidationFailed, keychainOutcomeUnknown
        case legacyMigrationConflict, persistenceFailure, persistenceOutcomeUnknown, transportFailure
        case sideSignServerReportedError, sideSignBadResponse, sideSignInvalidResponse
        case sideSignMissingKey, sideSignDeveloperPortalError, anisetteFailure
        case anisetteKitInvalidArgument, anisetteKitLoaderFailed, anisetteKitSymbolMissing, anisetteKitReadFailure, anisetteKitInvalidResponse, anisetteKitADIError, anisetteKitLibrariesNotFound, anisetteKitHTTPError, decodingTypeMismatch, decodingValueNotFound, decodingKeyNotFound, decodingDataCorrupted
        case archiveFileNotFound, archiveCorrupt, archiveReadFailed, archiveWriteFailed, archiveMissingApp
        case unknownAccountFailure
        case anisetteIdentityStateInvalid
    }
    let step: CombinedFailure.SourceStep
    let kind: Kind
    let underlying: Error
    let serverCode: Int?
    var httpStatus: Int? = nil
    var nativeEvidence: V3AnisetteNativeEvidence? = nil
    var anisetteAttempt: V3AnisetteAttemptContext? = nil

    var errorDescription: String? { "An account operation failed; review the safe diagnostics." }
    var credentialCommit: Bool { step == .credentialCommit && kind != .anisetteIdentityStateInvalid }
    // Apple Developer Portal result 1100 rejects the portal session. Scope this
    // to the observed team-list boundary; an NSError bridge code is not proof.
    var portalSessionRejected: Bool {
        step == .fetchTeams && kind == .sideSignServerReportedError && serverCode == 1100
    }
    var requiresReconciliation: Bool {
        kind == .keychainOutcomeUnknown || kind == .persistenceOutcomeUnknown
    }
    var failureStage: CombinedFailure.Stage {
        if kind == .anisetteIdentityStateInvalid { return .authentication }
        switch step {
        case .credentialCommit, .saveAccount, .activateAccount, .activateCertificate: return .persistence
        case .authenticate, .anisetteFetch, .appleAuthentication, .accountLookup: return .authentication
        default: return .provisioning
        }
    }
    func failure(operation: String, id: String) -> CombinedFailure {
        let native = underlying as NSError
        let safeCause: CombinedFailure.SafeCause?
        if kind == .anisetteIdentityStateInvalid { safeCause = nil }
        else if credentialCommit {
            safeCause = kind == .keychainOutcomeUnknown ? .credentialCommitOutcomeUnknown : .credentialCommitFailed
        } else if step == .activateAccount { safeCause = .accountActivationFailed }
        else if step == .activateCertificate || step == .saveAccount { safeCause = .provisioningStorageFailed }
        else { safeCause = nil }
        // An associated Apple result is separate from Swift's enum bridge code.
        // HTTP status remains unavailable unless a typed producer observes it.
        var signingContext = ["typed_error": kind.rawValue,
            "server_code": serverCode.map(String.init) ?? "unknown", "http_status": httpStatus.map(String.init) ?? "unavailable"]
        if kind == .anisetteKitADIError, let nativeEvidence {
            signingContext["native_code"] = String(nativeEvidence.code)
            signingContext["native_phase"] = nativeEvidence.phase.rawValue
            signingContext["native_subcode"] = nativeEvidence.subcode.map(String.init) ?? "unknown"
        }
        if let anisetteAttempt {
            signingContext.merge(anisetteAttempt.diagnosticFields) { _, observed in observed }
        }
        return CombinedFailure(operation: operation, stage: failureStage, id: id,
            underlying: NSError(domain: native.domain, code: native.code),
            retryable: safeCause != nil || portalSessionRejected || kind == .anisetteIdentityStateInvalid ? false : nil, safeCause: safeCause,
            sourceStep: kind == .anisetteIdentityStateInvalid ? .anisetteFetch : step,
            signingContext: signingContext)
    }
}

// Journal only the account/team activation transaction, before the database is
// touched. No password, DSID, token, certificate or provider payload is stored.
// A crash is resolved from a fresh persistent-store read against the exact
// pre-transaction or intended active identity set, never account-row presence.
struct V3AccountDatabaseOutcomeUnknownError: Error, LocalizedError {
    var errorDescription: String? { "The local account activation outcome needs reconciliation." }
}

enum V3AccountDatabaseRecovery {
    static let key = "V3AccountDatabaseActivationPendingV1"
    static var requiresReconciliation: Bool { UserDefaults.standard.object(forKey: key) != nil }

    private static func valid(_ values: [String]) -> Bool {
        values.count <= 1024 && values == values.sorted() && Set(values).count == values.count &&
            values.allSatisfy { value in
                value.utf8.count <= 1024 &&
                    ((value.hasPrefix("account:") && value.count > 8) ||
                     (value.hasPrefix("team:") && value.count > 5))
            }
    }
    static func begin(previous: [String], intended: [String], defaults: UserDefaults = .standard) throws {
        guard valid(previous), valid(intended), defaults.object(forKey: key) == nil else {
            throw V3AccountDatabaseOutcomeUnknownError()
        }
        let record: [String: Any] = ["previous": previous, "intended": intended]
        defaults.set(record, forKey: key)
        guard defaults.synchronize(),
              let saved = defaults.dictionary(forKey: key),
              saved["previous"] as? [String] == previous,
              saved["intended"] as? [String] == intended else {
            throw V3AccountDatabaseOutcomeUnknownError()
        }
    }
    static func reconcile(observed: [String], defaults: UserDefaults = .standard) throws {
        guard defaults.object(forKey: key) != nil else { return }
        guard valid(observed), let record = defaults.dictionary(forKey: key),
              Set(record.keys) == Set(["previous", "intended"]),
              let previous = record["previous"] as? [String], valid(previous),
              let intended = record["intended"] as? [String], valid(intended),
              observed == previous || observed == intended else {
            throw V3AccountDatabaseOutcomeUnknownError()
        }
        defaults.removeObject(forKey: key)
        guard defaults.synchronize(), defaults.object(forKey: key) == nil else {
            // Restore the hold if durable removal cannot be established.
            defaults.set(record, forKey: key)
            _ = defaults.synchronize()
            throw V3AccountDatabaseOutcomeUnknownError()
        }
    }
}

