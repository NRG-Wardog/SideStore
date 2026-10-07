//
//  AppDelegate.swift
//  AltStore
//
//  Created by Riley Testut on 5/9/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import UserNotifications
import SideSign
import CoreData

extension AppDelegate
{
    
    nonisolated static let appBackupDidFinish = Notification.Name(Bundle.Info.appbundleIdentifier + ".AppBackupDidFinish")
    
    nonisolated static let appBackupResultKey = "result"
    
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

    
    #if !os(tvOS)
    #endif
    
    public let consoleLog = ConsoleLog()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
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
                // V3_SIDESTORE_STATUS_SNAPSHOT_V1: retired in favor of live XPC reads.
                
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
        
        // V3_HEADLESS_IMAGE_PIPELINE_REMOVED_V1: the headless service does not initialize legacy screen imagery.

        SecureValueTransformer.register()        
        
        UserDefaults.standard.preferredServerID = Bundle.main.object(forInfoDictionaryKey: Bundle.Info.serverID) as? String
        
        #if DEBUG && targetEnvironment(simulator)
        UserDefaults.standard.isDebugModeEnabled = true
        #endif
        
        
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


    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any]) -> Bool
    {
        return self.open(url)
    }
    
    // V3_HEADLESS_INTENT_ROUTING_REMOVED_V1: LiveContainer declares the host-owned intents.

    
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

    

    func open(_ url: URL) -> Bool
    {
        // V3_HEADLESS_EXTERNAL_OPEN_V1: host-owned install/source routes do not present in LiveProcess.
        URLHandler.shared.handle(url)
    }
}

extension AppDelegate
{
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
        // V3_HEADLESS_SERVICE_V1: refresh scheduling belongs to LiveContainer.
        completionHandler(.noData)
    }

    func application(_ application: UIApplication, performFetchWithCompletionHandler backgroundFetchCompletionHandler: @escaping (UIBackgroundFetchResult) -> Void)
    {
        // The embedded backend is invoked by the host scheduler, not by a
        // second SideStore background-refresh engine.
        backgroundFetchCompletionHandler(.noData)
    }
}

private extension AppDelegate {
    func setupCrashHandler() {
        NSSetUncaughtExceptionHandler { exception in
            // Clear handler immediately so execution can never recurse under any circumstance.
            NSSetUncaughtExceptionHandler(nil)

            // V3_CRASH_REASON_LOG_PRIVACY_V1: exception reasons and call stacks can contain secrets or paths.
            let message = V3CrashLogPrivacy.safeCrashMarker(reason: exception.reason)
            debugLog(message)
            fputs(message, stderr)
            fflush(stderr)
            NSLog("%@", message)
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

// V3_HEADLESS_SIDESTORE_APP_UI_REMOVED_V1: generated service has no standalone navigation appearance or Patreon UI.
import Foundation
import CoreFoundation
import CryptoKit

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

// V3_WIRE_CONTRACT_V1: shared source, compiled independently in each process.
// V3_HEADLESS_CONTRACT_V2: SideStore is a headless backend. All presentation
// decisions cross as data (prompts/confirmations); no remote UI is addressed.
enum V3WireContract {
    static let requestLimit = 16_384
    static let responseLimit = 4_194_304
    static let authSessionLifetime: TimeInterval = 600
    static let cancellationScopes: Set<String> = ["auth", "operation", "request"]

    static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func strictInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let type = String(cString: number.objCType)
        guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) else {
            return nil
        }
        if ["C", "S", "I", "L", "Q"].contains(type) {
            return Int(exactly: number.uint64Value)
        }
        return Int(exactly: number.int64Value)
    }

    static func authSnapshot(_ reply: [String: Any]) -> V3AuthServiceSnapshot? {
        guard let authenticated = strictBool(reply["authenticated"]),
              let provisioningIncomplete = strictBool(reply["provisioningIncomplete"]),
              let provisioningRetryAvailable = strictBool(reply["provisioningRetryAvailable"]),
              let authenticationActive = strictBool(reply["authenticationActive"]) else {
            return nil
        }
        let authenticationSessionID: String?
        if let rawAuthenticationSessionID = reply["authenticationSessionID"] {
            guard let value = rawAuthenticationSessionID as? String else { return nil }
            authenticationSessionID = value
        } else {
            authenticationSessionID = nil
        }
        if authenticationActive {
            guard let authenticationSessionID,
                  UUID(uuidString: authenticationSessionID)?.uuidString == authenticationSessionID else { return nil }
        } else if authenticationSessionID != nil {
            return nil
        }
        guard let identityStamp = reply["identityStamp"] as? String,
              !identityStamp.isEmpty, identityStamp.utf8.count <= 128,
              let identityStable = strictBool(reply["identityStable"]) else { return nil }
        return V3AuthServiceSnapshot(authenticated: authenticated,
            provisioningIncomplete: provisioningIncomplete,
            provisioningRetryAvailable: provisioningRetryAvailable,
            authenticationActive: authenticationActive,
            authenticationSessionID: authenticationSessionID,
            credentialRoutePresent: strictBool(reply["credentialRoutePresent"]) ?? false,
            identityStamp: identityStamp, identityStable: identityStable)
    }

    static func invalidRequestIdentity(from data: Data) -> (id: String?, operation: String?) {
        guard data.count <= requestLimit,
              let envelope = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return (nil, nil)
        }
        let rawID = envelope["id"] as? String
        // Preserve the caller's spelling so reply correlation remains exact;
        // UUID(uuidString:) accepts lowercase forms as valid UUIDs too.
        let id = rawID.flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
        let rawOperation = envelope["operation"] as? String
        let operation = rawOperation.flatMap { operations.contains($0) ? $0 : nil } ?? "command"
        return (id, operation)
    }

    static let operations: Set<String> = ["snapshot", "catalog", "appIcon", "cancel", "refreshSources",
        "refreshAdmissionBegin", "refreshAdmissionEnd",
        "signOut", "syncAppIDs", "clearCache", "jit", "backupResult",
        "authBegin", "authPoll", "authRespond", "authCancel", "authRetryProvisioning", "authReconcileStorage",
        "opStart", "opPoll", "opAnswer", "opCancel", "opRecoveryPrepare", "opRecoveryReconcile",
        "refreshAdmissionReconcile", "recoveryDiscardUnreadable", "directRecoveryInspect",
        "directRecoveryReconcile", "ipaCleanup", "ipaActiveTokens",
        "certList", "certExportActive", "certSetActive", "certDelete", "certPortalList", "certRevoke", "certCreate",
        "devTeams", "devDevices", "devAppIDs", "devGroups", "devProfiles",
        "sourcePreview", "sourceAddConfirmed", "sourceRemoveConfirmed",
        "pairingImportData", "settingsGet", "settingsSet",
        "anisetteList", "anisetteReset", "anisetteSync",
        "sidesignGet", "sidesignSet", "sidesignReset", "sidesignImport", "sidesignExport",
        "logTail", "healthSnapshot", "accountExport", "accountImport"]
    static let readOperations: Set<String> = ["snapshot", "catalog", "appIcon",
        "authPoll", "opPoll", "opCancel", "ipaCleanup", "ipaActiveTokens", "authCancel", "certList", "certExportActive", "certPortalList",
        "devTeams", "devDevices", "devAppIDs", "devGroups", "devProfiles",
        "sourcePreview", "settingsGet",
        "anisetteList", "sidesignGet", "sidesignExport", "logTail", "healthSnapshot",
        "directRecoveryInspect"]

    static func decodeRequest(_ data: Data, now: Date = Date()) -> [String: Any]? {
        guard data.count <= requestLimit,
              let request = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              Set(request.keys).isSubset(of: ["version", "id", "operation", "target", "deadline", "cursor", "payload"]),
              strictInt(request["version"]) == 1,
              let id = request["id"] as? String, UUID(uuidString: id) != nil,
              let operation = request["operation"] as? String, operations.contains(operation),
              let target = request["target"] as? String, target.utf8.count <= 4096,
              let deadline = request["deadline"] as? Date,
              deadline > now, deadline.timeIntervalSince(now) <= 610 else { return nil }
        if request["value"] != nil { return nil }
        let emptyTargetOperations: Set<String> = [
            "snapshot", "opStart", "accountExport", "ipaActiveTokens", "refreshSources", "signOut",
            "syncAppIDs", "clearCache", "settingsGet", "settingsSet", "sidesignGet", "sidesignSet",
            "sidesignReset", "sidesignExport", "anisetteList", "anisetteReset", "anisetteSync",
            "logTail", "certList", "certExportActive", "certPortalList", "certCreate", "opRecoveryPrepare",
            "recoveryDiscardUnreadable", "authReconcileStorage",
            "devTeams", "devDevices", "devAppIDs", "devGroups", "devProfiles"
        ]
        if emptyTargetOperations.contains(operation) && !target.isEmpty { return nil }
        if operation == "healthSnapshot", !["", "hostSigningOnly"].contains(target) { return nil }
        if ["authBegin", "authPoll", "authRespond", "authCancel", "authRetryProvisioning",
            "opPoll", "opAnswer", "opCancel", "pairingImportData", "sidesignImport", "accountImport",
            "refreshAdmissionBegin", "refreshAdmissionEnd", "refreshAdmissionReconcile",
            "opRecoveryReconcile", "directRecoveryInspect", "directRecoveryReconcile", "cancel"].contains(operation),
           !canonicalSecretToken(target) { return nil }
        if operation == "ipaCleanup", !canonicalLowercaseFileToken(target) { return nil }
        if ["appIcon", "jit"].contains(operation),
           !acceptsCoreDataTarget(target, entity: "InstalledApp") { return nil }
        if ["sourcePreview", "sourceAddConfirmed"].contains(operation), !isHTTPURL(target) { return nil }
        if operation == "backupResult", !canonicalSecretToken(target) { return nil }
        if let cursor = request["cursor"] {
            guard operation == "catalog", let value = strictInt(cursor),
                  value >= 0, value <= 1_000_000 else { return nil }
        }
        if let rawPayload = request["payload"] {
            guard let payload = rawPayload as? [String: Any],
                  acceptsPayload(operation: operation, target: target, payload: payload, now: now) else { return nil }
        } else if requiredPayloadOperations.contains(operation) {
            return nil
        }
        return request
    }

    // Apply the service's exact request schema before a host message can cross
    // XPC. Decoding remains mandatory in the service; this outbound pass keeps
    // raw secrets and unsupported fields from being transmitted at all.
    static func encodeRequest(_ request: [String: Any], now: Date = Date()) -> Data? {
        guard let data = try? PropertyListSerialization.data(
                fromPropertyList: request, format: .binary, options: 0),
              decodeRequest(data, now: now) != nil else { return nil }
        return data
    }

    private static let requiredPayloadOperations: Set<String> = [
        "authBegin", "authRetryProvisioning", "authRespond", "opAnswer", "opStart", "opRecoveryPrepare",
        "cancel", "accountExport", "accountImport", "settingsSet", "sidesignSet", "refreshAdmissionEnd",
        "recoveryDiscardUnreadable", "directRecoveryReconcile", "backupResult"
    ]

    /// The one request key that may carry a credential, and only for the
    /// operations that declare it below.
    ///
    /// The answer used to cross as an opaque Keychain token in a shared access
    /// group. Re-signing can leave the service extension without that group,
    /// making the token inaccessible even when the host can write it. The
    /// answer now travels in the request itself, over the peer-validated channel,
    /// so there is no shared-storage copy of the credential to protect at all.
    ///
    /// This key is the ONLY exemption from the raw-secret sweep. Rejecting any
    /// nested value is what keeps the exemption from becoming a hole.
    private static let credentialAnswerKey = "answer"

    private static let credentialAnswerOperations: Set<String> = [
        "authRespond", "opAnswer", "accountExport", "accountImport"
    ]

    /// A flat, strictly bounded string map. Nothing can nest inside it, so the
    /// sweep's exemption can never carry a subtree past `containsRawSecretField`.
    private static func credentialAnswerIsBounded(_ value: Any?) -> Bool {
        guard let map = value as? [String: String], !map.isEmpty, map.count <= 32 else { return false }
        return map.allSatisfy { key, text in
            !key.isEmpty && key.utf8.count <= 64 && text.utf8.count <= 4096
        }
    }

    private static func acceptsPayload(operation: String, target: String,
                                       payload: [String: Any], now: Date) -> Bool {
        // Skipped by exact key, and only where an operation declares it. Every
        // other key is still swept, at every depth.
        let skipping: Set<String> = credentialAnswerOperations.contains(operation)
            ? [credentialAnswerKey] : []
        guard !containsRawSecretField(payload, skipping: skipping) else { return false }
        switch operation {
        case "backupResult":
            return Set(payload.keys) == Set(["nonce", "action", "result"]) &&
                canonicalSecretToken(payload["nonce"]) &&
                ["backup", "restore"].contains(payload["action"] as? String ?? "") &&
                ["success", "failure"].contains(payload["result"] as? String ?? "")
        case "snapshot":
            return Set(payload.keys) == Set(["readinessOnly"]) &&
                strictBool(payload["readinessOnly"]) == true
        case "authBegin", "authRetryProvisioning":
            let baseKeys: Set<String> = ["session", "sessionDeadline"]
            // A control flag, not an authentication secret. Keep its name out
            // of the raw-secret vocabulary; do not exempt it from that sweep.
            let allowedKeys = operation == "authBegin" ? baseKeys.union(["provisioningLogin"]) : baseKeys
            guard baseKeys.isSubset(of: Set(payload.keys)), Set(payload.keys).isSubset(of: allowedKeys),
                  payload["provisioningLogin"] == nil || strictBool(payload["provisioningLogin"]) != nil,
                  let session = payload["session"] as? String,
                  canonicalSecretToken(session), session == target,
                  let sessionDeadline = payload["sessionDeadline"] as? Date,
                  sessionDeadline > now,
                  sessionDeadline.timeIntervalSince(now) <= authSessionLifetime + 10 else { return false }
            return true
        case "cancel":
            guard Set(payload.keys) == Set(["scope"]),
                  let scope = payload["scope"] as? String else { return false }
            return cancellationScopes.contains(scope)
        case "authRespond", "opAnswer":
            // The prompt id is what makes this one-shot: the service accepts an
            // answer only for the prompt it currently holds, and only once. The
            // token that used to sit here added no property the service did not
            // already enforce, and could not be read back under any signer.
            guard Set(payload.keys) == Set(["prompt", credentialAnswerKey]),
                  let prompt = payload["prompt"] as? String, !prompt.isEmpty, prompt.utf8.count <= 256,
                  credentialAnswerIsBounded(payload[credentialAnswerKey]) else { return false }
            return true
        case "accountExport":
            return Set(payload.keys) == Set(["includeApple", credentialAnswerKey]) &&
                strictBool(payload["includeApple"]) != nil &&
                credentialAnswerIsBounded(payload[credentialAnswerKey])
        case "accountImport":
            return Set(payload.keys) == Set([credentialAnswerKey]) &&
                credentialAnswerIsBounded(payload[credentialAnswerKey])
        case "opStart":
            guard Set(payload.keys) == Set(["kind", "target", "session"]),
                  let kind = payload["kind"] as? String, !kind.isEmpty, kind.utf8.count <= 128,
                  let operationTarget = payload["target"] as? String, operationTarget.utf8.count <= 4096,
                  let session = payload["session"] as? String, canonicalSecretToken(session) else { return false }
            return acceptsOperationTarget(kind: kind, target: operationTarget)
        case "opRecoveryPrepare":
            guard Set(payload.keys) == Set(["kind", "target", "session"]),
                  let kind = payload["kind"] as? String,
                  let operationTarget = payload["target"] as? String, operationTarget.utf8.count <= 4096,
                  let session = payload["session"] as? String, canonicalSecretToken(session) else { return false }
            return acceptsOperationTarget(kind: kind, target: operationTarget)
        case "opRecoveryReconcile", "refreshAdmissionReconcile":
            return Set(payload.keys) == Set(["userConfirmed"]) && strictBool(payload["userConfirmed"]) == true
        case "directRecoveryReconcile":
            if Set(payload.keys) == Set(["ackTerminal"]) {
                return strictBool(payload["ackTerminal"]) == true
            }
            return Set(payload.keys) == Set(["userConfirmed"]) && strictBool(payload["userConfirmed"]) == true
        case "recoveryDiscardUnreadable":
            return Set(payload.keys) == Set(["userConfirmed"]) && strictBool(payload["userConfirmed"]) == true
        case "refreshAdmissionEnd":
            return Set(payload.keys) == Set(["state"]) &&
                ["completed", "failed", "notDispatched"].contains(payload["state"] as? String ?? "")
        case "opCancel":
            return Set(payload.keys) == Set(["knownStarted"]) &&
                strictBool(payload["knownStarted"]) != nil
        case "settingsSet":
            guard let key = payload["key"] as? String, !key.isEmpty, key.utf8.count <= 256,
                  let type = payload["type"] as? String else { return false }
            switch type {
            case "bool":
                return Set(payload.keys) == Set(["key", "type", "bool"]) && strictBool(payload["bool"]) != nil
            case "string":
                guard Set(payload.keys) == Set(["key", "type", "string"]),
                      let value = payload["string"] as? String else { return false }
                return value.utf8.count <= 8192
            case "int":
                return Set(payload.keys) == Set(["key", "type", "int"]) && strictInt(payload["int"]) != nil
            default: return false
            }
        case "sidesignSet":
            // SideSign headers are user configuration and legitimately contain an
            // Authorization header, so their text is not content-scanned. The
            // bound that matters is the size cap.
            guard Set(payload.keys) == Set(["config"]),
                  let config = payload["config"] as? String, config.utf8.count <= 8192 else {
                return false
            }
            return true
        default:
            // Every unlisted operation is payloadless. New payload-bearing
            // commands must add an explicit schema before crossing XPC.
            return false
        }
    }

    private static func canonicalSecretToken(_ value: Any?) -> Bool {
        guard let token = value as? String, let uuid = UUID(uuidString: token) else { return false }
        return uuid.uuidString == token
    }

    private static func canonicalLowercaseFileToken(_ token: String) -> Bool {
        guard token.utf8.count == 36, let uuid = UUID(uuidString: token) else { return false }
        return uuid.uuidString.lowercased() == token
    }

    private static func acceptsOperationTarget(kind: String, target: String) -> Bool {
        switch kind {
        case "installSharedIPA":
            return canonicalLowercaseFileToken(target)
        case "installURL":
            return isHTTPURL(target)
        case "install":
            return acceptsCoreDataTarget(target, entity: "StoreApp")
        case "update", "refreshApp", "activate", "deactivate", "remove", "delete", "backup", "restore":
            return acceptsCoreDataTarget(target, entity: "InstalledApp")
        default:
            return false
        }
    }

    private static func acceptsCoreDataTarget(_ target: String, entity expectedEntity: String) -> Bool {
        guard let components = URLComponents(string: target),
              components.scheme?.lowercased() == "x-coredata",
              let host = components.host, UUID(uuidString: host) != nil,
              components.user == nil, components.password == nil,
              components.port == nil, components.query == nil, components.fragment == nil else { return false }
        let path = components.percentEncodedPath.split(separator: "/")
        return path.count == 2 && String(path[0]) == expectedEntity &&
            path[1].first == "p" && Int(path[1].dropFirst()) != nil
    }

    private static func isHTTPURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return false }
        if let port = components.port, !(1...65535).contains(port) { return false }
        return true
    }

    private static let sensitiveSecretFieldFragments: [String] = [
        "appleid", "password", "passphrase", "answer", "verificationcode", "securitycode", "otp",
        "privatekey", "p12", "credential", "auth", "accesstoken", "refreshtoken",
        "authorization", "cookie", "dsid", "phoneid", "phonenumber", "secret", "token", "udid"
    ]

    private static func containsRawSecretField(_ value: Any, skipping: Set<String> = []) -> Bool {
        var pending: [Any] = [value]
        while let current = pending.popLast() {
            if let dictionary = current as? [String: Any] {
                for (key, nested) in dictionary {
                    let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                    // Matched before the fragment sweep, and the subtree is not
                    // traversed. Its shape is bounded separately, in
                    // `credentialAnswerIsBounded`.
                    if skipping.contains(normalized) { continue }
                    // This UUID is a non-secret, one-time capability allowed
                    // only by the exact schemas validated below.
                    let opaqueHandoffToken = normalized == "secrettoken"
                    if !opaqueHandoffToken && sensitiveSecretFieldFragments.contains(where: { normalized.contains($0) }) {
                        return true
                    }
                    pending.append(nested)
                }
            } else if let array = current as? [Any] {
                pending.append(contentsOf: array)
            }
        }
        return false
    }

    // V3_PROPERTY_LIST_VALUE_V1
    // Property lists cannot encode a Swift Optional that has been boxed into
    // `Any`. Assigning `someOptional` to an `[String: Any]` value stores
    // `Optional<T>.none` as a live object, and serialization then fails for the
    // whole response, long after the value was read correctly from its owner.
    //
    // V3_PLIST_LEAF_CONTRACT_V1: the accepted leaf set is Foundation's, not a
    // hand-written list, so it cannot drift from CoreFoundation. The previous
    // list accepted `URL`, which CoreFoundation rejects for every property-list
    // format except OpenStep: a `URL` object is not a property-list leaf and a
    // URL must be sent as `url.absoluteString`. It also rejected `Float` and the
    // narrow integer types, which do serialize. `NSNumber` is used because every
    // Swift numeric type bridges to it, including Bool, so one case covers the
    // whole numeric family without a remembered list.
    enum V3PropertyListValue {
        /// Returns the unwrapped value, or nil when it is absent.
        ///
        /// Only the Optional case is unwrapped. A value that is present but not
        /// representable is returned unchanged so the encoder can report a real
        /// encoding failure instead of silently dropping data.
        static func unwrapOptional(_ value: Any?) -> Any? {
            guard let value else { return nil }
            let mirror = Mirror(reflecting: value)
            guard mirror.displayStyle == .optional else { return value }
            return mirror.children.first?.value
        }

        /// Builds a property-list-safe dictionary, omitting keys whose value is
        /// an absent Optional. A key whose value is present but unrepresentable
        /// is preserved so serialization fails loudly rather than quietly.
        static func dictionary(_ entries: [String: Any?]) -> [String: Any] {
            var result: [String: Any] = [:]
            result.reserveCapacity(entries.count)
            for (key, value) in entries {
                if let unwrapped = unwrapOptional(value) { result[key] = unwrapped }
            }
            return result
        }

        /// True when a value can be encoded by PropertyListSerialization.
        ///
        /// `URL` is deliberately absent and unknown types are rejected rather
        /// than stringified: silently coercing an arbitrary object would put
        /// unreviewable text on the wire, and dropping it would lose data without
        /// reporting anything.
        static func isEncodable(_ value: Any) -> Bool {
            // A still-boxed Optional is never encodable, so an absent value
            // reports false rather than being silently accepted.
            guard let unwrapped = unwrapOptional(value) else { return false }
            if unwrapped is String || unwrapped is NSNumber
                || unwrapped is Date || unwrapped is Data { return true }
            if let array = unwrapped as? [Any] { return array.allSatisfy { isEncodable($0) } }
            if let dictionary = unwrapped as? [String: Any] {
                return dictionary.values.allSatisfy { isEncodable($0) }
            }
            return false
        }
    }
}

enum V3RequestReplayPolicy {
    static let cancellationOperations: Set<String> = ["cancel", "authCancel", "opCancel"]

    static func requiresCompletedReply(operation: String) -> Bool {
        cancellationOperations.contains(operation)
    }

    static func fingerprint(_ requestData: Data) -> Data {
        Data(SHA256.hash(data: requestData))
    }

    static func matches(cachedFingerprint: Data?, incomingRequestData: Data) -> Bool {
        guard let cachedFingerprint else { return false }
        return cachedFingerprint == fingerprint(incomingRequestData)
    }

    static func matchesInFlight(cachedFingerprint: Data?, incomingRequestData: Data) -> Bool {
        matches(cachedFingerprint: cachedFingerprint, incomingRequestData: incomingRequestData)
    }

    static func isIdentifierCollision(cachedFingerprint: Data?, incomingRequestData: Data) -> Bool {
        guard let cachedFingerprint else { return false }
        return !matches(cachedFingerprint: cachedFingerprint, incomingRequestData: incomingRequestData)
    }

    static func mayClaimNotDispatched(operation: String, identifierCollision: Bool) -> Bool {
        !identifierCollision && ["opStart", "authBegin", "authRetryProvisioning"].contains(operation)
    }
}

enum V3RefreshAdmissionCancellationAckPolicy {
    static func accepts(_ data: Data, cancellationID: String) -> Bool {
        guard !data.isEmpty, data.count <= V3WireContract.responseLimit,
              let reply = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              V3WireContract.strictInt(reply["version"]) == 1,
              reply["id"] as? String == cancellationID,
              V3WireContract.strictBool(reply["ok"]) == true,
              V3WireContract.strictBool(reply["refreshAdmissionReleased"]) == true else { return false }
        return true
    }
}

struct V3MutationReplyCacheBudget {
    static let maximumStoredBytes = 64 * 1024 * 1024
    static let maximumStoredReplies = 512
    static let reservedControlBytes = V3WireContract.responseLimit * 2
    // Prompt acknowledgements are not stored in the completed-request cache;
    // the session's accepted-prompt ledger makes them idempotent. Keep a small
    // reserve for starts and refresh admission release replies.
    static let authenticationLifecycleReplyBudget = 2
    static let provisioningRetryReplyBudget = 1
    // The operation start and its possible external SideBackup callback must
    // both fit. Ordinary operation polls and prompt answers do not consume it.
    static let operationPromptReplyBudget = 2
    static let reservedControlReplies = 8
    private(set) var storedBytes = 0

    static func isControlReply(operation: String) -> Bool {
        ["refreshAdmissionEnd", "refreshAdmissionReconcile", "opRecoveryReconcile", "directRecoveryReconcile", "recoveryDiscardUnreadable",
         "authBegin", "authRetryProvisioning", "opStart", "backupResult"]
            .contains(operation) || V3RequestReplayPolicy.requiresCompletedReply(operation: operation)
    }

    static func shouldCacheResponse(operation: String) -> Bool {
        !["authRespond", "opAnswer", "certExportActive"].contains(operation)
    }

    static func minimumAvailableRepliesToAdmit(operation: String) -> Int {
        switch operation {
        case "authBegin": return authenticationLifecycleReplyBudget
        case "authRetryProvisioning": return provisioningRetryReplyBudget
        case "opStart": return operationPromptReplyBudget
        default: return 1
        }
    }

    static func minimumReplyBytesToAdmit(operation: String) -> Int {
        ["authBegin", "opStart"].contains(operation)
            ? V3WireContract.responseLimit * 2
            : V3WireContract.responseLimit
    }

    static func canAdmit(operation: String, completedReplyCount: Int) -> Bool {
        let required = minimumAvailableRepliesToAdmit(operation: operation)
        return completedReplyCount >= 0 && completedReplyCount <= maximumStoredReplies - required
    }

    func canReserve(maximumResponseBytes: Int = V3WireContract.responseLimit,
                    preservingControlCapacity: Bool = true) -> Bool {
        let limit = Self.maximumStoredBytes - (preservingControlCapacity ? Self.reservedControlBytes : 0)
        return maximumResponseBytes >= 0 && maximumResponseBytes <= limit &&
            storedBytes <= limit - maximumResponseBytes
    }

    mutating func record(_ byteCount: Int, controlResponse: Bool = false) -> Bool {
        guard byteCount >= 0,
              canReserve(maximumResponseBytes: byteCount, preservingControlCapacity: !controlResponse) else { return false }
        storedBytes += byteCount
        return true
    }

    static func responseCountLimit(isControlResponse: Bool) -> Int {
        isControlResponse ? maximumStoredReplies : maximumStoredReplies - reservedControlReplies
    }

    mutating func remove(_ byteCount: Int) {
        storedBytes = max(0, storedBytes - max(0, byteCount))
    }
}

enum V3ServiceReadinessReply: Equatable {
    case invalid
    case notReady
    case failed(V3ServiceReadinessFailure)
    case ready

    // This source fragment is compiled independently in both processes, so
    // its allowlist intentionally has no dependency on the typed failure model. The
    // executable vocabulary-parity harness verifies every typed cause and
    // source step is accepted here while unknown values remain rejected.
    static let knownSafeCauseValues: Set<String> = [
        "networkConnectionLost", "networkTimedOut", "networkUnavailable",
        "anisetteServerUnavailable", "anisetteServerRejected", "anisetteRequestTimedOut",
        "anisetteRateLimited", "anisetteInvalidResponse", "anisetteUnknownFailure",
        "signingNetworkConnectionLost", "signingNetworkTimedOut", "signingNetworkUnavailable",
        "developerPortalRejectedRequest", "developerPortalInvalidResponse", "appIDLimitReached",
        "provisioningProfileUnavailable", "certificateUnavailable", "signingStorageUnverified", "wifiUnavailable",
        "localDevVPNUnavailable", "unknownSigningCause", "sourceNetworkFailure",
        "sourceInvalidManifest", "sourcePersistenceUnverified", "sourceInvalidURL",
        "sourceBlocked", "sourceChangedID", "sourceDuplicate", "sourceUnsupported",
        "sourceValidationFailed", "sourceRemoveFailed", "sourceRemoveBusy", "sourceAddBusy",
        "operationInProgress", "responseCapacityUnavailable", "staleRefreshAttempt",
        "knownSourcePolicyNetworkFailure", "knownSourcePolicyInvalidResponse",
        "catalogUnavailable", "catalogSourceUnavailable", "responseEncodingFailed",
        "responseTooLarge", "pairingRequired", "invalidPairingFile",
        "pairingFilePreparationFailed", "authAttemptNotDispatched",
        "authProvisioningRetryNotDispatched", "authSessionUnavailable",
        "authResponseCapacityUnavailable", "operationPersistenceFailed", "keychainSignOutFailed",
        "credentialCommitFailed", "credentialCommitOutcomeUnknown", "accountActivationFailed", "provisioningStorageFailed",
        "keychainSignOutOutcomeUnknown", "recoveryMalformedRecord",
        "recoveryIncompatibleRecord", "recoveryStorageUnavailable",
"recoveryLockUnavailable", "recoveryReadFailure", "recoveryDeleteFailure",
        "sharedStoreUnavailable", "secretHandoffUnavailable"
    ]
    static let knownSourceStepValues: Set<String> = [
        "authenticate", "anisetteFetch", "appleAuthentication", "accountLookup", "credentialCommit", "fetchTeams", "saveAccount", "fetchCertificate",
        "activateCertificate", "registerDevice", "activateAccount", "provisioningUnknown",
        "provisioningProfileFetch", "certificateValidation", "localCodeSigning",
        "appIDLookup", "appIDRegistration", "appIDCapabilitiesUpdate",
        "appGroupLookup", "appGroupRegistration", "appGroupAssignment",
        "provisioningProfileRetrieval", "provisioningProfileCreation", "provisioningProfileUpdate",
        "sourceDownload", "manifestParsing", "sourceValidation", "knownSourcePolicyFetch",
        "knownSourcePolicyParsing", "catalogRead"
    ]

    static func decode(_ data: Data, requestID: String) -> V3ServiceReadinessReply {
        guard !data.isEmpty, data.count <= V3WireContract.responseLimit,
              let reply = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              V3WireContract.strictInt(reply["version"]) == 1,
              reply["id"] as? String == requestID else { return .invalid }
        // A structured failure is authoritative even when a malformed peer
        // omits the legacy error token. Fail closed on success-shaped replies
        // that also carry an invalid structured failure envelope.
        if reply["error"] != nil || reply["failure"] != nil {
            guard let envelope = reply["failure"] as? [String: Any],
                  Set(envelope.keys).isSubset(of: Set(["version", "operation", "stage", "code", "correlationID",
                      "underlyingDomain", "underlyingCode", "retryable", "safeCause", "sourceStep", "signingContext"])),
                  V3WireContract.strictInt(envelope["version"]) == 1,
                  envelope["correlationID"] as? String == requestID,
                  let operation = envelope["operation"] as? String,
                  let stage = envelope["stage"] as? String,
                  let code = envelope["code"] as? String,
                  let domain = envelope["underlyingDomain"] as? String,
                  let underlyingCode = V3WireContract.strictInt(envelope["underlyingCode"]) else { return .invalid }
            guard !operation.isEmpty, operation.utf8.count <= 64,
                  !stage.isEmpty, stage.utf8.count <= 64,
                  !code.isEmpty, code.utf8.count <= 64,
                  domain.utf8.count <= 128 else { return .invalid }
            let retryable: Bool?
            if let raw = envelope["retryable"] {
                guard let value = V3WireContract.strictBool(raw) else { return .invalid }
                retryable = value
            } else { retryable = nil }
            let safeCause: String?
            if let raw = envelope["safeCause"] {
                guard let value = raw as? String, Self.knownSafeCauseValues.contains(value) else { return .invalid }
                safeCause = value
            } else { safeCause = nil }
            let sourceStep: String?
            if let raw = envelope["sourceStep"] {
                guard let value = raw as? String, Self.knownSourceStepValues.contains(value) else { return .invalid }
                sourceStep = value
            } else { sourceStep = nil }
            var failure = V3ServiceReadinessFailure(operation: operation, stage: stage, code: code,
                correlationID: requestID, underlyingDomain: domain, underlyingCode: underlyingCode,
                safeCause: safeCause, sourceStep: sourceStep,
                retryable: retryable)
            if let raw = envelope["signingContext"] {
                guard let fields = raw as? [String: String], fields.count <= 20,
                      fields.allSatisfy({ $0.key.utf8.count <= 64 &&
                          $0.value.utf8.count <= ($0.key == "debug_temporary_anisette_trace" ? 2048 : 512) }) else { return .invalid }
                // The typed failure boundary validates the fixed keys
                // and values before any diagnostic publication.
                failure.signingContext = fields
            }
            if ["snapshot", "status"].contains(failure.operation) && failure.stage == "serviceReadiness" &&
               failure.code == "notReady" && failure.retryable == true {
                return .notReady
            }
            return .failed(failure)
        }
        guard V3WireContract.strictBool(reply["ok"]) == true,
              let result = reply["result"] as? [String: Any],
              let ready = V3WireContract.strictBool(result["ready"]) else { return .invalid }
        return ready ? .ready : .notReady
    }
}

struct V3ServiceReadinessFailure: Equatable {
    let operation: String
    let stage: String
    let code: String
    let correlationID: String
    let underlyingDomain: String
    let underlyingCode: Int
    let safeCause: String?
    let sourceStep: String?
    let retryable: Bool?
    var signingContext: [String: String] = [:]
}
import Foundation

enum V3SetupSnapshotOutcome: String, Equatable {
    case applied
    case snapshotFailed
    case notObserved
}

enum V3SetupReloadRecomputePolicy {
    static func mayRecompute(outcome: V3SetupSnapshotOutcome) -> Bool {
        outcome == .applied
    }
}

struct V3HostDirectRecoveryRecord: Equatable {
    enum Phase: String { case prepared, dispatched, terminal, unknown }

    let requestID: String
    let operation: String
    let phase: Phase
    let resultState: String?
    let postcondition: V3DirectRecoveryPostcondition?

    init?(_ rawValue: Any?) {
        guard let raw = rawValue as? [String: Any],
              Set(raw.keys).isSubset(of: ["requestID", "operation", "phase", "resultState", "postcondition"]),
              let requestID = raw["requestID"] as? String,
              UUID(uuidString: requestID)?.uuidString == requestID,
              let operation = raw["operation"] as? String,
              Self.operations.contains(operation),
              let phase = (raw["phase"] as? String).flatMap(Phase.init(rawValue:)),
              !raw.keys.contains("resultState") || raw["resultState"] is String else { return nil }
        let resultState = raw["resultState"] as? String
        guard resultState.map({ ["completed", "createdAndStored",
              "remoteCreatedLocalStorageUnverified"].contains($0) }) ?? true,
              (phase == .terminal) == (resultState != nil) else { return nil }
        let postcondition: V3DirectRecoveryPostcondition?
        if raw.keys.contains("postcondition") {
            guard let rawPostcondition = raw["postcondition"] as? String,
                  let parsed = V3DirectRecoveryPostcondition(rawValue: rawPostcondition) else { return nil }
            postcondition = parsed
        } else {
            postcondition = nil
        }
        self.requestID = requestID
        self.operation = operation
        self.phase = phase
        self.resultState = resultState
        self.postcondition = postcondition
    }

    init?(snapshotValue: Any?) {
        guard let raw = snapshotValue as? [String: Any], !raw.keys.contains("postcondition"),
              let parsed = V3HostDirectRecoveryRecord(raw) else { return nil }
        self = parsed
    }

    init?(inspectionReply: [String: Any]) {
        guard let parsed = V3HostDirectRecoveryRecord(inspectionReply),
              parsed.postcondition != nil else { return nil }
        self = parsed
    }

    static let operations: Set<String> = [
        "certCreate", "certRevoke", "sourceAddConfirmed", "sourceRemoveConfirmed",
        "pairingImportData", "settingsSet", "accountImport"
    ]
}

enum V3DirectRecoveryPostcondition: String {
    case achieved, notAchieved, indeterminate, manualCheckRequired, notDispatched
}

enum V3DirectRecoveryHostPolicy {
    static func mayOfferUserConfirmation(_ record: V3HostDirectRecoveryRecord,
                                        postcondition: V3DirectRecoveryPostcondition?) -> Bool {
        record.phase != .dispatched && postcondition != nil
    }

    static func mayAcknowledgeSuccessfulResponse(operation: String,
                                                  result: [String: Any]) -> Bool {
        guard V3HostDirectRecoveryRecord.operations.contains(operation) else { return false }
        if operation == "certCreate" {
            return result["outcome"] as? String == "createdAndStored"
        }
        if operation == "accountImport" { return false }
        return true
    }

    static func mayAcknowledgeInspectedTerminal(_ record: V3HostDirectRecoveryRecord,
                                                 postcondition: V3DirectRecoveryPostcondition) -> Bool {
        guard record.phase == .terminal, postcondition == .achieved else { return false }
        if record.operation == "certCreate",
           record.resultState == "remoteCreatedLocalStorageUnverified" { return false }
        return true
    }
}

enum V3DirectRecoveryPresentationPolicy {
    static func operationName(_ operation: String) -> String {
        switch operation {
        case "certCreate": return "certificate creation"
        case "certRevoke": return "certificate revocation"
        case "sourceAddConfirmed": return "source add"
        case "sourceRemoveConfirmed": return "source removal"
        case "pairingImportData": return "pairing import"
        case "settingsSet": return "setting change"
        case "accountImport": return "account import"
        default: return "SideStore request"
        }
    }

    static func explanation(record: V3HostDirectRecoveryRecord,
                            postcondition: V3DirectRecoveryPostcondition?) -> String {
        if record.operation == "certCreate",
           record.resultState == "remoteCreatedLocalStorageUnverified" {
            return "The remote certificate may exist, but local storage was not verified. Check before trying again."
        }
        switch postcondition {
        case .achieved:
            return "The service verified the requested result. The matching terminal record can be acknowledged."
        case .notAchieved:
            return "The service did not observe the requested result. Check the account or device before clearing this hold."
        case .indeterminate:
            return "The service could not verify the result. Check the account or device before clearing this hold."
        case .manualCheckRequired:
            return "The result needs a manual account or device check before the recovery hold can be cleared."
        case .notDispatched:
            return "The service confirms this request was not dispatched. Clear the reservation only after reviewing it."
        case nil:
            return record.phase == .prepared
                ? "SideStore prepared the request but did not confirm dispatch. Inspect the result before retrying."
                : "The original reply is unavailable. Inspect the exact request before retrying."
        }
    }
}

enum V3AuthReadStampPolicy {
    static func ownsTicket(captured: UInt64, current: UInt64) -> Bool {
        captured == current
    }

    static func mayReturn(capturedStamp: String, currentStamp: String, stable: Bool) -> Bool {
        stable && capturedStamp == currentStamp
    }

    static func mayCommit(capturedTicket: UInt64, currentTicket: UInt64,
                          capturedStamp: String, currentStamp: String?, stable: Bool,
                          resultStamps: [String?], authenticationActive: Bool = false) -> Bool {
        stable && !authenticationActive && capturedTicket == currentTicket &&
            currentStamp == capturedStamp && !resultStamps.isEmpty &&
            resultStamps.allSatisfy { $0 == capturedStamp }
    }
}

enum V3AuthSessionCoalescerKey {
    static func value(for identityStamp: String) -> String {
        "apple_auth_session:" + identityStamp
    }
}

struct V3AsyncRequestOwner: Equatable, Sendable {
    let generation: UInt64
    let bindingID: String?
}

struct V3AsyncRequestOwnerState: Sendable {
    private(set) var generation: UInt64 = 0

    mutating func begin(bindingID: String? = nil) -> V3AsyncRequestOwner {
        generation &+= 1
        return V3AsyncRequestOwner(generation: generation, bindingID: bindingID)
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func owns(_ owner: V3AsyncRequestOwner, bindingID: String? = nil) -> Bool {
        owner.generation == generation && owner.bindingID == bindingID
    }
}

struct V3StatusWriteTicket: Equatable, Sendable {
    let revision: UInt64
    let serviceEpoch: UInt64
    let ownerID: String
    let serviceInstanceID: String
    let kind: V3StatusAuthorityLeaseKind
}

enum V3StatusAuthorityLeaseKind: String, Equatable, Sendable {
    case snapshot
    case mutation
}

struct V3StatusLeaseWaiterOrder: Sendable {
    private var ids: [String] = []

    mutating func enqueue(_ id: String) {
        ids.append(id)
    }

    mutating func remove(_ id: String) {
        ids.removeAll { $0 == id }
    }

    mutating func takeNext() -> String? {
        ids.isEmpty ? nil : ids.removeFirst()
    }

    var count: Int { ids.count }
}

enum V3StatusWriteOutcome: Equatable, Sendable {
    case committed
    case failed
    case notDispatched
    case outcomeUnknown
}

/// One bridge-owned revision and lease authority for status snapshots and writes.
/// Cancellation ACKs never complete a lease; only its original callback or
/// explicit service retirement does.
struct V3StatusWriteAuthority: Sendable {
    private(set) var revision: UInt64 = 0
    private(set) var serviceEpoch: UInt64 = 0
    private(set) var serviceInstanceID: String?
    private(set) var activeLease: V3StatusWriteTicket?
    // Unknown one-shot owners are deliberately not evicted or cleared by a
    // generic snapshot; operation-specific reconciliation must resolve them.
    private(set) var unresolvedOwnerIDs: Set<String> = []

    func canBegin(kind: V3StatusAuthorityLeaseKind,
                  allowUnresolvedMutation: Bool = false) -> Bool {
        activeLease == nil && (kind == .snapshot || allowUnresolvedMutation || !hasUnresolvedMutation)
    }

    /// A mutation reserves a revision before it can suspend for a lease or XPC.
    mutating func reserveMutationRevision() -> UInt64 {
        revision &+= 1
        return revision
    }

    mutating func begin(ownerID: String, revision reservedRevision: UInt64,
                        serviceInstanceID: String,
                        kind: V3StatusAuthorityLeaseKind,
                        allowUnresolvedMutation: Bool = false) -> V3StatusWriteTicket? {
        guard canBegin(kind: kind, allowUnresolvedMutation: allowUnresolvedMutation),
              reservedRevision <= revision else { return nil }
        let ticket = V3StatusWriteTicket(revision: reservedRevision,
            serviceEpoch: serviceEpoch, ownerID: ownerID,
            serviceInstanceID: serviceInstanceID, kind: kind)
        activeLease = ticket
        return ticket
    }

    @discardableResult
    mutating func complete(_ ticket: V3StatusWriteTicket,
                           outcome: V3StatusWriteOutcome) -> Bool {
        guard activeLease == ticket else { return false }
        activeLease = nil
        switch outcome {
        case .outcomeUnknown:
            if ticket.kind == .mutation { unresolvedOwnerIDs.insert(ticket.ownerID) }
        case .committed, .failed, .notDispatched:
            unresolvedOwnerIDs.remove(ticket.ownerID)
        }
        return true
    }

    /// Observing a replacement process advances the epoch. A matching long
    /// session control may transfer its lease to that process; unrelated work
    /// cannot take ownership from the original request.
    mutating func observeServiceInstance(_ instanceID: String,
                                         continuingOwnerID: String?) -> V3StatusWriteTicket? {
        if serviceInstanceID != instanceID {
            serviceEpoch &+= 1
            serviceInstanceID = instanceID
        }
        guard let activeLease, let continuingOwnerID,
              activeLease.ownerID == continuingOwnerID else {
            return nil
        }
        guard activeLease.serviceEpoch != serviceEpoch ||
              activeLease.serviceInstanceID != instanceID else { return activeLease }
        let rebound = V3StatusWriteTicket(revision: activeLease.revision,
            serviceEpoch: serviceEpoch, ownerID: activeLease.ownerID,
            serviceInstanceID: instanceID, kind: activeLease.kind)
        self.activeLease = rebound
        return rebound
    }

    /// Explicit process retirement is the only no-callback release path.
    mutating func retireService() -> V3StatusWriteTicket? {
        serviceEpoch &+= 1
        serviceInstanceID = nil
        guard let retired = activeLease else { return nil }
        activeLease = nil
        if retired.kind == .mutation && !retired.ownerID.hasPrefix("recovery-control:") {
            unresolvedOwnerIDs.insert(retired.ownerID)
        }
        return retired
    }

    func mayApply(_ ticket: V3StatusWriteTicket,
                  currentServiceEpoch: UInt64,
                  currentServiceInstanceID: String) -> Bool {
        activeLease == nil && ticket.revision == revision &&
            ticket.serviceEpoch == currentServiceEpoch &&
            ticket.serviceInstanceID == currentServiceInstanceID &&
            !unresolvedOwnerIDs.contains(ticket.ownerID)
    }

    @discardableResult
    mutating func resolveOwnerAfterReconciliation(_ ownerID: String) -> Bool {
        guard unresolvedOwnerIDs.remove(ownerID) != nil else { return false }
        revision &+= 1
        return true
    }

    /// Exact authoritative session evidence can also settle a matching active
    /// lease. This is separate from generic unknown-owner reconciliation so a
    /// caller cannot clear an unrelated active mutation.
    @discardableResult
    mutating func resolveOwnerAfterAuthoritativeReconciliation(_ ownerID: String) -> Bool {
        if activeLease?.ownerID == ownerID {
            activeLease = nil
            unresolvedOwnerIDs.remove(ownerID)
            revision &+= 1
            return true
        }
        return resolveOwnerAfterReconciliation(ownerID)
    }

    var hasActiveWrite: Bool { activeLease?.kind == .mutation }
    var hasActiveLease: Bool { activeLease != nil }
    var hasUnresolvedMutation: Bool { !unresolvedOwnerIDs.isEmpty }
}

enum V3StatusReplyCommitPolicy {
    static func mayApply(_ ticket: V3StatusWriteTicket,
                         authority: V3StatusWriteAuthority,
                         currentServiceEpoch: UInt64,
                         currentServiceInstanceID: String,
                         busySnapshot: Bool = false) -> Bool {
        if ticket.kind == .snapshot && busySnapshot { return false }
        return authority.mayApply(ticket, currentServiceEpoch: currentServiceEpoch,
            currentServiceInstanceID: currentServiceInstanceID)
    }
}

enum V3RecoveryOnlySnapshotPolicy {
    static func mayApplyFullStatus(busy: Bool, activeMutation: Bool,
                                   recoveryHold: Bool, hasTypedRecoveryEvidence: Bool) -> Bool {
        busy && !activeMutation && recoveryHold && hasTypedRecoveryEvidence
    }
}

enum V3RecoveryStoragePresentationPolicy {
    static func mayOfferClear(connected: Bool, unresolved: Bool, kind: String?,
                              serverClearEligible: Bool) -> Bool {
        connected && unresolved && serverClearEligible &&
            ["malformedRecord", "incompatibleRecord"].contains(kind ?? "")
    }

    static func confirmsCleared(snapshotApplied: Bool, unreadable: Bool,
                                operationRecovery: Bool, directRecovery: Bool,
                                refreshRecovery: Bool) -> Bool {
        snapshotApplied && !unreadable && !operationRecovery && !directRecovery && !refreshRecovery
    }
}

enum V3RecoveryClearHostAdmissionPolicy {
    static func permits(operation: String, target: String, userConfirmed: Bool,
                        recoveryHold: Bool, otherMutationActive: Bool) -> Bool {
        operation == "recoveryDiscardUnreadable" && target.isEmpty && userConfirmed &&
            recoveryHold && !otherMutationActive
    }
}

enum V3StatusRecoveryEvidencePolicy {
    static func mayApply(busySnapshot: Bool, activeMutation: Bool?,
                         hasDurableRecoveryEvidence: Bool) -> Bool {
        busySnapshot && activeMutation != true && hasDurableRecoveryEvidence
    }

    static func hasRecoveryEvidence(_ reply: [String: Any]) -> Bool {
        let recoveryHold = V3OperationReplyFieldPolicy.strictBoolean(reply["recoveryHold"]) == true
        let operation = reply["operationRecovery"] as? [String: Any]
        let operationEvidence = operation?["session"] as? String
        let refresh = reply["refreshRecovery"] as? [String: Any]
        let refreshRunID = refresh?["runID"] as? String
        let refreshEvidence = refreshRunID.map { UUID(uuidString: $0)?.uuidString == $0 } == true &&
            V3OperationReplyFieldPolicy.strictBoolean(refresh?["ownerLost"]) == true
        let unreadable = V3OperationReplyFieldPolicy.strictBoolean(reply["recoveryJournalUnreadable"]) == true
        let direct = V3HostDirectRecoveryRecord(snapshotValue: reply["directRecovery"])
        let directEvidence = direct != nil && recoveryHold
        let hasRecoveryField = reply.keys.contains("operationRecovery") ||
            reply.keys.contains("refreshRecovery") || reply.keys.contains("directRecovery")
        return recoveryHold || hasRecoveryField || directEvidence || unreadable || refreshEvidence ||
            (operationEvidence.map { UUID(uuidString: $0) != nil } == true &&
             (operation?["kind"] as? String)?.isEmpty == false &&
             V3OperationRecoveryRecord.Phase(rawValue: operation?["phase"] as? String ?? "") != nil)
    }
}

// Direct Apple certificate mutations must not outrun an interrupted local
// credential, certificate or account activation commit. Local readback repair
// is deliberately outside this policy and still uses the normal mutation gate.
enum V3CertificateStorageAdmission {
    static func failure(operation: String, id: String,
                        databaseRequiresReconciliation: Bool,
                        keychainRequiresReconciliation: () throws -> Bool) -> CombinedFailure? {
        guard ["certCreate", "certRevoke"].contains(operation) else { return nil }
        let unresolved = databaseRequiresReconciliation ||
            ((try? keychainRequiresReconciliation()) ?? true)
        guard unresolved else { return nil }
        return CombinedFailure(operation: operation, stage: .persistence, code: .notReady,
            id: id, retryable: false, safeCause: .signingStorageUnverified)
    }
}

enum V3StatusAuthorityOperationPolicy {
    static func directWriteOwnerID(operation: String, requestID: String) -> String? {
        // `backupResult` is control for its existing operation owner; `ipaCleanup`
        // only retires staged files. Neither creates a new status writer. Recovery journal edits
        // do change fields in the next authoritative snapshot and are fenced.
        let writes: Set<String> = [
            "signOut", "accountImport", "syncAppIDs", "clearCache", "refreshSources", "jit",
            "certSetActive", "certDelete", "certRevoke", "certCreate",
            "sourceAddConfirmed", "sourceRemoveConfirmed", "pairingImportData", "settingsSet",
            "sidesignSet", "sidesignReset", "sidesignImport", "anisetteReset", "anisetteSync",
            "opRecoveryPrepare", "recoveryDiscardUnreadable", "authReconcileStorage"
        ]
        return writes.contains(operation) ? "request:\(requestID)" : nil
    }

    static func longOwnerID(operation: String, sessionID: String?) -> String? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        switch operation {
        case "authBegin", "authRetryProvisioning": return "auth:\(sessionID)"
        case "opStart": return "operation:\(sessionID)"
        case "refreshAdmissionBegin": return "refresh:\(sessionID)"
        default: return nil
        }
    }

    static func controlOwnerID(operation: String, sessionID: String?) -> String? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        switch operation {
        case "authPoll", "authRespond", "authCancel": return "auth:\(sessionID)"
        case "opPoll", "opAnswer", "opCancel", "opRecoveryReconcile", "backupResult": return "operation:\(sessionID)"
        case "refreshAdmissionEnd", "refreshAdmissionReconcile": return "refresh:\(sessionID)"
        default: return nil
        }
    }

    static func terminalOutcome(operation: String, result: [String: Any]) -> V3StatusWriteOutcome? {
        let payload = result["result"] as? [String: Any] ?? result
        switch operation {
        case "authBegin", "authRetryProvisioning", "authPoll", "authRespond", "authCancel":
            guard let state = payload["state"] as? String,
                  ["completed", "failed", "cancelled", "timedOut", "promptExpired", "resultUnknown"].contains(state) else {
                return nil
            }
            return state == "resultUnknown" ? .outcomeUnknown : .committed
        case "opStart", "opPoll", "opAnswer", "opCancel":
            guard let state = payload["state"] as? String,
                  ["completed", "failed", "cancelled", "requiresSource", "waitingForAuthentication"].contains(state) else {
                return nil
            }
            let settled = V3OperationReplyFieldPolicy.strictBoolean(payload["backendSettled"]) == true ||
                V3OperationReplyFieldPolicy.strictBoolean(payload["stopConfirmed"]) == true
            return settled ? .committed : .outcomeUnknown
        case "refreshAdmissionBegin", "refreshAdmissionEnd", "refreshAdmissionReconcile":
            if operation != "refreshAdmissionBegin" &&
               (V3OperationReplyFieldPolicy.strictBoolean(payload["released"]) == true ||
                V3OperationReplyFieldPolicy.strictBoolean(payload["reconciled"]) == true) { return .committed }
            return nil
        case "opRecoveryReconcile":
            return V3OperationReplyFieldPolicy.strictBoolean(payload["reconciled"]) == true
                ? .committed : nil
        case "directRecoveryReconcile":
            return V3OperationReplyFieldPolicy.strictBoolean(payload["reconciled"]) == true
                ? .committed : nil
        default:
            return .committed
        }
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

// V3_CRASH_REASON_LOG_PRIVACY_V1: exception reasons and call stacks may contain
// credentials, URLs, user data, or local paths. Callers may only log this marker.
enum V3CrashLogPrivacy {
    static func safeCrashMarker(reason: String?) -> String {
        _ = reason
        return "[AppDelegate] UNCAUGHT_NSEXCEPTION_CRASH details=omitted"
    }
}

// Operation phases are fed by PipelineExecutor's actual PipelineStep callback.
// Unknown steps intentionally collapse to Working... rather than inferring a
// stage from progress percentages.
enum V3OperationPhase: String, Equatable, CaseIterable {
    case working
    case preparing
    case preparingIPA
    case downloadingIPA
    case verifying
    case preparingSigning
    case fetchingProvisioningProfile
    case signing
    case preparingInstallation
    case transferringToDevice
    case installing
    case refreshing
    case deleting
    case backingUp
    case restoring
    case updating
    case cleaningUp

    var label: String {
        switch self {
        case .working: return "Working..."
        case .preparing: return "Preparing..."
        case .preparingIPA: return "Preparing IPA..."
        case .downloadingIPA: return "Downloading IPA..."
        case .verifying: return "Verifying..."
        case .preparingSigning: return "Preparing signing..."
        case .fetchingProvisioningProfile: return "Fetching provisioning profile..."
        case .signing: return "Signing..."
        case .preparingInstallation: return "Preparing installation..."
        case .transferringToDevice: return "Transferring to device..."
        case .installing: return "Installing..."
        case .refreshing: return "Refreshing..."
        case .deleting: return "Removing app..."
        case .backingUp: return "Backing up..."
        case .restoring: return "Restoring..."
        case .updating: return "Updating app..."
        case .cleaningUp: return "Cleaning up..."
        }
    }

    static func forPipelineStep(_ step: String, downloadUsesNetwork: Bool = false) -> Self? {
        switch step {
        case "userCustomization", "preflightChecks", "cacheApp": return .preparing
        case "downloadApp": return downloadUsesNetwork ? .downloadingIPA : .preparingIPA
        case "verifyApp", "verifyCertificate": return .verifying
        case "updateAppCertificate": return .preparingSigning
        case "fetchProvisioningProfiles": return .fetchingProvisioningProfile
        case "embedSigningCert", "resignApp", "cacheSigningCert": return .signing
        case "stageApp", "stageBackupApp", "changeAppIcon", "removeAppExtensions",
             "prepareAppExtensionBundleIDs", "createIPA", "exportResignedIPA":
            return .preparingInstallation
        case "sendApp": return .transferringToDevice
        case "installApp": return .installing
        case "refreshApp": return .refreshing
        case "uninstallApp", "removeApp": return .deleting
        case "backupAppData": return .backingUp
        case "restoreAppData": return .restoring
        case "deactivateApp", "markAppInactive": return .updating
        case "removeBackupData", "cleanStagedApp": return .cleaningUp
        default: return nil
        }
    }
}

struct V3OperationPhaseTracker: Equatable {
    private(set) var phase: V3OperationPhase = .working

    mutating func recordPipelineStep(_ step: String, downloadUsesNetwork: Bool = false) {
        phase = V3OperationPhase.forPipelineStep(step, downloadUsesNetwork: downloadUsesNetwork) ?? .working
    }

    mutating func record(_ phase: V3OperationPhase) {
        self.phase = phase
    }
}

enum V3NormalizedProgress {
    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    static func displayValue(_ value: Double, state: String) -> Double {
        state == "completed" ? 1 : clamp(value)
    }

    static func percent(_ value: Double, state: String) -> Int {
        Int((displayValue(value, state: state) * 100).rounded())
    }
}

enum V3SourceAddDecision: Equatable { case save, alreadyAdded }

enum V3SourceAddPersistencePolicy {
    static func decision(sourceIsPersisted: Bool) -> V3SourceAddDecision {
        sourceIsPersisted ? .alreadyAdded : .save
    }

    static func verifiedResult(identifier: String, alreadyAdded: Bool,
                                authoritativeCount: Int) -> [String: Any]? {
        guard !identifier.isEmpty, authoritativeCount == 1 else { return nil }
        return ["identifier": identifier,
                "added": !alreadyAdded,
                "alreadyAdded": alreadyAdded,
                "persistenceVerified": true]
    }

    static func confirmationMessage(_ result: [String: Any]) -> String? {
        guard result["persistenceVerified"] as? Bool == true,
              let identifier = result["identifier"] as? String, !identifier.isEmpty,
              let added = result["added"] as? Bool,
              let alreadyAdded = result["alreadyAdded"] as? Bool else { return nil }
        if added && !alreadyAdded { return "Source added." }
        if !added && alreadyAdded { return "Source already added." }
        return nil
    }

    static func validatedURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func unverifiedPersistenceFailure(correlationID: String) -> CombinedFailure {
        CombinedFailure(operation: "source", stage: .source, code: .invalidResponse,
            id: correlationID, retryable: false,
            safeCause: .sourcePersistenceUnverified, sourceStep: .catalogRead)
    }
}

// Source identifiers are normalized database keys, not fetchable URLs. Never
// reconstruct a URL from one: normalization removes scheme/query and lowercases
// case-sensitive paths. Missing URLs from older backends require manual recovery.
enum V3SourceRecoveryPolicy {
    static func isSettledStartReply(_ reply: [String: Any], sessionID: String) -> Bool {
        reply["session"] as? String == sessionID &&
            reply["state"] as? String == "requiresSource" &&
            V3OperationReplyFieldPolicy.strictBoolean(reply["failedToStart"]) == true &&
            V3OperationReplyFieldPolicy.strictBoolean(reply["backendSettled"]) == true &&
            !V3OperationReplyFieldPolicy.outcomeUnknown(reply["outcomeUnknown"])
    }

    static func target(sourceID: String, sourceURL: String?) -> String? {
        guard !sourceID.isEmpty, let sourceURL,
              V3SourceAddPersistencePolicy.validatedURL(sourceURL) != nil else { return nil }
        return sourceURL
    }

    static func matchesPreview(_ preview: [String: Any], sourceID: String) -> Bool {
        !sourceID.isEmpty && preview["identifier"] as? String == sourceID
    }

    static func verifiedAddition(_ result: [String: Any], sourceID: String) -> Bool {
        guard matchesPreview(result, sourceID: sourceID),
              V3SourceAddPersistencePolicy.confirmationMessage(result) != nil,
              let sources = result["sources"] as? [[String: Any]] else { return false }
        return sources.contains { $0["identifier"] as? String == sourceID }
    }
}

enum V3SourceAddFailurePolicy {
    static func normalized(_ failure: CombinedFailure) -> CombinedFailure {
        guard failure.operation == "source", failure.stage == .command,
              failure.safeCause == nil else { return failure }
        let stage: CombinedFailure.Stage = [.notReady, .unavailable].contains(failure.code)
            ? .serviceReadiness : .source
        let cause: CombinedFailure.SafeCause? = failure.code == .busy ? .sourceAddBusy : nil
        let underlying: NSError? = failure.underlyingDomain == "none" && failure.underlyingCode == 0
            ? nil : NSError(domain: failure.underlyingDomain, code: failure.underlyingCode)
        return CombinedFailure(operation: "source", stage: stage, code: failure.code,
            id: failure.correlationID, underlying: underlying,
            retryable: failure.retryable, safeCause: cause)
    }
}

enum V3SourceSubmissionPolicy {
    static func mayResubmit(retryable: Bool?, safeCause: String?,
                            failedInput: String?, currentInput: String) -> Bool {
        guard failedInput == currentInput else { return true }
        if retryable == false {
            return [CombinedFailure.SafeCause.sourceInvalidManifest.rawValue,
                    CombinedFailure.SafeCause.sourcePersistenceUnverified.rawValue].contains(safeCause ?? "")
        }
        return ![CombinedFailure.SafeCause.responseEncodingFailed.rawValue,
                 CombinedFailure.SafeCause.responseTooLarge.rawValue].contains(safeCause ?? "")
    }
}

enum V3JITLessReadiness: String, Equatable {
    case notRequired
    case setupRequired
    case certificateImported
    case needsCertificateRefresh
    case revoked
    case activeCertificateRevoked
    case activeCertificateExpired
    // V3_JITLESS_CERT_DISTINCTION_V1: SideStore's active certificate being
    // absent is a different problem from the LiveContainer copy being stale, and
    // neither means the other's certificate is broken.
    case activeCertificateMissing
    case certificateMismatch
    case ready
    case unknown

    var isReady: Bool { self == .ready || self == .notRequired }

    /// True only for a genuinely finished JIT-Less state. Used so a completed
    /// JIT-Less setup is never rendered as an outstanding setup task.
    var isSatisfied: Bool { isReady }
}

// This policy describes only the LiveContainer copy and safe public identity
// facts. Import/repair remains LiveContainer's canonical settings flow.
enum V3JITLessReadinessPolicy {
    static func evaluate(osMajor: Int, hasCopy: Bool, activeCertificateExists: Bool,
                         activeCertificateStatus: String = "unknown", identitiesMatch: Bool?,
                         validationStatus: Int?, validationFailed: Bool) -> V3JITLessReadiness {
        guard osMajor >= 26 else { return .notRequired }
        if activeCertificateExists && activeCertificateStatus == "revoked" { return .activeCertificateRevoked }
        if activeCertificateExists && activeCertificateStatus == "expired" { return .activeCertificateExpired }
        // Distinct from "the copy is missing": the active SideStore certificate
        // itself is absent, which is a SideStore-side prerequisite.
        guard activeCertificateExists else { return .activeCertificateMissing }
        guard hasCopy else { return .setupRequired }
        guard let validationStatus else { return .certificateImported }
        if validationStatus == 1 {
            if activeCertificateExists, identitiesMatch == true { return .activeCertificateRevoked }
            return .revoked
        }
        guard validationStatus == 0, !validationFailed else { return .unknown }
        guard let identitiesMatch else { return .unknown }
        // The copy is valid but SideStore has since moved to a different
        // certificate. Only the copy is stale; SideStore's certificate is fine.
        return identitiesMatch ? .ready : .certificateMismatch
    }
}

// V3_JITLESS_PRESENTATION_V1
// One place that decides how a JIT-Less state is presented, so the Setup
// Assistant, Health and Settings cannot each invent their own treatment. A ready
// state is a completed result, not an outstanding setup task.
struct V3JITLessPresentation: Equatable {
    let readiness: V3JITLessReadiness
    let severity: V3StatusSeverity
    let title: String
    let detail: String
    /// True when this state still requires the user to do something.
    let isOutstandingSetupTask: Bool

    var icon: String { severity.icon }

    static func present(_ readiness: V3JITLessReadiness) -> V3JITLessPresentation {
        switch readiness {
        case .notRequired:
            return V3JITLessPresentation(readiness: .notRequired, severity: .completed,
                                        title: "Not required",
                                        detail: "This iOS version does not require a JIT-Less certificate.",
                                        isOutstandingSetupTask: false)
        case .ready:
            return V3JITLessPresentation(readiness: .ready, severity: .completed,
                                        title: "Configured / Ready",
                                        detail: "The LiveContainer JIT-Less certificate matches the active SideStore certificate.",
                                        isOutstandingSetupTask: false)
        case .certificateMismatch:
            return V3JITLessPresentation(readiness: .certificateMismatch, severity: .warning,
                                        title: "JIT-Less certificate copy is out of date",
                                        detail: "SideStore is using a different or newer signing certificate than the JIT-Less certificate stored by LiveContainer. Refresh the JIT-Less certificate copy.",
                                        isOutstandingSetupTask: true)
        case .activeCertificateMissing:
            return V3JITLessPresentation(readiness: .activeCertificateMissing, severity: .failed,
                                        title: "No active SideStore certificate",
                                        detail: "SideStore has no active signing certificate. Open Certificates and create or select one before configuring JIT-Less.",
                                        isOutstandingSetupTask: true)
        case .activeCertificateRevoked:
            return V3JITLessPresentation(readiness: .activeCertificateRevoked, severity: .failed,
                                        title: "Active certificate revoked",
                                        detail: "SideStore's active signing certificate is reported as revoked. Open Certificates and select or create a current certificate.",
                                        isOutstandingSetupTask: true)
        case .activeCertificateExpired:
            return V3JITLessPresentation(readiness: .activeCertificateExpired, severity: .failed,
                                        title: "Active certificate expired",
                                        detail: "SideStore's active signing certificate has expired. Open Certificates and select or create a current certificate.",
                                        isOutstandingSetupTask: true)
        case .setupRequired:
            return V3JITLessPresentation(readiness: .setupRequired, severity: .warning,
                                        title: "JIT-Less certificate not configured",
                                        detail: "LiveContainer has no JIT-Less certificate copy yet. Import one to launch guest apps on this iOS version.",
                                        isOutstandingSetupTask: true)
        case .revoked:
            return V3JITLessPresentation(readiness: .revoked, severity: .failed,
                                        title: "JIT-Less certificate copy is revoked",
                                        detail: "The certificate stored by LiveContainer is reported as revoked. Import a current copy.",
                                        isOutstandingSetupTask: true)
        case .certificateImported:
            return V3JITLessPresentation(readiness: .certificateImported, severity: .warning,
                                        title: "Certificate imported, validation pending",
                                        detail: "The certificate is stored but could not be validated yet.",
                                        isOutstandingSetupTask: true)
        case .needsCertificateRefresh:
            return V3JITLessPresentation(readiness: .needsCertificateRefresh, severity: .warning,
                                        title: "JIT-Less certificate needs refreshing",
                                        detail: "Refresh the JIT-Less certificate copy from SideStore.",
                                        isOutstandingSetupTask: true)
        case .unknown:
            return V3JITLessPresentation(readiness: .unknown, severity: .unknown,
                                        title: "Validation unknown",
                                        detail: "The JIT-Less certificate state could not be verified.",
                                        isOutstandingSetupTask: true)
        }
    }
}

enum V3JITLessSetupAction: Equatable {
    case setUp
    case refreshCertificate
    case openCertificates
    case openSetup
    case none
}

enum V3JITLessSetupActionPolicy {
    static func action(for readiness: V3JITLessReadiness) -> V3JITLessSetupAction {
        switch readiness {
        case .setupRequired: return .setUp
        case .needsCertificateRefresh, .certificateMismatch, .revoked:
            return .refreshCertificate
        case .activeCertificateMissing, .activeCertificateRevoked, .activeCertificateExpired:
            return .openCertificates
        case .certificateImported, .unknown: return .openSetup
        case .ready, .notRequired: return .none
        }
    }
}

struct V3SignInJITLessGuidance: Equatable {
    let readiness: V3JITLessReadiness
    let presentation: V3JITLessPresentation
    let action: V3JITLessSetupAction
}

/// Composes the existing authoritative readiness, presentation, and action
/// policies for the post-sign-in page. It observes a fact; it never reads or
/// guesses certificate readiness itself.
enum V3SignInJITLessGuidancePolicy {
    static func resolve(osMajor: Int, readiness: V3JITLessReadiness?) -> V3SignInJITLessGuidance? {
        guard V3JITLessCompletionPolicy.isRequired(osMajor: osMajor) else { return nil }
        // A "not required" fact cannot be trusted on a supported iOS version.
        // Treat it as unverified instead of presenting setup as complete.
        let observed: V3JITLessReadiness
        if let readiness, readiness != .notRequired {
            observed = readiness
        } else {
            observed = .unknown
        }
        return V3SignInJITLessGuidance(readiness: observed,
            presentation: V3JITLessPresentation.present(observed),
            action: V3JITLessSetupActionPolicy.action(for: observed))
    }
}

enum V3JITLessHealthRecoveryPolicy {
    static func shouldOfferCanonicalSetup(for readiness: V3JITLessReadiness,
                                          activeCertificateAvailable: Bool) -> Bool {
        switch readiness {
        case .unknown: return true
        case .certificateImported: return activeCertificateAvailable
        default: return false
        }
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
struct V3InstallPresentationRequest: Equatable {
    let attemptID: UUID
    let operationID: UUID
    let token: String
    let title: String
}

// Local IPA, URL, and catalog installs all converge on the same AppOperation
// builder after resolution has produced an AppProtocol value.
enum V3InstallInputRoute: String, Equatable { case localIPA, remoteURL, catalog }

enum V3InstallPipelineParity {
    static func makeOperation<ResolvedApp, Operation>(
        route: V3InstallInputRoute,
        _ resolvedApp: ResolvedApp,
        build: (ResolvedApp) -> Operation
    ) -> (route: V3InstallInputRoute, operation: Operation) {
        (route, build(resolvedApp))
    }
}

// Coordinates a direct root-owned UIKit picker. If the anchor is not in the
// window hierarchy yet, the attempt remains queued until UIKit reports that
// the anchor appeared; it is never converted into a nested SwiftUI sheet.
final class V3InstallPickerPresentationCoordinator {
    enum Phase: String, Equatable { case idle, queued, presenting, presented, dismissing, awaitingDismissal }
    enum Decision: Equatable {
        case present(UUID)
        case queued
        case dismissed(UUID)
        case rejected(UUID, String)
        case none
    }

    private(set) var phase: Phase = .idle
    private(set) var attemptID: UUID?

    func request(attemptID: UUID, presenterReady: Bool,
                 presenterBusy: Bool) -> Decision {
        guard phase == .idle else { return .rejected(attemptID, "presenter_busy") }
        self.attemptID = attemptID
        guard presenterReady else {
            phase = .queued
            return .queued
        }
        guard !presenterBusy else {
            phase = .queued
            return .rejected(attemptID, "presentation_active")
        }
        phase = .presenting
        return .present(attemptID)
    }

    func presenterBecameReady(isBusy: Bool) -> Decision {
        switch phase {
        case .queued:
            guard let attemptID else { return .none }
            guard !isBusy else {
                return .rejected(attemptID, "presentation_active")
            }
            phase = .presenting
            return .present(attemptID)
        case .awaitingDismissal:
            guard !isBusy, let attemptID else { return .none }
            reset()
            return .dismissed(attemptID)
        default:
            return .none
        }
    }

    @discardableResult
    func didPresent(attemptID id: UUID) -> Bool {
        guard attemptID == id, phase == .presenting else { return false }
        phase = .presented
        return true
    }

    @discardableResult
    func beginDismissal(attemptID id: UUID) -> Bool {
        guard attemptID == id, phase == .presenting || phase == .presented else { return false }
        phase = .dismissing
        return true
    }

    @discardableResult
    func didDismiss(attemptID id: UUID, presenterIsClear: Bool) -> Bool {
        guard attemptID == id, phase == .dismissing || phase == .presented else { return false }
        guard presenterIsClear else {
            phase = .awaitingDismissal
            return false
        }
        reset()
        return true
    }

    @discardableResult
    func fail(attemptID id: UUID) -> Bool {
        guard attemptID == id, phase != .idle else { return false }
        reset()
        return true
    }

    private func reset() {
        phase = .idle
        attemptID = nil
    }
}

struct V3InstallAttemptState {
    enum Phase: String, Equatable {
        case idle, pickerPresented, staging, waitingForPickerDismissal, waitingForReload
        case readyToPresentOperation, operationPresented, operationStarted, terminal, cleaningUp
    }

    private(set) var phase: Phase = .idle
    private(set) var attemptID: UUID?
    private(set) var operationID: UUID?
    private(set) var token: String?
    private(set) var title: String?
    private(set) var backendSessionID: String?
    private(set) var terminalOutcome: String?
    private(set) var operationViewDidAppear = false

    var isIdle: Bool { phase == .idle }
    var hasActiveAttempt: Bool { !isIdle }

    mutating func beginPicker() -> UUID? {
        guard isIdle else { return nil }
        reset()
        let id = UUID()
        attemptID = id
        phase = .pickerPresented
        return id
    }

    mutating func beginDirectStaging() -> UUID? {
        guard isIdle else { return nil }
        reset()
        let id = UUID()
        attemptID = id
        phase = .staging
        return id
    }

    @discardableResult
    mutating func beginStaging(attemptID id: UUID) -> Bool {
        guard attemptID == id, phase == .pickerPresented else { return false }
        phase = .staging
        return true
    }

    @discardableResult
    mutating func staged(attemptID id: UUID, token: String, title: String,
                         waitsForPickerDismissal: Bool, isLoading: Bool) -> Bool {
        guard attemptID == id, phase == .staging, UUID(uuidString: token) != nil,
              !title.isEmpty, title.utf8.count <= 160 else { return false }
        self.token = token
        self.title = title
        if waitsForPickerDismissal { phase = .waitingForPickerDismissal }
        else { phase = isLoading ? .waitingForReload : .readyToPresentOperation }
        return true
    }

    @discardableResult
    mutating func failStaging(attemptID id: UUID) -> Bool {
        guard attemptID == id, phase == .staging else { return false }
        reset()
        return true
    }

    @discardableResult
    mutating func pickerDidDisappear(attemptID id: UUID, isLoading: Bool) -> Bool {
        guard attemptID == id, phase == .waitingForPickerDismissal else { return false }
        phase = isLoading ? .waitingForReload : .readyToPresentOperation
        return true
    }

    @discardableResult
    mutating func cancelPicker(attemptID id: UUID) -> Bool {
        guard attemptID == id, phase == .pickerPresented || phase == .staging ||
                phase == .waitingForPickerDismissal else { return false }
        reset()
        return true
    }

    // A presentation can be discarded only before a backend session has been
    // issued, or after the caller has separately confirmed a terminal result.
    @discardableResult
    mutating func resetBeforeBackend(attemptID id: UUID) -> Bool {
        guard attemptID == id else { return false }
        switch phase {
        case .pickerPresented, .staging, .waitingForPickerDismissal,
             .waitingForReload, .readyToPresentOperation:
            reset()
            return true
        case .operationPresented where !operationViewDidAppear && backendSessionID == nil:
            reset()
            return true
        default:
            return false
        }
    }

    mutating func reloadFinished() {
        guard phase == .waitingForReload else { return }
        phase = .readyToPresentOperation
    }

    mutating func takeReadyOperation(isLoading: Bool,
                                     hasActiveOperationPresentation: Bool) -> V3InstallPresentationRequest? {
        guard phase == .readyToPresentOperation, !isLoading, !hasActiveOperationPresentation,
              let attemptID, let token, let title else { return nil }
        let operationID = UUID()
        self.operationID = operationID
        operationViewDidAppear = false
        phase = .operationPresented
        return V3InstallPresentationRequest(attemptID: attemptID, operationID: operationID,
                                            token: token, title: title)
    }

    @discardableResult
    mutating func markOperationViewDidAppear(attemptID id: UUID, operationID: UUID) -> Bool {
        guard attemptID == id, self.operationID == operationID,
              phase == .operationPresented || phase == .operationStarted else { return false }
        operationViewDidAppear = true
        return true
    }

    @discardableResult
    mutating func backendStarted(attemptID id: UUID, operationID: UUID, sessionID: String) -> Bool {
        guard attemptID == id, self.operationID == operationID,
              phase == .operationPresented, backendSessionID == sessionID,
              UUID(uuidString: sessionID) != nil else { return false }
        backendSessionID = sessionID
        phase = .operationStarted
        return true
    }

    @discardableResult
    mutating func backendStartRequested(attemptID id: UUID, operationID: UUID,
                                        sessionID: String) -> Bool {
        guard attemptID == id, self.operationID == operationID,
              phase == .operationPresented, UUID(uuidString: sessionID) != nil else { return false }
        backendSessionID = sessionID
        return true
    }

    @discardableResult
    mutating func recordTerminal(attemptID id: UUID, operationID: UUID, outcome: String) -> Bool {
        guard attemptID == id, self.operationID == operationID,
              phase == .operationPresented || phase == .operationStarted else { return false }
        terminalOutcome = outcome
        phase = .terminal
        return true
    }

    @discardableResult
    mutating func prepareRetry(attemptID id: UUID, operationID: UUID) -> Bool {
        guard attemptID == id, self.operationID == operationID, phase == .terminal else { return false }
        backendSessionID = nil
        terminalOutcome = nil
        operationViewDidAppear = true
        phase = .operationPresented
        return true
    }

    @discardableResult
    mutating func beginCleanup(attemptID id: UUID) -> Bool {
        guard attemptID == id, phase == .terminal else { return false }
        phase = .cleaningUp
        return true
    }

    @discardableResult
    mutating func finishCleanup(attemptID id: UUID) -> Bool {
        guard attemptID == id, phase == .cleaningUp else { return false }
        reset()
        return true
    }

    private mutating func reset() {
        phase = .idle
        attemptID = nil
        operationID = nil
        token = nil
        title = nil
        backendSessionID = nil
        terminalOutcome = nil
        operationViewDidAppear = false
    }
}

// Deletion completion is based on SideStore's pipeline/native uninstall result
// plus its persisted app-library state. Progress and a host-side list update do
// not establish success on their own.
struct V3DeleteCompletionContract {
    enum BackendResult: Equatable { case pending, succeeded, failed }
    enum Terminal: Equatable { case completed, failed, outcomeUnknown }

    private(set) var terminal: Terminal?

    mutating func resolve(backend: BackendResult, nativeUninstallSucceeded: Bool,
                          appStillInAuthoritativeLibrary: Bool, deadlineExpired: Bool,
                          progress: Double) -> Terminal? {
        _ = progress // Progress is deliberately never a success signal.
        guard terminal == nil else { return terminal }
        if backend == .failed {
            terminal = .failed
        } else if !appStillInAuthoritativeLibrary &&
                    (backend == .succeeded ||
                     (backend == .pending && nativeUninstallSucceeded && deadlineExpired)) {
            terminal = .completed
        } else if backend == .pending && deadlineExpired {
            // This is provisional. Keep the contract open so the late callback
            // can still establish the authoritative result.
            return .outcomeUnknown
        } else if deadlineExpired {
            terminal = .failed
        }
        return terminal
    }
}

enum V3DeleteCancellationPolicy {
    static func callbackCancellationRemainsPending(isCancellation: Bool,
                                                   cancellationRequested: Bool) -> Bool {
        isCancellation && cancellationRequested
    }

    static func cancelRequestReturnsBeforeDriverSettlement(operation: String,
                                                            driverIsRunning: Bool) -> Bool {
        operation == "delete" && driverIsRunning
    }

    static func keepsHostPollMonitor(operation: String) -> Bool {
        operation == "delete"
    }
}

enum V3OperationCancellationResolutionPolicy {
    static func requiresReconciliation(backendSettled: Bool?, outcomeUnknown: Bool) -> Bool {
        outcomeUnknown || backendSettled != true
    }
}

enum V3OperationReplyFieldPolicy {
    static func strictBoolean(_ rawValue: Any?) -> Bool? {
        guard let rawValue, let value = rawValue as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    // Missing is accepted for older service replies. A present malformed value
    // must fail closed because it cannot prove a terminal result is settled.
    static func outcomeUnknown(_ rawValue: Any?) -> Bool {
        guard let rawValue else { return false }
        return strictBoolean(rawValue) ?? true
    }
}

final class V3DeleteNativeSuccessRegistry: @unchecked Sendable {
    static let shared = V3DeleteNativeSuccessRegistry()
    static let retentionInterval: TimeInterval = 10 * 60
    static let maximumEntries = 512
    private let lock = NSLock()
    private var sessions: [String: Date] = [:]

    func record(sessionID: String, now: Date = Date()) {
        guard UUID(uuidString: sessionID) != nil else { return }
        lock.lock()
        pruneLocked(now: now)
        sessions[sessionID] = now.addingTimeInterval(Self.retentionInterval)
        if sessions.count > Self.maximumEntries {
            let oldest = sessions.sorted { $0.value < $1.value }
            for (id, _) in oldest.prefix(sessions.count - Self.maximumEntries) {
                sessions.removeValue(forKey: id)
            }
        }
        lock.unlock()
    }

    func contains(sessionID: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)
        guard sessions[sessionID] != nil else { return false }
        sessions[sessionID] = now.addingTimeInterval(Self.retentionInterval)
        return true
    }

    func remove(sessionID: String) {
        lock.lock()
        sessions.removeValue(forKey: sessionID)
        lock.unlock()
    }

    private func pruneLocked(now: Date) {
        sessions = sessions.filter { $0.value > now }
    }
}

// Shared state primitives used by the UI/backend and executable regression
// harnesses. These types deliberately carry no paths, credentials, or logs.
struct V3OperationAttemptState {
    private(set) var generation = UUID()
    private(set) var sessionID: String?
    private(set) var isTerminal = false
    private(set) var transitionInFlight = false

    mutating func begin() -> UUID {
        generation = UUID()
        sessionID = generation.uuidString
        isTerminal = false
        return generation
    }

    mutating func attach(sessionID: String) -> UUID? {
        guard let id = UUID(uuidString: sessionID), id.uuidString == sessionID else { return nil }
        generation = id
        self.sessionID = sessionID
        isTerminal = false
        transitionInFlight = false
        return id
    }

    mutating func bind(sessionID: String, generation: UUID) -> Bool {
        guard self.generation == generation, !isTerminal,
              self.sessionID == sessionID else { return false }
        return true
    }

    @discardableResult
    mutating func acceptStartFailure(generation: UUID) -> Bool {
        guard self.generation == generation, !isTerminal else { return false }
        isTerminal = true
        return true
    }

    func matches(generation: UUID, sessionID: String) -> Bool {
        self.generation == generation && self.sessionID == sessionID && !isTerminal
    }

    func owns(generation: UUID, sessionID: String) -> Bool {
        self.generation == generation && self.sessionID == sessionID
    }

    @discardableResult
    mutating func accept(state: String, generation: UUID, sessionID: String) -> Bool {
        guard matches(generation: generation, sessionID: sessionID) else { return false }
        if !["working", "awaitingPrompt", "cancelling", "reconciling"].contains(state) { isTerminal = true }
        return true
    }

    func ownsProvisionalResolution(generation: UUID, sessionID: String,
                                   currentState: String?, currentBackendSettled: Bool?,
                                   currentOutcomeUnknown: Bool, nextState: String?,
                                   nextBackendSettled: Bool?, nextOutcomeUnknown: Bool,
                                   nextOperation: String? = nil,
                                   verifiedDeleteCompletion: Bool = false) -> Bool {
        owns(generation: generation, sessionID: sessionID) && isTerminal &&
            V3OperationProvisionalOutcomePolicy.canResolve(
                currentState: currentState, currentBackendSettled: currentBackendSettled,
                currentOutcomeUnknown: currentOutcomeUnknown, nextState: nextState,
                nextBackendSettled: nextBackendSettled, nextOutcomeUnknown: nextOutcomeUnknown,
                nextOperation: nextOperation, verifiedDeleteCompletion: verifiedDeleteCompletion)
    }

    mutating func supersede() -> String? {
        let previousSession = sessionID
        generation = UUID()
        sessionID = nil
        isTerminal = true
        return previousSession
    }

    mutating func beginTransition() -> Bool {
        guard !transitionInFlight else { return false }
        transitionInFlight = true
        return true
    }

    mutating func endTransition() {
        transitionInFlight = false
    }
}

enum V3OperationCoverDismissalPolicy {
    static func mustConfirmBackendStop(isRunning: Bool, hasSession: Bool,
                                       sessionIsTerminal: Bool,
                                       hasUncertainSession: Bool,
                                       transitionInFlight: Bool) -> Bool {
        hasUncertainSession ||
            (!sessionIsTerminal && (isRunning || hasSession || transitionInFlight))
    }
}

struct V3OperationMutationRegistry {
    enum StartResult: Equatable { case started, cancelledBeforeStart, busy }
    enum CancelResult: Equatable { case active, recordedBeforeStart }

    private(set) var activeID: String?
    private var cancelledBeforeStart: [String: Date] = [:]

    mutating func begin(_ id: String, now: Date = Date()) -> StartResult {
        prune(now: now)
        if cancelledBeforeStart.removeValue(forKey: id) != nil { return .cancelledBeforeStart }
        guard activeID == nil else { return .busy }
        activeID = id
        return .started
    }

    mutating func cancel(_ id: String, now: Date = Date()) -> CancelResult {
        if activeID == id { return .active }
        cancelledBeforeStart[id] = now.addingTimeInterval(600)
        prune(now: now)
        return .recordedBeforeStart
    }

    @discardableResult
    mutating func finish(_ id: String) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }

    private mutating func prune(now: Date) {
        cancelledBeforeStart = cancelledBeforeStart.filter { $0.value > now }
        guard cancelledBeforeStart.count > 256 else { return }
        let oldest = cancelledBeforeStart.sorted { $0.value < $1.value }
        for (id, _) in oldest.prefix(cancelledBeforeStart.count - 256) {
            cancelledBeforeStart.removeValue(forKey: id)
        }
    }
}

// V3_OPERATION_RECOVERY_JOURNAL_V1
// This record is shared by LiveContainer and the embedded SideStore service.
// It intentionally contains identifiers and allow-listed markers only. It has
// no timestamp: process age and elapsed time never prove device settlement.
struct V3OperationRecoveryRecord: Equatable {
    enum Phase: String, Equatable { case prepared, dispatched }
    let sessionID: String
    let kind: String
    let phase: Phase
    let stagedIPAToken: String?

    static let allowedKinds: Set<String> = [
        "install", "installURL", "installSharedIPA", "update", "refreshApp",
        "activate", "deactivate", "remove", "delete", "backup", "restore", "refreshAll"
    ]

    init?(sessionID: String, kind: String, phase: Phase, stagedIPAToken: String? = nil) {
        guard let id = UUID(uuidString: sessionID), id.uuidString == sessionID,
              Self.allowedKinds.contains(kind) else { return nil }
        if let stagedIPAToken {
            guard let token = UUID(uuidString: stagedIPAToken),
                  token.uuidString.lowercased() == stagedIPAToken else { return nil }
        }
        self.sessionID = sessionID
        self.kind = kind
        self.phase = phase
        self.stagedIPAToken = stagedIPAToken
    }

    var propertyListRepresentation: [String: Any] {
        var value: [String: Any] = ["version": 1, "session": sessionID,
            "kind": kind, "phase": phase.rawValue]
        if let stagedIPAToken { value["ipa"] = stagedIPAToken }
        return value
    }

    static func decodePropertyList(_ value: Any) -> V3OperationRecoveryRecord? {
        guard let plist = value as? [String: Any] else { return nil }
        let requiredKeys: Set<String> = ["version", "session", "kind", "phase"]
        let hasIPA = plist.keys.contains("ipa")
        guard let version = plist["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1 else { return nil }
        guard Set(plist.keys) == (hasIPA ? requiredKeys.union(["ipa"]) : requiredKeys),
              let session = plist["session"] as? String,
              let kind = plist["kind"] as? String,
              let phaseRaw = plist["phase"] as? String,
              let phase = Phase(rawValue: phaseRaw) else { return nil }
        let token: String?
        if hasIPA {
            guard let value = plist["ipa"] as? String else { return nil }
            token = value
        } else {
            token = nil
        }
        return V3OperationRecoveryRecord(sessionID: session, kind: kind,
            phase: phase, stagedIPAToken: token)
    }
}

struct V3OperationRecoveryLease: Equatable {
    enum DispatchResult: Equatable { case reserved, alreadyOwned, blocked }
    private(set) var record: V3OperationRecoveryRecord?

    init(record: V3OperationRecoveryRecord? = nil) { self.record = record }

    mutating func reserve(sessionID: String, kind: String, stagedIPAToken: String? = nil) -> DispatchResult {
        guard let requested = V3OperationRecoveryRecord(sessionID: sessionID, kind: kind,
                phase: .prepared, stagedIPAToken: stagedIPAToken) else { return .blocked }
        guard let current = record else { record = requested; return .reserved }
        guard current.sessionID == requested.sessionID, current.kind == requested.kind,
              current.stagedIPAToken == requested.stagedIPAToken,
              current.phase == .prepared else { return .blocked }
        return .alreadyOwned
    }

    mutating func beginDispatch(sessionID: String, kind: String,
                                stagedIPAToken: String? = nil) -> Bool {
        guard let current = record, current.sessionID == sessionID,
              current.kind == kind, current.phase == .prepared,
              current.stagedIPAToken == stagedIPAToken,
              let dispatched = V3OperationRecoveryRecord(sessionID: sessionID, kind: kind,
                  phase: .dispatched, stagedIPAToken: stagedIPAToken) else { return false }
        record = dispatched
        return true
    }

    @discardableResult
    mutating func settle(sessionID: String, replySessionID: String?, state: String?,
                         backendSettled: Bool) -> Bool {
        guard let current = record, current.sessionID == sessionID,
              current.phase == .dispatched, replySessionID == sessionID, backendSettled,
              ["completed", "failed", "cancelled", "timedOut", "requiresSource", "waitingForAuthentication"].contains(state ?? "") else {
            return false
        }
        record = nil
        return true
    }

    @discardableResult
    mutating func reconcileAfterDeviceCheck(sessionID: String, userConfirmed: Bool) -> Bool {
        guard userConfirmed, record?.sessionID == sessionID else { return false }
        record = nil
        return true
    }

    @discardableResult
    mutating func clearPreparedAfterNotDispatched(sessionID: String, expectedRequestID: String,
                                                   replyRequestID: String?, operationNotDispatched: Bool) -> Bool {
        guard operationNotDispatched, replyRequestID == expectedRequestID,
              UUID(uuidString: expectedRequestID)?.uuidString == expectedRequestID,
              let current = record, current.sessionID == sessionID, current.phase == .prepared else { return false }
        record = nil
        return true
    }

    @discardableResult
    mutating func clearPreparedAfterConfirmedCancellation(sessionID: String, replySessionID: String?,
        state: String?, backendSettled: Bool, stopConfirmed: Bool, knownStarted: Bool) -> Bool {
        guard !knownStarted, let current = record,
              current.sessionID == sessionID, current.phase == .prepared,
              replySessionID == sessionID, state == "cancelled",
              backendSettled, stopConfirmed else { return false }
        record = nil
        return true
    }

    @discardableResult
    mutating func settleRefreshAdmission(runID: String, terminalState: String?,
                                         terminalConfirmed: Bool) -> Bool {
        guard terminalConfirmed, let current = record,
              current.sessionID == runID, current.kind == "refreshAll",
              (current.phase == .prepared ||
                (current.phase == .dispatched && terminalState != "notDispatched")),
              ["completed", "failed", "notDispatched"].contains(terminalState ?? "") else { return false }
        record = nil
        return true
    }

    @discardableResult
    mutating func clearPreparedRefreshAdmissionAfterRequestCancellation(runID: String) -> Bool {
        guard let current = record, current.sessionID == runID,
              current.kind == "refreshAll", current.phase == .prepared else { return false }
        record = nil
        return true
    }

    @discardableResult
    mutating func reconcileRefreshAdmissionAfterDeviceCheck(runID: String, userConfirmed: Bool) -> Bool {
        guard record?.kind == "refreshAll" else { return false }
        return reconcileAfterDeviceCheck(sessionID: runID, userConfirmed: userConfirmed)
    }

    var blocksMutation: Bool { record != nil }
    var protectedStagedIPAToken: String? { record?.stagedIPAToken }
}

// A staged IPA remains owned while any session task can still inspect it,
// preparation has not settled, or the global mutation registry still assigns
// the native mutation to that session. Age alone never releases a live lease.
enum V3StagedIPALeasePolicy {
    static func isLeased(hasOperationTask: Bool, preparationFinished: Bool,
                         ownsMutationRegistry: Bool) -> Bool {
        hasOperationTask || !preparationFinished || ownsMutationRegistry
    }
}

enum V3StagedIPACleanupFallbackPolicy {
    static func mayDeleteLocally(serviceReportsBusy: Bool,
                                 callerConfirmsNeverStartedOrSettled: Bool) -> Bool {
        callerConfirmsNeverStartedOrSettled && !serviceReportsBusy
    }
}

// Terminal responses are write-once. Callback and cancellation paths may race,
// so the first terminal result is authoritative and later results are ignored.
final class V3TerminalResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any]?

    @discardableResult
    func setIfEmpty(_ response: [String: Any]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storage == nil else { return false }
        storage = response
        return true
    }

    var value: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var isEmpty: Bool { if case nil = value { return true }; return false }
}

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

enum V3DeleteReconciliationPolicy {
    static let callbackGrace: TimeInterval = 5
    static let libraryRecheckInterval: TimeInterval = 15
    static let maximumCallbackPollInterval: TimeInterval = 15

    static func shouldCheckLibrary(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= libraryRecheckInterval
    }

    static func shouldThrottleLibraryChecks(authoritativeAbsenceConfirmed: Bool,
                                            cancellationRequested: Bool) -> Bool {
        authoritativeAbsenceConfirmed || cancellationRequested
    }

    static func nextCallbackPollDelay(current: TimeInterval, backendPending: Bool,
                                      nativeUninstallSucceeded: Bool,
                                      appStillInLibrary: Bool,
                                      cancellationRequested: Bool = false) -> TimeInterval {
        if !backendPending {
            guard appStillInLibrary else { return 1.0 }
            let settledBase = current.isFinite && current > 0 ? current : 0.5
            return min(max(settledBase * 2, 1.0), maximumCallbackPollInterval)
        }
        guard cancellationRequested || (nativeUninstallSucceeded && !appStillInLibrary) else { return 1.0 }
        let base = current.isFinite && current > 0 ? current : 0.25
        return min(base * 2, maximumCallbackPollInterval)
    }

    static func shouldRequestCancellation(deadlineElapsed: Bool, backendPending: Bool,
                                         cancellationAlreadyRequested: Bool) -> Bool {
        deadlineElapsed && backendPending && !cancellationAlreadyRequested
    }

    static func callbackGraceElapsed(requestedAt: Date?, now: Date) -> Bool {
        guard let requestedAt else { return false }
        return now.timeIntervalSince(requestedAt) >= callbackGrace
    }

    static func shouldPublishOutcomeUnknown(backendPending: Bool, requestedAt: Date?,
                                           now: Date) -> Bool {
        backendPending && callbackGraceElapsed(requestedAt: requestedAt, now: now)
    }

    static func mayPublishVerifiedDeleteCompletion(backendPending: Bool,
                                                    nativeUninstallSucceeded: Bool,
                                                    appStillInLibrary: Bool,
                                                    reconciliationDeadlineElapsed: Bool) -> Bool {
        backendPending && nativeUninstallSucceeded && !appStillInLibrary &&
            reconciliationDeadlineElapsed
    }

    static func shouldReleaseMutationOwnership(backendSettled: Bool) -> Bool {
        backendSettled
    }
}

enum V3OperationSessionRetentionPolicy {
    static let terminalRetention: TimeInterval = 600

    static func shouldRefreshTerminalAt(terminalAccepted: Bool, backendSettled: Bool) -> Bool {
        terminalAccepted || backendSettled
    }

    static func isExpired(backendSettled: Bool, terminalAt: Date?, now: Date) -> Bool {
        guard backendSettled, let terminalAt else { return false }
        return now.timeIntervalSince(terminalAt) > terminalRetention
    }
}

enum V3OperationCompletionDisposition: Equatable {
    case notCompleted
    case completed
    case completedAwaitingBackendSettlement
    case outcomeUnknownAwaitingBackendSettlement
}

enum V3OperationCompletionPolicy {
    static func disposition(state: String, backendSettled: Bool?,
                            outcomeUnknown: Bool = false) -> V3OperationCompletionDisposition {
        if outcomeUnknown {
            return .outcomeUnknownAwaitingBackendSettlement
        }
        guard state == "completed" else { return .notCompleted }
        return backendSettled == true ? .completed : .completedAwaitingBackendSettlement
    }

    static func shouldContinuePolling(state: String, backendSettled: Bool?,
                                      outcomeUnknown: Bool = false) -> Bool {
        switch disposition(state: state, backendSettled: backendSettled,
                           outcomeUnknown: outcomeUnknown) {
        case .completedAwaitingBackendSettlement, .outcomeUnknownAwaitingBackendSettlement: return true
        case .notCompleted, .completed: return false
        }
    }

    static func shouldRetrySettlementPollFailure(state: String, backendSettled: Bool?,
                                                  outcomeUnknown: Bool,
                                                  cancellationRequested: Bool = false) -> Bool {
        shouldContinuePolling(state: state, backendSettled: backendSettled,
                              outcomeUnknown: outcomeUnknown) ||
            (state == "cancelling" && cancellationRequested)
    }

    static func requiresDeviceCheck(state: String, backendSettled: Bool?,
                                    deviceCheckConfirmed: Bool,
                                    outcomeUnknown: Bool = false) -> Bool {
        shouldContinuePolling(state: state, backendSettled: backendSettled,
                              outcomeUnknown: outcomeUnknown) && !deviceCheckConfirmed
    }

    static func mayDismiss(state: String, backendSettled: Bool?,
                           deviceCheckConfirmed: Bool = false,
                           outcomeUnknown: Bool = false) -> Bool {
        !requiresDeviceCheck(state: state, backendSettled: backendSettled,
                             deviceCheckConfirmed: deviceCheckConfirmed,
                             outcomeUnknown: outcomeUnknown)
    }

    static func pollInterval(state: String, backendSettled: Bool?,
                             outcomeUnknown: Bool = false) -> TimeInterval {
        shouldContinuePolling(state: state, backendSettled: backendSettled,
                              outcomeUnknown: outcomeUnknown) ? 5 : 1
    }

    static func nextSettlementPollRetryDelay(current: TimeInterval) -> TimeInterval {
        let base = current.isFinite && current > 0 ? current : 5
        if base < 5 { return 5 }
        return min(base * 2, 30)
    }
}

enum V3OperationProvisionalOutcomePolicy {
    static func canResolve(currentState: String?, currentBackendSettled: Bool?,
                           currentOutcomeUnknown: Bool, nextState: String?,
                           nextBackendSettled: Bool?, nextOutcomeUnknown: Bool,
                           nextOperation: String? = nil,
                           verifiedDeleteCompletion: Bool = false) -> Bool {
        let priorResultIsProvisional =
            ["reconciling", "failed", "cancelled"].contains(currentState ?? "") &&
            currentOutcomeUnknown && currentBackendSettled == false
        guard priorResultIsProvisional, !nextOutcomeUnknown else { return false }
        let settledTerminal = nextBackendSettled == true &&
            ["completed", "failed", "cancelled"].contains(nextState ?? "")
        let verifiedDeleteWhileCallbackPending = nextOperation == "delete" &&
            verifiedDeleteCompletion && nextState == "completed" && nextBackendSettled == false
        return settledTerminal || verifiedDeleteWhileCallbackPending
    }
}

// Cancellation is a request to stop. It is never itself a terminal result:
// the backend driver commits completed/failed/cancelled only after its native
// callback and required verification have settled.
final class V3OperationTerminalResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any]?
    private var cancellationRequested = false

    @discardableResult
    func requestCancellation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storage == nil else { return false }
        cancellationRequested = true
        return true
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    @discardableResult
    func setIfEmpty(_ response: [String: Any]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storage == nil else { return false }
        storage = response
        return true
    }

    // A reconciling record is provisional, not a terminal result. It can be
    // replaced once the backend callback settles, but ordinary terminal
    // responses remain write-once.
    @discardableResult
    func resolveProvisionalOutcome(_ response: [String: Any]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = storage,
              V3OperationProvisionalOutcomePolicy.canResolve(
                currentState: current["state"] as? String,
                currentBackendSettled: current["backendSettled"] as? Bool,
                currentOutcomeUnknown: current["outcomeUnknown"] as? Bool == true,
                nextState: response["state"] as? String,
                nextBackendSettled: response["backendSettled"] as? Bool,
                nextOutcomeUnknown: response["outcomeUnknown"] as? Bool == true,
                nextOperation: response["operation"] as? String,
                verifiedDeleteCompletion: V3OperationReplyFieldPolicy.strictBoolean(
                    response["verifiedDeleteCompletion"]) == true) else { return false }
        storage = response
        return true
    }

    @discardableResult
    func finishOrResolve(_ response: [String: Any], backendSettled: Bool) -> Bool {
        var resolved = response
        resolved["backendSettled"] = backendSettled
        return setIfEmpty(resolved) || resolveProvisionalOutcome(resolved)
    }

    var value: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var isEmpty: Bool { value == nil }

    func reply(sessionID: String, backendSettled: Bool) -> [String: Any]? {
        guard var response = value else { return nil }
        response["session"] = sessionID
        response["backendSettled"] = backendSettled
        return response
    }
}

// Owns pre-driver work such as resolving or downloading a URL IPA. The session
// is not stopped until this gate finishes; cancellation is forwarded to the
// concrete preparation task and callers can await its settlement.
final class V3OperationPreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var cancellationRequested = false
    private var cancellationAction: (() -> Void)?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    var pendingWaiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func installCancellation(_ action: @escaping () -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        cancellationAction = action
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { action() }
    }

    @discardableResult
    func requestCancellation() -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        let firstRequest = !cancellationRequested
        cancellationRequested = true
        let action = firstRequest ? cancellationAction : nil
        lock.unlock()
        action?()
        return true
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        cancellationAction = nil
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

struct V3SettingsWriteGeneration {
    private var values: [String: UInt64] = [:]
    private var pending: [String: Set<UInt64>] = [:]

    mutating func begin(_ key: String) -> UInt64 {
        let next = (values[key] ?? 0) &+ 1
        values[key] = next
        pending[key, default: []].insert(next)
        return next
    }

    mutating func finish(_ generation: UInt64, for key: String) {
        pending[key]?.remove(generation)
        if pending[key]?.isEmpty == true { pending.removeValue(forKey: key) }
    }

    func isPending(_ generation: UInt64, for key: String) -> Bool {
        pending[key]?.contains(generation) == true
    }

    func hasPendingWrites(for key: String) -> Bool {
        pending[key]?.isEmpty == false
    }

    func isCurrent(_ generation: UInt64, for key: String) -> Bool {
        values[key] == generation
    }

    func current(for key: String) -> UInt64 {
        values[key] ?? 0
    }

    func isUnchanged(since captured: V3SettingsWriteGeneration) -> Bool {
        values == captured.values && pending.isEmpty && captured.pending.isEmpty
    }

    // A read can start before OR during a write and return after it settles.
    // Reject both cases per key, retaining unrelated authoritative read values.
    func mergingSnapshot<Value>(_ snapshot: [String: Value], into currentValues: [String: Value],
                                captured: V3SettingsWriteGeneration) -> [String: Value] {
        var result = currentValues
        for key in Set(currentValues.keys).union(snapshot.keys)
            where current(for: key) == captured.current(for: key) &&
                  pending[key] == nil && captured.pending[key] == nil {
            result[key] = snapshot[key]
        }
        return result
    }
}

// V3_STATUS_PRESENTATION_V1
// One reusable semantic status model. Success, warning and failure were drawn
// with almost the same treatment in the operation sheet, Sources, Setup
// Assistant, Health and install flows, so a red failure and a grey informational
// line were hard to tell apart. Every state carries an icon AND a text label so
// the meaning never depends on colour alone.
enum V3StatusSeverity: String, Equatable, CaseIterable {
    case working
    case completed
    case warning
    case failed
    case cancelled
    case unknown

    var icon: String {
        switch self {
        case .working: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// The colour used alongside the icon and the text.
    var severityName: String {
        switch self {
        case .working: return "working"
        case .completed: return "success"
        case .warning: return "warning"
        case .failed: return "failure"
        case .cancelled: return "cancelled"
        case .unknown: return "unknown"
        }
    }

    var isFailure: Bool { self == .failed }
    var isSuccess: Bool { self == .completed }
    /// Only a genuine success is presented as a tick.
    var showsCheckmark: Bool { self == .completed }
}

struct V3StatusPresentation: Equatable {
    let severity: V3StatusSeverity
    let title: String
    let detail: String

    var icon: String { severity.icon }
    var severityName: String { severity.severityName }
    var isFailure: Bool { severity.isFailure }
    var isSuccess: Bool { severity.isSuccess }

    init(severity: V3StatusSeverity, title: String, detail: String = "") {
        self.severity = severity
        self.title = title
        self.detail = detail
    }

    /// Maps a product state word onto the shared severity model.
    static func severity(forState state: String) -> V3StatusSeverity {
        switch state {
        case "complete", "completed", "verified", "ready", "success": return .completed
        case "failed", "error": return .failed
        case "warning", "actionRequired", "needsAttention": return .warning
        case "running", "checking", "working", "loading", "inProgress": return .working
        case "cancelled", "canceled": return .cancelled
        default: return .unknown
        }
    }

    /// V3_RELOAD_STATUS_VISIBILITY_V1: loading wins over connected. The previous
    /// ordering rendered a green "Active & Connected" while a reload was
    /// actively running, so the button appeared to do nothing.
    static func connectionState(connected: Bool, loading: Bool) -> V3StatusPresentation {
        if loading {
            return V3StatusPresentation(severity: .working, title: "Reloading Status...")
        }
        if connected {
            return V3StatusPresentation(severity: .completed, title: "Connected")
        }
        return V3StatusPresentation(severity: .failed, title: "Not Connected")
    }
}

// V3_USER_FACING_ISSUE_V1
// The global alert used to offer "Retry Connection" for essentially every
// failure, which trained users to read every problem as a networking problem.
// A source failure, a certificate failure, an auth failure and a pairing failure
// each get the action that can actually resolve them. Connection evidence opens
// Connection Settings; it does not claim that reloading status retried a mutation.
enum V3IssueAction: String, Equatable, CaseIterable {
    case retrySource
    case reloadSources
    case reloadStatus
    case openCertificates
    case openAccount
    case showPairingSetup
    case openConnectionCheck
    case chooseIPA
    case openSetup
    case openSources
    case dismiss

    var title: String {
        switch self {
        case .retrySource: return "Retry Source"
        case .reloadSources: return "Reload Sources"
        case .reloadStatus: return "Reload Status"
        case .openCertificates: return "Open Certificates"
        case .openAccount: return "Open Account & Signing"
        case .showPairingSetup: return "Show Pairing Setup"
        case .openConnectionCheck: return "Open Connection Settings"
        case .chooseIPA: return "Choose IPA Again"
        case .openSetup: return "Open Setup Assistant"
        case .openSources: return "Open Sources"
        case .dismiss: return "OK"
        }
    }

    /// The screen this action opens, or nil for an action that re-requests.
    var destination: String? {
        switch self {
        case .openCertificates: return "certificates"
        case .openAccount: return "signIn"
        case .showPairingSetup: return "pairing"
        case .openConnectionCheck: return "connection"
        case .chooseIPA: return "ipa"
        case .openSetup: return "setup"
        case .retrySource, .reloadSources, .openSources: return "sources"
        case .reloadStatus: return nil
        case .dismiss: return nil
        }
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

enum V3AnisetteFailureGuidance {
    static func message(_ failure: CombinedFailure) -> String? {
        guard failure.operation.lowercased().hasPrefix("anisette") else { return nil }
        if failure.code == .cancelled {
            return "What happened: The Anisette Servers request was cancelled.\nWhat you can do: Reopen Anisette Servers to check the current state before trying again.\n\(failure.diagnosticLabel)"
        }
        guard failure.stage == .network ||
              failure.safeCause == .networkConnectionLost ||
              failure.safeCause == .networkTimedOut ||
              failure.safeCause == .networkUnavailable else { return nil }
        return "What happened: SideStore could not reach the configured Anisette server.\nWhat you can do: Check its address and your network, then try again. This does not show that LocalDevVPN is unavailable.\n\(failure.diagnosticLabel)"
    }
}

enum V3SideJITReachabilityFeedback {
    static let unreachable = "The SideJIT server could not be reached. Check its address and network, then try again." + "\nError ID: SS-NET-D061"

    static func reachable(httpStatusCode: Int?) -> String {
        httpStatusCode.map { "Reachable (HTTP \($0))." } ?? "Reachable."
    }
}

struct V3UserFacingIssue: Equatable {
    let title: String
    let severity: V3StatusSeverity
    let whatHappened: String
    let whatToDo: String
    let technicalDetails: String
    let primaryAction: V3IssueAction
    let secondaryAction: V3IssueAction
    let recoveryDestination: String?
    let retryDisposition: V3RetryDisposition

    /// The single place that decides which action a failure deserves. Selection
    /// is driven by the typed operation, stage and safe cause, never by a
    /// numeric code or by the mere fact that a request failed.
    static func make(operation: String, stage: String, code: String,
                     safeCause: String?, sourceStep: String?, retryable: Bool?,
                     whatHappened: String, whatToDo: String, technicalDetails: String) -> V3UserFacingIssue {
        let anisetteNetworkFailure = operation.lowercased().hasPrefix("anisette") &&
            [CombinedFailure.SafeCause.networkConnectionLost.rawValue,
             CombinedFailure.SafeCause.networkTimedOut.rawValue,
             CombinedFailure.SafeCause.networkUnavailable.rawValue].contains(safeCause ?? "")
        let anisetteServerUnavailable = operation.lowercased().hasPrefix("anisette") &&
            safeCause == CombinedFailure.SafeCause.anisetteServerUnavailable.rawValue
        let destination: String? = {
            // A remote Anisette server outage is service evidence even if an
            // upstream caller labels the boundary as `.network`. Do not let
            // the generic stage fallback send it to LocalDevVPN settings.
            if anisetteNetworkFailure || anisetteServerUnavailable { return nil }
            if safeCause == CombinedFailure.SafeCause.pairingRequired.rawValue ||
               safeCause == CombinedFailure.SafeCause.invalidPairingFile.rawValue { return "pairing" }
            if safeCause == CombinedFailure.SafeCause.authResponseCapacityUnavailable.rawValue { return "signIn" }
            if safeCause == CombinedFailure.SafeCause.keychainSignOutFailed.rawValue { return "signIn" }
            if safeCause == CombinedFailure.SafeCause.sourceRemoveFailed.rawValue ||
               safeCause == CombinedFailure.SafeCause.sourceRemoveBusy.rawValue { return "sources" }
            if [CombinedFailure.SafeCause.signingNetworkConnectionLost.rawValue,
                CombinedFailure.SafeCause.signingNetworkTimedOut.rawValue,
                CombinedFailure.SafeCause.signingNetworkUnavailable.rawValue].contains(safeCause ?? "") {
                return "connection"
            }
            if operation == "source" && stage == CombinedFailure.Stage.serviceReadiness.rawValue {
                return "sources"
            }
            if stage == CombinedFailure.Stage.authentication.rawValue { return "signIn" }
            if stage == CombinedFailure.Stage.filePreparation.rawValue { return "ipa" }
            if sourceStep == CombinedFailure.SourceStep.certificateValidation.rawValue
                || safeCause == CombinedFailure.SafeCause.certificateUnavailable.rawValue {
                return "certificates"
            }
            if operation == "source" || sourceStep == CombinedFailure.SourceStep.manifestParsing.rawValue
                || sourceStep == CombinedFailure.SourceStep.sourceDownload.rawValue {
                return "sources"
            }
            // Only these stages actually implicate connectivity or readiness.
            if stage == CombinedFailure.Stage.network.rawValue
                || stage == CombinedFailure.Stage.coreDevice.rawValue
                || stage == CombinedFailure.Stage.cdTunnel.rawValue
                || stage == CombinedFailure.Stage.rsdDiscovery.rawValue
                || stage == CombinedFailure.Stage.rsdService.rawValue
                || stage == CombinedFailure.Stage.lockdownConnection.rawValue
                || stage == CombinedFailure.Stage.uniqueDeviceID.rawValue
                || stage == CombinedFailure.Stage.heartbeat.rawValue
                || stage == CombinedFailure.Stage.endpointSelection.rawValue
                || safeCause == CombinedFailure.SafeCause.networkConnectionLost.rawValue
                || safeCause == CombinedFailure.SafeCause.networkTimedOut.rawValue
                || safeCause == CombinedFailure.SafeCause.networkUnavailable.rawValue
                || safeCause == CombinedFailure.SafeCause.wifiUnavailable.rawValue
                || safeCause == CombinedFailure.SafeCause.localDevVPNUnavailable.rawValue {
                return "connection"
            }
            if stage == CombinedFailure.Stage.provisioning.rawValue {
                return "setup"
            }
            return nil
        }()

        let primary: V3IssueAction = {
            switch destination {
            case "certificates": return .openCertificates
            case "signIn": return .openAccount
            case "pairing": return .showPairingSetup
            case "ipa": return .chooseIPA
            case "sources":
                if safeCause == CombinedFailure.SafeCause.sourceRemoveFailed.rawValue ||
                   safeCause == CombinedFailure.SafeCause.sourceRemoveBusy.rawValue { return .reloadSources }
                if safeCause == CombinedFailure.SafeCause.knownSourcePolicyNetworkFailure.rawValue ||
                    safeCause == CombinedFailure.SafeCause.knownSourcePolicyInvalidResponse.rawValue ||
                    safeCause == CombinedFailure.SafeCause.sourceInvalidManifest.rawValue ||
                    safeCause == CombinedFailure.SafeCause.sourceInvalidURL.rawValue ||
                    safeCause == CombinedFailure.SafeCause.sourceBlocked.rawValue ||
                    safeCause == CombinedFailure.SafeCause.sourceChangedID.rawValue ||
                    safeCause == CombinedFailure.SafeCause.sourceDuplicate.rawValue ||
                    safeCause == CombinedFailure.SafeCause.sourceUnsupported.rawValue ||
                    safeCause == CombinedFailure.SafeCause.sourceValidationFailed.rawValue {
                    return .openSources
                }
                if [CombinedFailure.SafeCause.responseEncodingFailed.rawValue,
                    CombinedFailure.SafeCause.responseTooLarge.rawValue,
                    CombinedFailure.SafeCause.responseCapacityUnavailable.rawValue,
                    CombinedFailure.SafeCause.operationInProgress.rawValue].contains(safeCause ?? "") {
                    return .dismiss
                }
                if stage == CombinedFailure.Stage.serviceReadiness.rawValue { return .openSources }
                return .retrySource
            case "setup": return .openSetup
            // Reloading a snapshot does not retry the failed mutation. Send the
            // user to the connection settings that can resolve this evidence.
            case "connection": return .openConnectionCheck
            default:
                // No evidence points anywhere specific. Never assume networking.
                return .dismiss
            }
        }()

        let disposition: V3RetryDisposition = {
            if safeCause == CombinedFailure.SafeCause.responseCapacityUnavailable.rawValue ||
               safeCause == CombinedFailure.SafeCause.authResponseCapacityUnavailable.rawValue {
                return .prerequisite
            }
            if retryable == false { return .blocked }
            if destination == "connection" && retryable == true { return .allowed }
            if retryable == true { return .allowed }
            return .unknown
        }()

        return V3UserFacingIssue(
            title: "SideStore",
            severity: .failed,
            whatHappened: whatHappened,
            whatToDo: anisetteNetworkFailure
                ? "Check the configured Anisette server and your network, then try again."
                : whatToDo,
            technicalDetails: technicalDetails,
            primaryAction: primary,
            secondaryAction: .dismiss,
            recoveryDestination: destination,
            retryDisposition: disposition)
    }

    /// Builds an issue from a typed failure, preserving its privacy-safe text.
    static func make(_ failure: CombinedFailure) -> V3UserFacingIssue {
        make(operation: failure.operation, stage: failure.stage.rawValue, code: failure.code.rawValue,
             safeCause: failure.safeCause?.rawValue, sourceStep: failure.sourceStep?.rawValue,
             retryable: failure.retryable, whatHappened: failure.safeMessage,
             whatToDo: failure.recovery, technicalDetails: failure.technicalDetails)
    }

    /// One-line summary, kept short enough for a copyable alert body.
    var summary: String { whatHappened }
}

// V3_CATALOG_ROW_POLICY_V1
// The catalog view deduplicated by snapshotting the accumulated IDs before
// filtering a page, so an identifier repeated inside one page passed twice. The
// rule lives here so the real behaviour is executable rather than asserted as
// source text.
enum V3CatalogRowPolicy {
    static func identifier(of row: [String: Any]) -> String? {
        guard let value = row["identifier"] as? String, !value.isEmpty else { return nil }
        return value
    }

    static func isDisplayable(_ row: [String: Any]) -> Bool {
        identifier(of: row) != nil && row["name"] as? String != nil
    }

    /// Removes duplicates by identifier, preserving first-seen order, across
    /// every page seen so far. Rows without a usable identifier are rejected
    /// rather than silently kept, because they cannot be deduplicated or
    /// installed.
    static func dedupe(_ rows: [[String: Any]]) -> [[String: Any]] {
        var seen = Set<String>()
        var result: [[String: Any]] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            guard let identifier = identifier(of: row) else { continue }
            if seen.insert(identifier).inserted { result.append(row) }
        }
        return result
    }

}

struct V3CatalogRowsAccumulator {
    private(set) var rows: [[String: Any]] = []
    private var identifiers = Set<String>()

    mutating func append(_ page: [[String: Any]]) {
        for row in page {
            guard V3CatalogRowPolicy.isDisplayable(row),
                  let identifier = V3CatalogRowPolicy.identifier(of: row),
                  identifiers.insert(identifier).inserted else { continue }
            rows.append(row)
        }
    }
}

// V3_RELOAD_GATE_V1
// The reload gate rules, made explicit and executable. The store previously
// inlined this, and callers could not await an authoritative snapshot, so a
// recalculate could read the previous snapshot.
// V3_LOAD_ACTIVITY_OWNERSHIP_V1
// One `loading` flag used to mean two different things: an authoritative status
// snapshot, and a mutation such as refreshSources, signOut, clearCache, syncAppIDs
// or a JIT operation. The reload gate read that flag as "a snapshot is in flight",
// so a caller awaiting an authoritative snapshot could join a mutation instead,
// and the mutation's completion released it with a not-observed outcome before
// any snapshot had been performed. The activity is now named, and the gate can
// tell the two apart.
enum V3LoadActivity: String, Equatable, CaseIterable {
    case idle
    /// An authoritative status snapshot is in flight. This is the only activity
    /// that may resolve a snapshot waiter.
    case snapshot
    /// A mutation is in flight. A snapshot must be requested after it, never
    /// substituted by it.
    case mutation
}

// V3_SNAPSHOT_GATE_V1
// The decision a snapshot request makes. It is a pure function so the ordering
// contract is executable behaviour rather than a comment about a flag.
enum V3SnapshotDecision: String, Equatable, CaseIterable {
    /// The caller owns the snapshot and must perform it now.
    case performSnapshot
    /// A snapshot is genuinely in flight. The caller parks and joins it.
    case joinSnapshot
    /// A mutation is in flight. The caller parks, and a snapshot is owed for
    /// after the mutation. The mutation's completion must not resolve it.
    case awaitMutationThenSnapshot
    /// A presented operation owns the state a snapshot would report. The caller
    /// parks, and a snapshot is owed for when the operation ends.
    case deferForPresentation
    /// A snapshot is owed, but its mutation/presentation blocker is still
    /// active. Keep the owed intent and parked waiters until that blocker ends.
    case stillBlocked
    /// Policy refuses an optional non-manual snapshot, so callers are told
    /// truthfully that nothing was observed. No continuation may remain parked.
    case doNotObserve
}

enum V3SnapshotGate {
    /// A presented operation owns the state, so its snapshot is deferred even
    /// when nothing else is running. This is checked first because a sheet can
    /// be up while a mutation is still settling, and both must be honoured.
    static func decide(activity: V3LoadActivity, presentationActive: Bool,
                       manual: Bool, requiresConnectionRetry: Bool) -> V3SnapshotDecision {
        if presentationActive { return .deferForPresentation }
        switch activity {
        case .snapshot: return .joinSnapshot
        case .mutation: return .awaitMutationThenSnapshot
        case .idle: break
        }
        if !manual && requiresConnectionRetry { return .doNotObserve }
        return .performSnapshot
    }

    /// The result of running an owed snapshot once the blocking activity has
    /// ended. Every case is total: no input leaves a parked continuation
    /// without a resumption, which is what made a non-manual deferred reload a
    /// latent permanent hang.
    static func drain(activity: V3LoadActivity, presentationActive: Bool,
                      owed: Bool, anyWaiterNeedsManual: Bool,
                      explicitManualOwed: Bool = false,
                      requiresConnectionRetry: Bool) -> V3SnapshotDecision {
        guard owed else { return .doNotObserve }
        guard activity == .idle, !presentationActive else { return .stillBlocked }
        return decide(activity: .idle, presentationActive: false,
                      manual: explicitManualOwed || anyWaiterNeedsManual || !requiresConnectionRetry,
                      requiresConnectionRetry: requiresConnectionRetry)
    }
}

// Fire-and-forget reloads have no waiter from which to recover their manual
// intent after a mutation or presentation defers them. Keep that intent with
// the owed snapshot so a manual request still clears a prior connection retry
// latch when the blocker ends.
struct V3SnapshotOwedIntent: Equatable {
    private(set) var isOwed = false
    private(set) var requiresManualSnapshot = false

    mutating func record(manual: Bool) {
        isOwed = true
        requiresManualSnapshot = requiresManualSnapshot || manual
    }

    mutating func clear() {
        isOwed = false
        requiresManualSnapshot = false
    }
}

// V3_SOURCE_EDITING_POLICY_V1
// Issue #40: the Add Source field had no focus state and no explicit dismissal,
// so Return was the only way out of the keyboard and read as a submit action.
// The cancel semantics are stated here so they are executable and testable:
// Cancel restores the URL that was present when editing began, and neither
// Cancel nor Done may preview, request, or persist anything.
enum V3SourceEditingOutcome: Equatable {
    case dismissed
    case restored(String)
}

struct V3SourceFormState: Equatable {
    var isPresented: Bool
    var url: String
    var originalURL: String
    var isFocused: Bool
    var hasPreview: Bool
}

enum V3SourceFormEffect: Equatable {
    case preview
    case validate
    case persist
}

struct V3SourceFormTransition: Equatable {
    var state: V3SourceFormState
    var effects: [V3SourceFormEffect]
}

struct V3SourcePreviewRequest: Equatable {
    let generation: UInt64
    let targetURL: String
}

struct V3SourcePreviewSession {
    private(set) var generation: UInt64 = 0
    private(set) var activeRequest: V3SourcePreviewRequest?

    mutating func begin(targetURL: String) -> V3SourcePreviewRequest? {
        guard !targetURL.isEmpty else { return nil }
        generation &+= 1
        let request = V3SourcePreviewRequest(generation: generation, targetURL: targetURL)
        activeRequest = request
        return request
    }

    mutating func invalidate() {
        generation &+= 1
        activeRequest = nil
    }

    func mayApply(_ request: V3SourcePreviewRequest, currentURL: String,
                  formPresented: Bool) -> Bool {
        formPresented && activeRequest == request && generation == request.generation &&
            currentURL == request.targetURL
    }

    static func responseRow(_ payload: [String: Any], for request: V3SourcePreviewRequest) -> [String: Any] {
        var row = payload
        row["url"] = request.targetURL
        return row
    }
}

struct V3SourceFormOpenRequestLedger {
    private(set) var lastClaimedRequestID: UUID?

    mutating func claim(_ requestID: UUID?) -> Bool {
        guard let requestID, requestID != lastClaimedRequestID else { return false }
        lastClaimedRequestID = requestID
        return true
    }
}

enum V3SourceEditingPolicy {
    static func canCancelForm(isAdding: Bool) -> Bool { !isAdding }

    /// Done: a pure UI dismissal. The typed value is kept.
    static func done(typed: String) -> V3SourceEditingOutcome { .dismissed }

    /// Cancel: restore the pre-edit value, so a URL is never silently discarded
    /// and a later focus always starts from a predictable value.
    static func cancel(typed: String, beforeEditing: String) -> V3SourceEditingOutcome {
        .restored(beforeEditing)
    }

    /// The value the field should hold after the outcome is applied.
    static func resolved(_ outcome: V3SourceEditingOutcome, typed: String) -> String {
        switch outcome {
        case .dismissed: return typed
        case .restored(let value): return value
        }
    }

    /// Closing Add Source is a UI-only transition. It restores the value that
    /// was present when the form opened and cannot request preview, validation,
    /// or persistence work.
    static func closeForm(_ current: V3SourceFormState) -> V3SourceFormTransition {
        V3SourceFormTransition(
            state: V3SourceFormState(
                isPresented: false,
                url: current.originalURL,
                originalURL: current.originalURL,
                isFocused: false,
                hasPreview: false),
            effects: [])
    }
}

// V3_SETUP_COMPLETION_POLICY_V1
// One authority for "is setup finished". Home and the Setup Assistant each used
// their own rule, so Home could stop showing "Finish Setup" while the assistant
// still considered setup incomplete. Two authorities for one product state is
// the defect; this type removes the possibility of disagreement by having exactly
// one decision, consumed by both, and by reporting which item is outstanding
// rather than a bare boolean.
// V3_INSTALLED_HOST_SIGNING_V1: local compatibility is a current observation,
// separate from successful refresh history and the imported JIT-Less copy.
// It does not establish portal revocation status or exact signing provenance.
enum V3HostSigningState: String, Equatable, Sendable {
    case unknown, compatible, refreshRequired, paidSignerUnverified

    var detail: String {
        switch self {
        case .unknown:
            return "Installed host signing could not be checked. Reload Status to check again." + "\nError ID: SS-VERIFY-D062"
        case .compatible:
            return "The installed host is locally compatible with the active signing setup. Revocation was not checked."
        case .refreshRequired:
            return "The installed host signing is expired or differs from the active setup. Run Test Refresh after completing account and certificate setup." + "\nError ID: SS-VERIFY-D063"
        case .paidSignerUnverified:
            return "The installed host uses a different paid-team signer. Its portal status was not checked; a re-sign is not known to be required. You can inspect Certificates or explicitly run Test Refresh."
        }
    }
}

struct V3HostSigningObservation: Equatable, Sendable {
    // Match the existing shared setup-fact observation interval.
    static let maximumAge: TimeInterval = 5 * 60
    var context = ""
    var state: V3HostSigningState = .unknown
    var checkedAt = Date.distantPast
    var validUntil = Date.distantPast

    func currentState(context: String?, now: Date = Date()) -> V3HostSigningState {
        guard let context, !context.isEmpty, self.context == context,
              now >= checkedAt, now < validUntil,
              now.timeIntervalSince(checkedAt) < Self.maximumAge else { return .unknown }
        return state
    }

    var wire: [String: Any] {
        ["context": context, "state": state.rawValue, "checkedAt": checkedAt, "validUntil": validUntil]
    }

    static func decode(_ value: Any?) -> V3HostSigningObservation? {
        guard let value = value as? [String: Any],
              let context = value["context"] as? String,
              context.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let rawState = value["state"] as? String, let state = V3HostSigningState(rawValue: rawState),
              let checkedAt = value["checkedAt"] as? Date,
              let validUntil = value["validUntil"] as? Date,
              checkedAt.timeIntervalSince1970.isFinite, validUntil.timeIntervalSince1970.isFinite,
              validUntil <= checkedAt.addingTimeInterval(maximumAge) else { return nil }
        return V3HostSigningObservation(context: context, state: state,
            checkedAt: checkedAt, validUntil: validUntil)
    }
}

enum V3SetupOutstandingItem: String, Equatable, CaseIterable {
    case account
    case provisioning
    case pairing
    case jitless
    case network
    case tunnel
    case backgroundRefresh
    case schedule
    case verifiedRefresh
    case installedHostSigning

    /// User-facing label, so the UI can name the outstanding step.
    var title: String {
        switch self {
        case .account: return "Sign in with your Apple ID"
        case .provisioning: return "Finish device provisioning"
        case .pairing: return "Add a pairing file"
        case .jitless: return "Configure the JIT-Less certificate"
        case .network: return "Connect to Wi-Fi"
        case .tunnel: return "Enable LocalDevVPN"
        case .backgroundRefresh: return "Allow Background App Refresh"
        case .schedule: return "Enable scheduled refresh"
        case .verifiedRefresh: return "Run one verified refresh"
        case .installedHostSigning: return "Check installed host signing"
        }
    }
}

struct V3SetupCompletionInputs: Equatable {
    var accountComplete = false
    var provisioningIncomplete = false
    var pairingSatisfied = false
    var jitlessRequired = false
    var jitlessComplete = false
    var networkComplete = false
    var tunnelComplete = false
    var backgroundRefreshAvailable = false
    var scheduleEnabled = false
    var verifiedRefreshPresent = false
    var installedHostSigningCompatible = false

    /// The only legal way to decide whether setup is finished.
    func outstanding() -> [V3SetupOutstandingItem] {
        var items: [V3SetupOutstandingItem] = []
        if !accountComplete { items.append(.account) }
        if provisioningIncomplete { items.append(.provisioning) }
        if !pairingSatisfied { items.append(.pairing) }
        // JIT-Less is only a prerequisite where the platform requires it.
        if jitlessRequired && !jitlessComplete { items.append(.jitless) }
        if !networkComplete { items.append(.network) }
        if !tunnelComplete { items.append(.tunnel) }
        if !backgroundRefreshAvailable { items.append(.backgroundRefresh) }
        if !scheduleEnabled { items.append(.schedule) }
        if !verifiedRefreshPresent { items.append(.verifiedRefresh) }
        if !installedHostSigningCompatible { items.append(.installedHostSigning) }
        return items
    }

    var isComplete: Bool { outstanding().isEmpty }
}

// V3_FAILURE_GUIDANCE_V1
// A failure that reached a view as an untyped error was displayed as
// error.localizedDescription. That publishes whatever text the service happened
// to attach, which for a bridged NSError includes its numeric domain and code
// and means nothing to a user, and it offered no guidance at all. Every
// user-visible failure message now comes from here.
//
// A typed CombinedFailure keeps its own product recovery copy. An untyped error
// cannot be attributed to a cause, so the guidance deliberately does not guess
// one: it says what is known, and it points at the diagnostics that can identify
// it. The unreadable text is kept out of the interface and offered through
// Copy Diagnostics instead.
enum V3FailureGuidance {
    static func message(_ error: Error) -> String {
        if let combined = error as? CombinedFailure {
            return combined.recovery + "\n" + combined.diagnosticLabel
        }
        // The earlier wording asserted "and nothing was changed". Nothing
        // supports that: an untyped failure can arrive after the service applied
        // the request, and the same helper is used after settings writes, source
        // confirmation, pairing import and install staging. Claiming a known
        // side-effect from an unknown cause is the same class of error as
        // blaming the network, so the claim is removed and the outcome is stated
        // as unknown.
        return "That action did not complete, and whether it took effect is not known. Reload status to see the current state before trying again. If it keeps failing, copy diagnostics to identify the cause.\nError ID: SS-CMD-C11"
    }

    /// Privacy-safe diagnostic text, never shown as guidance.
    static func diagnostics(_ error: Error) -> String {
        if let combined = error as? CombinedFailure {
            return combined.technicalDetails
        }
        let nsError = error as NSError
        let underlying = CombinedFailure.safeDiagnosticUnderlying(domain: nsError.domain,
            code: nsError.code)
        return "diagnostic_code=SS-CMD-C11 builder_commit=\(V3DiagnosticBuild.commit) operation=untyped stage=command code=failed underlying_domain=\(underlying.domain) underlying_code=\(underlying.code)"
    }
}

// V3_RESPONSE_CLASSIFICATION_CARRIER_V1
// The service's reply encoder and the host's reply classifier are separated by
// a property-list boundary, and the classification of a reply the service could
// not deliver has to survive that boundary. It previously did not: the service
// wrote the specific token under a legacy "error" key and a cause-less
// structured "failure", and the host prefers the structured envelope, so every
// encoding failure arrived as a generic invalidResponse.
//
// Both halves live here, as pure functions, so the pair can be executed together
// against real property-list bytes rather than asserted about in source text.
// The host still prefers the structured envelope; the classification simply
// travels inside it now, and the legacy token remains for an older host.
enum V3ResponseClassifier {
    /// The legacy string tokens a service may put in the "error" key.
    enum Token {
        static let encodingFailed = "responseEncodingFailed"
        static let tooLarge = "responseTooLarge"
    }

    /// The safe cause that carries a token's classification across the wire.
    static func safeCause(for token: String) -> CombinedFailure.SafeCause? {
        switch token {
        case Token.encodingFailed: return .responseEncodingFailed
        case Token.tooLarge: return .responseTooLarge
        default: return nil
        }
    }
}

// V3_RESPONSE_ENCODER_V1
// The service side of the classification pair. It is a separate enum rather than
// a private method so the harness can execute the real encoder, and it reads the
// shared responseLimit instead of repeating the literal.
struct V3EncodedServiceResponse {
    let data: Data
    let fallbackToken: String?
}

enum V3ResponseEncoder {
    /// Encodes a reply, or returns a correlated, typed fallback that says which
    /// of the two failure modes occurred.
    ///
    /// The limit is a parameter rather than a read of `V3WireContract` so this
    /// file stays independently compilable, exactly as the wire contract stays
    /// free of the error model. The caller passes the one shared constant, so
    /// the limit still has a single definition in production.
    static func encode(_ value: [String: Any], operation: String = "command",
                       limit: Int) -> Data {
        encodeDetailed(value, operation: operation, limit: limit).data
    }

    /// Returns a safe fallback marker with the data so the service can log
    /// classification without parsing every successful serialized reply.
    static func encodeDetailed(_ value: [String: Any], operation: String = "command",
                               limit: Int) -> V3EncodedServiceResponse {
        let correlationID = value["id"] as? String ?? ""
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            guard data.count <= limit else {
                return V3EncodedServiceResponse(data: fallback(id: correlationID, operation: operation,
                                token: V3ResponseClassifier.Token.tooLarge,
                                code: .invalidResponse,
                                safeCause: V3ResponseClassifier.safeCause(for: V3ResponseClassifier.Token.tooLarge)),
                    fallbackToken: V3ResponseClassifier.Token.tooLarge)
            }
            return V3EncodedServiceResponse(data: data, fallbackToken: nil)
        } catch {
            return V3EncodedServiceResponse(data: fallback(id: correlationID, operation: operation,
                            token: V3ResponseClassifier.Token.encodingFailed,
                            code: .invalidResponse,
                            safeCause: V3ResponseClassifier.safeCause(for: V3ResponseClassifier.Token.encodingFailed)),
                fallbackToken: V3ResponseClassifier.Token.encodingFailed)
        }
    }

    /// Builds a small, correlated, typed fallback reply. Always serializable
    /// because every value is a concrete String, Bool or Int.
    ///
    /// The reply deliberately carries BOTH the legacy "error" token and the
    /// structured "failure" envelope, because that is the shape production
    /// emits. The structured envelope is authoritative on the host, so the
    /// classification that survives is the safeCause set here.
    static func fallback(id: String, operation: String, token: String,
                         code: CombinedFailure.Code,
                         safeCause: CombinedFailure.SafeCause? = nil) -> Data {
        let value: [String: Any] = [
            "version": 1,
            "id": id,
            "error": token,
            "failure": CombinedFailure(operation: operation, stage: .replyEncoding, code: code,
                                       id: id, safeCause: safeCause).wire
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)) ?? Data()
    }
}

// V3_SHARED_JITLESS_FACT_V1
// Home and the Setup Assistant each decided JIT-Less completion separately. Home
// had no access to the certificate facts, so on the platforms that require
// JIT-Less it reported the item as permanently outstanding while the assistant,
// which had the real readiness, showed it complete. One observed readiness is
// now published and both surfaces read it.
//
// A nil readiness means "not observed yet", which counts as outstanding. Guessing
// "fine" there is what produced the original disagreement.
enum V3JITLessCompletionPolicy {
    static func isComplete(_ readiness: V3JITLessReadiness?) -> Bool {
        guard let readiness else { return false }
        return readiness.isReady
    }

    /// True where an unobserved JIT-Less state is still an outstanding item.
    static func isRequired(osMajor: Int) -> Bool { osMajor >= 26 }
}

enum V3SetupFactObservationPolicy {
    static let maximumAge: TimeInterval = 5 * 60

    static func shouldObserve(connected: Bool, setupPresented: Bool,
                              operationPresented: Bool, loading: Bool,
                              returnToSetupPending: Bool, lastAttemptAt: Date?,
                              now: Date = Date()) -> Bool {
        guard connected, !setupPresented, !operationPresented, !loading,
              !returnToSetupPending else { return false }
        guard let lastAttemptAt else { return true }
        guard lastAttemptAt <= now else { return false }
        return now.timeIntervalSince(lastAttemptAt) >= maximumAge
    }
}

enum V3SetupFactRevisionPolicy {
    static func mayApply(captured: UInt64, current: UInt64) -> Bool {
        captured == current
    }
}

// V3_HOST_SNAPSHOT_WAITER_LIFETIME_V1
// Snapshot callers may cancel while the shared service request must continue
// for other callers. This registry gives each waiter one removable identity and
// drains only the waiters that are still pending when the snapshot finishes.
struct V3SnapshotWaiterRegistry {
    private struct Waiter: Equatable {
        let manual: Bool
        let requiredSnapshotGeneration: UInt64
    }
    private var waitersByID: [UUID: Waiter] = [:]

    var isEmpty: Bool { waitersByID.isEmpty }
    var anyManualWaiter: Bool { waitersByID.values.contains(where: \.manual) }

    mutating func insert(_ id: UUID, manual: Bool,
                         requiredSnapshotGeneration: UInt64 = 0) {
        waitersByID[id] = Waiter(manual: manual,
                                 requiredSnapshotGeneration: requiredSnapshotGeneration)
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        waitersByID.removeValue(forKey: id) != nil
    }

    /// Take only callers whose freshness requirement is met by this snapshot.
    /// Waiters parked behind a blocker during an older in-flight snapshot remain
    /// registered until a later generation completes.
    mutating func take(throughSnapshotGeneration generation: UInt64) -> [UUID] {
        let ready = waitersByID.compactMap { id, waiter in
            waiter.requiredSnapshotGeneration <= generation ? id : nil
        }
        for id in ready { waitersByID.removeValue(forKey: id) }
        return ready
    }

    mutating func takeAll() -> [UUID] {
        let ids = Array(waitersByID.keys)
        waitersByID.removeAll(keepingCapacity: true)
        return ids
    }
}

/// Maps the gate decision to the minimum snapshot generation that can satisfy
/// the caller. A deferred request must not be released by a snapshot that began
/// before its mutation/presentation blocker ended.
enum V3SnapshotWaiterEpochPolicy {
    static func requiredGeneration(for decision: V3SnapshotDecision,
                                   currentGeneration: UInt64) -> UInt64 {
        switch decision {
        case .performSnapshot, .joinSnapshot, .doNotObserve:
            return currentGeneration
        case .awaitMutationThenSnapshot, .deferForPresentation, .stillBlocked:
            return currentGeneration &+ 1
        }
    }
}

enum V3SnapshotErrorPolicy {
    /// Cancellation is a local control-flow result, not evidence that the
    /// backend became disconnected.
    static func shouldMarkDisconnected(_ error: Error) -> Bool {
        !(error is CancellationError)
    }
}

// Health notifications can arrive while a request is in flight. Keep one
// pending rerun so a certificate update is observed after the current request.
struct V3HealthReloadQueue {
    private(set) var isChecking = false
    private(set) var rerunRequested = false

    mutating func request() -> Bool {
        guard !isChecking else {
            rerunRequested = true
            return false
        }
        isChecking = true
        return true
    }

    /// Returns true when exactly one queued request should run next.
    mutating func finishIteration() -> Bool {
        guard rerunRequested else {
            isChecking = false
            return false
        }
        rerunRequested = false
        return true
    }
}

enum V3RetryDisposition: Equatable {
    case allowed
    case unknown
    case prerequisite
    case blocked
}

enum V3CatalogRetryPresentation: Equatable {
    case retry
    case retryWithUnknownDisposition
    case reloadCatalog
    case noRetry
}

enum V3CatalogRetryPresentationPolicy {
    static func action(for disposition: V3RetryDisposition,
                       safeCause: String? = nil) -> V3CatalogRetryPresentation {
        if safeCause == CombinedFailure.SafeCause.catalogUnavailable.rawValue {
            return .reloadCatalog
        }
        switch disposition {
        case .allowed: return .retry
        case .unknown: return .retryWithUnknownDisposition
        case .prerequisite, .blocked: return .noRetry
        }
    }
}

// V3_REFRESH_PREREQUISITE_POLICY_V1
// One authoritative prerequisite contract for every refresh entry point. Home
// Refresh All, Setup Assistant Test Refresh, Refresh Manager Manual Refresh,
// and targeted per-app refresh all call this instead of re-deriving rules, so
// a prerequisite the host already knows about can never be reported later as
// "no safe underlying cause was available".
//
// Two invariants are encoded here rather than at each call site.
// 1. The service's pairing status string is interpreted in exactly one place.
// 2. Only an authoritative "Pairing file required" blocks. "Unknown" (before
//    the first snapshot, or after a failed snapshot) does not block, so a host
//    restart can never permanently disable a correctly configured device.
//    Nothing is blocked on Wi-Fi, LocalDevVPN, or an account here: those are
//    not proven required for a refresh, and the scheduler already owns the
//    transport preflight for them.
enum V3RefreshPrerequisiteState: String, Equatable {
    case unknown
    case satisfied
    case unsatisfied
}

enum V3RefreshPrerequisiteKind: String, Equatable {
    case pairing
}

struct V3RefreshPrerequisite: Equatable {
    let state: V3RefreshPrerequisiteState
    let kind: V3RefreshPrerequisiteKind?
    let detail: String

    static let pairingRequiredDetail = "A valid pairing file is required before device refresh."

    private init(state: V3RefreshPrerequisiteState, kind: V3RefreshPrerequisiteKind?, detail: String) {
        self.state = state
        self.kind = kind
        self.detail = detail
    }

    static let unknown = V3RefreshPrerequisite(state: .unknown, kind: nil, detail: "")
    static let satisfied = V3RefreshPrerequisite(state: .satisfied, kind: nil, detail: "Pairing file available")
    static let pairingRequired = V3RefreshPrerequisite(state: .unsatisfied, kind: .pairing, detail: pairingRequiredDetail)

    /// The only interpretation of the authoritative pairing snapshot string.
    static func evaluate(pairingStatus: String?) -> V3RefreshPrerequisite {
        switch pairingStatus {
        case "Pairing file available": return .satisfied
        case "Pairing file required", "Pairing file invalid": return .pairingRequired
        default: return .unknown
        }
    }

    static func isConfirmed(pairingStatus: String?) -> Bool {
        evaluate(pairingStatus: pairingStatus).state == .satisfied
    }

    /// A cached pairing string is authoritative only while its snapshot is
    /// connected. After a failed snapshot, preserve the value for diagnostics
    /// but treat it as unknown for admission so stale state cannot block a run.
    static func evaluate(statusConnected: Bool, pairingStatus: String?) -> V3RefreshPrerequisite {
        guard statusConnected else { return .unknown }
        return evaluate(pairingStatus: pairingStatus)
    }

    var blocksRefresh: Bool { state == .unsatisfied }
    var blocksTargetedRefresh: Bool { blocksRefresh }
    var recoveryDestination: String? { kind == .pairing ? "pairing" : nil }
    var recoveryActionTitle: String? { kind == .pairing ? "Show Pairing Setup" : nil }
    var recommendedAction: String {
        kind == .pairing
            ? "Place or import a valid pairing file, then try again."
            : "Reload status, then try again."
    }

    /// The canonical structured failure for a blocked refresh. Minted only on
    /// demand so it can carry the caller's correlation ID.
    func failure(correlationID: String) -> CombinedFailure? {
        guard kind == .pairing else { return nil }
        return CombinedFailure(operation: "refresh", stage: .pairing, code: .notReady,
                               id: correlationID, retryable: false, safeCause: .pairingRequired)
    }
}

enum V3PairingPresentationPolicy {
    static func state(statusConnected: Bool, pairingStatus: String?) -> V3RefreshPrerequisiteState {
        V3RefreshPrerequisite.evaluate(statusConnected: statusConnected,
            pairingStatus: pairingStatus).state
    }

    /// A cached pairing value remains useful as history after a failed reload,
    /// but it must not look like a current authoritative result.
    static func displayText(statusConnected: Bool, pairingStatus: String) -> String {
        guard !statusConnected else { return pairingStatus }
        guard pairingStatus != "Unknown" else { return "Unknown" }
        return "Unknown (last known: \(pairingStatus))"
    }

    static func isConfirmed(statusConnected: Bool, pairingStatus: String?) -> Bool {
        state(statusConnected: statusConnected, pairingStatus: pairingStatus) == .satisfied
    }
}

enum V3IssueActionOutcomePolicy {
    /// Re-request actions dismiss the issue only when their request was
    /// accepted. A rejected retry replaces the alert with its current blocker.
    static func shouldDismiss(action: V3IssueAction, didStart: Bool) -> Bool {
        switch action {
        case .retrySource, .reloadSources: return didStart
        default: return true
        }
    }
}

struct V3OperationFailureDetails {
    let operation: String
    let stage: String
    let code: String
    let correlation: String
    let underlyingDomain: String
    let underlyingCode: Int
    let retryable: Bool?
    let safeCause: String?
    let sourceStep: String?
    let whatHappened: String
    let whatToDo: String
    let technical: String

    init(_ failure: CombinedFailure) {
        operation = failure.operation
        stage = failure.stage.rawValue
        code = failure.code.rawValue
        correlation = failure.correlationID
        underlyingDomain = failure.underlyingDomain
        underlyingCode = failure.underlyingCode
        retryable = failure.retryable
        safeCause = failure.safeCause?.rawValue
        sourceStep = failure.sourceStep?.rawValue
        whatHappened = failure.safeMessage
        whatToDo = failure.recovery
        technical = failure.technicalDetails
    }

    var retryDisposition: V3RetryDisposition {
        if safeCause == CombinedFailure.SafeCause.catalogSourceUnavailable.rawValue ||
           safeCause == CombinedFailure.SafeCause.responseEncodingFailed.rawValue ||
           safeCause == CombinedFailure.SafeCause.responseTooLarge.rawValue {
            return .blocked
        }
        if retryable == false { return .blocked }
        if stage == CombinedFailure.Stage.authentication.rawValue ||
           stage == CombinedFailure.Stage.filePreparation.rawValue ||
           safeCause == CombinedFailure.SafeCause.certificateUnavailable.rawValue ||
           safeCause == CombinedFailure.SafeCause.provisioningProfileUnavailable.rawValue ||
           safeCause == CombinedFailure.SafeCause.operationInProgress.rawValue ||
           safeCause == CombinedFailure.SafeCause.responseCapacityUnavailable.rawValue ||
           safeCause == CombinedFailure.SafeCause.authResponseCapacityUnavailable.rawValue {
            return .prerequisite
        }
        return retryable == true ? .allowed : .unknown
    }

    var recoveryDestination: String? {
        if operation == "source" ||
           [CombinedFailure.SafeCause.sourceNetworkFailure.rawValue,
            CombinedFailure.SafeCause.sourceInvalidManifest.rawValue,
            CombinedFailure.SafeCause.sourcePersistenceUnverified.rawValue,
            CombinedFailure.SafeCause.sourceInvalidURL.rawValue,
            CombinedFailure.SafeCause.sourceAddBusy.rawValue,
            CombinedFailure.SafeCause.catalogSourceUnavailable.rawValue].contains(safeCause ?? "") {
            return "sources"
        }
        if safeCause == CombinedFailure.SafeCause.pairingRequired.rawValue ||
           safeCause == CombinedFailure.SafeCause.invalidPairingFile.rawValue { return "pairing" }
        if safeCause == CombinedFailure.SafeCause.authResponseCapacityUnavailable.rawValue { return "signIn" }
        if stage == CombinedFailure.Stage.authentication.rawValue { return "signIn" }
        if stage == CombinedFailure.Stage.filePreparation.rawValue { return "ipa" }
        if safeCause == CombinedFailure.SafeCause.signingNetworkConnectionLost.rawValue ||
           safeCause == CombinedFailure.SafeCause.signingNetworkTimedOut.rawValue ||
           safeCause == CombinedFailure.SafeCause.signingNetworkUnavailable.rawValue {
            return "connection"
        }
        if stage == CombinedFailure.Stage.network.rawValue ||
           safeCause == CombinedFailure.SafeCause.networkConnectionLost.rawValue ||
           safeCause == CombinedFailure.SafeCause.networkTimedOut.rawValue ||
           safeCause == CombinedFailure.SafeCause.networkUnavailable.rawValue ||
           safeCause == CombinedFailure.SafeCause.signingNetworkConnectionLost.rawValue ||
           safeCause == CombinedFailure.SafeCause.signingNetworkTimedOut.rawValue ||
           safeCause == CombinedFailure.SafeCause.signingNetworkUnavailable.rawValue ||
           safeCause == CombinedFailure.SafeCause.wifiUnavailable.rawValue ||
           safeCause == CombinedFailure.SafeCause.localDevVPNUnavailable.rawValue {
            return "connection"
        }
        if sourceStep == CombinedFailure.SourceStep.certificateValidation.rawValue ||
           safeCause == CombinedFailure.SafeCause.certificateUnavailable.rawValue {
            return "certificates"
        }
        return nil
    }

    var recoveryActionTitle: String? {
        switch recoveryDestination {
        case "signIn": return "Open Account & Signing"
        case "ipa": return "Choose IPA Again"
        case "certificates": return "Open Certificates"
        case "connection": return "Open Connection Settings"
        case "pairing": return "Open Pairing File"
        case "sources": return "Open Sources"
        default: return nil
        }
    }

    var recommendedAction: String {
        if safeCause == CombinedFailure.SafeCause.appIDLimitReached.rawValue { return whatToDo }
        if safeCause == CombinedFailure.SafeCause.responseEncodingFailed.rawValue {
            return "Copy Diagnostics and report that the service could not encode its response. Repeating the same request will not help."
        }
        if safeCause == CombinedFailure.SafeCause.responseTooLarge.rawValue {
            return "Copy Diagnostics and report that the service reply exceeded the transfer limit. Repeating the same request will fail again."
        }
        if safeCause == CombinedFailure.SafeCause.catalogUnavailable.rawValue {
            return "Reload this source's catalog. If it still cannot be read, copy Diagnostics and report the local catalog failure."
        }
        if safeCause == CombinedFailure.SafeCause.responseCapacityUnavailable.rawValue ||
           safeCause == CombinedFailure.SafeCause.authResponseCapacityUnavailable.rawValue {
            return "Wait for SideStore to release earlier request results, reload status, then try again."
        }
        switch safeCause ?? "" {
        case CombinedFailure.SafeCause.sourceNetworkFailure.rawValue:
            return "Open Sources. Check the network, then retry adding the source."
        case CombinedFailure.SafeCause.sourceInvalidManifest.rawValue,
             CombinedFailure.SafeCause.sourceInvalidURL.rawValue:
            return "Open Sources and correct the source URL or manifest before retrying."
        case CombinedFailure.SafeCause.sourceBlocked.rawValue:
            return "Do not add this source. Verify with the provider that it is safe before trying again."
        case CombinedFailure.SafeCause.sourceChangedID.rawValue:
            return "Contact the source provider before removing the saved source or adding it again."
        case CombinedFailure.SafeCause.sourceDuplicate.rawValue:
            return "Open Sources and use the existing source. Remove it only after confirming which entry is correct."
        case CombinedFailure.SafeCause.sourceUnsupported.rawValue:
            return "Update SideStore or use a source format supported by this version."
        case CombinedFailure.SafeCause.sourceValidationFailed.rawValue:
            return "Ask the source provider to correct its metadata, then preview it again."
        case CombinedFailure.SafeCause.sourcePersistenceUnverified.rawValue:
            return "Open Sources and reload the list to see whether the source was saved before retrying."
        case CombinedFailure.SafeCause.sourceAddBusy.rawValue,
             CombinedFailure.SafeCause.sourceRemoveBusy.rawValue:
            return "Wait for SideStore's active request to finish, then open Sources and check the result."
        case CombinedFailure.SafeCause.catalogSourceUnavailable.rawValue:
            return "Open Sources to confirm the source is still added, then reopen its catalog."
        default: break
        }
        if operation == "source" ||
           sourceStep == CombinedFailure.SourceStep.sourceDownload.rawValue ||
           sourceStep == CombinedFailure.SourceStep.manifestParsing.rawValue {
            return "Open Sources and review the source request. Copy Diagnostics if the result remains unclear."
        }
        switch safeCause ?? "" {
        case CombinedFailure.SafeCause.responseCapacityUnavailable.rawValue:
            return "Wait for SideStore to release earlier request results, check the current state, then retry this action."
        case CombinedFailure.SafeCause.pairingRequired.rawValue:
            return "Add the pairing file, then start the refresh again."
        case CombinedFailure.SafeCause.invalidPairingFile.rawValue:
            return "Open Pairing File and replace the saved pairing record, then retry."
        case CombinedFailure.SafeCause.operationInProgress.rawValue:
            return "Wait for the active SideStore operation to finish, then start this action again."
        case CombinedFailure.SafeCause.staleRefreshAttempt.rawValue:
            return "This stale refresh request was not started. Return to Refresh and start a new refresh."
        case CombinedFailure.SafeCause.signingNetworkConnectionLost.rawValue:
            return "Your current connection may still be healthy. Retry once. If this happens again, open Connection Settings."
        case CombinedFailure.SafeCause.signingNetworkTimedOut.rawValue:
            return "The provisioning service timed out for this request. Retry once. If it happens again, open Connection Settings."
        case CombinedFailure.SafeCause.signingNetworkUnavailable.rawValue:
            return "The provisioning service could not be reached for this request. Retry once. If it happens again, open Connection Settings."
        default: break
        }
        switch recoveryDestination {
        case "signIn": return "Open Account & Signing and complete the required account step."
        case "ipa": return "Choose the IPA again so SideStore can stage a fresh copy."
        case "certificates": return "Open Certificates and review the active certificate and provisioning profile."
        case "setup": return "Open Health Check / Connection and restore the required connection."
        default:
            if retryable == false {
                return "This operation is not marked safe to retry. Check the app and signing status before running it again."
            }
            if retryable == nil {
                if !whatToDo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return whatToDo
                }
                return "The service could not determine whether retry is safe. Check the app and signing status before deciding to retry."
            }
            return whatToDo
        }
    }
}

struct V3OperationPromptFailureDetails {
    let failure: V3OperationFailureDetails
    let blocksResubmission: Bool

    init(_ combinedFailure: CombinedFailure) {
        let details = V3OperationFailureDetails(combinedFailure)
        failure = details
        blocksResubmission = details.retryDisposition != .allowed
    }
}

// Keeps the failed pipeline stage across a Retry transition. A failure while
// creating the next backend session is explicitly separate from pipeline failure.
struct V3OperationRetryContext {
    private(set) var previousFailure: V3OperationFailureDetails?
    private(set) var currentFailure: V3OperationFailureDetails?
    private(set) var retryCouldNotStart = false

    mutating func recordPipelineFailure(_ failure: CombinedFailure) {
        currentFailure = V3OperationFailureDetails(failure)
        retryCouldNotStart = false
    }

    mutating func beginRetry() {
        previousFailure = currentFailure
        currentFailure = nil
        retryCouldNotStart = false
    }

    mutating func operationStarted() {
        previousFailure = nil
        currentFailure = nil
        retryCouldNotStart = false
    }

    mutating func recordStartFailure(_ failure: CombinedFailure) {
        currentFailure = V3OperationFailureDetails(failure)
        retryCouldNotStart = true
    }

    mutating func reset() {
        previousFailure = nil
        currentFailure = nil
        retryCouldNotStart = false
    }

    var whatHappened: String {
        guard let currentFailure else { return "The operation failed." + "\nError ID: SS-CMD-D064" }
        guard retryCouldNotStart else { return currentFailure.whatHappened }
        if currentFailure.safeCause == CombinedFailure.SafeCause.operationInProgress.rawValue {
            if let previousFailure {
                return "The retry could not start because another SideStore operation is still active. Previous attempt: \(previousFailure.whatHappened)"
            }
            return "The operation could not start because another SideStore operation is still active." + "\nError ID: SS-CMD-D065"
        }
        if let previousFailure {
            if ["timedOut", "interrupted"].contains(currentFailure.code) {
                return "The retry could not be confirmed as started. The previous operation may still be active. Previous attempt: \(previousFailure.whatHappened)"
            }
            return "The retry could not start, so the app operation did not run. Previous attempt: \(previousFailure.whatHappened)"
        }
        if ["timedOut", "interrupted"].contains(currentFailure.code) {
            return "The operation could not be confirmed as started. It may still be active." + "\nError ID: SS-CMD-D066"
        }
        return "The operation could not start, so the app pipeline did not run." + "\nError ID: SS-CMD-D067"
    }

    var whatToDo: String {
        guard let currentFailure else { return "Review the operation and try again only when it is safe." }
        guard retryCouldNotStart else { return currentFailure.recommendedAction }
        if currentFailure.safeCause == CombinedFailure.SafeCause.operationInProgress.rawValue {
            return "Wait for the active SideStore operation to finish, then start a fresh attempt."
        }
        if previousFailure != nil {
            return "The retry could not start. \(currentFailure.recommendedAction)"
        }
        return "The operation could not start. \(currentFailure.recommendedAction)"
    }

    var technicalDetails: String {
        let current = currentFailure?.technical ?? "No structured failure record was returned."
        guard retryCouldNotStart, let previousFailure else { return current }
        return "retry_start_failure:\n\(current)\nprevious_attempt_failure:\n\(previousFailure.technical)"
    }

    var retryDisposition: V3RetryDisposition {
        guard let currentFailure else { return .unknown }
        return currentFailure.retryDisposition
    }
}

enum V3OperationRetrySafetyPolicy {
    enum Disposition: Equatable { case retry, alreadyCompleted, outcomeUnknown }

    static func canRetry(backendSettled: Bool?, outcomeUnknown: Bool) -> Bool {
        !outcomeUnknown && backendSettled == true
    }

    static func disposition(state: String?, backendSettled: Bool?, outcomeUnknown: Bool) -> Disposition {
        guard canRetry(backendSettled: backendSettled, outcomeUnknown: outcomeUnknown) else {
            return .outcomeUnknown
        }
        if state == "completed" { return .alreadyCompleted }
        guard ["failed", "cancelled", "requiresSource", "waitingForAuthentication"].contains(state ?? "") else {
            return .outcomeUnknown
        }
        return .retry
    }
}

enum V3OperationRetryButtonPolicy {
    static func title(state: String, retryDisposition: V3RetryDisposition) -> String {
        if state == "cancelled" { return "Retry" }
        return retryDisposition == .unknown ? "Retry (retryability unknown)" : "Retry"
    }
}

struct V3OperationCancellationPresentation: Equatable {
    let message: String
    let whatToDo: String
}

enum V3OperationCancellationPresentationPolicy {
    static func resolve(userRequested: Bool) -> V3OperationCancellationPresentation {
        V3OperationCancellationPresentation(
            message: userRequested ? "The operation was cancelled." : "The operation was cancelled before it finished.",
            whatToDo: userRequested
                ? "The backend confirmed it stopped. Retry when you are ready to run this action again."
                : "The backend confirmed it stopped. Retry if you still need to complete this action.")
    }
}

enum V3OperationMissingSessionPolicy {
    static func unknownTerminal(sessionID: String, knownStarted: Bool) -> [String: Any]? {
        guard knownStarted else { return nil }
        return ["session": sessionID, "state": "failed", "backendSettled": false,
                "outcomeUnknown": true, "stopConfirmed": false,
                "message": "The operation session is no longer available, so its device result cannot be confirmed." + "\nError ID: SS-CMD-D068"]
    }
}

enum V3OperationTerminalAcceptancePolicy {
    static func isSettledTerminal(state: String?, backendSettled: Bool?, stopConfirmed: Bool?,
                                  outcomeUnknown: Bool = false) -> Bool {
        guard !outcomeUnknown else { return false }
        guard ["completed", "failed", "cancelled", "requiresSource", "waitingForAuthentication"]
                .contains(state ?? "") else { return false }
        return backendSettled == true || stopConfirmed == true
    }
}

enum V3OperationCancellationOutcomePolicy {
    static func isCorrelated(expectedSessionID: String, replySessionID: String?) -> Bool {
        replySessionID == expectedSessionID
    }

    static func terminalState(expectedSessionID: String, replySessionID: String?,
                              state: String?, backendSettled: Bool?, stopConfirmed: Bool?,
                              outcomeUnknown: Bool) -> String? {
        guard isCorrelated(expectedSessionID: expectedSessionID, replySessionID: replySessionID),
              V3OperationTerminalAcceptancePolicy.isSettledTerminal(state: state,
                  backendSettled: backendSettled, stopConfirmed: stopConfirmed,
                  outcomeUnknown: outcomeUnknown) else { return nil }
        return state
    }

    static func shouldClearSessionHandle(currentSessionID: String?, expectedSessionID: String,
                                         replySessionID: String?, state: String?,
                                         backendSettled: Bool?, stopConfirmed: Bool?,
                                         outcomeUnknown: Bool) -> Bool {
        currentSessionID == expectedSessionID &&
            terminalState(expectedSessionID: expectedSessionID, replySessionID: replySessionID,
                state: state, backendSettled: backendSettled, stopConfirmed: stopConfirmed,
                outcomeUnknown: outcomeUnknown) != nil
    }
}

enum V3OperationCancellationReplyPolicy {
    static func shouldApplyPollState(userRequestedCancellation: Bool, nextState: String) -> Bool {
        !(userRequestedCancellation && ["working", "awaitingPrompt"].contains(nextState))
    }
}

enum V3OperationStartDispatchPolicy {
    static func provesNotDispatched(resultWasReturned: Bool) -> Bool {
        !resultWasReturned
    }
}

enum V3RefreshTerminalRecoveryPolicy {
    enum Action: Equatable {
        case finalizeVerified
        case finalizeFailed
        case markInterrupted
    }

    static func action(state: String, terminalIntent: String?, manifestIsComplete: Bool,
                       hostHandoffPending: Bool) -> Action? {
        guard !["completed", "failed"].contains(state) else { return nil }
        if terminalIntent == "verified" && manifestIsComplete { return .finalizeVerified }
        if terminalIntent == "failed" { return .finalizeFailed }
        if hostHandoffPending { return nil }
        return ["running", "verifying", "failing"].contains(state) ? .markInterrupted : nil
    }
}

struct V3RefreshRunIdentitySelection: Equatable {
    let runID: String
    let schedulerOwned: Bool

    static func select(schedulerRunID: String?, expectedRunID: String?,
                       activeRunID: String?, newRunID: String) -> Self? {
        if let schedulerRunID {
            guard let parsed = UUID(uuidString: schedulerRunID), parsed.uuidString == schedulerRunID,
                  expectedRunID == schedulerRunID, activeRunID == schedulerRunID else { return nil }
            return Self(runID: schedulerRunID, schedulerOwned: true)
        }
        // A direct AppIntent cannot borrow an active scheduler's run identity.
        guard activeRunID == nil else { return nil }
        guard let generated = UUID(uuidString: newRunID), generated.uuidString == newRunID else { return nil }
        return Self(runID: newRunID, schedulerOwned: false)
    }
}

enum V3DirectRefreshPreflightPolicy {
    static func isBlocked(activeRunID: String?, hostHandoffPending: Bool,
                          uncertainMutationRunID: String?) -> Bool {
        activeRunID != nil || hostHandoffPending || uncertainMutationRunID != nil
    }
}

enum V3DirectRefreshRunClaimPolicy {
    static let defaultsKey = "liveContainerAutoRefreshDirectRunClaim"

    static func isActive(runID: String?, deadline: Date?, now: Date = Date()) -> Bool {
        guard let runID, let parsed = UUID(uuidString: runID), parsed.uuidString == runID,
              let deadline else { return false }
        return deadline > now
    }
}

enum V3RequestRetirementPolicy {
    private static let sessionControls: Set<String> = [
        "opStart", "opPoll", "opAnswer", "opCancel", "backupResult",
        "authPoll", "authRespond"
    ]

    static func shouldRetireServiceIfRequestStaysPending(_ operation: String) -> Bool {
        !sessionControls.contains(operation)
    }
}

enum V3CancellationRecoveryReplyPolicy {
    // Late auth/session-creation replies are not passed through the original
    // result classifier after settlement. Keep their service-retirement timer;
    // ordinary one-shot mutation callbacks retain their terminal recovery path.
    static func mayCancelRetirement(operation: String, requestStillPending: Bool) -> Bool {
        if requestStillPending { return true }
        // A late auth reply has not passed the request's result classifier, so
        // retain recovery until bounded service retirement clears host owners.
        if ["authBegin", "authRetryProvisioning", "authCancel", "refreshAdmissionBegin"].contains(operation) {
            return false
        }
        return true
    }
}

enum V3IdleReadRetirementPolicy {
    static func shouldRetireService(operation: String, hostMutationActive: Bool,
                                    refreshAttemptActive: Bool) -> Bool {
        guard !hostMutationActive, !refreshAttemptActive else { return false }
        // A timed-out authPoll is one lost observation of a live session, not
        // evidence that the in-memory SignInOperation should be discarded.
        return operation != "authPoll"
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
struct V3BackupCallbackIdentity: Equatable, Sendable {
    let session: String
    let nonce: String
    let action: String

    init?(session: String, nonce: String, action: String) {
        guard UUID(uuidString: session)?.uuidString == session,
              UUID(uuidString: nonce)?.uuidString == nonce,
              ["backup", "restore"].contains(action) else { return nil }
        self.session = session; self.nonce = nonce; self.action = action
    }

    init?(_ raw: Any?) {
        guard let values = raw as? [String: String],
              Set(values.keys) == Set(["session", "nonce", "action"]),
              let session = values["session"], let nonce = values["nonce"],
              let action = values["action"] else { return nil }
        self.init(session: session, nonce: nonce, action: action)
    }

    var wire: [String: String] { ["session": session, "nonce": nonce, "action": action] }
    var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "v3Session", value: session),
         URLQueryItem(name: "v3Nonce", value: nonce),
         URLQueryItem(name: "v3Action", value: action)]
    }

    static func supports(kind: String, action: String) -> Bool {
        switch (kind, action) {
        case ("backup", "backup"), ("deactivate", "backup"),
             ("restore", "restore"), ("activate", "restore"): return true
        default: return false
        }
    }
}

struct V3BackupCallbackResult: Equatable, Sendable {
    let identity: V3BackupCallbackIdentity
    let succeeded: Bool

    init?(session: String, payload: [String: Any]) {
        guard Set(payload.keys) == Set(["nonce", "action", "result"]),
              let nonce = payload["nonce"] as? String,
              let action = payload["action"] as? String,
              let result = payload["result"] as? String,
              ["success", "failure"].contains(result),
              let identity = V3BackupCallbackIdentity(session: session, nonce: nonce, action: action)
        else { return nil }
        self.identity = identity; self.succeeded = result == "success"
    }

    // URLs come from outside the process. Reject ambiguous and unbound input;
    // external descriptions, error domains and codes never enter XPC or logs.
    init?(url: URL, expectedTargetBundleID: String) {
        guard url.absoluteString.utf8.count <= 8192,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "sidestore",
              components.host?.lowercased() == "appbackupresponse",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              ["/success", "/failure"].contains(components.path.lowercased()) else { return nil }
        let items = components.queryItems ?? []
        let allowed: Set<String> = ["targetBundleID", "v3Session", "v3Nonce", "v3Action",
                                    "errorDomain", "errorCode", "errorDescription"]
        guard items.count <= allowed.count, Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ allowed.contains($0.name) && $0.value != nil }) else { return nil }
        let values = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        guard !expectedTargetBundleID.isEmpty, values["targetBundleID"] == expectedTargetBundleID,
              let session = values["v3Session"], let nonce = values["v3Nonce"],
              let action = values["v3Action"] else { return nil }
        self.init(session: session, payload: ["nonce": nonce, "action": action,
            "result": components.path.lowercased() == "/success" ? "success" : "failure"])
    }

    var payload: [String: Any] {
        ["nonce": identity.nonce, "action": identity.action,
         "result": succeeded ? "success" : "failure"]
    }
}

enum V3ServiceMutationAdmissionPolicy {
    static func hasConflictingOperationMutation(operation: String, target: String,
                                                activeOperationID: String?,
                                                backupCallbackControl: Bool = false) -> Bool {
        guard let activeOperationID else { return false }
        return !(target == activeOperationID &&
            (["opPoll", "opAnswer", "opCancel"].contains(operation) ||
             (operation == "backupResult" && backupCallbackControl)))
    }

    static func admits(isMutation: Bool, anotherMutationActive: Bool,
                       authenticationActive: Bool, isAuthContinuation: Bool,
                       responseCapacityAvailable: Bool,
                       refreshActive: Bool = false,
                       isRefreshRelease: Bool = false) -> Bool {
        guard isMutation else { return true }
        guard !anotherMutationActive, responseCapacityAvailable else { return false }
        guard !refreshActive || isRefreshRelease else { return false }
        return !authenticationActive || isAuthContinuation
    }

    static func permitsAuthenticationControl(_ operation: String,
                                              ownsActiveSession: Bool,
                                              authenticationActive: Bool) -> Bool {
        if ["authBegin", "authRetryProvisioning"].contains(operation) {
            return V3AuthSessionAdmissionPolicy.mayStartNewSession(
                hasActiveSession: authenticationActive)
        }
        return ownsActiveSession && ["authRespond", "authCancel"].contains(operation)
    }

    static func ownsRefreshAdmissionControl(operation: String, target: String,
                                             activeRunID: String?, refreshAttemptActive: Bool,
                                             anotherHostMutationActive: Bool = false,
                                             userConfirmedReconciliation: Bool = false) -> Bool {
        if operation == "refreshAdmissionReconcile" {
            return userConfirmedReconciliation &&
                UUID(uuidString: target)?.uuidString == target
        }
        return ["refreshAdmissionBegin", "refreshAdmissionEnd"].contains(operation) &&
            refreshAttemptActive && !anotherHostMutationActive && !target.isEmpty && activeRunID == target
    }
}

enum V3ServiceMutationBusyCausePolicy {
    static func safeCause(operation: String, anotherMutationActive: Bool,
                          responseCapacityAvailable: Bool, refreshActive: Bool,
                          refreshRelease: Bool, authenticationActive: Bool,
                          isAuthContinuation: Bool) -> CombinedFailure.SafeCause {
        let ownershipConflict = anotherMutationActive || (refreshActive && !refreshRelease) ||
            (authenticationActive && !isAuthContinuation)
        if !ownershipConflict && !responseCapacityAvailable {
            return .responseCapacityUnavailable
        }
        if operation == "sourceRemoveConfirmed" { return .sourceRemoveBusy }
        return .operationInProgress
    }
}

enum V3KnownSourcePreflightPolicy {
    static let maximumAge: TimeInterval = 6 * 60 * 60

    static func shouldRefresh(hasCachedBlocklist: Bool, lastSuccessfulUpdate: Date?,
                              now: Date = Date(),
                              maximumAge: TimeInterval = V3KnownSourcePreflightPolicy.maximumAge) -> Bool {
        guard hasCachedBlocklist, let lastSuccessfulUpdate,
              lastSuccessfulUpdate <= now,
              maximumAge > 0 else { return true }
        return now.timeIntervalSince(lastSuccessfulUpdate) >= maximumAge
    }
}

enum V3OperationSessionCorrelationPolicy {
    static func requestSessionID(operation: String, target: String,
                                 payload: [String: Any]) -> String? {
        if operation == "opStart" { return payload["session"] as? String }
        if ["opPoll", "opAnswer", "opCancel", "backupResult"].contains(operation) {
            return target.isEmpty ? nil : target
        }
        return nil
    }

    static func matches(operation: String, target: String, requestedStartSession: String?,
                        resultSession: String?) -> Bool {
        guard ["opStart", "opPoll", "opAnswer", "opCancel", "backupResult"].contains(operation) else { return true }
        let expected = operation == "opStart" ? requestedStartSession : target
        guard let expected, !expected.isEmpty else { return false }
        return resultSession == expected
    }
}

struct V3ServiceRecoveryAdmissionDecision: Equatable {
    let recoveryControl: Bool
    let matchingPreparedStart: Bool
    let matchingPreparedReservation: Bool
    let blocksMutation: Bool
    let refreshRelease: Bool
}

enum V3ServiceRecoveryAdmissionPolicy {
    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func decide(operation: String, target: String, payload: [String: Any],
                       operationSessionID: String?, recovery: V3OperationRecoveryRecord?,
                       recoveryReadFailed: Bool, recoveryDiscardable: Bool = false,
                       refreshOwnerLost: Bool, backupCallbackControl: Bool = false) -> V3ServiceRecoveryAdmissionDecision {
        let refreshRecordMatches = recovery?.kind == "refreshAll" && recovery?.sessionID == target
        let refreshTerminalState = payload["state"] as? String
        let hasRefreshTerminal = ["completed", "failed", "notDispatched"].contains(refreshTerminalState ?? "")
        let userConfirmed = strictBoolean(payload["userConfirmed"]) == true
        let operationControl = recovery?.kind != "refreshAll" &&
            (((["opPoll", "opAnswer", "opCancel"].contains(operation) ||
               (operation == "backupResult" && backupCallbackControl)) &&
              operationSessionID == recovery?.sessionID) ||
             (operation == "opRecoveryReconcile" && target == recovery?.sessionID && userConfirmed))
        let refreshControl = refreshRecordMatches &&
            ((operation == "refreshAdmissionEnd" && hasRefreshTerminal) ||
             (operation == "refreshAdmissionReconcile" && userConfirmed))
        let unreadableRecoveryControl = operation == "recoveryDiscardUnreadable" &&
            recovery == nil && userConfirmed && (!recoveryReadFailed || recoveryDiscardable)
        let recoveryControl = operationControl || refreshControl || unreadableRecoveryControl
        let matchingPreparedStart = operation == "opStart" && recovery?.kind != "refreshAll" &&
            operationSessionID == recovery?.sessionID && payload["kind"] as? String == recovery?.kind &&
            recovery?.phase == .prepared
        let matchingPreparedReservation = operation == "opRecoveryPrepare" && recovery?.kind != "refreshAll" &&
            payload["session"] as? String == recovery?.sessionID && payload["kind"] as? String == recovery?.kind &&
            recovery?.phase == .prepared
        let blocksMutation = (recoveryReadFailed && !unreadableRecoveryControl) ||
            (recovery != nil && !recoveryControl && !matchingPreparedStart && !matchingPreparedReservation)
        let unreadableRefreshRelease = operation == "recoveryDiscardUnreadable" &&
            unreadableRecoveryControl && refreshOwnerLost
        let refreshRelease = unreadableRefreshRelease || (refreshRecordMatches &&
            ((operation == "refreshAdmissionEnd" && hasRefreshTerminal) ||
             (operation == "refreshAdmissionReconcile" && refreshOwnerLost && userConfirmed)))
        return V3ServiceRecoveryAdmissionDecision(recoveryControl: recoveryControl,
            matchingPreparedStart: matchingPreparedStart,
            matchingPreparedReservation: matchingPreparedReservation,
            blocksMutation: blocksMutation, refreshRelease: refreshRelease)
    }
}

enum V3OperationCancelKnownStartedPolicy {
    static func resolve(sessionID: String, hostReportedKnownStarted: Bool,
                        recovery: V3OperationRecoveryRecord?) -> Bool {
        guard let recovery, recovery.sessionID == sessionID,
              recovery.kind != "refreshAll" else { return hostReportedKnownStarted }
        return recovery.phase == .dispatched
    }
}

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
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// IPA bytes live only in a private directory inside the shared App Group.
// XPC carries a canonical UUID token; the service derives every path itself.
enum V3IPAStaging {
    private static let directoryComponents = ["Library", "Application Support", "LiveContainer", "V3IPAStaging"]
    /// The packaged group name, retained for diagnostics and for the packaged
    /// fallback ranking. It is never used as a fixed runtime group: a re-signed
    /// build may only be entitled to a team-suffixed variant, or to the group
    /// LiveContainer itself selected.
    static let sideStoreAppGroupIdentifier = V3SharedAppGroup.packagedGroup
    static let orphanRetention: TimeInterval = 24 * 60 * 60

    /// Staging, the secret handoff lock, the recovery journal, the service
    /// Keychain lock and the cross-process refresh store all resolve the group
    /// through V3SharedAppGroup, so they cannot end up in different containers.
    /// This entry point takes every input explicitly and never reads process
    /// state, so the same call with the same facts always yields the same
    /// container in both processes.
    static func sharedIdentity(selectedGroup: String? = nil,
                               inheritedGroup: String? = nil,
                               bundleInfo: [String: Any],
                               resolveContainer: (String) -> URL?) -> V3SharedAppGroup.Identity? {
        V3SharedAppGroup.identity(selectedGroup: selectedGroup, inheritedGroup: inheritedGroup,
                                  usesEnvironment: false, bundleInfo: bundleInfo,
                                  resolveContainer: resolveContainer)
    }

    static func sideStoreContainerRoot(bundleInfo: [String: Any],
                                       selectedGroup: String? = nil,
                                       resolveContainer: (String) -> URL?) -> URL? {
        sharedIdentity(selectedGroup: selectedGroup, bundleInfo: bundleInfo,
                       resolveContainer: resolveContainer)?.containerRoot
    }

    static func sideStoreContainerRoot(bundle: Bundle = .main,
                                       fileManager: FileManager = .default,
                                       selectedGroup: String? = nil) -> URL? {
        V3SharedAppGroup.runtimeIdentity(selectedGroup: selectedGroup, bundle: bundle,
                                         fileManager: fileManager)?.containerRoot
    }

    private final class CopyStatus: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        func markFailed() { lock.withLock { failed = true } }
        var didFail: Bool { lock.withLock { failed } }
    }

    static func canonicalToken(_ token: String) throws -> String {
        guard token.utf8.count == 36,
              let value = UUID(uuidString: token),
              value.uuidString.lowercased() == token else {
            throw CombinedIPAFileError(.invalidToken)
        }
        return token
    }

    static func stagingDirectory(containerRoot: URL) -> URL {
        directoryComponents.reduce(containerRoot.standardizedFileURL) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.standardizedFileURL
    }

    private static func ensureDirectory(containerRoot: URL, fileManager: FileManager) throws -> URL {
        let root = containerRoot.resolvingSymlinksInPath().standardizedFileURL
        let directory = stagingDirectory(containerRoot: root)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  directory.resolvingSymlinksInPath().standardizedFileURL == directory else {
                throw CombinedIPAFileError(.fileAccess)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return directory
        } catch let error as CombinedIPAFileError {
            throw error
        } catch {
            throw CombinedIPAFileError(.stagingFailed)
        }
    }

    private static func url(token: String, directory: URL) throws -> URL {
        let canonical = try canonicalToken(token)
        let candidate = directory.appendingPathComponent(canonical + ".ipa", isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory.standardizedFileURL,
              candidate.lastPathComponent == canonical + ".ipa" else {
            throw CombinedIPAFileError(.invalidToken)
        }
        return candidate
    }

    private static func requireRegularNonEmptyFile(_ file: URL, fileManager: FileManager) throws {
        do {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw CombinedIPAFileError(.missingFile)
            }
            guard (values.fileSize ?? 0) > 0 else { throw CombinedIPAFileError(.emptyFile) }
        } catch let error as CombinedIPAFileError {
            throw error
        } catch {
            throw CombinedIPAFileError(.missingFile)
        }
    }

    private static func removePartial(_ file: URL?, directory: URL?, fileManager: FileManager) {
        guard let file, let directory,
              file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink != true,
              file.resolvingSymlinksInPath().standardizedFileURL == file.standardizedFileURL else { return }
        try? fileManager.removeItem(at: file)
    }

    private static func copyLeaseURL(token: String, directory: URL) -> URL {
        directory.appendingPathComponent(token + ".lease", isDirectory: false)
    }

    /// A per-token flock survives actor/process scheduling and is released by
    /// the OS after a crash. Never wait for an active copy during orphan cleanup.
    private static func acquireCopyLease(token: String, directory: URL, create: Bool) throws -> Int32? {
        _ = try canonicalToken(token)
        let lease = copyLeaseURL(token: token, directory: directory)
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT | O_EXCL : 0)
        let descriptor = open(lease.path, flags, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if create { throw CombinedIPAFileError(.stagingFailed) }
            return nil
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(descriptor)
            if create { throw CombinedIPAFileError(.stagingFailed) }
            return nil
        }
        var opened = stat()
        var named = stat()
        // A writer may have paused between open and flock while a cleaner
        // acquired/unlinked the lease. It must not copy through that stale FD.
        guard fstat(descriptor, &opened) == 0, lstat(lease.path, &named) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              !create || fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            if create { throw CombinedIPAFileError(.stagingFailed) }
            return nil
        }
        return descriptor
    }

    private static func releaseCopyLease(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    /// Inputs are value snapshots: no store, picker, or mutable UI ownership
    /// crosses into this detached worker. Security scope and coordination stay
    /// inside stage() until the synchronous copy has fully returned.
    static func stageOffMainActor(sourceURL: URL, bookmark: Data? = nil, containerRoot: URL) async throws -> String {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let token = try stage(sourceURL: sourceURL, bookmark: bookmark, containerRoot: containerRoot)
            guard !Task.isCancelled else {
                // Cancellation cannot interrupt FileManager.copyItem safely.
                // This token has no host/service owner until we return it.
                try? cleanup(token: token, containerRoot: containerRoot)
                throw CancellationError()
            }
            return token
        }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    /// Only for a completed token which was never handed to an install attempt.
    /// Active or terminal backend tokens still use the service lease checks.
    static func cleanupUnclaimedOffMainActor(token: String, containerRoot: URL) async {
        await Task.detached(priority: .utility) {
            try? cleanup(token: token, containerRoot: containerRoot)
        }.value
    }

    static func stage(sourceURL: URL, bookmark: Data? = nil, containerRoot: URL,
                      fileManager: FileManager = .default) throws -> String {
        var source = sourceURL
        if let bookmark {
            var stale = false
            do {
                source = try URL(resolvingBookmarkData: bookmark, options: .withoutUI,
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                throw CombinedIPAFileError(.fileAccess)
            }
            _ = stale // A stale bookmark is usable only for this immediate copy.
        }
        guard source.isFileURL, source.pathExtension.lowercased() == "ipa" else {
            throw CombinedIPAFileError(.invalidPackage)
        }

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var partialDirectory: URL?
        var partialDestination: URL?
        do {
            let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard sourceValues.isSymbolicLink != true, sourceValues.isRegularFile == true else { throw CombinedIPAFileError(.fileAccess) }
            guard (sourceValues.fileSize ?? 0) > 0 else { throw CombinedIPAFileError(.emptyFile) }
            let directory = try ensureDirectory(containerRoot: containerRoot, fileManager: fileManager)
            partialDirectory = directory
            let token = UUID().uuidString.lowercased()
            let destination = try url(token: token, directory: directory)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw CombinedIPAFileError(.stagingFailed)
            }
            // An in-flight copy is not a published IPA token. In particular,
            // an old source mtime must not let orphan pruning delete a file
            // while the provider/FileManager is still writing it.
            let partial = directory.appendingPathComponent(token + ".partial", isDirectory: false)
            guard !fileManager.fileExists(atPath: partial.path) else {
                throw CombinedIPAFileError(.stagingFailed)
            }
            guard let lease = try acquireCopyLease(token: token, directory: directory, create: true) else {
                throw CombinedIPAFileError(.stagingFailed)
            }
            defer {
                // Keep the lease if cleanup still owes a partial file. A later
                // orphan pass can reclaim both after proving no process owns it.
                if !fileManager.fileExists(atPath: partial.path) {
                    try? fileManager.removeItem(at: copyLeaseURL(token: token, directory: directory))
                }
                releaseCopyLease(lease)
            }
            partialDestination = partial
            defer { removePartial(partialDestination, directory: partialDirectory, fileManager: fileManager) }
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            let copyStatus = CopyStatus()
            coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
                do { try fileManager.copyItem(at: readableURL, to: partial) }
                catch { copyStatus.markFailed() }
            }
            guard coordinationError == nil, !copyStatus.didFail else { throw CombinedIPAFileError(.stagingFailed) }
            try fileManager.setAttributes([.posixPermissions: 0o600, .modificationDate: Date()],
                                          ofItemAtPath: partial.path)
            try requireRegularNonEmptyFile(partial, fileManager: fileManager)
            try fileManager.moveItem(at: partial, to: destination)
            partialDestination = nil
            return token
        } catch let error as CombinedIPAFileError {
            removePartial(partialDestination, directory: partialDirectory, fileManager: fileManager)
            throw error
        } catch {
            removePartial(partialDestination, directory: partialDirectory, fileManager: fileManager)
            throw CombinedIPAFileError(.stagingFailed)
        }
    }

    static func resolve(token: String, containerRoot: URL,
                        fileManager: FileManager = .default) throws -> URL {
        let directory = try ensureDirectory(containerRoot: containerRoot, fileManager: fileManager)
        let file = try url(token: token, directory: directory)
        try requireRegularNonEmptyFile(file, fileManager: fileManager)
        guard file.resolvingSymlinksInPath().standardizedFileURL == file else {
            throw CombinedIPAFileError(.missingFile)
        }
        return file
    }

    static func cleanup(token: String, containerRoot: URL,
                        fileManager: FileManager = .default) throws {
        let directory = try ensureDirectory(containerRoot: containerRoot, fileManager: fileManager)
        let file = try url(token: token, directory: directory)
        guard fileManager.fileExists(atPath: file.path) else { return }
        do {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true,
                  file.resolvingSymlinksInPath().standardizedFileURL == file else {
                throw CombinedIPAFileError(.fileAccess)
            }
            try fileManager.removeItem(at: file)
        } catch let error as CombinedIPAFileError {
            throw error
        } catch {
            throw CombinedIPAFileError(.fileAccess)
        }
    }

    /// Recover canonical IPA files absent from the ownership snapshot, plus
    /// abandoned partial-copy records whose per-token lease can be acquired.
    /// Age alone never establishes that a copy or backend token is unowned.
    @discardableResult
    static func cleanupOrphans(containerRoot: URL, preservingTokens: Set<String>, now: Date = Date(),
                               fileManager: FileManager = .default) throws -> Int {
        let directory = try ensureDirectory(containerRoot: containerRoot, fileManager: fileManager)
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
        } catch {
            throw CombinedIPAFileError(.stagingFailed)
        }
        var removed = 0
        for file in files {
            guard file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { continue }
            if file.pathExtension == "lease" {
                let token = file.deletingPathExtension().lastPathComponent
                guard (try? canonicalToken(token)) == token, !preservingTokens.contains(token),
                      let lease = try acquireCopyLease(token: token, directory: directory, create: false) else { continue }
                defer { releaseCopyLease(lease) }
                // Re-read age after taking the lock, and only touch a sibling
                // regular partial belonging to this exact canonical token.
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) >= orphanRetention else { continue }
                let partial = directory.appendingPathComponent(token + ".partial", isDirectory: false)
                do {
                    if fileManager.fileExists(atPath: partial.path) {
                        let partialValues = try partial.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard partialValues.isRegularFile == true, partialValues.isSymbolicLink != true,
                              partial.resolvingSymlinksInPath().standardizedFileURL == partial else { continue }
                        try fileManager.removeItem(at: partial)
                    }
                    try fileManager.removeItem(at: file)
                    removed += 1
                } catch { continue }
                continue
            }
            guard file.pathExtension == "ipa" else { continue }
            let token = file.deletingPathExtension().lastPathComponent
            guard (try? canonicalToken(token)) == token,
                  !preservingTokens.contains(token),
                  !fileManager.fileExists(atPath: copyLeaseURL(token: token, directory: directory).path),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) >= orphanRetention,
                  file.resolvingSymlinksInPath().standardizedFileURL == file.standardizedFileURL else { continue }
            do {
                try fileManager.removeItem(at: file)
                removed += 1
            } catch {
                // One undeletable orphan must not block staging or cleanup for
                // the remaining canonical files.
                continue
            }
        }
        return removed
    }

    static func inspect<T>(token: String, containerRoot: URL,
                           fileManager: FileManager = .default,
                           readMetadata: (URL) throws -> T) throws -> T {
        let file = try resolve(token: token, containerRoot: containerRoot, fileManager: fileManager)
        do { return try readMetadata(file) }
        catch let error as CombinedIPAFileError { throw error }
        catch { throw CombinedIPAFileError(.invalidPackage) }
    }
}

// V3_SIDESTORE_COMMAND_SERVICE_V1
// Compiled only into SideStore. No managed objects cross XPC. Only allow-listed
// transient secrets cross, including explicit bounded active-certificate export.
// V3_HEADLESS_SERVICE_V2: headless backend. This file owns the command gate,
// snapshots, and non-interactive reads. All interactive work runs through
// V3HeadlessRuntime sessions; no window, presenter, or visible UI exists here.
// V3_CERTIFICATE_CREATE_ADAPTER_V1: use the upstream portal and persistence
// implementations, but make their non-throwing persistence contract explicit
// at the v3 boundary. Certificate creation must never implicitly activate it.
enum V3CertificateCreateAdapter {
    enum Outcome: String {
        case createdAndStored
        case remoteCreatedLocalStorageUnverified
    }

    static func createAndPersist<Certificate>(
        create: () async throws -> Certificate,
        persist: (Certificate) -> Void,
        verifyStored: (Certificate) -> Bool
    ) async throws -> Outcome {
        let certificate = try await create()
        persist(certificate)
        return verifyStored(certificate) ? .createdAndStored : .remoteCreatedLocalStorageUnverified
    }

    static func matchesStoredCertificate(expectedSerial: String, parsedSerial: String?,
                                         enumeratedSerials: [String]) -> Bool {
        guard !expectedSerial.isEmpty, let parsedSerial, !parsedSerial.isEmpty,
              expectedSerial == parsedSerial else { return false }
        return enumeratedSerials.contains(expectedSerial)
    }
}

// V3_ACTIVE_CERTIFICATE_EXPORT_V1: export only the upstream active certificate
// tuple to the host's explicit, request-owned import flow. This does not read or
// write another Keychain group and never places private material in diagnostics.
enum V3ActiveCertificateExportAdapter {
    static let maximumP12Bytes = 1_048_576
    static let maximumPasswordBytes = 512

    static func response(p12Data: Data, password: String, teamIdentifier: String,
                         identitySHA256: String) -> [String: Any]? {
        guard !p12Data.isEmpty, p12Data.count <= maximumP12Bytes,
              password.utf8.count <= maximumPasswordBytes,
              !teamIdentifier.isEmpty, teamIdentifier.utf8.count <= 64,
              identitySHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return nil
        }
        return ["data": p12Data, "password": password,
                "teamIdentifier": teamIdentifier, "identitySHA256": identitySHA256]
    }
}

// V3_OPERATION_RECOVERY_JOURNAL_V1
// Shared by LiveContainer's App Group and this service process. Serialization
// uses the existing process-shared App Group lock; the record stores only IDs
// and fixed allow-listed markers.
private enum V3DirectMutationRecoveryPhase: String {
    case prepared, dispatched, terminal, unknown
}

private enum V3DirectMutationRecoveryHash {
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct V3DirectMutationRecoveryRecord {
    let requestID: String
    let operation: String
    let phase: V3DirectMutationRecoveryPhase
    let serviceInstanceID: String
    let targetDigest: String?
    let teamDigest: String?
    let identityStampDigest: String?
    let settingsKey: String?
    let settingsType: String?
    let settingsBool: Bool?
    let settingsInt: Int?
    // Accepted for records written by earlier v3.0.3 candidates. New writes
    // omit this field, but retaining it prevents an upgrade from making a
    // valid unresolved request look corrupt.
    let settingsValueDigest: String?
    let terminalOutcome: String?

    // Scope classification: certSetActive/certDelete are local desired-state
    // writes with certList/snapshot readback; signOut has checked keychain and
    // identity-snapshot postconditions; syncAppIDs/refreshSources have callback
    // completion plus developer/source-list readback; clearCache is repeatable;
    // JIT is repeatable enable but still needs device-side verification. SideSign
    // and Anisette replace/reset operations expose getters for readback. These
    // are not covered by this lease and must not be added without their own
    // reconciliation rule. accountImport has an identity-transition wrapper
    // but no idempotency key or durable postcondition, so it is included as a
    // manual-check-only operation. Long auth/op/refresh flows retain their
    // session-owned recovery paths.
    static let allowedOperations: Set<String> = [
        "certCreate", "certRevoke", "sourceAddConfirmed", "sourceRemoveConfirmed",
        "pairingImportData", "settingsSet", "accountImport"
    ]

    static func isEligible(request: [String: Any]) -> Bool {
        guard let operation = request["operation"] as? String,
              allowedOperations.contains(operation) else { return false }
        guard operation == "settingsSet" else { return true }
        let payload = request["payload"] as? [String: Any] ?? [:]
        guard let key = payload["key"] as? String, let type = payload["type"] as? String else { return false }
        switch type {
        case "bool":
            return (V3BackendCommands.boolSettings.contains(key) || key == "widgetVerboseLogging") &&
                V3WireContract.strictBool(payload["bool"]) != nil
        case "int":
            return V3BackendCommands.intSettings.contains(key) && V3WireContract.strictInt(payload["int"]) != nil
        case "string":
            return V3BackendCommands.stringSettings.contains(key) && payload["string"] is String
        default: return false
        }
    }

    init?(requestID: String, operation: String, phase: V3DirectMutationRecoveryPhase,
          serviceInstanceID: String, targetDigest: String? = nil, teamDigest: String? = nil,
          identityStampDigest: String? = nil,
          settingsKey: String? = nil,
          settingsType: String? = nil, settingsBool: Bool? = nil, settingsInt: Int? = nil,
          settingsValueDigest: String? = nil,
          terminalOutcome: String? = nil) {
        guard UUID(uuidString: requestID)?.uuidString == requestID,
              Self.allowedOperations.contains(operation),
              UUID(uuidString: serviceInstanceID)?.uuidString == serviceInstanceID,
              targetDigest.map({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) ?? true,
              teamDigest.map({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) ?? true,
              identityStampDigest.map({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) ?? true,
              settingsKey.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
              settingsType.map({ ["bool", "int", "string"].contains($0) }) ?? true,
              settingsValueDigest.map({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) ?? true,
              terminalOutcome.map({ ["completed", "createdAndStored", "remoteCreatedLocalStorageUnverified"].contains($0) }) ?? true else {
            return nil
        }
        if operation == "settingsSet" {
            guard settingsKey != nil, settingsType != nil else { return nil }
            switch settingsType {
            case "bool": guard settingsBool != nil, settingsInt == nil, settingsValueDigest == nil else { return nil }
            case "int": guard settingsInt != nil, settingsBool == nil, settingsValueDigest == nil else { return nil }
            case "string": guard settingsBool == nil, settingsInt == nil else { return nil }
            default: return nil
            }
        } else if settingsKey != nil || settingsType != nil || settingsBool != nil ||
                    settingsInt != nil || settingsValueDigest != nil {
            return nil
        }
        if operation != "certRevoke", (teamDigest != nil || identityStampDigest != nil) { return nil }
        if phase == .terminal {
            guard terminalOutcome != nil else { return nil }
        } else if terminalOutcome != nil {
            return nil
        }
        self.requestID = requestID
        self.operation = operation
        self.phase = phase
        self.serviceInstanceID = serviceInstanceID
        self.targetDigest = targetDigest
        self.teamDigest = teamDigest
        self.identityStampDigest = identityStampDigest
        self.settingsKey = settingsKey
        self.settingsType = settingsType
        self.settingsBool = settingsBool
        self.settingsInt = settingsInt
        self.settingsValueDigest = settingsValueDigest
        self.terminalOutcome = terminalOutcome
    }

    var propertyListRepresentation: [String: Any] {
        var value: [String: Any] = ["version": 2, "recordType": "directMutation",
            "requestID": requestID, "operation": operation, "phase": phase.rawValue,
            "serviceInstanceID": serviceInstanceID]
        if let targetDigest { value["targetDigest"] = targetDigest }
        if let teamDigest { value["teamDigest"] = teamDigest }
        if let identityStampDigest { value["identityStampDigest"] = identityStampDigest }
        if let settingsKey { value["settingsKey"] = settingsKey }
        if let settingsType { value["settingsType"] = settingsType }
        if let settingsBool { value["settingsBool"] = settingsBool }
        if let settingsInt { value["settingsInt"] = settingsInt }
        if let settingsValueDigest { value["settingsValueDigest"] = settingsValueDigest }
        if let terminalOutcome { value["terminalOutcome"] = terminalOutcome }
        return value
    }

    static func decode(_ value: Any) -> V3DirectMutationRecoveryRecord? {
        guard let plist = value as? [String: Any],
              let version = plist["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 2,
              plist["recordType"] as? String == "directMutation",
              let requestID = plist["requestID"] as? String,
              let operation = plist["operation"] as? String,
              let phaseRaw = plist["phase"] as? String,
              let phase = V3DirectMutationRecoveryPhase(rawValue: phaseRaw),
              let serviceInstanceID = plist["serviceInstanceID"] as? String else { return nil }
        let allowed: Set<String> = ["version", "recordType", "requestID", "operation", "phase",
            "serviceInstanceID", "targetDigest", "settingsKey", "settingsType", "settingsBool",
            "settingsInt", "settingsValueDigest", "terminalOutcome", "teamDigest", "identityStampDigest"]
        guard Set(plist.keys).isSubset(of: allowed),
              (plist["targetDigest"] == nil || plist["targetDigest"] is String),
              (plist["teamDigest"] == nil || plist["teamDigest"] is String),
              (plist["identityStampDigest"] == nil || plist["identityStampDigest"] is String),
              (plist["settingsKey"] == nil || plist["settingsKey"] is String),
              (plist["settingsType"] == nil || plist["settingsType"] is String),
              (plist["settingsBool"] == nil || V3WireContract.strictBool(plist["settingsBool"]) != nil),
              (plist["settingsInt"] == nil || V3WireContract.strictInt(plist["settingsInt"]) != nil),
              (plist["settingsValueDigest"] == nil || plist["settingsValueDigest"] is String),
              (plist["terminalOutcome"] == nil || plist["terminalOutcome"] is String) else { return nil }
        return V3DirectMutationRecoveryRecord(requestID: requestID, operation: operation,
            phase: phase, serviceInstanceID: serviceInstanceID,
            targetDigest: plist["targetDigest"] as? String,
            teamDigest: plist["teamDigest"] as? String,
            identityStampDigest: plist["identityStampDigest"] as? String,
            settingsKey: plist["settingsKey"] as? String,
            settingsType: plist["settingsType"] as? String,
            settingsBool: V3WireContract.strictBool(plist["settingsBool"]),
            settingsInt: V3WireContract.strictInt(plist["settingsInt"]),
            settingsValueDigest: plist["settingsValueDigest"] as? String,
            terminalOutcome: plist["terminalOutcome"] as? String)
    }

    func replacing(phase: V3DirectMutationRecoveryPhase, serviceInstanceID: String? = nil,
                   terminalOutcome: String? = nil) -> V3DirectMutationRecoveryRecord? {
        V3DirectMutationRecoveryRecord(requestID: requestID, operation: operation, phase: phase,
            serviceInstanceID: serviceInstanceID ?? self.serviceInstanceID,
            targetDigest: targetDigest, teamDigest: teamDigest,
            identityStampDigest: identityStampDigest,
            settingsKey: settingsKey, settingsType: settingsType,
            settingsBool: settingsBool, settingsInt: settingsInt,
            settingsValueDigest: settingsValueDigest, terminalOutcome: terminalOutcome)
    }
}

private enum V3DirectMutationPreDispatchReplyPolicy {
    static func mayClaimInvalidRequestNotDispatched(operation: String, requestID: String?,
                                                     identifierCollision: Bool,
                                                     heldRequestID: String?,
                                                     journalReadable: Bool) -> Bool {
        if V3RequestReplayPolicy.mayClaimNotDispatched(operation: operation,
            identifierCollision: identifierCollision) { return true }
        return !identifierCollision && journalReadable &&
            V3DirectMutationRecoveryRecord.allowedOperations.contains(operation) &&
            requestID != nil && requestID != heldRequestID
    }

    // This helper is only used on receive() exits before beginDirectDispatch.
    // The held request ID guard prevents confusing a replay of the unresolved
    // original with a new request that was rejected by the recovery hold.
    static func annotate(request: [String: Any], heldRequestID: String? = nil,
                         response: inout [String: Any]) -> Bool {
        guard V3DirectMutationRecoveryRecord.isEligible(request: request),
              let requestID = request["id"] as? String,
              response["id"] as? String == requestID,
              requestID != heldRequestID else { return false }
        response["operationNotDispatched"] = true
        return true
    }
}

private enum V3ServiceRecoveryFileRecord {
    case operation(V3OperationRecoveryRecord)
    case directMutation(V3DirectMutationRecoveryRecord)
}

// Only safe OS domain/code pairs leave the service. No path, plist contents,
// account identifier, or arbitrary NSError text is retained in this error.
private struct V3RecoveryStorageFailure: Error {
    enum Kind: String {
        case malformedRecord, incompatibleRecord, storageUnavailable
        case lockUnavailable, readFailure, deleteFailure

        var retryable: Bool {
            switch self {
            case .malformedRecord, .incompatibleRecord: return false
            case .storageUnavailable, .lockUnavailable, .readFailure, .deleteFailure: return true
            }
        }

        var safeCause: CombinedFailure.SafeCause {
            switch self {
            case .malformedRecord: return .recoveryMalformedRecord
            case .incompatibleRecord: return .recoveryIncompatibleRecord
            case .storageUnavailable: return .recoveryStorageUnavailable
            case .lockUnavailable: return .recoveryLockUnavailable
            case .readFailure: return .recoveryReadFailure
            case .deleteFailure: return .recoveryDeleteFailure
            }
        }
    }

    let kind: Kind
    let underlyingDomain: String
    let underlyingCode: Int
    let recordPresent: Bool
    let deletionPossible: Bool
    let sourceStep: String

    init(_ kind: Kind, underlying: Error? = nil, recordPresent: Bool = false,
         deletionPossible: Bool = false, sourceStep: String = "unknown") {
        self.kind = kind
        let native = underlying as NSError?
        if let native, [NSCocoaErrorDomain, NSPOSIXErrorDomain].contains(native.domain) {
            underlyingDomain = native.domain
            underlyingCode = native.code
        } else {
            underlyingDomain = native == nil ? "none" : "redacted"
            underlyingCode = 0
        }
        self.recordPresent = recordPresent
        self.deletionPossible = deletionPossible
        self.sourceStep = sourceStep
    }

    var isMalformedOrIncompatible: Bool {
        kind == .malformedRecord || kind == .incompatibleRecord
    }

    var clearEligible: Bool { isMalformedOrIncompatible && recordPresent && deletionPossible }

    var snapshotValue: [String: Any] {
        ["kind": kind.rawValue, "recordPresent": recordPresent,
         "clearEligible": clearEligible, "underlyingDomain": underlyingDomain,
         "underlyingCode": underlyingCode, "retryable": kind.retryable,
         "sourceStep": sourceStep]
    }

    func combined(operation: String, id: String) -> CombinedFailure {
        let native: Error? = underlyingDomain == "none" || underlyingDomain == "redacted"
            ? nil : NSError(domain: underlyingDomain, code: underlyingCode)
        return CombinedFailure(operation: operation, stage: .persistence,
            code: kind == .storageUnavailable || kind == .lockUnavailable ? .unavailable : .failed,
            id: id, underlying: native, retryable: kind.retryable, safeCause: kind.safeCause)
    }
}

private enum V3OperationRecoveryJournal {
    private static let components = ["Library", "Application Support", "LiveContainer"]
    private static let fileName = "operation-recovery.plist"

    // LiveProcess validates the host-selected group against its own sandbox
    // before SideStore boots and publishes it; the host publishes the same key
    // for itself. The journal therefore resolves the identical identity IPA
    // staging and the secret handoff lock use. A bundle declaration is only the
    // packaged fallback for a launch that published nothing.
    private static func runtimeGroup() -> String? {
        V3SharedAppGroup.environmentGroup() ?? V3SharedAppGroup.runtimeIdentity()?.identifier
    }

    static func appGroupDiagnostic(selectedGroup: String?, inheritedGroup: String?,
                                   signedEntitled: Bool?,
                                   resolveContainer: (String) -> URL?) -> [String: Any] {
        let source: String
        if selectedGroup == nil || selectedGroup?.isEmpty == true { source = "none" }
        else if selectedGroup == inheritedGroup { source = "inherited" }
        else { source = "runtimeSelected" }
        let digest = selectedGroup.map {
            String(SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }
                .joined().prefix(12))
        } ?? "none"
        let available = selectedGroup.flatMap(resolveContainer) != nil
        return ["groupHash": digest, "selectionSource": source,
                "signedEntitled": signedEntitled.map { $0 ? "yes" : "no" } ?? "unknown",
                "containerResolves": available]
    }

    static func runtimeAppGroupDiagnostic() -> [String: Any] {
        let selected = runtimeGroup()
        // LiveProcess records these process-local facts before LC swaps its
        // UserDefaults implementation during embedded SideStore bootstrap.
        let inherited = V3SharedAppGroup.environmentGroup()
        let signed = signedEntitlementContains(selectedGroup: selected,
            digestList: processEnvironment("LC_V3_SIGNED_APP_GROUP_DIGESTS"))
        return appGroupDiagnostic(selectedGroup: selected, inheritedGroup: inherited,
                                  signedEntitled: signed) {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    }

    static func signedEntitlementContains(selectedGroup: String?, digestList: String?) -> Bool? {
        guard let selectedGroup, !selectedGroup.isEmpty, let digestList else { return nil }
        if digestList.isEmpty { return false }
        let digests = digestList.split(separator: ",", omittingEmptySubsequences: false)
        guard digests.allSatisfy({ $0.count == 64 && $0.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        } }) else { return nil }
        let selectedDigest = SHA256.hash(data: Data(selectedGroup.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return digests.contains(Substring(selectedDigest))
    }

    private static func processEnvironment(_ name: String) -> String? {
        #if canImport(Darwin)
        return name.withCString { key in
            guard let value = getenv(key) else { return nil }
            return String(cString: value)
        }
        #else
        return nil
        #endif
    }

    private static func recordURL(containerRoot container: URL) throws -> URL {
        let directory = components.reduce(container.standardizedFileURL) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  directory.resolvingSymlinksInPath().standardizedFileURL == directory else {
                throw V3RecoveryStorageFailure(.storageUnavailable, sourceStep: "directory")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch let failure as V3RecoveryStorageFailure { throw failure }
          catch { throw V3RecoveryStorageFailure(.storageUnavailable, underlying: error,
                                                sourceStep: "directory") }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    static func resolvedRoot(containerRoot: URL?,
                             selectedGroup: () -> String? = { runtimeGroup() },
                             resolveContainer: (String) -> URL? = {
                                 FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
                             }) throws -> URL {
        if let containerRoot { return containerRoot }
        // A fixed build-time group may not be entitled after the combined app
        // is signed for a device. Never silently switch groups after a failed
        // lookup: that could make an unresolved recovery record disappear.
        guard let group = selectedGroup(), !group.isEmpty,
              let container = resolveContainer(group) else {
            throw V3RecoveryStorageFailure(.storageUnavailable, sourceStep: "appGroup")
        }
        return container
    }

    private static func withLease<T>(containerRoot: URL?, _ body: (URL) throws -> T) throws -> T {
        let root = try resolvedRoot(containerRoot: containerRoot)
        var acquired = false
        var failedStep = "unknown"
        var failedDomain = "none"
        var failedCode = 0
        do {
            return try V3AppGroupProcessLock.withLock(containerRoot: root,
                onFailure: { step, domain, code in
                    failedStep = step; failedDomain = domain; failedCode = code
                }) {
                acquired = true
                return try body(recordURL(containerRoot: root))
            }
        } catch let failure as V3RecoveryStorageFailure {
            throw failure
        } catch {
            let native: Error? = failedDomain == "none" || failedDomain == "redacted"
                ? nil : NSError(domain: failedDomain, code: failedCode)
            throw V3RecoveryStorageFailure(acquired || failedStep == "directory"
                                           ? .storageUnavailable : .lockUnavailable,
                                           underlying: native ?? error, sourceStep: failedStep)
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let native = error as NSError
        return (native.domain == NSCocoaErrorDomain && [4, 260].contains(native.code)) ||
            (native.domain == NSPOSIXErrorDomain && native.code == ENOENT)
    }

    private static func canDelete(_ url: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    private static func readState(_ url: URL) throws -> V3ServiceRecoveryFileRecord? {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            if isMissingFile(error) { return nil }
            throw V3RecoveryStorageFailure(.readFailure, underlying: error, sourceStep: "metadata")
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
            throw V3RecoveryStorageFailure(.readFailure, recordPresent: true, sourceStep: "fileType")
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            if isMissingFile(error) { return nil }
            throw V3RecoveryStorageFailure(.readFailure, underlying: error,
                                           recordPresent: true, sourceStep: "readData")
        }
        let deletionPossible = canDelete(url)
        guard !data.isEmpty, data.count <= 4096,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let fields = plist as? [String: Any] else {
            throw V3RecoveryStorageFailure(.malformedRecord, recordPresent: true,
                                           deletionPossible: deletionPossible, sourceStep: "parse")
        }
        guard let version = fields["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID() else {
            throw V3RecoveryStorageFailure(.malformedRecord, recordPresent: true,
                                           deletionPossible: deletionPossible, sourceStep: "schema")
        }
        switch version.intValue {
        case 1:
            let allowed: Set<String> = ["version", "session", "kind", "phase", "ipa"]
            guard Set(fields.keys).isSubset(of: allowed) else {
                throw V3RecoveryStorageFailure(.incompatibleRecord, recordPresent: true,
                                               deletionPossible: deletionPossible)
            }
            guard let operation = V3OperationRecoveryRecord.decodePropertyList(fields) else {
                throw V3RecoveryStorageFailure(.malformedRecord, recordPresent: true,
                                               deletionPossible: deletionPossible)
            }
            return .operation(operation)
        case 2:
            let allowed: Set<String> = ["version", "recordType", "requestID", "operation", "phase",
                "serviceInstanceID", "targetDigest", "settingsKey", "settingsType", "settingsBool",
                "settingsInt", "settingsValueDigest", "terminalOutcome", "teamDigest", "identityStampDigest"]
            guard fields["recordType"] as? String == "directMutation",
                  Set(fields.keys).isSubset(of: allowed) else {
                throw V3RecoveryStorageFailure(.incompatibleRecord, recordPresent: true,
                                               deletionPossible: deletionPossible)
            }
            guard let direct = V3DirectMutationRecoveryRecord.decode(fields) else {
                throw V3RecoveryStorageFailure(.malformedRecord, recordPresent: true,
                                               deletionPossible: deletionPossible)
            }
            return .directMutation(direct)
        default:
            throw V3RecoveryStorageFailure(.incompatibleRecord, recordPresent: true,
                                           deletionPossible: deletionPossible)
        }
    }

    private static func read(_ url: URL) throws -> V3OperationRecoveryLease {
        switch try readState(url) {
        case nil: return V3OperationRecoveryLease()
        case .operation(let record): return V3OperationRecoveryLease(record: record)
        case .directMutation: throw V3RecoveryStorageFailure(.incompatibleRecord, recordPresent: true)
        }
    }

    private static func write(_ lease: V3OperationRecoveryLease, to url: URL) throws {
        guard let record = lease.record else {
            if try readState(url) != nil {
                do { try FileManager.default.removeItem(at: url) }
                catch {
                    if !isMissingFile(error) {
                        throw V3RecoveryStorageFailure(.deleteFailure, underlying: error,
                                                       recordPresent: true)
                    }
                }
            }
            return
        }
        do {
            try writePropertyList(record.propertyListRepresentation, to: url)
        } catch { throw V3RecoveryStorageFailure(.storageUnavailable, underlying: error) }
    }

    static func current(containerRoot: URL? = nil) throws -> V3OperationRecoveryRecord? {
        try withLease(containerRoot: containerRoot) { try read($0).record }
    }

    static func currentState(containerRoot: URL? = nil) throws -> V3ServiceRecoveryFileRecord? {
        try withLease(containerRoot: containerRoot) { try readState($0) }
    }

    @discardableResult
    static func discardUnreadableAfterDeviceCheck(userConfirmed: Bool,
                                                   containerRoot: URL? = nil,
                                                   deleteRecord: (URL) throws -> Void = {
                                                       try FileManager.default.removeItem(at: $0)
                                                   }) throws -> Bool {
        guard userConfirmed else { return false }
        return try withLease(containerRoot: containerRoot) { url in
            do {
                guard try readState(url) != nil else { return true }
                return false // A valid operation or direct mutation still owns it.
            } catch let failure as V3RecoveryStorageFailure {
                guard failure.isMalformedOrIncompatible else { throw failure }
                guard failure.clearEligible else {
                    throw V3RecoveryStorageFailure(.deleteFailure, recordPresent: true)
                }
                do { try deleteRecord(url) }
                catch {
                    if !isMissingFile(error) {
                        throw V3RecoveryStorageFailure(.deleteFailure, underlying: error,
                                                       recordPresent: true)
                    }
                }
                // Prove absence under the same process-shared lock before
                // releasing any host or service recovery ownership.
                guard try readState(url) == nil else {
                    throw V3RecoveryStorageFailure(.deleteFailure, recordPresent: true)
                }
                return true
            }
        }
    }

    static func reserve(sessionID: String, kind: String, stagedIPAToken: String? = nil,
                        containerRoot: URL? = nil) throws -> Bool {
        try withLease(containerRoot: containerRoot) { url in
            var lease = try read(url)
            let result = lease.reserve(sessionID: sessionID, kind: kind, stagedIPAToken: stagedIPAToken)
            if result == .reserved { try write(lease, to: url) }
            return result != .blocked
        }
    }

    static func reserveDirect(request: [String: Any], requestID: String,
                              serviceInstanceID: String, teamIdentifier: String? = nil,
                              identityStamp: String? = nil,
                              containerRoot: URL? = nil) throws -> Bool {
        guard let operation = request["operation"] as? String,
              V3DirectMutationRecoveryRecord.allowedOperations.contains(operation) else { return false }
        let target = request["target"] as? String ?? ""
        let payload = request["payload"] as? [String: Any] ?? [:]
        let targetDigest = target.isEmpty || ["pairingImportData", "accountImport"].contains(operation)
            ? nil : V3DirectMutationRecoveryHash.digest(target)
        let teamDigest = operation == "certRevoke"
            ? teamIdentifier.map(V3DirectMutationRecoveryHash.digest) : nil
        let identityStampDigest = operation == "certRevoke"
            ? identityStamp.map(V3DirectMutationRecoveryHash.digest) : nil
        let key = payload["key"] as? String
        let type = payload["type"] as? String
        let record = V3DirectMutationRecoveryRecord(requestID: requestID, operation: operation,
            phase: .prepared, serviceInstanceID: serviceInstanceID,
            targetDigest: targetDigest, teamDigest: teamDigest,
            identityStampDigest: identityStampDigest,
            settingsKey: key, settingsType: type,
            settingsBool: V3WireContract.strictBool(payload["bool"]),
            settingsInt: V3WireContract.strictInt(payload["int"]))
        guard let record else { return false }
        return try withLease(containerRoot: containerRoot) { url in
            guard case nil = try readState(url) else { return false }
            try writeDirect(record, to: url)
            return true
        }
    }

    static func beginDirectDispatch(requestID: String, serviceInstanceID: String,
                                   containerRoot: URL? = nil) throws -> Bool {
        try withLease(containerRoot: containerRoot) { url in
            guard case .directMutation(let current)? = try readState(url),
                  current.requestID == requestID, current.phase == .prepared,
                  let dispatched = current.replacing(phase: .dispatched, serviceInstanceID: serviceInstanceID) else { return false }
            try writeDirect(dispatched, to: url)
            return true
        }
    }

    static func clearPreparedDirectAfterNotDispatched(requestID: String,
                                                       containerRoot: URL? = nil) throws -> Bool {
        try withLease(containerRoot: containerRoot) { url in
            guard case .directMutation(let current)? = try readState(url),
                  current.requestID == requestID, current.phase == .prepared else { return false }
            try writeEmpty(to: url)
            return true
        }
    }

    static func settleDirect(requestID: String, terminalOutcome: String,
                             containerRoot: URL? = nil) throws -> Bool {
        guard ["completed", "createdAndStored", "remoteCreatedLocalStorageUnverified"].contains(terminalOutcome) else {
            return false
        }
        return try withLease(containerRoot: containerRoot) { url in
            guard case .directMutation(let current)? = try readState(url),
                  current.requestID == requestID,
                  (current.phase == .dispatched || current.phase == .unknown),
                  let terminal = current.replacing(phase: .terminal, terminalOutcome: terminalOutcome) else { return false }
            try writeDirect(terminal, to: url)
            return true
        }
    }

    static func direct(containerRoot: URL? = nil) throws -> V3DirectMutationRecoveryRecord? {
        try withLease(containerRoot: containerRoot) { url in
            guard case .directMutation(let record)? = try readState(url) else { return nil }
            return record
        }
    }

    static func markDirectUnknownIfOwnerLost(requestID: String, currentServiceInstanceID: String,
                                             containerRoot: URL? = nil) throws -> V3DirectMutationRecoveryRecord? {
        try withLease(containerRoot: containerRoot) { url in
            guard case .directMutation(let current)? = try readState(url), current.requestID == requestID else { return nil }
            guard current.phase == .dispatched, current.serviceInstanceID != currentServiceInstanceID,
                  let unknown = current.replacing(phase: .unknown, serviceInstanceID: currentServiceInstanceID) else {
                return current
            }
            try writeDirect(unknown, to: url)
            return unknown
        }
    }

    static func markDirectUnknownAfterRunFailure(requestID: String, serviceInstanceID: String,
                                                 containerRoot: URL? = nil) throws -> Bool {
        try withLease(containerRoot: containerRoot) { url in
            guard case .directMutation(let current)? = try readState(url),
                  current.requestID == requestID, current.phase == .dispatched,
                  current.serviceInstanceID == serviceInstanceID,
                  let unknown = current.replacing(phase: .unknown) else { return false }
            try writeDirect(unknown, to: url)
            return true
        }
    }

    static func reconcileDirect(requestID: String, allowUnknownDeviceCheck: Bool,
                                containerRoot: URL? = nil) throws -> Bool {
        try withLease(containerRoot: containerRoot) { url in
            guard case .directMutation(let current)? = try readState(url), current.requestID == requestID else { return false }
            guard current.phase == .terminal || current.phase == .prepared ||
                  (current.phase == .unknown && allowUnknownDeviceCheck) else { return false }
            try writeEmpty(to: url)
            return true
        }
    }

    private static func writeDirect(_ record: V3DirectMutationRecoveryRecord, to url: URL) throws {
        try writePropertyList(record.propertyListRepresentation, to: url)
    }

    private static func writeEmpty(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { throw V3SecretHandoffError.unavailable(.sharedGroupUnavailable,
                osStatus: Int32((error as NSError).code)) }
        }
    }

    private static func writePropertyList(_ value: [String: Any], to url: URL) throws {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            guard data.count <= 4096 else {
                throw V3SecretHandoffError.unavailable(.sharedGroupUnavailable)
            }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let failure as V3SecretHandoffError {
            throw failure
        } catch {
            throw V3SecretHandoffError.unavailable(.sharedGroupUnavailable,
                osStatus: Int32((error as NSError).code))
        }
    }

    static func beginDispatch(sessionID: String, kind: String, stagedIPAToken: String? = nil,
                              containerRoot: URL? = nil) throws -> Bool {
        try withLease(containerRoot: containerRoot) { url in
            var lease = try read(url)
            guard lease.beginDispatch(sessionID: sessionID, kind: kind, stagedIPAToken: stagedIPAToken) else { return false }
            try write(lease, to: url)
            return true
        }
    }

    @discardableResult
    static func settle(sessionID: String, replySessionID: String?, state: String?, backendSettled: Bool,
                       containerRoot: URL? = nil) throws -> Bool {
        try withLease(containerRoot: containerRoot) { url in
            var lease = try read(url)
            guard lease.settle(sessionID: sessionID, replySessionID: replySessionID,
                state: state, backendSettled: backendSettled) else { return false }
            try write(lease, to: url)
            return true
        }
    }

    @discardableResult
    static func settleRefreshAdmission(runID: String, terminalState: String?,
                                       terminalConfirmed: Bool,
                                       containerRoot: URL? = nil) throws -> Bool {
        try withLease(containerRoot: containerRoot) { url in
            var lease = try read(url)
            guard lease.settleRefreshAdmission(runID: runID, terminalState: terminalState,
                terminalConfirmed: terminalConfirmed) else { return false }
            try write(lease, to: url)
            return true
        }
    }

    @discardableResult
    static func clearPreparedRefreshAdmissionAfterRequestCancellation(runID: String,
                                                                       containerRoot: URL? = nil) throws -> Bool {
        try withLease(containerRoot: containerRoot) { url in
            var lease = try read(url)
            guard lease.clearPreparedRefreshAdmissionAfterRequestCancellation(runID: runID) else { return false }
            try write(lease, to: url)
            return true
        }
    }

    @discardableResult
    static func reconcileRefreshAdmissionAfterDeviceCheck(runID: String, userConfirmed: Bool,
                                                          containerRoot: URL? = nil) throws -> Bool {
        try withLease(containerRoot: containerRoot) { url in
            var lease = try read(url)
            guard lease.reconcileRefreshAdmissionAfterDeviceCheck(runID: runID,
                userConfirmed: userConfirmed) else { return false }
            try write(lease, to: url)
            return true
        }
    }

    @discardableResult
    static func reconcileAfterDeviceCheck(sessionID: String, userConfirmed: Bool,
                                          containerRoot: URL? = nil) throws -> Bool {
        try withLease(containerRoot: containerRoot) { url in
            var lease = try read(url)
            guard lease.reconcileAfterDeviceCheck(sessionID: sessionID, userConfirmed: userConfirmed) else { return false }
            try write(lease, to: url)
            return true
        }
    }

    @discardableResult
    static func clearPreparedAfterNotDispatched(sessionID: String, expectedRequestID: String,
                                                 replyRequestID: String?, operationNotDispatched: Bool,
                                                 containerRoot: URL? = nil) throws -> Bool {
        try withLease(containerRoot: containerRoot) { url in
            var lease = try read(url)
            guard lease.clearPreparedAfterNotDispatched(sessionID: sessionID,
                expectedRequestID: expectedRequestID, replyRequestID: replyRequestID,
                operationNotDispatched: operationNotDispatched) else { return false }
            try write(lease, to: url)
            return true
        }
    }

    @discardableResult
    static func clearPreparedAfterConfirmedCancellation(sessionID: String, replySessionID: String?,
        state: String?, backendSettled: Bool, stopConfirmed: Bool, knownStarted: Bool,
        containerRoot: URL? = nil) throws -> Bool {
        try withLease(containerRoot: containerRoot) { url in
            var lease = try read(url)
            guard lease.clearPreparedAfterConfirmedCancellation(sessionID: sessionID,
                replySessionID: replySessionID, state: state, backendSettled: backendSettled,
                stopConfirmed: stopConfirmed, knownStarted: knownStarted) else { return false }
            try write(lease, to: url)
            return true
        }
    }
}

/// Keeps the dispatched write, terminal journal, and post-run cancellation
/// check in one ordered path. A thrown operation intentionally leaves the
/// dispatched record for service-restart reconciliation.
private enum V3DirectMutationRecoveryLifecycle {
    static func reserve(request: [String: Any], requestID: String,
                        serviceInstanceID: String, teamIdentifier: String?,
                        identityStamp: String?, containerRoot: URL? = nil) throws -> Bool {
        try V3OperationRecoveryJournal.reserveDirect(request: request, requestID: requestID,
            serviceInstanceID: serviceInstanceID, teamIdentifier: teamIdentifier,
            identityStamp: identityStamp, containerRoot: containerRoot)
    }

    @MainActor
    static func dispatchAndSettle(requestID: String, operation: String,
                                  serviceInstanceID: String,
                                  containerRoot: URL? = nil,
                                  run: @MainActor () async throws -> [String: Any]) async throws -> [String: Any]? {
        guard try V3OperationRecoveryJournal.beginDirectDispatch(requestID: requestID,
            serviceInstanceID: serviceInstanceID, containerRoot: containerRoot) else { return nil }
        do {
            let result = try await run()
            let terminalOutcome = operation == "certCreate"
                ? (result["outcome"] as? String ?? "") : "completed"
            guard try V3OperationRecoveryJournal.settleDirect(requestID: requestID,
                terminalOutcome: terminalOutcome, containerRoot: containerRoot) else { return nil }
            return result
        } catch {
            // The operation task is no longer running. Keep the ambiguity, but
            // make it explicitly reconcilable in this still-live service.
            _ = try? V3OperationRecoveryJournal.markDirectUnknownAfterRunFailure(
                requestID: requestID, serviceInstanceID: serviceInstanceID,
                containerRoot: containerRoot)
            throw error
        }
    }

    static func clearPreparedAfterFailure(requestID: String, containerRoot: URL? = nil) -> Bool {
        (try? V3OperationRecoveryJournal.clearPreparedDirectAfterNotDispatched(
            requestID: requestID, containerRoot: containerRoot)) == true
    }
}

// V3_NATIVE_CALLBACK_GATE_V1: native completions can arrive on arbitrary queues.
// Cancellation does not manufacture a native completion or release the mutation gate.
// The owning service retains it until the real callback returns or the process retires.
final class V3ServiceCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func settle(_ result: Result<Void, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
// V3_NATIVE_CALLBACK_GATE_END

private struct V3KnownSourcePolicyFailure: Error {
    enum Kind: Equatable { case network, invalidResponse }
    let kind: Kind
    let underlyingDomain: String
    let underlyingCode: Int

    // Cancellation belongs to the request lifecycle. Let the service-level
    // cancellation path see it instead of translating it into a list parse error.
    static func preservingCancellation(_ error: Error) -> Error {
        if error is CancellationError { return error }
        let cause = error as NSError
        if CombinedFailure.isURLCancellation(domain: cause.domain, code: cause.code) { return error }
        return V3KnownSourcePolicyFailure(error)
    }

    init(_ error: Error) {
        let cause = error as NSError
        // URL-loading errors include local temporary-file I/O. The shared
        // domain-and-code policy separates those from typed transport failures.
        kind = CombinedFailure.knownURLTransportCause(domain: cause.domain, code: cause.code) != nil
            ? .network : .invalidResponse
        underlyingDomain = [NSURLErrorDomain, NSPOSIXErrorDomain,
                            "kCFErrorDomainCFNetwork", "NSCocoaErrorDomain"]
            .contains(cause.domain) ? cause.domain : "redacted"
        underlyingCode = cause.code
    }
}

@MainActor
@objc(V3SideStoreService)
final class V3SideStoreService: NSObject {
    static let shared = V3SideStoreService()
    var tasks: [String: Task<Void, Never>] = [:]
    private var deadlineTasks: [String: Task<Void, Never>] = [:]
    var cancellations: [String: () -> Void] = [:]
    var completed: [String: (data: Data, deadline: Date)] = [:]
    private var completedRequestFingerprints: [String: Data] = [:]
    private var inFlightRequestFingerprints: [String: Data] = [:]
    private var completedCacheBudget = V3MutationReplyCacheBudget()
    private var pendingCancellationReplyReservations: Set<String> = []
    var mutationID: String?
    private var refreshAdmission = V3RefreshAdmissionLease()
    private var pendingRefreshAdmissionRequests: Set<String> = []
    private var pendingAuthStartSessions: [String: String] = [:]
    private var knownSourcesUpdateTask: Task<Void, Error>?
    private let recoveryServiceInstanceID = UUID().uuidString

    @objc(execute:reply:)
    nonisolated static func execute(_ data: Data, reply: @escaping (Data) -> Void) {
        Task { @MainActor in shared.receive(data, reply: reply) }
    }

    private func receive(_ data: Data, reply: @escaping (Data) -> Void) {
        // V3_CORRELATED_INVALID_REQUEST_V1: a request that fails the strict
        // contract is still answered with its own correlation and operation
        // whenever a well-formed envelope can be read, so the host can
        // classify the real reason instead of receiving an idless token it must
        // treat as a stale reply.
        guard let request = V3WireContract.decodeRequest(data) else {
            reply(encode(invalidRequestReply(for: data)))
            return
        }
        guard let id = request["id"] as? String,
              let operation = request["operation"] as? String,
              let deadline = request["deadline"] as? Date,
              deadline > Date(), deadline.timeIntervalSinceNow <= 610 else {
            reply(encode(invalidRequestReply(for: data)))
            return
        }
        let target = request["target"] as? String ?? ""
        let payload = request["payload"] as? [String: Any] ?? [:]
        let operationSessionID = V3OperationSessionCorrelationPolicy.requestSessionID(
            operation: operation, target: target, payload: payload)
        let requestFingerprint = V3RequestReplayPolicy.fingerprint(data)
        let expiredReplies = completed.compactMap { key, value in
            value.deadline <= Date() ? (key, value.data.count) : nil
        }
        for (key, byteCount) in expiredReplies {
            completed.removeValue(forKey: key)
            completedRequestFingerprints.removeValue(forKey: key)
            completedCacheBudget.remove(byteCount)
        }
        _ = refreshAdmission.expire()
        if let previous = completed[id] {
            guard V3RequestReplayPolicy.matches(
                cachedFingerprint: completedRequestFingerprints[id], incomingRequestData: data) else {
                reply(encode(invalidRequestReply(for: data), operation: operation))
                return
            }
            reply(previous.data)
            return
        }
        // Bind IDs while work is still running as well as after completion.
        // This check must precede the cancellation fast path: a different
        // command reusing an active mutation ID must not cancel unrelated work.
        if tasks[id] != nil {
            guard V3RequestReplayPolicy.matchesInFlight(
                cachedFingerprint: inFlightRequestFingerprints[id], incomingRequestData: data) else {
                reply(encode(invalidRequestReply(for: data), operation: operation))
                return
            }
        }
        if operation == "cancel" {
            let target = request["target"] as? String ?? ""
            guard let cancelScope = (request["payload"] as? [String: Any])?["scope"] as? String,
                  V3WireContract.cancellationScopes.contains(cancelScope) else {
                reply(encode(invalidRequestReply(for: data), operation: operation))
                return
            }
            guard reserveCancellationReply(operation: operation, id: id) else {
                let failure = CombinedFailure(operation: operation, stage: .command, code: .busy,
                    id: id, retryable: true, safeCause: .responseCapacityUnavailable)
                reply(encode(["version": 1, "id": id, "error": "busy", "failure": failure.wire],
                    operation: operation))
                return
            }
            let isPendingRefreshAdmission = cancelScope == "request" &&
                (pendingRefreshAdmissionRequests.contains(target) || refreshAdmission.requestID == target)
            if cancelScope == "request", let session = pendingAuthStartSessions[target] {
                _ = V3HeadlessRuntime.shared.auth.cancelBeforeBegin(id: session)
            }
            if !V3HeadlessRuntime.shared.cancelSession(target, scope: cancelScope) {
                tasks[target]?.cancel()
                cancellations[target]?()
            }
            var cancellationReply: [String: Any] = ["id": id, "version": 1, "ok": true]
            if isPendingRefreshAdmission {
                let refreshRunID = refreshAdmission.runID
                if refreshAdmission.release(requestID: target), let refreshRunID,
                   (try? V3OperationRecoveryJournal.clearPreparedRefreshAdmissionAfterRequestCancellation(
                    runID: refreshRunID)) == true {
                    cancellationReply["refreshAdmissionReleased"] = true
                }
            }
            let encoded = encode(cancellationReply, operation: operation)
            _ = finishCancellationReplyReservation(id: id, requestFingerprint: requestFingerprint,
                deadline: deadline, encoded: encoded)
            reply(encoded)
            return
        }
        guard tasks[id] == nil else {
            let failure = operation == "sourceRemoveConfirmed"
                ? CombinedFailure(operation: "source", stage: .source, code: .busy, id: id,
                                  retryable: true, safeCause: .sourceRemoveBusy)
                : operation == "opStart"
                ? CombinedFailure(operation: operation, stage: .command, code: .busy, id: id,
                                  retryable: true, safeCause: .operationInProgress)
                : CombinedFailure(operation: operation, stage: .command, code: .busy, id: id,
                                  retryable: true, safeCause: .operationInProgress)
            var response: [String: Any] = ["version": 1, "id": id, "error": "busy", "failure": failure.wire]
            reply(encode(response, operation: operation))
            return
        }
        let mutation = !V3WireContract.readOperations.contains(operation)
        let authenticationActive = V3HeadlessRuntime.shared.auth.hasActiveSession
        let authContinuation = V3ServiceMutationAdmissionPolicy.permitsAuthenticationControl(
            operation,
            ownsActiveSession: V3HeadlessRuntime.shared.auth.ownsActiveSession(target),
            authenticationActive: authenticationActive)
        let recoveryRecord: V3OperationRecoveryRecord?
        var directRecoveryRecord: V3DirectMutationRecoveryRecord?
        let recoveryReadFailed: Bool
        let recoveryStorageFailure: V3RecoveryStorageFailure?
        do {
            switch try V3OperationRecoveryJournal.currentState() {
            case .operation(let value): recoveryRecord = value
            case .directMutation(let value):
                directRecoveryRecord = try V3OperationRecoveryJournal.markDirectUnknownIfOwnerLost(
                    requestID: value.requestID, currentServiceInstanceID: recoveryServiceInstanceID) ?? value
                recoveryRecord = nil
            case nil: recoveryRecord = nil
            }
            recoveryReadFailed = false
            recoveryStorageFailure = nil
        } catch let failure as V3RecoveryStorageFailure {
            recoveryRecord = nil; directRecoveryRecord = nil; recoveryReadFailed = true
            recoveryStorageFailure = failure
        } catch {
            recoveryRecord = nil; directRecoveryRecord = nil; recoveryReadFailed = true
            recoveryStorageFailure = V3RecoveryStorageFailure(.readFailure, underlying: error)
        }
        if mutation, let failure = recoveryStorageFailure, !failure.clearEligible {
            let refusal = operation == "recoveryDiscardUnreadable" && failure.isMalformedOrIncompatible
                ? V3RecoveryStorageFailure(.deleteFailure, recordPresent: true) : failure
            var response: [String: Any] = ["version": 1, "id": id, "error": "failed",
                "failure": refusal.combined(operation: operation, id: id).wire]
            if ["opStart", "authBegin", "authRetryProvisioning"].contains(operation) {
                response["operationNotDispatched"] = true
            }
            _ = V3DirectMutationPreDispatchReplyPolicy.annotate(request: request, response: &response)
            reply(encode(response, operation: operation))
            return
        }
        let directRecoveryControl = directRecoveryRecord?.requestID == target &&
            ["directRecoveryInspect", "directRecoveryReconcile"].contains(operation)
        if ["directRecoveryInspect", "directRecoveryReconcile"].contains(operation),
           !directRecoveryControl {
            reply(encode(["version": 1, "id": id, "error": "invalidRequest",
                "failure": CombinedFailure(operation: operation, stage: .command,
                    code: .invalidConfiguration, id: id).wire], operation: operation))
            return
        }
        if operation == "directRecoveryReconcile", let directRecoveryRecord,
           directRecoveryRecord.phase == .dispatched {
            reply(encode(["version": 1, "id": id, "error": "busy",
                "failure": CombinedFailure(operation: operation, stage: .command,
                    code: .busy, id: id, retryable: false, safeCause: .operationInProgress).wire], operation: operation))
            return
        }
        if let recoveryRecord, recoveryRecord.kind == "refreshAll",
           !refreshAdmission.owns(recoveryRecord.sessionID) {
            _ = refreshAdmission.restoreLost(runID: recoveryRecord.sessionID)
        }
        let backupCallback = operation == "backupResult"
            ? V3BackupCallbackResult(session: target, payload: payload) : nil
        let backupCallbackControl = backupCallback.map {
            V3HeadlessRuntime.shared.operations.ownsBackupCallback($0)
        } ?? false
        let recoveryDecision = V3ServiceRecoveryAdmissionPolicy.decide(operation: operation,
            target: target, payload: payload, operationSessionID: operationSessionID,
            recovery: recoveryRecord, recoveryReadFailed: recoveryReadFailed,
            recoveryDiscardable: recoveryStorageFailure?.clearEligible == true,
            refreshOwnerLost: refreshAdmission.ownerLost, backupCallbackControl: backupCallbackControl)
        let policyOperationMutationActive = V3ServiceMutationAdmissionPolicy.hasConflictingOperationMutation(
            operation: operation, target: target,
            activeOperationID: V3HeadlessRuntime.shared.operations.activeMutationID,
            backupCallbackControl: backupCallbackControl) ||
            recoveryDecision.blocksMutation
        let operationMutationActive = (operation == "opRecoveryReconcile" && recoveryDecision.recoveryControl) ||
            directRecoveryControl ? false : policyOperationMutationActive
        if mutation, directRecoveryRecord != nil, !directRecoveryControl {
            let failure = CombinedFailure(operation: operation, stage: .command, code: .busy,
                id: id, retryable: false, safeCause: .operationInProgress)
            var response: [String: Any] = ["version": 1, "id": id, "error": "busy", "failure": failure.wire]
            _ = V3DirectMutationPreDispatchReplyPolicy.annotate(request: request,
                heldRequestID: directRecoveryRecord?.requestID, response: &response)
            reply(encode(response, operation: operation))
            return
        }
        let refreshRelease = recoveryDecision.refreshRelease
        let controlReply = V3MutationReplyCacheBudget.isControlReply(operation: operation)
        let cacheResponse = V3MutationReplyCacheBudget.shouldCacheResponse(operation: operation)
        let cancellationReplay = V3RequestReplayPolicy.requiresCompletedReply(operation: operation)
        let responseCapacityAvailable = !cacheResponse || (!mutation && !cancellationReplay) ||
            (cancellationReplay
                ? canReserveCancellationReply(operation: operation)
                : completed.count + pendingCancellationReplyReservations.count <
                    V3MutationReplyCacheBudget.responseCountLimit(isControlResponse: controlReply) &&
             completedCacheBudget.canReserve(
                maximumResponseBytes: V3MutationReplyCacheBudget.minimumReplyBytesToAdmit(operation: operation),
                preservingControlCapacity: !controlReply) &&
             V3MutationReplyCacheBudget.canAdmit(operation: operation,
                completedReplyCount: completed.count + pendingCancellationReplyReservations.count))
        if cancellationReplay && !responseCapacityAvailable {
            let failure = CombinedFailure(operation: operation, stage: .command, code: .busy,
                id: id, retryable: true, safeCause: .responseCapacityUnavailable)
            reply(encode(["version": 1, "id": id, "error": "busy", "failure": failure.wire],
                operation: operation))
            return
        }
        guard V3ServiceMutationAdmissionPolicy.admits(isMutation: mutation,
            anotherMutationActive: mutationID != nil || operationMutationActive,
            authenticationActive: authenticationActive,
            isAuthContinuation: authContinuation,
            responseCapacityAvailable: responseCapacityAvailable,
            refreshActive: refreshAdmission.isActive,
            isRefreshRelease: refreshRelease) else {
            let safeCause = V3ServiceMutationBusyCausePolicy.safeCause(
                operation: operation,
                anotherMutationActive: mutationID != nil || operationMutationActive,
                responseCapacityAvailable: responseCapacityAvailable,
                refreshActive: refreshAdmission.isActive, refreshRelease: refreshRelease,
                authenticationActive: authenticationActive,
                isAuthContinuation: authContinuation)
            let sourceRemoval = safeCause == .sourceRemoveBusy
            let failure = CombinedFailure(
                operation: sourceRemoval ? "source" : operation.hasPrefix("refreshAdmission") ? "refresh" : operation,
                stage: sourceRemoval ? .source : .command,
                code: .busy, id: id, retryable: true, safeCause: safeCause)
            var response: [String: Any] = ["version": 1, "id": id, "error": "busy", "failure": failure.wire]
            if ["opStart", "authBegin", "authRetryProvisioning"].contains(operation) {
                response["operationNotDispatched"] = true
            }
            _ = V3DirectMutationPreDispatchReplyPolicy.annotate(request: request,
                heldRequestID: directRecoveryRecord?.requestID, response: &response)
            clearPreparedOperationRecoveryIfProven(request: request, reply: response)
            reply(encode(response, operation: operation))
            return
        }
        if cancellationReplay, !reserveCancellationReply(operation: operation, id: id) {
            let failure = CombinedFailure(operation: operation, stage: .command, code: .busy,
                id: id, retryable: true, safeCause: .responseCapacityUnavailable)
            reply(encode(["version": 1, "id": id, "error": "busy", "failure": failure.wire],
                operation: operation))
            return
        }
        // Check before reserving a direct-mutation journal: this refusal is
        // proven not dispatched and cannot strand a new recovery owner.
        if let failure = signingStorageFailure(operation: operation, id: id) {
            var response: [String: Any] = ["version": 1, "id": id, "error": "notReady",
                "failure": failure.wire]
            _ = V3DirectMutationPreDispatchReplyPolicy.annotate(request: request, response: &response)
            reply(encode(response, operation: operation))
            return
        }
        if V3DirectMutationRecoveryRecord.isEligible(request: request) {
            do {
                guard try V3DirectMutationRecoveryLifecycle.reserve(request: request, requestID: id,
                    serviceInstanceID: recoveryServiceInstanceID,
                    teamIdentifier: DatabaseManager.shared.activeTeam()?.identifier,
                    identityStamp: AuthManager.shared.v3IdentityIsStable
                        ? AuthManager.shared.v3IdentityStamp : nil) else {
                    throw ServiceError.busy
                }
            } catch {
                let failure = CombinedFailure(operation: operation, stage: .command, code: .busy,
                    id: id, retryable: false, safeCause: .operationInProgress)
                var response: [String: Any] = ["version": 1, "id": id, "error": "busy", "failure": failure.wire]
                let heldRequestID = (try? V3OperationRecoveryJournal.direct())?.requestID
                _ = V3DirectMutationPreDispatchReplyPolicy.annotate(request: request,
                    heldRequestID: heldRequestID, response: &response)
                reply(encode(response, operation: operation))
                return
            }
        }
        if mutation { mutationID = id }
        if operation == "refreshAdmissionBegin" { pendingRefreshAdmissionRequests.insert(id) }
        if ["authBegin", "authRetryProvisioning"].contains(operation),
           let session = (request["payload"] as? [String: Any])?["session"] as? String {
            pendingAuthStartSessions[id] = session
        }
        inFlightRequestFingerprints[id] = requestFingerprint
        tasks[id] = Task { @MainActor in
            defer {
                tasks[id] = nil
                inFlightRequestFingerprints.removeValue(forKey: id)
                deadlineTasks.removeValue(forKey: id)?.cancel()
                cancellations[id] = nil
                pendingRefreshAdmissionRequests.remove(id)
                pendingAuthStartSessions[id] = nil
                if mutationID == id { mutationID = nil }
            }
            var response: [String: Any] = ["version": 1, "id": id]
            do {
                guard DatabaseManager.shared.isStarted else { throw ServiceError.notReady }
                try Task.checkCancellation()
                if V3DirectMutationRecoveryRecord.isEligible(request: request) {
                    guard let result = try await V3DirectMutationRecoveryLifecycle.dispatchAndSettle(
                        requestID: id, operation: operation,
                        serviceInstanceID: recoveryServiceInstanceID, run: {
                            try await run(operation, request: request, id: id)
                        }) else { throw ServiceError.busy }
                    response["result"] = result
                } else {
                    response["result"] = try await run(operation, request: request, id: id)
                }
                try Task.checkCancellation()
                response["ok"] = true
            } catch {
                let directNotDispatched = V3DirectMutationRecoveryRecord.isEligible(request: request) &&
                    V3DirectMutationRecoveryLifecycle.clearPreparedAfterFailure(requestID: id)
                if operation == "refreshAdmissionBegin", error is CancellationError,
                   let refreshRunID = request["target"] as? String,
                   refreshAdmission.release(runID: refreshRunID) {
                    _ = try? V3OperationRecoveryJournal.clearPreparedRefreshAdmissionAfterRequestCancellation(
                        runID: refreshRunID)
                }
                // Raw framework errors can contain URLs, authentication data or server responses.
                // Detailed errors remain inside the SideStore process.
                if let serviceError = error as? ServiceError { response["error"] = serviceError.rawValue }
                else if let headlessError = error as? V3SideStoreServiceError { response["error"] = headlessError.rawValue }
                else if error is CancellationError { response["error"] = "cancelled" }
                else { response["error"] = "operationFailed" }
                if operation == "opStart",
                   V3OperationStartDispatchPolicy.provesNotDispatched(
                    resultWasReturned: response["result"] != nil) {
                    response["operationNotDispatched"] = true
                } else if ["authBegin", "authRetryProvisioning"].contains(operation),
                          response["result"] == nil,
                          (error is ServiceError || error is V3SideStoreServiceError) {
                    response["operationNotDispatched"] = true
                }
                if directNotDispatched { response["operationNotDispatched"] = true }
                var stage: CombinedFailure.Stage
                switch operation {
                case "snapshot": stage = .serviceReadiness
                case "authReconcileStorage": stage = .persistence
                case "catalog": stage = .catalog
                case "authBegin", "authPoll", "authRespond", "authCancel", "authRetryProvisioning", "accountExport", "accountImport": stage = .authentication
                case "opStart", "opPoll", "opAnswer", "opCancel": stage = .command
                case "certList", "certExportActive", "certSetActive", "certDelete", "certPortalList", "certRevoke", "certCreate": stage = .signing
                case "devTeams", "devDevices", "devAppIDs", "devGroups", "devProfiles", "syncAppIDs": stage = .authentication
                case "sourcePreview", "sourceAddConfirmed", "sourceRemoveConfirmed", "refreshSources": stage = .source
                default: stage = .command
                }
                var readinessNotReady = false
                if let serviceError = error as? ServiceError, case .notReady = serviceError {
                    stage = .serviceReadiness
                    readinessNotReady = true
                }
                if let serviceError = error as? V3SideStoreServiceError, case .notReady = serviceError {
                    stage = .serviceReadiness
                    readinessNotReady = true
                }
                if operation.hasPrefix("refreshAdmission") { stage = .serviceReadiness }
                if operation == "sourceRemoveConfirmed" {
                    if let serviceError = error as? ServiceError, case .notReady = serviceError {
                        response["failure"] = CombinedFailure(operation: "source", stage: .serviceReadiness,
                            code: .notReady, id: id, retryable: true).wire
                    } else if let headlessError = error as? V3SideStoreServiceError,
                              case .notReady = headlessError {
                        response["failure"] = CombinedFailure(operation: "source", stage: .serviceReadiness,
                            code: .notReady, id: id, retryable: true).wire
                    } else if let serviceError = error as? ServiceError, case .busy = serviceError {
                        response["failure"] = CombinedFailure(operation: "source", stage: .source,
                            code: .busy, id: id, retryable: true, safeCause: .sourceRemoveBusy).wire
                    } else if let headlessError = error as? V3SideStoreServiceError, case .busy = headlessError {
                        response["failure"] = CombinedFailure(operation: "source", stage: .source,
                            code: .busy, id: id, retryable: true, safeCause: .sourceRemoveBusy).wire
                    } else {
                        response["failure"] = CombinedFailure(operation: "source", stage: .source, code: .failed,
                            id: id, underlying: error, safeCause: .sourceRemoveFailed,
                            sourceStep: .catalogRead).wire
                    }
                } else if let serviceError = error as? ServiceError {
                    let code: CombinedFailure.Code
                    switch serviceError {
                    case .notReady: code = .notReady
                    case .busy: code = .busy
                    case .unsupported: code = .unsupported
                    case .notFound: code = .unavailable
                    case .invalidRequest: code = .invalidConfiguration
                    }
                    if ["authBegin", "authRetryProvisioning"].contains(operation) && code == .busy {
                        response["failure"] = CombinedFailure(operation: "signIn", stage: .serviceReadiness,
                            code: .busy, id: id, retryable: true, safeCause: .operationInProgress).wire
                    } else if operation.hasPrefix("refreshAdmission") {
                        response["failure"] = CombinedFailure(operation: "refresh",
                            stage: .command, code: code, id: id,
                            retryable: code == .busy,
                            safeCause: code == .busy ? .operationInProgress : nil).wire
                    } else {
                        response["failure"] = CombinedFailure(operation: operation, stage: stage,
                            code: code, id: id,
                            retryable: V3ServiceReadinessRetryPolicy.retryable(
                                operation: operation, stage: stage, code: code,
                                typedNotReady: readinessNotReady)).wire
                    }
                } else if let headlessError = error as? V3SideStoreServiceError {
                    let code: CombinedFailure.Code
                    switch headlessError {
                    case .notReady: code = .notReady
                    case .busy: code = .busy
                    case .unsupported: code = .unsupported
                    case .notFound: code = .unavailable
                    case .invalidRequest: code = .invalidConfiguration
                    case .authRequired: code = .notReady
                    case .persistenceUnverified: code = .failed
                    // V3_CATALOG_SOURCE_MISSING_V1: a typed, non-manifest cause.
                    case .catalogSourceUnavailable: code = .unavailable
                    }
                    if headlessError == .catalogSourceUnavailable {
                        response["failure"] = CombinedFailure(operation: "catalog", stage: .catalog,
                            code: code, id: id, safeCause: .catalogSourceUnavailable,
                            sourceStep: .catalogRead).wire
                    } else if headlessError == .invalidRequest && ["sourcePreview", "sourceAddConfirmed"].contains(operation) {
                        response["failure"] = CombinedFailure(operation: "source", stage: .source,
                            code: .invalidConfiguration, id: id, safeCause: .sourceInvalidURL,
                            sourceStep: .sourceDownload).wire
                    } else if headlessError == .persistenceUnverified && operation == "sourceAddConfirmed" {
                        response["failure"] = CombinedFailure(operation: "source", stage: .source, code: code,
                            id: id, safeCause: .sourcePersistenceUnverified, sourceStep: .catalogRead).wire
                    } else {
                        response["failure"] = CombinedFailure(operation: operation, stage: stage, code: code, id: id,
                            retryable: V3ServiceReadinessRetryPolicy.retryable(
                                operation: operation, stage: stage, code: code,
                                typedNotReady: readinessNotReady)).wire
                    }
                } else if let policyError = error as? V3KnownSourcePolicyFailure {
                    let network = policyError.kind == .network
                    response["failure"] = CombinedFailure(operation: "source", stage: .source,
                        code: network ? .failed : .invalidResponse, id: id,
                        underlying: NSError(domain: policyError.underlyingDomain, code: policyError.underlyingCode),
                        retryable: network ? true : nil,
                        safeCause: network ? .knownSourcePolicyNetworkFailure : .knownSourcePolicyInvalidResponse,
                        sourceStep: network ? .knownSourcePolicyFetch : .knownSourcePolicyParsing).wire
                } else if let sourceError = error as? V3SourceCommandError {
                    switch sourceError.kind {
                    case .network:
                        response["failure"] = CombinedFailure(operation: "source", stage: .source, code: .failed,
                            id: id, underlying: NSError(domain: sourceError.domain, code: sourceError.code),
                            retryable: true, safeCause: sourceError.safeCause,
                            sourceStep: sourceError.sourceStep).wire
                    case .invalidManifest:
                        response["failure"] = CombinedFailure(operation: "source", stage: .source, code: .invalidResponse,
                            id: id, underlying: NSError(domain: sourceError.domain, code: sourceError.code),
                            retryable: false, safeCause: sourceError.safeCause,
                            sourceStep: sourceError.sourceStep).wire
                    case .validation:
                        response["failure"] = CombinedFailure(operation: "source", stage: .source,
                            code: .invalidResponse, id: id,
                            underlying: NSError(domain: sourceError.domain, code: sourceError.code),
                            retryable: false, safeCause: sourceError.safeCause,
                            sourceStep: sourceError.sourceStep).wire
                    }
                } else if operation == "catalog" {
                    response["failure"] = CombinedFailure(operation: "catalog", stage: .catalog, code: .failed,
                        id: id, underlying: error, safeCause: .catalogUnavailable, sourceStep: .catalogRead).wire
                } else if let handoffError = error as? V3SecretHandoffError,
                          V3SecretHandoffFailurePolicy.applies(to: operation) {
                    // V3_SECRET_HANDOFF_FAILURE_TYPED_V1: the response never
                    // reached Apple, so this must not be reported as an
                    // authentication failure. It is a transport failure of the
                    // secure channel between the two signed processes, it belongs
                    // to persistence rather than authentication, and its OSStatus
                    // distinguishes an unauthorized group from an absent item.
                    V3SecretHandoffTrace.emit(handoffError.diagnostics)
                    response["failure"] = V3SecretHandoffFailurePolicy.failure(
                        handoffError, operation: operation, id: id).wire
                } else if let structuredFailure = error as? CombinedFailure {
                    // V3_WIRE_FAILURE_CORRELATION_V1: preserve the typed cause
                    // but correlate the reply to this XPC request, not to the
                    // auth/operation session that caused the failure.
                    response["failure"] = structuredFailure.correlating(to: id).wire
                } else if operation == "anisetteSync" {
                    // V3_ANISETTE_SYNC_FAILURE_V1: preserve Anisette operation
                    // identity and classify only typed transport/HTTP evidence.
                    response["failure"] = V3AnisetteSyncFailurePolicy.failure(error, id: id).wire
                } else {
                    response["failure"] = CombinedFailure.capture(
                        V3HeadlessPairingFailure.tagIfInvalidPairing(error),
                        operation: operation, stage: stage, id: id).wire
                }
                clearPreparedOperationRecoveryIfProven(request: request, reply: response)
            }
            let encoded = encode(response, operation: operation)
            if mutation && cacheResponse || cancellationReplay && cacheResponse {
                let cached: Bool
                if cancellationReplay {
                    cached = finishCancellationReplyReservation(id: id,
                        requestFingerprint: requestFingerprint, deadline: deadline, encoded: encoded)
                } else if completedCacheBudget.record(encoded.count, controlResponse: controlReply) {
                    completed[id] = (encoded, deadline)
                    completedRequestFingerprints[id] = requestFingerprint
                    cached = true
                } else {
                    cached = false
                }
                if !cached {
                    // Admission reserves one full maximum-size response before
                    // dispatch. Reaching this branch means cache accounting
                    // lost a reservation while the command was running.
                    debugLog("[V3_WIRE] mutation_reply_cache_reservation_failed operation=\(operation)")
                }
            }
            reply(encoded)
        }
        deadlineTasks[id] = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000))
            } catch { return }
            guard self.tasks[id] != nil else {
                self.deadlineTasks[id] = nil
                return
            }
            self.deadlineTasks[id] = nil
            if let session = self.pendingAuthStartSessions[id] {
                _ = V3HeadlessRuntime.shared.auth.cancelBeforeBegin(id: session)
            }
            self.tasks[id]?.cancel()
            self.cancellations[id]?()
        }
    }

    enum ServiceError: String, Error { case notReady, invalidRequest, notFound, unsupported, busy }

    // Reads only the envelope fields the contract already trusts: the request ID
    // must be a valid UUID and the operation must be on the allow list. Nothing
    // from the payload is echoed back.
    private func invalidRequestReply(for data: Data) -> [String: Any] {
        let identity = V3WireContract.invalidRequestIdentity(from: data)
        let id = identity.id ?? UUID().uuidString
        let operation = identity.operation ?? "command"
        let identifierCollision = identity.id.map {
            V3RequestReplayPolicy.isIdentifierCollision(
                cachedFingerprint: inFlightRequestFingerprints[$0] ?? completedRequestFingerprints[$0],
                incomingRequestData: data)
        } ?? false
        var response: [String: Any] = ["version": 1, "id": id, "error": "invalidRequest",
                "failure": CombinedFailure(operation: operation, stage: .command,
                    code: .invalidConfiguration, id: id).wire]
        let directRequest = V3DirectMutationRecoveryRecord.allowedOperations.contains(operation)
        var directJournalReadable = true
        let heldDirectRequestID: String?
        if directRequest {
            do { heldDirectRequestID = try V3OperationRecoveryJournal.direct()?.requestID }
            catch { heldDirectRequestID = nil; directJournalReadable = false }
        } else {
            heldDirectRequestID = nil
        }
        if V3DirectMutationPreDispatchReplyPolicy.mayClaimInvalidRequestNotDispatched(
            operation: operation, requestID: identity.id,
            identifierCollision: identifierCollision, heldRequestID: heldDirectRequestID,
            journalReadable: directJournalReadable) {
            response["operationNotDispatched"] = true
        }
        return response
    }

    private func canReserveCancellationReply(operation: String) -> Bool {
        guard V3RequestReplayPolicy.requiresCompletedReply(operation: operation) else { return false }
        let controlReply = V3MutationReplyCacheBudget.isControlReply(operation: operation)
        return completed.count + pendingCancellationReplyReservations.count <
                V3MutationReplyCacheBudget.responseCountLimit(isControlResponse: controlReply) &&
            completedCacheBudget.canReserve(
                maximumResponseBytes: V3WireContract.responseLimit,
                preservingControlCapacity: !controlReply) &&
            V3MutationReplyCacheBudget.canAdmit(operation: operation, completedReplyCount: completed.count)
    }

    private func reserveCancellationReply(operation: String, id: String) -> Bool {
        guard !pendingCancellationReplyReservations.contains(id),
              canReserveCancellationReply(operation: operation),
              completedCacheBudget.record(V3WireContract.responseLimit, controlResponse: true) else { return false }
        pendingCancellationReplyReservations.insert(id)
        return true
    }

    private func finishCancellationReplyReservation(id: String, requestFingerprint: Data,
                                                     deadline: Date, encoded: Data) -> Bool {
        guard pendingCancellationReplyReservations.remove(id) != nil else { return false }
        completedCacheBudget.remove(V3WireContract.responseLimit)
        guard completedCacheBudget.record(encoded.count, controlResponse: true) else { return false }
        completed[id] = (encoded, deadline)
        completedRequestFingerprints[id] = requestFingerprint
        return true
    }

    // V3_RESPONSE_CLASSIFICATION_CARRIER_V1: the encoder and its typed fallback
    // live in the shared wire contract so the host's classifier and the
    // service's encoder can be executed together against real bytes. The
    // classification travels in the structured envelope's safeCause, not only in
    // the legacy "error" token: the host prefers the structured failure and
    // throws it, so a token-only classification was discarded on arrival and
    // every encoding failure reached the user as a generic invalidResponse.
    private func encode(_ value: [String: Any], operation: String = "command") -> Data {
        let correlationID = value["id"] as? String ?? ""
        let encoded = V3ResponseEncoder.encodeDetailed(value, operation: operation,
            limit: V3WireContract.responseLimit)
        // A fallback reply is a defect and it must be visible. A serialization or
        // oversize regression is otherwise indistinguishable in the field from
        // the failure it causes, because the host reports a generic
        // invalidResponse either way. Only the classification and the
        // correlation are recorded; the value that could not be encoded, and
        // the raw error text, never are.
        if let token = encoded.fallbackToken {
            debugLog("[V3_ENCODE] FAIL operation=\(operation) request_id=\(correlationID) classification=\(token) correlated=\(correlationID.isEmpty ? "no" : "yes")")
        }
        return encoded.data
    }

    private func settleOperationRecoveryIfTerminal(_ reply: [String: Any], requestedSessionID: String) {
        let state = reply["state"] as? String
        let outcomeUnknown = V3OperationReplyFieldPolicy.outcomeUnknown(reply["outcomeUnknown"])
        let backendSettled = !outcomeUnknown && V3WireContract.strictBool(reply["backendSettled"]) == true
        _ = try? V3OperationRecoveryJournal.settle(sessionID: requestedSessionID,
            replySessionID: reply["session"] as? String, state: state, backendSettled: backendSettled)
    }

    private func clearPreparedOperationRecoveryIfProven(request: [String: Any], reply: [String: Any]) {
        guard request["operation"] as? String == "opStart",
              let requestID = request["id"] as? String,
              reply["id"] as? String == requestID,
              V3WireContract.strictBool(reply["operationNotDispatched"]) == true,
              let payload = request["payload"] as? [String: Any],
              let sessionID = payload["session"] as? String else { return }
        _ = try? V3OperationRecoveryJournal.clearPreparedAfterNotDispatched(
            sessionID: sessionID, expectedRequestID: requestID,
            replyRequestID: reply["id"] as? String, operationNotDispatched: true)
    }

    private func signingStorageFailure(operation: String, id: String) -> CombinedFailure? {
        V3CertificateStorageAdmission.failure(operation: operation, id: id,
            databaseRequiresReconciliation: V3AccountDatabaseRecovery.requiresReconciliation,
            keychainRequiresReconciliation: { try Keychain.shared.storageRequiresReconciliation() })
    }

    private func run(_ operation: String, request: [String: Any], id: String) async throws -> [String: Any] {
        let context = DatabaseManager.shared.viewContext
        let target = request["target"] as? String ?? ""
        let payload = request["payload"] as? [String: Any] ?? [:]
        switch operation {
        case "snapshot":
            if V3WireContract.strictBool(payload["readinessOnly"]) == true {
                return ["ready": DatabaseManager.shared.isStarted]
            }
            return try snapshot()
        case "directRecoveryInspect":
            return try await directRecoveryInspection(requestID: target)
        case "directRecoveryReconcile":
            let acknowledgesTerminal = V3WireContract.strictBool(payload["ackTerminal"]) == true
            let userConfirmed = V3WireContract.strictBool(payload["userConfirmed"]) == true
            guard acknowledgesTerminal != userConfirmed,
                  let record = try V3OperationRecoveryJournal.direct(), record.requestID == target else {
                throw ServiceError.invalidRequest
            }
            let current = try V3OperationRecoveryJournal.markDirectUnknownIfOwnerLost(
                requestID: target, currentServiceInstanceID: recoveryServiceInstanceID) ?? record
            guard current.phase != .dispatched else { throw ServiceError.busy }
            guard (current.phase == .terminal && acknowledgesTerminal) ||
                  ((current.phase == .prepared || current.phase == .unknown) && userConfirmed) else {
                throw ServiceError.invalidRequest
            }
            let postcondition = current.phase == .prepared
                ? "notDispatched" : await directRecoveryPostcondition(current)
            guard try V3OperationRecoveryJournal.reconcileDirect(requestID: target,
                allowUnknownDeviceCheck: current.phase == .unknown && userConfirmed) else { throw ServiceError.busy }
            return ["requestID": target, "reconciled": true, "postcondition": postcondition]
        case "refreshAdmissionBegin":
            guard refreshAdmission.acquire(runID: target,
                    requestID: id,
                    authenticationActive: V3HeadlessRuntime.shared.auth.hasActiveSession,
                    anotherMutationActive: (mutationID != nil && mutationID != id) ||
                        V3HeadlessRuntime.shared.operations.activeMutationID != nil
                    // This ownership lifetime follows the native refresh timeout,
                    // not the short XPC begin-request deadline.
                    ) else {
                throw ServiceError.busy
            }
            do {
                guard try V3OperationRecoveryJournal.reserve(sessionID: target, kind: "refreshAll") else {
                    throw ServiceError.busy
                }
            } catch {
                _ = refreshAdmission.release(runID: target)
                throw ServiceError.busy
            }
            return ["runID": target, "admitted": true]
        case "refreshAdmissionEnd":
            guard let parsed = UUID(uuidString: target), parsed.uuidString == target else {
                throw ServiceError.invalidRequest
            }
            guard let terminalState = payload["state"] as? String,
                  ["completed", "failed", "notDispatched"].contains(terminalState) else {
                throw ServiceError.invalidRequest
            }
            let recovery: V3OperationRecoveryRecord?
            do { recovery = try V3OperationRecoveryJournal.current() }
            catch { throw ServiceError.busy }
            guard let recovery else {
                guard !refreshAdmission.isActive else { throw ServiceError.busy }
                return ["runID": target, "released": true, "alreadyReleased": true]
            }
            guard recovery.kind == "refreshAll", recovery.sessionID == target,
                  try V3OperationRecoveryJournal.settleRefreshAdmission(runID: target,
                    terminalState: terminalState, terminalConfirmed: true) else {
                throw ServiceError.notFound
            }
            _ = refreshAdmission.release(runID: target)
            return ["runID": target, "released": true]
        case "refreshAdmissionReconcile":
            guard let parsed = UUID(uuidString: target), parsed.uuidString == target,
                  V3WireContract.strictBool(payload["userConfirmed"]) == true,
                  refreshAdmission.ownerLost else {
                throw ServiceError.invalidRequest
            }
            do {
                guard try V3OperationRecoveryJournal.reconcileRefreshAdmissionAfterDeviceCheck(
                    runID: target, userConfirmed: true) else { throw ServiceError.invalidRequest }
            } catch { throw ServiceError.busy }
            _ = refreshAdmission.release(runID: target)
            return ["runID": target, "released": true, "reconciled": true]
        case "appIcon":
            let app: InstalledApp = try object(target)
            guard let image = try await app.loadIcon() else { return [:] }
            try Task.checkCancellation()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 192, height: 192), format: format).image { _ in
                image.draw(in: CGRect(x: 0, y: 0, width: 192, height: 192))
            }
            guard let data = thumbnail.pngData(), data.count <= 262_144 else { return [:] }
            return ["icon": data]
        case "backupResult":
            guard let result = V3BackupCallbackResult(session: target, payload: payload),
                  V3HeadlessRuntime.shared.operations.acceptBackupCallback(result) else {
                throw ServiceError.invalidRequest
            }
            return ["session": target, "accepted": true]
        case "catalog":
            // V3_CATALOG_DIAGNOSTICS_V1: the catalog read is measured with
            // privacy-safe facts only: whether the source row exists, whether
            // its identifier matches the request, and how many catalog rows were
            // returned. No source identifier, URL, name, bundle identifier,
            // description, object URI, or filesystem path is ever recorded.
            let sourceQuery = NSFetchRequest<Source>(entityName: "Source")
            sourceQuery.predicate = NSPredicate(format: "identifier == %@", target)
            sourceQuery.fetchLimit = 1
            let storedSource = try context.fetch(sourceQuery).first
            // V3_CATALOG_SOURCE_MISSING_V1: a source that no longer exists must
            // not be reported as a valid source with zero apps, or a stale
            // catalog screen becomes indistinguishable from an empty catalog.
            // This is NOT a manifest problem and is never reported as one.
            guard let storedSource else {
                throw V3SideStoreServiceError.catalogSourceUnavailable
            }
            let sourceMatch = storedSource.identifier == target
            let query = NSFetchRequest<StoreApp>(entityName: "StoreApp")
            query.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                StoreApp.visibleAppsPredicate, NSPredicate(format: "sourceIdentifier == %@", target)])
            let offset = request["cursor"] as? Int ?? 0
            query.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true),
                                     NSSortDescriptor(key: "bundleIdentifier", ascending: true)]
            query.fetchOffset = offset
            query.fetchLimit = 51
            let fetched = try context.fetch(query)
            let apps = Array(fetched.prefix(50))
            debugLog("[V3_CATALOG] RESULT operation=catalog stage=catalogRead request_id=\(id) cursor=\(offset) source_found=yes source_identifier_match=\(sourceMatch ? "yes" : "no") catalog_row_count=\(apps.count) has_more=\(fetched.count > 50 ? "yes" : "no")")
            return ["apps": apps.map { app in
                // V3_CATALOG_ROW_PLIST_SAFE_V1: the row is built explicitly and
                // every value is unwrapped. An app that is not installed has no
                // installedVersion, and an absent key is the correct encoding of
                // an absent value: placing a Swift Optional into this dictionary
                // boxes Optional.none into Any, which PropertyListSerialization
                // cannot encode, so the whole catalog response would fail to
                // serialize even though the Core Data read succeeded.
                V3WireContract.V3PropertyListValue.dictionary([
                    "identifier": app.objectID.uriRepresentation().absoluteString,
                    "bundleID": app.bundleIdentifier,
                    "name": app.name,
                    // Coalesced to a concrete String: the host renders this as a
                    // non-optional version label, so the placeholder is part of
                    // the display contract rather than a leaked Optional.
                    "version": app.latestSupportedVersion?.version ?? "Unavailable",
                    "developer": app.developerName,
                    "description": app.localizedDescription,
                    "iconURL": app.iconURL.absoluteString,
                    "downloadURL": app.latestSupportedVersion?.downloadURL.absoluteString ?? "",
                    "canInstall": app.latestSupportedVersion != nil,
                    "installedID": app.installedApp?.objectID.uriRepresentation().absoluteString ?? "",
                    // The only field that was genuinely optional. It is omitted
                    // entirely when the app is not installed. The host already
                    // models it as an optional, so no placeholder is invented and
                    // no Optional is boxed into the response graph.
                    "installedVersion": app.installedApp?.version
                ])
            }, "nextCursor": fetched.count > 50 ? offset + 50 : -1]
        case "signOut":
            // Resolve any interrupted activation while its prior/intended rows
            // still exist. Sign Out cannot silently erase ambiguous evidence.
            if V3AccountDatabaseRecovery.requiresReconciliation {
                try await v3ReconcileAccountDatabaseStorage()
            }
            try V3BackendCommands.prepareSignOut()
            // Preserve reusable certificate and anisette state, matching upgrade preservation.
            AuthManager.shared.signOut(keepCertificate: true, keepAnisetteData: true)
            return try snapshot()
        case "syncAppIDs":
            let credentials = AuthManager.shared.authenticationSnapshot
            if !V3AuthIdentityBindingPolicy.hasTokenBackedRoute(
                credentialRoutePresent: credentials?.isAuthenticated == true,
                dsid: credentials?.appleIDAdsid, xcodeToken: credentials?.appleIDXcodeToken) {
                throw V3SideStoreServiceError.authRequired
            }
            try await callback { done in AppManager.shared.syncAppIDs(completionHandler: done) }
            return try snapshot()
        case "clearCache":
            try await callback { done in AppManager.shared.clearAppCache(completion: done) }
            return try snapshot()
        case "refreshSources":
            try await ensureKnownSourcesUpdated()
            try await callback { done in AppManager.shared.updateAllSources(completion: done) }
            return try snapshot()
        case "jit":
            let app: InstalledApp = try object(target)
            try await callback { done in AppManager.shared.enableJIT(for: app, completionHandler: done) }
            return try snapshot()
        case "authReconcileStorage":
            // This is a gated local readback repair, never a remote provisioning retry.
            try await V3HeadlessRuntime.shared.auth.reconcileStorage()
            return try snapshot()
        case "authBegin":
            guard !V3HeadlessRuntime.shared.auth.provisioningRecoveryRequiresReconciliation else {
                throw ServiceError.busy
            }
            guard let deadline = payload["sessionDeadline"] as? Date,
                  deadline > Date(), deadline.timeIntervalSinceNow <= V3WireContract.authSessionLifetime + 10,
                  let session = payload["session"] as? String, session == target else {
                throw ServiceError.invalidRequest
            }
            guard !V3HeadlessRuntime.shared.auth.hasActiveSession else { throw ServiceError.busy }
            let reauthenticate = payload["provisioningLogin"] as? Bool == true
            if reauthenticate && !V3HeadlessRuntime.shared.auth.canReauthenticateProvisioning() {
                throw ServiceError.busy
            }
            return await V3HeadlessRuntime.shared.auth.begin(deadline: deadline,
                mode: reauthenticate ? .reauthenticateProvisioning : .interactive,
                requestDeadline: request["deadline"] as? Date, sessionID: session)
        case "authRetryProvisioning":
            guard !V3HeadlessRuntime.shared.auth.provisioningRecoveryRequiresReconciliation else {
                throw ServiceError.busy
            }
            // V3_PROVISIONING_RESUME_V1: Apple authentication already succeeded.
            // This re-enters provisioning with the saved session so credentials
            // and 2FA are never requested a second time.
            guard let deadline = payload["sessionDeadline"] as? Date,
                  deadline > Date(), deadline.timeIntervalSinceNow <= V3WireContract.authSessionLifetime + 10,
                  let session = payload["session"] as? String, session == target else {
                throw ServiceError.invalidRequest
            }
            guard !V3HeadlessRuntime.shared.auth.hasActiveSession else { throw ServiceError.busy }
            return await V3HeadlessRuntime.shared.auth.begin(deadline: deadline,
                mode: .resumeProvisioning, requestDeadline: request["deadline"] as? Date,
                sessionID: session)
        case "authPoll":
            guard let reply = V3HeadlessRuntime.shared.auth.poll(id: target) else {
                throw CombinedFailure(operation: "signIn", stage: .authentication,
                    code: .invalidResponse, id: target, retryable: false,
                    safeCause: .authSessionUnavailable)
            }
            return reply
        case "authRespond":
            guard let promptID = payload["prompt"] as? String,
                  let answer = payload["answer"] as? [String: String] else {
                throw ServiceError.invalidRequest
            }
            // The answer arrives in this request. It is not written to a shared
            // Keychain group first: the extension may not be entitled to the
            // host's group after re-signing. `promptID` makes delivery one-shot: `respond` accepts
            // an answer only for the prompt this session currently holds.
            V3SecretHandoffTrace.emit(V3SecretHandoffDiagnostics(
                role: V3SecretHandoffRole.service, operation: "authRespond",
                tokenWellFormed: !answer.isEmpty))
            guard let reply = V3HeadlessRuntime.shared.auth.respond(id: target, promptID: promptID, answer: answer) else {
                throw ServiceError.invalidRequest
            }
            // Only now is the response in SideSign's hands. Nothing before this
            // line involved Apple.
            V3SecretHandoffTrace.emit(V3SecretHandoffDiagnostics(
                role: V3SecretHandoffRole.service, operation: "authDelivered",
                groupDiscovered: true, tokenWellFormed: true))
            return reply
        case "authCancel":
            guard await V3HeadlessRuntime.shared.auth.cancelAndWait(id: target) else { throw ServiceError.invalidRequest }
            guard let reply = V3HeadlessRuntime.shared.auth.poll(id: target) else { throw ServiceError.invalidRequest }
            return reply
        case "opRecoveryPrepare":
            guard let kind = payload["kind"] as? String,
                  let session = payload["session"] as? String,
                  let operationTarget = payload["target"] as? String else {
                throw ServiceError.invalidRequest
            }
            let stagedIPAToken = kind == "installSharedIPA" ? operationTarget : nil
            do {
                guard try V3OperationRecoveryJournal.reserve(sessionID: session, kind: kind,
                    stagedIPAToken: stagedIPAToken) else { throw ServiceError.busy }
            } catch { throw ServiceError.busy }
            return ["session": session, "kind": kind, "phase": "prepared"]
        case "recoveryDiscardUnreadable":
            guard target.isEmpty, V3WireContract.strictBool(payload["userConfirmed"]) == true else {
                throw ServiceError.invalidRequest
            }
            do {
                guard try V3OperationRecoveryJournal.discardUnreadableAfterDeviceCheck(userConfirmed: true) else {
                    throw CombinedFailure(operation: operation, stage: .persistence,
                        code: .busy, id: id, retryable: false, safeCause: .operationInProgress)
                }
            } catch let failure as V3RecoveryStorageFailure {
                throw failure.combined(operation: operation, id: id)
            }
            if refreshAdmission.ownerLost, let runID = refreshAdmission.runID {
                _ = refreshAdmission.release(runID: runID)
            }
            return ["discardedUnreadable": true]
        case "opRecoveryReconcile":
            guard let parsedID = UUID(uuidString: target), parsedID.uuidString == target,
                  V3WireContract.strictBool(payload["userConfirmed"]) == true else {
                throw ServiceError.invalidRequest
            }
            do {
                guard try V3OperationRecoveryJournal.reconcileAfterDeviceCheck(
                    sessionID: target, userConfirmed: true) else { throw ServiceError.invalidRequest }
            } catch { throw ServiceError.busy }
            return ["session": target, "reconciled": true]
        case "opStart":
            guard let kind = payload["kind"] as? String,
                  let session = payload["session"] as? String,
                  let deadline = request["deadline"] as? Date else { throw ServiceError.invalidRequest }
            let value: Bool?
            if let rawValue = payload["value"] {
                guard let parsedValue = V3WireContract.strictBool(rawValue) else {
                    throw ServiceError.invalidRequest
                }
                value = parsedValue
            } else {
                value = nil
            }
            let opTarget = payload["target"] as? String ?? target
            let stagedIPAToken = kind == "installSharedIPA" ? opTarget : nil
            do {
                guard try V3OperationRecoveryJournal.beginDispatch(sessionID: session, kind: kind,
                    stagedIPAToken: stagedIPAToken) else { throw ServiceError.busy }
            } catch { throw ServiceError.busy }
            let result = await V3HeadlessRuntime.shared.operations.start(kind: kind, target: opTarget,
                value: value, sessionID: session, deadline: deadline)
            settleOperationRecoveryIfTerminal(result, requestedSessionID: session)
            return result
        case "opPoll":
            guard let reply = V3HeadlessRuntime.shared.operations.poll(id: target) else { throw ServiceError.invalidRequest }
            settleOperationRecoveryIfTerminal(reply, requestedSessionID: target)
            return reply
        case "opAnswer":
            guard let promptID = payload["prompt"] as? String,
                  let answer = payload["answer"] as? [String: String] else {
                throw ServiceError.invalidRequest
            }
            guard let reply = V3HeadlessRuntime.shared.operations.answer(id: target, promptID: promptID, answer: answer) else {
                throw ServiceError.invalidRequest
            }
            settleOperationRecoveryIfTerminal(reply, requestedSessionID: target)
            return reply
        case "opCancel":
            let hostReportedKnownStarted = V3WireContract.strictBool(payload["knownStarted"]) ?? true
            let cancellationRecovery: V3OperationRecoveryRecord?
            do { cancellationRecovery = try V3OperationRecoveryJournal.current() }
            catch { throw ServiceError.busy }
            let knownStarted = V3OperationCancelKnownStartedPolicy.resolve(sessionID: target,
                hostReportedKnownStarted: hostReportedKnownStarted, recovery: cancellationRecovery)
            guard let result = await V3HeadlessRuntime.shared.operations.cancelAndWait(
                id: target, knownStarted: knownStarted) else {
                throw ServiceError.invalidRequest
            }
            if knownStarted {
                settleOperationRecoveryIfTerminal(result, requestedSessionID: target)
            } else {
                _ = try? V3OperationRecoveryJournal.clearPreparedAfterConfirmedCancellation(
                    sessionID: target, replySessionID: result["session"] as? String,
                    state: result["state"] as? String,
                    backendSettled: V3WireContract.strictBool(result["backendSettled"]) == true,
                    stopConfirmed: V3WireContract.strictBool(result["stopConfirmed"]) == true,
                    knownStarted: false)
            }
            return result
        case "ipaCleanup":
            let recovery: V3OperationRecoveryRecord?
            do { recovery = try V3OperationRecoveryJournal.current() }
            catch { throw ServiceError.busy }
            if recovery?.stagedIPAToken == target {
                throw ServiceError.busy
            }
            try V3HeadlessRuntime.shared.operations.cleanupIPA(token: target)
            return [:]
        case "ipaActiveTokens":
            let lease: V3OperationRecoveryRecord?
            do { lease = try V3OperationRecoveryJournal.current() }
            catch { throw ServiceError.busy }
            var tokens = V3HeadlessRuntime.shared.operations.activeStagedIPATokens()
            if let token = lease?.stagedIPAToken { tokens.append(token) }
            return ["tokens": Array(Set(tokens)).sorted().prefix(512).map { $0 }]
        case "certList":
            return ["certificates": V3BackendCommands.certificates()]
        case "certExportActive":
            let auth = AuthManager.shared
            guard auth.v3IdentityIsStable, !V3HeadlessRuntime.shared.auth.hasActiveSession else {
                throw ServiceError.notFound
            }
            let capturedStamp = auth.v3IdentityStamp
            let authSnapshot = auth.authenticationSnapshot
            guard authSnapshot?.isAuthenticated == true,
                  let account = DatabaseManager.shared.activeAccount(),
                  let teamRecord = DatabaseManager.shared.activeTeam(),
                  teamRecord.account?.identifier == account.identifier,
                  V3AuthIdentityBindingPolicy.mayUseTeam(
                    sessionOwner: authSnapshot?.appleIDEmailAddress,
                    teamOwner: account.appleID) else { throw ServiceError.notFound }
            let team = teamRecord.identifier
            guard !team.isEmpty else { throw ServiceError.notFound }
            guard let active = CertificateManager.shared.activeCertificate,
                  let der = active.certificate.x509.data else { throw ServiceError.notFound }
            // Upstream supports both password-protected and unencrypted P12s.
            // The host's existing parser accepts an empty passphrase for the latter.
            let password = active.password ?? ""
            let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            guard let exported = V3ActiveCertificateExportAdapter.response(
                      p12Data: active.p12Data, password: password,
                      teamIdentifier: team, identitySHA256: fingerprint),
                  auth.v3IdentityIsStable, auth.v3IdentityStamp == capturedStamp,
                  !V3HeadlessRuntime.shared.auth.hasActiveSession,
                  let current = CertificateManager.shared.activeCertificate,
                  current.p12Data == active.p12Data, current.password == active.password,
                  current.certificate.x509.data == der,
                  DatabaseManager.shared.activeTeam()?.identifier == team,
                  DatabaseManager.shared.activeAccount()?.identifier == account.identifier,
                  DatabaseManager.shared.activeTeam()?.account?.identifier == account.identifier else {
                throw ServiceError.notFound
            }
            return exported
        case "certSetActive":
            guard let certificate = CertificateManager.shared.getLocalCertificate(serialNumber: target) else {
                throw ServiceError.notFound
            }
            try CertificateManager.shared.setActiveCertificate(certificate)
            return try snapshot()
        case "certDelete":
            CertificateManager.shared.deleteCertificate(serialNumber: target)
            return try snapshot()
        case "certPortalList":
            return try await accountScopedRead("certificates") {
                try await V3BackendCommands.portalCertificates()
            }
        case "certRevoke":
            _ = try await AuthManager.shared.getAuthenticatedSession()
            let team = try await AuthManager.shared.getAuthenticatedTeam()
            let certificates = try await DeveloperPortalProxy.shared.fetchCertificates(team: team)
            guard let certificate = certificates.first(where: { $0.serialNumber == target }) else {
                throw ServiceError.notFound
            }
            // Account lookups above suspend; recheck immediately at dispatch.
            if let failure = signingStorageFailure(operation: operation, id: id) { throw failure }
            _ = try await DeveloperPortalProxy.shared.revokeCertificate(certificate, team: team)
            return try snapshot()
        case "certCreate":
            _ = try await AuthManager.shared.getAuthenticatedSession()
            let team = try await AuthManager.shared.getAuthenticatedTeam()
            let name = UIDevice.current.name
            let outcome = try await V3CertificateCreateAdapter.createAndPersist(
                create: {
                    // Recheck after asynchronous account/team lookup. The
                    // existing dispatched journal still owns any later error.
                    if let failure = self.signingStorageFailure(operation: operation, id: id) { throw failure }
                    return try await DeveloperPortalProxy.shared.createCertificate(
                        machineName: "SideStore - \(team.name)'s \(name)", team: team)
                },
                persist: { certificate in
                    // Reuse SideStore's canonical local certificate storage.
                    // Its save API is non-throwing and can suppress conversion
                    // failures, so success is decided only by the read-back.
                    CertificateManager.shared.saveCertificate(certificate)
                },
                verifyStored: { certificate in
                    let parsedSerial: String? = Keychain.shared[certificateSerial: certificate.serialNumber]
                        .flatMap { p12 in
                            try? CertificateManager.parse(
                                p12, password: CertificateManager.shared.getPassword(for: certificate.serialNumber))
                        }?.serialNumber
                    let enumeratedSerials = CertificateManager.shared.getAllLocalX509Certificates()
                        .map(\.serialNumber)
                    // These are separate persisted facts: validate the actual
                    // per-serial PKCS#12 and SideStore's canonical local index.
                    return V3CertificateCreateAdapter.matchesStoredCertificate(
                        expectedSerial: certificate.serialNumber,
                        parsedSerial: parsedSerial,
                        enumeratedSerials: enumeratedSerials)
                })
            // Do not return a generic failure after Apple has created the
            // certificate: that could encourage a duplicate portal request.
            // The host distinguishes a verified local copy from this partial
            // remote-success outcome and directs the user to inspect/reload.
            return ["outcome": outcome.rawValue]
        case "devTeams":
            return try await accountScopedRead("teams") { try await V3BackendCommands.developerTeams() }
        case "devDevices":
            return try await accountScopedRead("devices") { try await V3BackendCommands.developerDevices() }
        case "devAppIDs":
            return try await accountScopedRead("appIDs") { try await V3BackendCommands.developerAppIDs() }
        case "devGroups":
            return try await accountScopedRead("groups") { try await V3BackendCommands.developerGroups() }
        case "devProfiles":
            return try await accountScopedRead("profiles") { try await V3BackendCommands.developerProfiles() }
        case "sourcePreview":
            guard V3SourceAddPersistencePolicy.validatedURL(target) != nil else {
                throw V3SideStoreServiceError.invalidRequest
            }
            try await ensureKnownSourcesUpdated()
            return try await V3BackendCommands.sourcePreview(urlString: target)
        case "sourceAddConfirmed":
            guard V3SourceAddPersistencePolicy.validatedURL(target) != nil else {
                throw V3SideStoreServiceError.invalidRequest
            }
            try await ensureKnownSourcesUpdated()
            let addResult = try await V3BackendCommands.sourceAddConfirmed(urlString: target)
            var updated = try snapshot()
            let persistedSources = try await V3BackendCommands.authoritativeSourceRows()
            let sourceID = addResult["identifier"] as? String ?? ""
            guard persistedSources.contains(where: { $0["identifier"] as? String == sourceID }) else {
                throw V3SideStoreServiceError.persistenceUnverified
            }
            updated["sources"] = persistedSources
            return updated.merging(addResult) { _, authoritative in authoritative }
        case "sourceRemoveConfirmed":
            try await V3BackendCommands.sourceRemoveConfirmed(identifier: target)
            return try snapshot()
        case "pairingImportData":
            try V3BackendCommands.pairingImportData(token: target)
            return try snapshot()
        case "settingsGet":
            return V3BackendCommands.settingsGet()
        case "settingsSet":
            try V3BackendCommands.settingsSet(payload: payload)
            return try snapshot()
        case "anisetteList":
            return ["servers": await V3BackendCommands.anisetteList()]
        case "anisetteReset":
            _ = try await AnisetteServersManager.shared.resetToOriginalState()
            return ["servers": await V3BackendCommands.anisetteList()]
        case "anisetteSync":
            _ = try await AnisetteServersManager.shared.syncWithRemote()
            return ["servers": await V3BackendCommands.anisetteList()]
        case "sidesignGet":
            return ["config": try await V3BackendCommands.sidesignConfigText()]
        case "sidesignSet":
            guard let config = payload["config"] as? String else { throw ServiceError.invalidRequest }
            try await V3BackendCommands.sidesignSet(config: config)
            return ["config": try await V3BackendCommands.sidesignConfigText()]
        case "sidesignReset":
            _ = SideSignConfigManager.shared.resetToDefaults()
            return ["config": try await V3BackendCommands.sidesignConfigText()]
        case "sidesignImport":
            try await V3BackendCommands.sidesignImport(token: target)
            return ["config": try await V3BackendCommands.sidesignConfigText()]
        case "sidesignExport":
            return ["config": try await V3BackendCommands.sidesignExportText()]
        case "logTail":
            return V3BackendCommands.logTail()
        case "healthSnapshot":
            // All-iOS host signing observation is local and never starts OCSP
            // or anisette/network work on devices that do not need JIT-Less.
            if target == "hostSigningOnly" { return await V3BackendCommands.hostSigningHealth() }
            return await V3BackendCommands.health()
        case "accountExport":
            guard let answer = payload["answer"] as? [String: String],
                  let password = answer["password"], !password.isEmpty else {
                throw ServiceError.invalidRequest
            }
            let includeApple: Bool
            if let rawIncludeApple = payload["includeApple"] {
                guard let parsedIncludeApple = V3WireContract.strictBool(rawIncludeApple) else {
                    throw ServiceError.invalidRequest
                }
                includeApple = parsedIncludeApple
            } else {
                includeApple = false
            }
            return ["backup": try V3BackendCommands.accountExport(password: password, includeApplePassword: includeApple)]
        case "accountImport":
            guard let answer = payload["answer"] as? [String: String],
                  let password = answer["password"], !password.isEmpty else { throw ServiceError.invalidRequest }
            AuthManager.shared.v3BeginIdentityTransition()
            defer { AuthManager.shared.v3CompleteIdentityTransition() }
            return try V3BackendCommands.accountImport(token: target, password: password)
        default: throw ServiceError.invalidRequest
        }
    }

    private func object<T: NSManagedObject>(_ identifier: String) throws -> T {
        guard let url = URL(string: identifier),
              let id = DatabaseManager.shared.persistentContainer.persistentStoreCoordinator.managedObjectID(forURIRepresentation: url),
              let object = try DatabaseManager.shared.viewContext.existingObject(with: id) as? T else { throw ServiceError.notFound }
        return object
    }

    private func directRecoveryInspection(requestID: String) async throws -> [String: Any] {
        guard let stored = try V3OperationRecoveryJournal.direct(), stored.requestID == requestID else {
            throw ServiceError.notFound
        }
        let record = try V3OperationRecoveryJournal.markDirectUnknownIfOwnerLost(
            requestID: requestID, currentServiceInstanceID: recoveryServiceInstanceID) ?? stored
        var response = safeDirectRecovery(record)
        response["postcondition"] = record.phase == .prepared
            ? "notDispatched" : await directRecoveryPostcondition(record)
        return response
    }

    private func safeDirectRecovery(_ record: V3DirectMutationRecoveryRecord) -> [String: Any] {
        var value: [String: Any] = ["requestID": record.requestID,
            "operation": record.operation, "phase": record.phase.rawValue]
        if let terminalOutcome = record.terminalOutcome { value["resultState"] = terminalOutcome }
        return value
    }

    private func directRecoveryPostcondition(_ record: V3DirectMutationRecoveryRecord) async -> String {
        if record.operation == "certCreate" {
            if record.terminalOutcome == "createdAndStored" { return "achieved" }
            return "manualCheckRequired"
        }
        if ["pairingImportData", "accountImport"].contains(record.operation) { return "manualCheckRequired" }
        if record.operation == "sourceAddConfirmed" || record.operation == "sourceRemoveConfirmed" {
            guard let targetDigest = record.targetDigest,
                  let rows = try? await V3BackendCommands.authoritativeSourceRows() else { return "indeterminate" }
            let matched = rows.contains { row in
                let value = record.operation == "sourceAddConfirmed" ? row["url"] : row["identifier"]
                guard let value = value as? String else { return false }
                return V3DirectMutationRecoveryHash.digest(value) == targetDigest
            }
            if record.operation == "sourceAddConfirmed" { return matched ? "achieved" : "indeterminate" }
            return matched ? "notAchieved" : "achieved"
        }
        if record.operation == "certRevoke" {
            guard let targetDigest = record.targetDigest, let teamDigest = record.teamDigest,
                  let identityStampDigest = record.identityStampDigest,
                  AuthManager.shared.v3IdentityIsStable,
                  V3DirectMutationRecoveryHash.digest(AuthManager.shared.v3IdentityStamp) == identityStampDigest,
                  let activeTeamID = DatabaseManager.shared.activeTeam()?.identifier,
                  V3DirectMutationRecoveryHash.digest(activeTeamID) == teamDigest,
                  let authenticatedTeam = try? await AuthManager.shared.getAuthenticatedTeam(),
                  V3DirectMutationRecoveryHash.digest(authenticatedTeam.identifier) == teamDigest,
                  let rows = try? await V3BackendCommands.portalCertificates() else { return "indeterminate" }
            return rows.contains { row in
                guard let serial = row["serial"] as? String else { return false }
                return V3DirectMutationRecoveryHash.digest(serial) == targetDigest
            } ? "notAchieved" : "achieved"
        }
        if record.operation == "settingsSet" {
            let current = V3BackendCommands.settingsGet()
            switch record.settingsType {
            case "bool":
                guard let key = record.settingsKey,
                      let expected = record.settingsBool,
                      let values = current["bools"] as? [String: Bool],
                      let actual = values[key] else { return "indeterminate" }
                return actual == expected ? "achieved" : "notAchieved"
            case "int":
                guard let key = record.settingsKey,
                      let expected = record.settingsInt,
                      let values = current["ints"] as? [String: Int],
                      let actual = values[key] else { return "indeterminate" }
                return actual == expected ? "achieved" : "notAchieved"
            case "string": return "manualCheckRequired"
            default: return "indeterminate"
            }
        }
        return "manualCheckRequired"
    }

    // Native callbacks may fire more than once or race on arbitrary queues.
    // The first terminal result wins; late callbacks are ignored. Cancellation
    // never releases the continuation early: the task keeps awaiting the
    // native terminal callback so the service mutation gate is not freed early.
    final class V3ServiceCallbackGate {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var settled = false
        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }
        func settle(_ result: Result<Void, Error>) {
            lock.lock()
            let pending = continuation
            let first = !settled
            settled = true
            continuation = nil
            lock.unlock()
            if first, let pending = pending {
                pending.resume(with: result)
            }
        }
    }
    // V3_NATIVE_CALLBACK_GATE_END

    private func callback(_ start: (@escaping (Result<Void, Error>) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = V3ServiceCallbackGate(continuation)
            start { result in gate.settle(result) }
        }
    }

    // Upstream SideStore refreshes its server-owned allow/block source lists at
    // launch. The headless backend has no launch screen, so source preview, add,
    // and source refresh run a bounded cached preflight before AppManager source
    // operations rely on UserDefaults.blockedSources. Concurrent callers share
    // one UpdateKnownSourcesOperation with a 15-second total time bound.
    private func ensureKnownSourcesUpdated() async throws {
        let defaults = UserDefaults.standard
        let hasCachedBlocklist = defaults.blockedSources != nil
        let lastUpdated = defaults.object(forKey: "v3KnownSourcesUpdatedAt") as? Date
        guard V3KnownSourcePreflightPolicy.shouldRefresh(
            hasCachedBlocklist: hasCachedBlocklist,
            lastSuccessfulUpdate: lastUpdated) else { return }

        if let knownSourcesUpdateTask {
            do { try await knownSourcesUpdateTask.value }
            catch { throw V3KnownSourcePolicyFailure.preservingCancellation(error) }
            guard defaults.blockedSources != nil else { throw ServiceError.notReady }
            return
        }
        let task = Task<Void, Error> { @MainActor in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await UpdateKnownSourcesOperation().execute()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    throw URLError(.timedOut)
                }
                let completedUpdate = try await group.next()
                guard case .some = completedUpdate else { throw CancellationError() }
                group.cancelAll()
            }
        }
        knownSourcesUpdateTask = task
        defer { knownSourcesUpdateTask = nil }
        do { try await task.value }
        catch { throw V3KnownSourcePolicyFailure.preservingCancellation(error) }
        guard defaults.blockedSources != nil else { throw ServiceError.notReady }
        defaults.set(Date(), forKey: "v3KnownSourcesUpdatedAt")
    }

    private func accountScopedRead(_ key: String,
                                   fetch: () async throws -> Any) async throws -> [String: Any] {
        let auth = AuthManager.shared
        guard auth.v3IdentityIsStable,
              !V3HeadlessRuntime.shared.auth.hasActiveSession else {
            throw V3SideStoreServiceError.authRequired
        }
        let capturedStamp = auth.v3IdentityStamp
        let value = try await fetch()
        guard auth.v3IdentityIsStable, auth.v3IdentityStamp == capturedStamp,
              !V3HeadlessRuntime.shared.auth.hasActiveSession else {
            throw V3SideStoreServiceError.authRequired
        }
        return [key: value, "identityStamp": capturedStamp, "identityStable": true]
    }

    private func snapshot() throws -> [String: Any] {
        let identityGenerationAtStart = AuthManager.shared.v3IdentityGeneration
        let identityStampAtStart = AuthManager.shared.v3IdentityStamp
        let context = DatabaseManager.shared.viewContext
        let apps = InstalledApp.all(in: context)
        let sources = try context.fetch(NSFetchRequest<Source>(entityName: "Source"))
        let storedTeam = DatabaseManager.shared.activeTeam()
        let activeCertificate = CertificateManager.shared.activeCertificate
        let certificate = activeCertificate?.certificate.x509
        // V3_AUTH_SESSION_SNAPSHOT_V1: Apple authentication can succeed before
        // the account row is activated, because activation happens at the end
        // of SignInOperation.finalizeAuthentication. Reporting "Not signed in"
        // in that window made a successful sign-in look like a failed one and
        // hid the authenticated session from Retry Provisioning. The session
        // itself is authoritative; the active row is reported separately as
        // provisioningIncomplete so no active team is ever implied.
        let storedAccount = DatabaseManager.shared.activeAccount()
        let authCredentials = AuthManager.shared.authenticationSnapshot
        let identityReadStable = AuthManager.shared.v3IdentityIsStable &&
            V3AuthIdentityBindingPolicy.mayProjectIdentity(
            generationBefore: identityGenerationAtStart,
            generationAfter: AuthManager.shared.v3IdentityGeneration) &&
            identityStampAtStart == AuthManager.shared.v3IdentityStamp
        let credentialRoutePresent = identityReadStable && authCredentials?.isAuthenticated == true
        let credentialAppleID = V3AuthIdentityBindingPolicy.normalizedOwner(authCredentials?.appleIDEmailAddress)
        let authenticated = credentialRoutePresent &&
            authCredentials?.appleIDAdsid?.isEmpty == false && authCredentials?.appleIDXcodeToken?.isEmpty == false
        let activeAccount = identityReadStable ? storedAccount.flatMap { candidate in
            V3AuthIdentityBindingPolicy.mayUseTeam(sessionOwner: credentialAppleID,
                teamOwner: candidate.appleID) ? candidate : nil
        } : nil
        let team = identityReadStable ? storedTeam.flatMap { candidate in
            // A directly attached account is authoritative. Only an ownerless
            // active team may inherit the current active account's identity.
            let owner = V3AuthIdentityBindingPolicy.normalizedOwner(candidate.account?.appleID) ??
                V3AuthIdentityBindingPolicy.resolveColdTeamOwner(
                    storedTeamOwners: [], activeTeamIdentifier: storedTeam?.identifier,
                    requestedTeamIdentifier: candidate.identifier,
                    activeAccountOwner: activeAccount?.appleID, sessionOwner: credentialAppleID)
            return V3AuthIdentityBindingPolicy.mayUseTeam(sessionOwner: credentialAppleID,
                teamOwner: owner) ? candidate : nil
        } : nil
        let account = activeAccount?.appleID ?? (identityReadStable && credentialRoutePresent
            ? authCredentials?.appleIDEmailAddress : nil) ?? "Not signed in"
        let activeAuthenticationSessionID = V3HeadlessRuntime.shared.auth.activeSessionIDForSnapshot
        _ = refreshAdmission.expire()
        let operationRecovery: V3OperationRecoveryRecord?
        var directRecoveryRecord: V3DirectMutationRecoveryRecord?
        let recoveryJournalUnreadable: Bool
        let recoveryStorageFailure: V3RecoveryStorageFailure?
        do {
            switch try V3OperationRecoveryJournal.currentState() {
            case .operation(let value): operationRecovery = value
            case .directMutation(let value):
                directRecoveryRecord = try V3OperationRecoveryJournal.markDirectUnknownIfOwnerLost(
                    requestID: value.requestID, currentServiceInstanceID: recoveryServiceInstanceID) ?? value
                operationRecovery = nil
            case nil: operationRecovery = nil
            }
            recoveryJournalUnreadable = false
            recoveryStorageFailure = nil
        } catch let failure as V3RecoveryStorageFailure {
            operationRecovery = nil; recoveryJournalUnreadable = true
            recoveryStorageFailure = failure
        } catch {
            operationRecovery = nil; recoveryJournalUnreadable = true
            recoveryStorageFailure = V3RecoveryStorageFailure(.readFailure, underlying: error)
        }
        let activeMutation = mutationID != nil || activeAuthenticationSessionID != nil ||
            V3HeadlessRuntime.shared.operations.activeMutationID != nil || refreshAdmission.isActive
        let provisioningState = V3HeadlessRuntime.shared.auth.provisioningCompletion.status(
            owner: credentialAppleID, identityStamp: identityStampAtStart, identityStable: identityReadStable,
            activeAccountPresent: activeAccount != nil, activeTeamPresent: team != nil,
            activeCertificatePresent: activeCertificate != nil,
            binding: v3ProvisioningCompletionBinding(credentials: authCredentials,
                teamID: team?.identifier, certificateSerial: activeCertificate?.certificate.serialNumber))
        let provisioningIncomplete = authenticated && provisioningState != "complete"
        let provisioningRetryAvailable = V3HeadlessRuntime.shared.auth.canResumeProvisioning()
        let provisioningReauthenticationAvailable = provisioningIncomplete && !provisioningRetryAvailable &&
            !activeMutation && operationRecovery == nil && directRecoveryRecord == nil && !recoveryJournalUnreadable &&
            V3HeadlessRuntime.shared.auth.canReauthenticateProvisioning()
        var response: [String: Any] = ["updatedAt": Date(), "busy": mutationID != nil ||
                    activeAuthenticationSessionID != nil ||
                    V3HeadlessRuntime.shared.operations.activeMutationID != nil || refreshAdmission.isActive ||
                    operationRecovery != nil || directRecoveryRecord != nil || recoveryJournalUnreadable,
                 "activeMutation": activeMutation,
                 "recoveryHold": operationRecovery != nil || directRecoveryRecord != nil || recoveryJournalUnreadable,
                 "recoveryJournalUnreadable": recoveryJournalUnreadable,
                 "account": account,
                 "authenticated": authenticated,
                 "credentialRoutePresent": credentialRoutePresent,
                 "identityStamp": identityStampAtStart,
                 "identityStable": identityReadStable,
                 "hostSigningContext": identityReadStable ? v3CurrentHostSigningContext()?.digest ?? "" : "",
                 "activeAccountPresent": activeAccount != nil,
                 "activeTeamPresent": team != nil,
                 "activeCertificatePresent": activeCertificate != nil,
                 "authenticationActive": activeAuthenticationSessionID != nil,
                 "provisioningIncomplete": provisioningIncomplete,
                 "provisioningState": provisioningState,
                 "accountRecoveryProtocol": 1,
                 "provisioningRecoveryRequiresReconciliation": V3HeadlessRuntime.shared.auth.provisioningRecoveryRequiresReconciliation,
                 "provisioningReauthenticationAvailable": provisioningReauthenticationAvailable,
                "provisioningRetryAvailable": provisioningRetryAvailable,
                "team": team?.name ?? "No active team", "teamID": team?.identifier ?? "",
                "signing": team == nil ? "Sign in required" : "Team selected",
                "certificate": activeCertificate == nil ? "No active certificate" : "Active certificate available",
                "certificateExpiration": certificate?.expiryDate ?? Date.distantPast,
                "pairing": V3BackendCommands.pairingFileStatus(),
                "installedApps": apps.map { app in
                    ["identifier": app.objectID.uriRepresentation().absoluteString,
                     "bundleID": app.bundleIdentifier, "name": app.name, "version": app.version,
                     "isActive": app.isActive, "expirationDate": app.expirationDate,
                     "refreshedDate": app.refreshedDate, "hasUpdate": app.hasUpdate,
                     "certificateStatus": app.certificateStatusRaw ?? "unknown",
                     "openURL": app.openAppURL.absoluteString,
                     "isHost": app.bundleIdentifier == StoreApp.altstoreAppID] as [String: Any]
                },
                "sources": sources.map { source in
                    ["identifier": source.identifier, "name": source.name, "subtitle": source.subtitle ?? "",
                     "url": source.sourceURL.absoluteString, "appCount": source.apps.count,
                     "canRemove": source.identifier != Source.altStoreIdentifier] as [String: Any]
                },
                "settings": ["betaUpdates": UserDefaults.standard.isBetaUpdatesEnabled,
                             "idleTimeoutDisabled": UserDefaults.standard.isIdleTimeoutDisableEnabled,
                             "responseCachingDisabled": UserDefaults.standard.responseCachingDisabled,
                             "verboseOperations": UserDefaults.standard.isVerboseOperationsLoggingEnabled]]
        if let recoveryStorageFailure {
            response["recoveryStorageFailure"] = recoveryStorageFailure.snapshotValue
        }
        response["recoveryAppGroup"] = V3OperationRecoveryJournal.runtimeAppGroupDiagnostic()
        if let activeSessionID = activeAuthenticationSessionID {
            response["authenticationSessionID"] = activeSessionID
        }
        if let operationRecovery, operationRecovery.kind != "refreshAll" {
            var safeRecovery: [String: Any] = ["session": operationRecovery.sessionID,
                "kind": operationRecovery.kind, "phase": operationRecovery.phase.rawValue]
            if let token = operationRecovery.stagedIPAToken { safeRecovery["stagedIPAToken"] = token }
            response["operationRecovery"] = safeRecovery
        }
        if let directRecoveryRecord {
            response["directRecovery"] = safeDirectRecovery(directRecoveryRecord)
        }
        if let operationRecovery, operationRecovery.kind == "refreshAll",
           !refreshAdmission.owns(operationRecovery.sessionID) {
            _ = refreshAdmission.restoreLost(runID: operationRecovery.sessionID)
        }
        if let operationRecovery, operationRecovery.kind == "refreshAll",
           refreshAdmission.ownerLost {
            response["refreshRecovery"] = ["runID": operationRecovery.sessionID, "ownerLost": true]
        } else if refreshAdmission.ownerLost, let runID = refreshAdmission.runID {
            response["refreshRecovery"] = ["runID": runID, "ownerLost": true]
        }
        return response
    }
}
import Foundation
import CoreData
import CryptoKit
import UIKit
import SideSign
import AnisetteKit
import Minimuxer
import MinimuxerCommon

enum V3HeadlessPairingFailure {
    static func tagIfInvalidPairing(_ error: Error) -> Error {
        if error is CombinedFailure { return error }
        guard let typedError = invalidPairingSource(error, depth: 0) else { return error }
        let native = typedError as NSError
        return NSError(domain: native.domain, code: native.code, userInfo: [
            NSLocalizedDescriptionKey: "SideStore could not read or validate the pairing file.",
            "LCStructuredFailureStageV1": CombinedFailure.Stage.pairing.rawValue,
            "LCStructuredFailureCauseV1": CombinedFailure.SafeCause.invalidPairingFile.rawValue
        ])
    }

    private static func invalidPairingSource(_ error: Error, depth: Int) -> Error? {
        guard depth < 8 else { return nil }
        if let operationError = error as? OperationError,
           case .invalidPairingFile(_) = operationError {
            return error
        }
        if let minimuxerError = error as? MinimuxerError,
           case .invalidPairing(_, _) = minimuxerError {
            return error
        }
        if let serviceError = error as? MinimuxerServiceError {
            return invalidPairingSource(serviceError.error, depth: depth + 1)
        }
        if let wrappedError = error as? ALTWrappedError {
            return invalidPairingSource(wrappedError.wrappedError, depth: depth + 1)
        }
        let native = error as NSError
        if let underlying = native.userInfo[NSUnderlyingErrorKey] as? Error,
           let found = invalidPairingSource(underlying, depth: depth + 1) {
            return found
        }
        if let underlying = native.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] {
            for error in underlying {
                if let found = invalidPairingSource(error, depth: depth + 1) { return found }
            }
        }
        return nil
    }
}

// V3_HEADLESS_RUNTIME_V1: SideStore executes as a headless backend. No window,
// presenter, view controller, picker, alert, or remotely rendered view exists
// on any normal path below. Every human decision crosses the bridge as data.

enum V3PromptAnswerDisposition: Equatable {
    case accepted
    case alreadySettled
    case unavailable
}

// Parked continuations resume from cancellation callbacks that run off-actor,
// so this center stays non-isolated and guards its boxes with a lock.
final class V3PromptCenter: @unchecked Sendable {
    private let lock = NSLock()
    private final class Pending: @unchecked Sendable {
        var continuation: CheckedContinuation<[String: String], Error>?
        var result: Result<[String: String], Error>?
    }
    private var boxes: [String: Pending] = [:]
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return boxes.count
    }

    func park(promptID: String, onReady: (@MainActor () -> Void)? = nil) async throws -> [String: String] {
        try Task.checkCancellation()
        let pending = Pending()
        let installed = lock.withLock { () -> Bool in
            guard boxes[promptID] == nil else { return false }
            boxes[promptID] = pending
            return true
        }
        guard installed else { throw NSError(domain: "V3Prompt", code: 1) }
        defer {
            lock.withLock {
                if boxes[promptID] === pending { boxes.removeValue(forKey: promptID) }
            }
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: String], Error>) in
                let result = self.lock.withLock { () -> Result<[String: String], Error>? in
                    if case nil = pending.result { pending.continuation = continuation }
                    return pending.result
                }
                if let result { continuation.resume(with: result) }
                else if let onReady {
                    Task { @MainActor in
                        guard self.isWaiting(promptID: promptID, pending: pending) else { return }
                        onReady()
                    }
                }
            }
        }, onCancel: {
            self.settle(promptID: promptID, pending: pending, result: .failure(CancellationError()))
        })
    }

    func answer(promptID: String, answer: [String: String]) -> V3PromptAnswerDisposition {
        lock.lock()
        let pending = boxes[promptID]
        lock.unlock()
        guard let pending else { return .unavailable }
        if settle(promptID: promptID, pending: pending, result: .success(answer)) { return .accepted }
        lock.lock()
        let stillPresent = boxes[promptID] === pending
        let alreadyAnswered: Bool
        if case .success? = pending.result { alreadyAnswered = true }
        else { alreadyAnswered = false }
        lock.unlock()
        return stillPresent && alreadyAnswered ? .alreadySettled : .unavailable
    }

    @discardableResult
    func cancel(promptID: String) -> Bool {
        lock.lock()
        let pending = boxes[promptID]
        lock.unlock()
        guard let pending else { return false }
        return settle(promptID: promptID, pending: pending, result: .failure(CancellationError()))
    }

    @discardableResult
    private func settle(promptID: String, pending: Pending, result: Result<[String: String], Error>) -> Bool {
        lock.lock()
        guard boxes[promptID] === pending, case nil = pending.result else {
            lock.unlock()
            return false
        }
        pending.result = result
        let continuation = pending.continuation
        pending.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }

    private func isWaiting(promptID: String, pending: Pending) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard boxes[promptID] === pending else { return false }
        if case nil = pending.result { return true }
        return false
    }
}

enum V3PromptResponseStatePolicy {
    static func shouldReturnCurrentStateAfterAcceptedDuplicate(acceptedPromptID: String?,
                                                               acceptedPromptIDs: [String] = [],
                                                               currentPromptID: String?,
                                                               submittedPromptID: String,
                                                               sessionTerminal: Bool = false,
                                                               cancellationRequested: Bool = false) -> Bool {
        (acceptedPromptID == submittedPromptID || acceptedPromptIDs.contains(submittedPromptID)) &&
            (sessionTerminal || cancellationRequested || currentPromptID != submittedPromptID)
    }

    static func recordAcceptedPrompt(_ acceptedPromptIDs: [String], promptID: String,
                                     limit: Int = 64) -> [String] {
        guard !promptID.isEmpty, limit > 0 else { return [] }
        var values = acceptedPromptIDs.filter { !$0.isEmpty && $0 != promptID }
        values.append(promptID)
        return Array(values.suffix(limit))
    }

    static func responsePending(_ disposition: V3PromptAnswerDisposition,
                                acceptedPromptID: String?, promptID: String,
                                sessionID: String, revision: Int,
                                state: String, prompt: [String: Any]?) -> [String: Any]? {
        guard disposition != .accepted, acceptedPromptID == promptID,
              prompt?["id"] as? String == promptID else { return nil }
        var reply: [String: Any] = ["session": sessionID, "state": state,
                                    "responsePending": true, "revision": revision]
        if let prompt { reply["prompt"] = prompt }
        return reply
    }
}

@MainActor
final class V3HeadlessRuntime {
    static let shared = V3HeadlessRuntime()
    let prompts = V3PromptCenter()
    let auth = V3AuthCenter()
    let operations = V3OperationCenter()

    func cancelSession(_ id: String, scope: String) -> Bool {
        switch scope {
        case "auth": return auth.cancelBeforeBegin(id: id)
        case "operation": return operations.cancelBeforeStart(id: id)
        case "request": return false
        default: return false
        }
    }
}

// MARK: - Prompt construction (plist-safe dictionaries only)

func v3Prompt(id: String = UUID().uuidString, kind: String, title: String, message: String,
              fields: [[String: String]] = [], options: [[String: String]] = [],
              destructive: Bool = false) -> [String: Any] {
    var prompt: [String: Any] = ["id": id, "kind": kind, "title": title, "message": message,
                                 "fields": fields, "options": options]
    if destructive { prompt["destructive"] = true }
    return prompt
}

// V3_PROMPT_OPTION_IDENTITY_V1: the host submits the selected option IDs as
// comma-separated strings. Decode those IDs against the raw values offered by
// this prompt so stale, forged, malformed, or repeated values cannot select a
// different backend object.
enum V3PromptSelectionPolicy {
    enum Revocation {
        case keepExisting
        case revoke(Set<String>)
    }

    enum Extensions {
        case keepAll
        case keepAllMainProfile
        case removeAll
        case remove(Set<String>)
    }

    static func rawValues(from optionIDs: String?, prefix: String,
                          offeredRawValues: [String]) throws -> Set<String> {
        guard let optionIDs, !optionIDs.isEmpty, !prefix.isEmpty else {
            throw CancellationError()
        }
        let offered = Set(offeredRawValues)
        guard offered.count == offeredRawValues.count,
              offered.allSatisfy({ !$0.isEmpty }) else {
            throw CancellationError()
        }
        let submitted = optionIDs.components(separatedBy: ",")
        guard !submitted.isEmpty, submitted.allSatisfy({ !$0.isEmpty }),
              Set(submitted).count == submitted.count else {
            throw CancellationError()
        }
        var selected = Set<String>()
        for optionID in submitted {
            guard optionID.hasPrefix(prefix) else { throw CancellationError() }
            let rawValue = String(optionID.dropFirst(prefix.count))
            guard !rawValue.isEmpty, offered.contains(rawValue) else {
                throw CancellationError()
            }
            selected.insert(rawValue)
        }
        guard !selected.isEmpty else { throw CancellationError() }
        return selected
    }

    static func revocation(choice: String?, submittedOptionIDs: String?,
                           offeredSerials: [String]) throws -> Revocation {
        switch choice {
        case "keep": return .keepExisting
        case "revoke":
            return .revoke(try rawValues(from: submittedOptionIDs, prefix: "revoke:",
                                         offeredRawValues: offeredSerials))
        default: throw CancellationError()
        }
    }

    static func extensions(choice: String?, submittedOptionIDs: String?,
                           offeredBundleIDs: [String]) throws -> Extensions {
        switch choice {
        case "keepAll": return .keepAll
        case "keepAllMainProfile": return .keepAllMainProfile
        case "removeAll": return .removeAll
        case "selected":
            return .remove(try rawValues(from: submittedOptionIDs, prefix: "remove:",
                                         offeredRawValues: offeredBundleIDs))
        default: throw CancellationError()
        }
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

// MARK: - Provisioning failure guidance (typed, never numeric)

// User-facing message plus what Retry means for a concrete
// DeveloperPortalError. The bridged NSError integer (e.g.
// SideSign.DeveloperPortalError 20) is never a stable semantic identifier,
// so classification switches on the typed cases only; the numeric code
// travels exclusively inside the separate technical details. Associated
// values are never forwarded (they can carry raw portal payloads).
// The switch is compiler-checked: @unknown default stays honest instead of
// inventing a cause.
func v3ProvisioningGuidance(_ error: DeveloperPortalError) -> (message: String, hint: String) {
    switch error {
    case .unknown:
        return ("The developer portal request failed for an unknown reason.",
                "You can retry; if it keeps failing, check the connection and try again later.")
    case .invalidParameters:
        return ("The provisioning request was malformed.",
                "Retry will repeat the same failure. Check the app configuration before trying again.")
    case .incorrectCredentials:
        return ("Apple did not accept the Apple ID or password.",
                "Signing in again with the correct credentials is required before retrying.")
    case .noTeams:
        return ("No Apple Developer team is available for this account.",
                "Join or create a developer team for this Apple ID before retrying.")
    case .appSpecificPasswordRequired:
        return ("Apple requires an app-specific password for this authentication path.",
                "Create an app-specific password for this Apple ID, then use it for this sign-in path.")
    case .invalidDeviceID:
        return ("This device could not be identified for registration.",
                "Retry will repeat the same failure until the device identifier issue is resolved.")
    case .deviceAlreadyRegistered:
        return ("This device is already registered with the selected developer team.",
                "No action is needed for the device itself; retry continues provisioning.")
    case .invalidCertificateRequest:
        return ("Apple rejected the development certificate request.",
                "Check the team certificates before retrying.")
    case .certificateDoesNotExist:
        return ("The selected development certificate no longer exists on the Apple Developer account.",
                "Choose or create a current certificate before retrying.")
    case .invalidAppIDName:
        return ("An App ID name was rejected as invalid.",
                "Fix the app identifier configuration before retrying.")
    case .invalidBundleIdentifier:
        return ("An app bundle identifier was rejected as invalid.",
                "Fix the bundle identifier before retrying.")
    case .bundleIdentifierUnavailable:
        return ("Apple could not register this app identifier for the selected team.",
                "Use a different identifier or team before retrying.")
    case .appIDDoesNotExist:
        return ("A required App ID no longer exists on the developer team.",
                "Recreate the App ID or sync app data before retrying.")
    case .maximumAppIDLimitReached:
        return ("The Apple Developer account has reached its App ID limit.",
                "Check App IDs for the selected team and retry when capacity is available. Changing certificates will not free an App ID slot.")
    case .invalidAppGroup:
        return ("An app group value was rejected as invalid.",
                "Fix the app group configuration before retrying.")
    case .appGroupDoesNotExist:
        return ("A required app group does not exist on the developer team.",
                "Recreate the app group before retrying.")
    case .invalidProvisioningProfileIdentifier:
        return ("Apple rejected the provisioning profile identifier.",
                "Check the provisioning configuration before retrying.")
    case .provisioningProfileDoesNotExist:
        return ("The required provisioning profile no longer exists.",
                "Create the missing provisioning profile before retrying.")
    case .requiresTwoFactorAuthentication:
        return ("Two-factor authentication is required to continue.",
                "Complete two-factor authentication, then retry.")
    case .userCancelled:
        return ("Provisioning was cancelled.",
                "Run the operation again when ready.")
    case .incorrectVerificationCode:
        return ("The verification code was not accepted.",
                "Enter a fresh verification code when asked, then retry.")
    case .authenticationHandshakeFailed:
        return ("The authentication handshake with Apple failed.",
                "Check the account sign-in state before retrying.")
    case .invalidAnisetteData:
        return ("Valid Anisette data could not be obtained.",
                "You can retry; if it keeps failing, check the Anisette servers.")
    case .tooManyCertificates:
        return ("The developer team has reached its development certificate limit.",
                "Revoke an unused certificate under Certificates before retrying.")
    case .tooManyAttempts:
        return ("Apple is temporarily limiting authentication or developer portal requests.",
                "Wait before trying again.")
    case .accountRepairRequired:
        return ("Apple requires attention on this account before provisioning can continue.",
                "Resolve the account issue with Apple before retrying.")
    case .invalid2FAResponse:
        return ("The two-factor authentication response was not valid.",
                "Start sign-in again so a fresh verification can complete.")
    @unknown default:
        return ("The developer portal request failed for an unknown reason.",
                "You can retry; if it keeps failing, check the connection and try again later.")
    }
}

// MARK: - SideStore OperationError provisioning guidance (typed, never numeric)

// V3_OPERATION_ERROR_PROVISIONING_GUIDANCE_V1
// Guidance for the concrete SideStore.OperationError cases that
// SignInOperation.provisioningLoop can raise after Apple authentication has
// already succeeded: team fetch, certificate fetch/create, revocation, device
// registration, and the transport/pairing prerequisites that registration needs.
//
// Two rules are absolute here.
// 1. The bridged NSError integer is never consulted. OperationError conforms to
//    CustomNSError but implements neither errorCode nor errorDomain, so every
//    case bridges to code 0 and its case ordinal is not a pinned contract. A
//    numeric mapping silently rots the moment upstream reorders the enum.
// 2. No associated value is ever forwarded. unknown/forbidden embed #fileID and
//    #line, provisioningError embeds the raw portal result, cacheClearError
//    embeds upstream strings, and SideJITIssue embeds a transport error. Only
//    the typed case and privacy-safe facts cross the bridge.
func v3OperationErrorGuidance(_ error: OperationError) -> (message: String, hint: String) {
    switch error {
    // Device connection / pairing prerequisites. These are the transport cases
    // MinimuxerWrapper.asOperationError can produce for a refresh pipeline.
    case .noConnection:
        return ("SideStore could not reach this device to finish provisioning.",
                "Restore the LocalDevVPN connection, then retry provisioning.")
    case .noVPN:
        return ("LocalDevVPN is not active, so this device cannot be registered.",
                "Connect LocalDevVPN, then retry provisioning.")
    case .invalidVPN:
        return ("The LocalDevVPN connection is not usable.",
                "Reconnect LocalDevVPN, then retry provisioning.")
    case .noDevice:
        return ("No usable device endpoint was selected for provisioning.",
                "Open Connection and select a working endpoint, then retry provisioning.")
    case .notReachable:
        return ("The device is not reachable at the selected endpoint.",
                "Open Connection, verify the endpoint, then retry provisioning.")
    case .invalidPairingFile:
        return ("The pairing file is invalid or unreadable.",
                "Place or import a current pairing file, then retry provisioning.")
    case .minimuxerNotStarted:
        return ("The device connection service has not started.",
                "Complete pairing, then retry provisioning.")
    case .pairingNotComplete:
        return ("A pairing file is required before this device can finish provisioning.",
                "Place or import a pairing file, then retry provisioning.")
    case .unknownUDID:
        return ("SideStore could not identify this device for registration.",
                "Check LocalDevVPN and the pairing file, then retry provisioning.")

    // Account / session state.
    case .notAuthenticated:
        return ("The saved Apple session is no longer valid.",
                "Sign in again with this Apple ID, then retry provisioning.")
    case .forbidden:
        return ("Apple denied the provisioning request for this account.",
                "Check the account and team under Account and Signing, then retry provisioning.")
    case .missingAppGroup:
        return ("A required app group is missing for this signing configuration.",
                "Fix the app group configuration, then retry provisioning.")

    // Certificates and profiles.
    case .certificateRevoked:
        return ("The signing certificate Apple holds for this app was revoked.",
                "Re-sign or reinstall the app under Certificates.")
    case .customCertificateRevoked:
        return ("The active custom signing certificate was revoked on the Developer Portal.",
                "Select or create a current certificate under Certificates.")
    case .customCertificateExpired:
        return ("The active custom signing certificate has expired.",
                "Select or create a current certificate under Certificates.")
    case .certificateExpired:
        return ("The signing certificate Apple holds for this app has expired.",
                "Re-sign or reinstall the app under Certificates.")
    case .certificateChanged:
        return ("The signing certificate for this app no longer matches the active certificate.",
                "Re-sign or reinstall the app under Certificates.")
    case .missingProvisioningProfile:
        return ("A required provisioning profile is not available.",
                "Open Certificates and review the active profile, then retry provisioning.")
    case .provisioningError:
        return ("Apple rejected the provisioning request for this app.",
                "Review the app identifier and team under Account and Signing, then retry provisioning.")
    case .maximumAppIDLimitReached:
        return ("The Apple Developer account has reached its App ID limit.",
                "Check App IDs for the selected team and retry when capacity is available. Changing certificates will not free an App ID slot.")

    // Timing.
    case .timedOut:
        return ("The provisioning request to Apple timed out.",
                "Retry once. If it repeats, check the connection and try again later.")
    case .connectionFailed:
        return ("The connection to the Apple Developer service failed during provisioning.",
                "Check the connection, then retry provisioning.")

    default:
        break
    }
    // Honesty: a case without specific guidance is reported as unclassified
    // rather than being relabelled as a credential, pairing, or manifest problem.
    return ("SideStore could not finish provisioning for a reason it does not classify.",
            "You can retry. If it keeps failing, keep the technical details and review Account and Signing and Certificates.")
}

// A new context observes committed rows, independent of any failed operation's
// registered objects. Only opaque identity sets reach the local recovery journal.
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

// MARK: - Headless pipeline decisions (every confirmation renders in the host)

@MainActor
final class V3HeadlessPipelineHandler: PipelineExecutionHandler, PreflightChecksHandler,
    EntitlementsReviewHandler, ExtensionRemovalHandler, UnsupportedVersionHandler,
    InstallAppHandler, UserCustomizationHandler {
    let sessionID: String
    init(sessionID: String) { self.sessionID = sessionID }

    var preflightChecksHandler: PreflightChecksHandler { self }
    var entitlementsReviewHandler: EntitlementsReviewHandler { self }
    var extensionRemovalHandler: ExtensionRemovalHandler { self }
    var unsupportedVersionHandler: UnsupportedVersionHandler { self }
    var installAppHandler: InstallAppHandler { self }
    var userCustomizationHandler: UserCustomizationHandler { self }
    var isResignActive: Bool { false }

    private func center() throws -> V3OperationCenter {
        let center = V3HeadlessRuntime.shared.operations
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
            }
        }
        return try await V3HeadlessRuntime.shared.prompts.park(promptID: promptID) {
            guard center.sessions[self.sessionID]?.terminal.isEmpty == true else { return }
            center.sessions[self.sessionID]?.prompt = prompt
            debugLog("[V3_OP] PROMPT session=\(self.sessionID) kind=\(kind)")
        }
    }

    func resolveBundleIDMismatch(targetID: String, activeEffectiveID: String) async -> Bool {
        let answer = try? await ask(kind: "bundleIDMismatch", title: "Bundle ID Mismatch",
                                    message: "The app reports \(targetID) but the active signing identity expects \(activeEffectiveID). Proceed anyway?",
                                    options: [["id": "proceed", "label": "Proceed"], ["id": "cancel", "label": "Cancel"]])
        return answer?["choice"] == "proceed"
    }

    func reviewPermissions(_ permissions: [ALTEntitlement], for app: AppProtocol, mode: PermissionReviewMode) async throws {
        let list = permissions.map(\.rawValue).sorted().joined(separator: "\n")
        let answer = try await ask(kind: "permissions", title: "Review Permissions",
                                   message: "\(app.name) requests \(permissions.count) permission(s):\n\(list)",
                                   options: [["id": "approve", "label": "Approve"], ["id": "deny", "label": "Deny"]])
        guard answer["choice"] == "approve" else { throw CancellationError() }
    }

    func selectAppExtensionsToRemove(appBundle: ALTApplication, localAppExtensions: [ALTApplication],
                                     excessExtensions: Set<ALTApplication>) async throws -> ExtensionRemovalDecision {
        return try await V3ExtensionRemovalPromptPolicy.decide(
            // Upstream customization reviews all target extensions. An empty
            // excess set also occurs on fresh installs and unchanged updates.
            targetExtensions: appBundle.appExtensions,
            whenEmpty: .keepAll(useMainProfile: false)
        ) {
            let sorted = appBundle.appExtensions.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
            let answer = try await self.ask(kind: "extensions", title: "App Extensions",
                message: "\(appBundle.bundleIdentifier) contains \(sorted.count) extension(s). Keep them using the main app's profile or register an App ID for each, or choose which to remove.",
                options: [["id": "keepAllMainProfile", "label": "Keep All (Use Main Profile)"],
                          ["id": "keepAll", "label": "Keep All (Register Each Extension)"]] +
                    sorted.map { ["id": "remove:\($0.bundleIdentifier)", "label": "Remove \($0.bundleIdentifier)"] } +
                    [["id": "removeAll", "label": "Remove All"], ["id": "cancel", "label": "Cancel"]])
            let selection = try V3PromptSelectionPolicy.extensions(
                choice: answer["choice"], submittedOptionIDs: answer["ids"],
                offeredBundleIDs: sorted.map(\.bundleIdentifier))
            switch selection {
            case .keepAll: return .keepAll(useMainProfile: false)
            case .keepAllMainProfile: return .keepAll(useMainProfile: true)
            case .removeAll: return .removeAll
            case .remove(let bundleIDs):
                let selected = Set(sorted.filter { bundleIDs.contains($0.bundleIdentifier) })
                guard selected.count == bundleIDs.count, !selected.isEmpty else {
                    throw CancellationError()
                }
                return .removeSelected(selected)
            }
        }
    }

    func resolveUnsupportediOSVersion(errorDescription: String, appName: String, compatibleVersion: String) async throws -> Bool {
        let answer = try await ask(kind: "unsupportedVersion", title: "Unsupported iOS Version",
                                   message: "\(errorDescription)\n\nDownload the last version compatible with this device instead?",
                                   options: [["id": "proceed", "label": "Download \(appName) \(compatibleVersion)"],
                                             ["id": "cancel", "label": "Cancel"]])
        return answer["choice"] == "proceed"
    }

    func requestBackgroundSuspension() async {}
    func suspendToHomeScreen() async {}
    func isAppInForeground() async -> Bool { false }

    func beginBackupCallback(action: String) throws -> V3BackupCallbackIdentity {
        try center().beginBackupCallback(id: sessionID, action: action)
    }

    func endBackupCallback(_ identity: V3BackupCallbackIdentity) {
        V3HeadlessRuntime.shared.operations.endBackupCallback(identity)
    }

    func backupCallbackMayOpen() -> Bool {
        let center = V3HeadlessRuntime.shared.operations
        guard center.activeMutationID == sessionID, let session = center.sessions[sessionID],
              session.terminal.isEmpty, !session.terminal.isCancellationRequested,
              session.backupCallback != nil else { return false }
        return true
    }

    func recordNativeUninstallSucceeded() {
        V3DeleteNativeSuccessRegistry.shared.record(sessionID: sessionID)
        debugLog("[V3_OP] DELETE_NATIVE_UNINSTALL_SUCCEEDED session=\(sessionID)")
    }

    // Called by PipelineExecutor immediately before it executes the concrete
    // pipeline step. This reflects backend state, never progress ranges.
    func recordPipelinePhase(_ step: PipelineStep, downloadUsesNetwork: Bool) {
        guard let center = try? center() else { return }
        center.recordPipelineStep(sessionID: sessionID, step: String(describing: step),
                                  downloadUsesNetwork: downloadUsesNetwork)
    }

    func resolveBundleIDOverride(initialBundleID: String) async throws -> (customID: String, appendTeamID: Bool)? {
        let answer = try await ask(kind: "bundleIDOverride", title: "Customize Bundle ID",
                                   message: "Optionally customize the bundle identifier used for signing.",
                                   fields: [["key": "customID", "label": "Bundle ID", "secure": "false", "value": initialBundleID],
                                            ["key": "appendTeamID", "label": "appendTeamID", "secure": "false", "value": "true"]],
                                   options: [["id": "custom", "label": "Use Custom ID"],
                                             ["id": "default", "label": "Use Default"],
                                             ["id": "cancel", "label": "Cancel"]])
        switch answer["choice"] {
        case "custom":
            // Match SideStore's confirmation behavior: trim the editable value,
            // and keep the original identifier when the field is left empty.
            let enteredID = answer["customID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let customID = enteredID?.isEmpty == false ? enteredID! : initialBundleID
            return (customID, answer["appendTeamID"] != "false")
        // UserCustomizationOperation treats nil as cancellation, so choosing
        // the default must return the original identifier explicitly.
        case "default": return (initialBundleID, true)
        default: throw CancellationError()
        }
    }

    func resolveAppGroupMismatch(originalGroup: String, correctedGroup: String) async throws -> AppGroupResolution {
        let answer = try await ask(kind: "appGroupMismatch", title: "App Group Mismatch",
                                   message: "The app group \(originalGroup) does not match the expected \(correctedGroup).",
                                   options: [["id": "correct", "label": "Use \(correctedGroup)"],
                                             ["id": "keep", "label": "Keep \(originalGroup)"]])
        switch answer["choice"] {
        case "correct": return .correctAndProceed(correctedGroup)
        case "keep": return .keepOriginal(originalGroup)
        default: throw CancellationError()
        }
    }
}

// MARK: - Headless operation sessions (install/update/refresh/activate/...)

@MainActor
final class V3OperationCenter {
    struct Session {
        var kind: String
        var task: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var preparation = V3OperationPreparationGate()
        var prompt: [String: Any]?
        var group: RefreshGroup?
        var phase = V3OperationPhaseTracker()
        var terminal = V3OperationTerminalResponse()
        var deadline = Date.distantFuture
        var terminalAt: Date?
        var ipaToken: String?
        var temporaryIPADirectory: URL?
        var acceptedPromptIDs: [String] = []
        var backupCallback: V3BackupCallbackIdentity?
    }

    var sessions: [String: Session] = [:]
    private var mutationRegistry = V3OperationMutationRegistry()
    var activeMutationID: String? { mutationRegistry.activeID }

    func start(kind: String, target: String, value: Bool?, sessionID requestedID: String,
               deadline: Date) async -> [String: Any] {
        _ = value
        cleanupSessions()
        guard let parsedID = UUID(uuidString: requestedID), parsedID.uuidString == requestedID else {
            return ["session": requestedID, "state": "failed", "failedToStart": true,
                    "backendSettled": true, "stopConfirmed": true, "code": "invalidConfiguration",
                    "message": "The operation attempt identifier is invalid."]
        }
        let id = requestedID
        if sessions[id] != nil { return terminalReply(id: id) }
        sessions[id] = Session(kind: kind, deadline: deadline)
        switch mutationRegistry.begin(id) {
        case .cancelledBeforeStart:
            sessions[id]?.preparation.finish()
            finish(id: id, response: ["state": "cancelled"])
            return terminalReply(id: id)
        case .busy:
            sessions[id]?.preparation.finish()
            let failure = CombinedFailure(operation: kind, stage: .command, code: .busy, id: id, retryable: true)
            finish(id: id, response: ["state": "failed", "failedToStart": true, "stage": failure.stage.rawValue,
                "code": failure.code.rawValue, "message": failure.message,
                "technical": failure.technicalDetails, "failure": failure.wire, "retryable": true])
            return terminalReply(id: id)
        case .started:
            break
        }
        if kind == "installSharedIPA" { sessions[id]?.ipaToken = target }
        let credentials = AuthManager.shared.authenticationSnapshot
        guard V3AuthIdentityBindingPolicy.hasTokenBackedRoute(
            credentialRoutePresent: credentials?.isAuthenticated == true,
            dsid: credentials?.appleIDAdsid, xcodeToken: credentials?.appleIDXcodeToken) else {
            sessions[id]?.preparation.finish()
            finish(id: id, response: ["state": "waitingForAuthentication"])
            mutationRegistry.finish(id)
            return terminalReply(id: id)
        }
        do {
            let driver = try await makeDriver(id: id, kind: kind, target: target)
            sessions[id]?.preparation.finish()
            guard sessions[id]?.terminal.isEmpty == true, mutationRegistry.activeID == id else {
                cleanupTemporaryIPA(id: id)
                return terminalReply(id: id)
            }
            if sessions[id]?.terminal.isCancellationRequested == true {
                cleanupTemporaryIPA(id: id)
                finish(id: id, response: ["state": "cancelled", "stopConfirmed": true])
                mutationRegistry.finish(id)
                return terminalReply(id: id)
            }
            sessions[id]?.task = Task { @MainActor in await self.drive(id: id, driver: driver) }
            sessions[id]?.watchdog = Task { @MainActor in
                let interval = deadline.timeIntervalSinceNow
                if interval > 0 { try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                self.expire(id: id)
            }
        } catch {
            sessions[id]?.preparation.finish()
            cleanupTemporaryIPA(id: id)
            if sessions[id]?.terminal.isCancellationRequested == true {
                finish(id: id, response: ["state": "cancelled", "stopConfirmed": true])
                mutationRegistry.finish(id)
                return terminalReply(id: id)
            }
            var failure = terminalFailure(id: id, kind: kind, error: error)
            failure["failedToStart"] = true
            finish(id: id, response: failure)
            mutationRegistry.finish(id)
            return terminalReply(id: id)
        }
        return ["session": id, "state": "working",
                "phase": V3OperationPhase.working.rawValue,
                "phaseLabel": V3OperationPhase.working.label]
    }

    private func drive(id: String, driver: V3OpDriver) async {
        let terminal: [String: Any]
        do {
            try await driver.run()
            terminal = ["state": "completed"]
        } catch {
            if error is CancellationError {
                terminal = ["state": "cancelled", "stopConfirmed": true]
            } else {
                terminal = terminalFailure(id: id, kind: driver.kind, error: error)
            }
        }
        sessions[id]?.prompt = nil
        sessions[id]?.task = nil
        sessions[id]?.watchdog?.cancel()
        sessions[id]?.watchdog = nil
        V3SideStoreService.shared.cancellations.removeValue(forKey: id)
        cleanupTemporaryIPA(id: id)
        mutationRegistry.finish(id)
        finish(id: id, response: terminal)
        debugLog("[V3_OP] TERMINAL session=\(id) kind=\(driver.kind) state=\(terminal["state"] as? String ?? "") stage=\(terminal["stage"] as? String ?? "") code=\(terminal["code"] as? String ?? "")")
        cleanupSessions()
    }

    func poll(id: String) -> [String: Any]? {
        cleanupSessions()
        guard let session = sessions[id] else { return nil }
        if let reply = session.terminal.reply(sessionID: id, backendSettled: session.task == nil) {
            return reply
        }
        let phase = session.phase.phase
        var reply: [String: Any] = ["session": id,
                                    "state": session.terminal.isCancellationRequested ? "cancelling" : "working",
                                    "phase": phase.rawValue, "phaseLabel": phase.label]
        if let progress = session.group?.progress.fractionCompleted, progress.isFinite {
            let normalized = V3NormalizedProgress.clamp(progress)
            if normalized != progress {
                debugLog("[V3_OP] PROGRESS_CLAMP session=\(id) out_of_range=1")
            }
            reply["progress"] = normalized
        }
        if let callback = session.backupCallback { reply["backupCallback"] = callback.wire }
        if let prompt = session.prompt, !session.terminal.isCancellationRequested {
            reply["state"] = "awaitingPrompt"
            reply["prompt"] = prompt
        }
        return reply
    }

    func beginBackupCallback(id: String, action: String) throws -> V3BackupCallbackIdentity {
        guard let session = sessions[id], session.terminal.isEmpty,
              !session.terminal.isCancellationRequested, mutationRegistry.activeID == id,
              session.backupCallback == nil,
              V3BackupCallbackIdentity.supports(kind: session.kind, action: action),
              let identity = V3BackupCallbackIdentity(session: id, nonce: UUID().uuidString, action: action)
        else { throw V3SideStoreServiceError.invalidRequest }
        sessions[id]?.backupCallback = identity
        return identity
    }

    func endBackupCallback(_ identity: V3BackupCallbackIdentity) {
        guard sessions[identity.session]?.backupCallback == identity else { return }
        sessions[identity.session]?.backupCallback = nil
    }

    func ownsBackupCallback(_ result: V3BackupCallbackResult) -> Bool {
        let id = result.identity.session
        guard mutationRegistry.activeID == id, let session = sessions[id],
              session.terminal.isEmpty, session.backupCallback == result.identity,
              V3BackupCallbackIdentity.supports(kind: session.kind, action: result.identity.action)
        else { return false }
        // Cancellation does not prove the external data copy stopped. Its real
        // callback still settles this step before the pipeline can acknowledge it.
        return true
    }

    @discardableResult
    func acceptBackupCallback(_ result: V3BackupCallbackResult) -> Bool {
        // Recheck durable ownership even for the service-local URL path. A URL
        // must not bypass the XPC recovery gate or revive a reconciled session.
        guard ownsBackupCallback(result),
              let recovery = try? V3OperationRecoveryJournal.current(),
              recovery.sessionID == result.identity.session, recovery.phase == .dispatched,
              recovery.kind == sessions[result.identity.session]?.kind else { return false }
        endBackupCallback(result.identity)
        let outcome: Result<Void, Error> = result.succeeded ? .success(()) :
            .failure(NSError(domain: "V3Backup", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The backup or restore operation did not complete."]))
        NotificationCenter.default.post(name: AppDelegate.appBackupDidFinish, object: nil,
            userInfo: [AppDelegate.appBackupResultKey: outcome, "v3BackupNonce": result.identity.nonce])
        return true
    }

    func recordPipelineStep(sessionID: String, step: String, downloadUsesNetwork: Bool) {
        guard var session = sessions[sessionID], session.terminal.isEmpty else { return }
        session.phase.recordPipelineStep(step, downloadUsesNetwork: downloadUsesNetwork)
        sessions[sessionID] = session
    }

    func setPhase(sessionID: String, phase: V3OperationPhase) {
        guard var session = sessions[sessionID], session.terminal.isEmpty else { return }
        session.phase.record(phase)
        sessions[sessionID] = session
    }

    func answer(id: String, promptID: String, answer: [String: String]) -> [String: Any]? {
        guard let session = sessions[id] else { return nil }
        if V3PromptResponseStatePolicy.shouldReturnCurrentStateAfterAcceptedDuplicate(
            acceptedPromptID: nil, acceptedPromptIDs: session.acceptedPromptIDs,
            currentPromptID: session.prompt?["id"] as? String,
            submittedPromptID: promptID, sessionTerminal: session.terminal.value != nil,
            cancellationRequested: session.terminal.isCancellationRequested) {
            return poll(id: id)
        }
        guard case nil = session.terminal.value,
              !session.terminal.isCancellationRequested else { return nil }
        if let pending = V3PromptResponseStatePolicy.responsePending(.unavailable,
            acceptedPromptID: session.acceptedPromptIDs.last, promptID: promptID,
            sessionID: id, revision: 0, state: "working", prompt: session.prompt) {
            return pending
        }
        guard session.prompt?["id"] as? String == promptID else { return nil }
        let disposition = V3HeadlessRuntime.shared.prompts.answer(promptID: promptID, answer: answer)
        if let pending = V3PromptResponseStatePolicy.responsePending(disposition,
            acceptedPromptID: session.acceptedPromptIDs.last, promptID: promptID,
            sessionID: id, revision: 0, state: "working", prompt: session.prompt) {
            return pending
        }
        guard disposition == .accepted else {
            return ["session": id, "state": "promptExpired"]
        }
        if let current = sessions[id] {
            sessions[id]?.acceptedPromptIDs = V3PromptResponseStatePolicy.recordAcceptedPrompt(
                current.acceptedPromptIDs, promptID: promptID)
        }
        return poll(id: id)
    }

    func expire(id: String) {
        guard let session = sessions[id], case nil = session.terminal.value else { return }
        _ = cancel(id: id)
    }

    @discardableResult
    func cancel(id: String) -> Bool {
        guard var session = sessions[id] else { return false }
        guard case nil = session.terminal.value else { return true }
        guard session.terminal.requestCancellation() else { return true }
        session.watchdog?.cancel()
        session.group?.cancel()
        if session.task == nil, !session.preparation.isFinished {
            _ = session.preparation.requestCancellation()
        }
        if let promptID = session.prompt?["id"] as? String {
            _ = V3HeadlessRuntime.shared.prompts.cancel(promptID: promptID)
        }
        session.prompt = nil
        sessions[id] = session
        V3SideStoreService.shared.cancellations[id]?()
        if session.task == nil, session.preparation.isFinished {
            finish(id: id, response: ["state": "cancelled", "stopConfirmed": true])
            V3SideStoreService.shared.cancellations.removeValue(forKey: id)
            cleanupTemporaryIPA(id: id)
            mutationRegistry.finish(id)
        }
        cleanupSessions()
        return true
    }

    @discardableResult
    func cancelBeforeStart(id: String) -> Bool {
        guard let parsedID = UUID(uuidString: id), parsedID.uuidString == id else { return false }
        if sessions[id] != nil { return cancel(id: id) }
        _ = mutationRegistry.cancel(id)
        return true
    }

    func cancelAndWait(id: String, knownStarted: Bool = false) async -> [String: Any]? {
        guard let parsedID = UUID(uuidString: id), parsedID.uuidString == id else { return nil }
        guard let session = sessions[id] else {
            if let unknown = V3OperationMissingSessionPolicy.unknownTerminal(
                sessionID: id, knownStarted: knownStarted) {
                // The start may have crossed XPC but not yet reached this
                // actor. Record cancellation so a delayed start cannot launch.
                _ = mutationRegistry.cancel(id)
                return unknown
            }
            _ = mutationRegistry.cancel(id)
            cleanupSessions()
            return ["session": id, "state": "cancelled", "stopConfirmed": true,
                    "backendSettled": true]
        }
        if session.terminal.value != nil, session.preparation.isFinished { return terminalReply(id: id) }
        if !session.preparation.isFinished {
            _ = cancel(id: id)
            await session.preparation.wait()
        }
        guard let settledSession = sessions[id] else { return nil }
        if settledSession.terminal.value != nil { return terminalReply(id: id) }
        let task = settledSession.task
        guard cancel(id: id) else { return nil }
        if settledSession.backupCallback != nil, task != nil {
            // SideBackup may still be copying data in another process. Return a
            // bounded control reply and keep polling; cancellation is not proof
            // that its data mutation stopped, and must not release this owner.
            return poll(id: id)
        }
        if V3DeleteCancellationPolicy.cancelRequestReturnsBeforeDriverSettlement(
            operation: settledSession.kind, driverIsRunning: task != nil) {
            // Delete's native callback can outlive the request to cancel its
            // detached PipelineRunner task. Return the current session state;
            // the operation sheet keeps its correlated poller active.
            return poll(id: id)
        }
        if let task { await task.value }
        return terminalReply(id: id)
    }

    func cleanupIPA(token: String) throws {
        let canonical = try V3IPAStaging.canonicalToken(token)
        guard !sessions.contains(where: { entry in
            entry.value.ipaToken == canonical && V3StagedIPALeasePolicy.isLeased(
                hasOperationTask: entry.value.task != nil,
                preparationFinished: entry.value.preparation.isFinished,
                ownsMutationRegistry: mutationRegistry.activeID == entry.key)
        }) else { throw V3SideStoreServiceError.busy }
        guard let root = V3IPAStaging.sideStoreContainerRoot() else {
            throw CombinedIPAFileError(.fileAccess)
        }
        try V3IPAStaging.cleanup(token: canonical, containerRoot: root)
    }

    func activeStagedIPATokens() -> [String] {
        let activeMutation = mutationRegistry.activeID
        let tokens = sessions.compactMap { id, session -> String? in
            guard let token = session.ipaToken,
                  V3StagedIPALeasePolicy.isLeased(hasOperationTask: session.task != nil,
                    preparationFinished: session.preparation.isFinished,
                    ownsMutationRegistry: activeMutation == id),
                  let canonical = try? V3IPAStaging.canonicalToken(token) else { return nil }
            return canonical
        }
        return Array(Set(tokens)).sorted().prefix(512).map { $0 }
    }

    private func finish(id: String, response: [String: Any]) {
        guard var session = sessions[id] else { return }
        let backendSettled = session.task == nil
        let terminalAccepted = session.terminal.finishOrResolve(
            response, backendSettled: backendSettled)
        if V3OperationSessionRetentionPolicy.shouldRefreshTerminalAt(
            terminalAccepted: terminalAccepted, backendSettled: backendSettled) {
            session.terminalAt = Date()
        }
        sessions[id] = session
        if terminalAccepted || backendSettled { cleanupSessions() }
    }

    private func cleanupTemporaryIPA(id: String) {
        guard var session = sessions[id], let directory = session.temporaryIPADirectory else { return }
        session.temporaryIPADirectory = nil
        sessions[id] = session
        do { try FileManager.default.removeItem(at: directory) }
        catch { debugLog("[V3_INSTALL_UI] temporary_ipa_cleanup_failed session=\(id)") }
    }

    private func cleanupSessions(now: Date = Date()) {
        let expired = sessions.compactMap { id, session in
            id != mutationRegistry.activeID && session.terminal.value != nil &&
                V3OperationSessionRetentionPolicy.isExpired(backendSettled: session.task == nil,
                    terminalAt: session.terminalAt, now: now) ? id : nil
        }
        for id in expired { sessions.removeValue(forKey: id) }
        let completed = sessions.filter { $0.key != mutationRegistry.activeID && $0.value.task == nil && $0.value.terminal.value != nil }
            .sorted { ($0.value.terminalAt ?? .distantPast) < ($1.value.terminalAt ?? .distantPast) }
        if completed.count > 256 {
            for (id, _) in completed.prefix(completed.count - 256) { sessions.removeValue(forKey: id) }
        }
    }

    private func terminalReply(id: String) -> [String: Any] {
        poll(id: id) ?? ["session": id, "state": "failed", "backendSettled": true]
    }

    private func terminalFailure(id: String, kind: String, error: Error) -> [String: Any] {
        if let required = error as? V3RequiresSourceError {
            var reply: [String: Any] = ["state": "requiresSource", "sourceID": required.sourceID,
                "sourceName": required.sourceName]
            if let url = V3SourceRecoveryPolicy.target(sourceID: required.sourceID, sourceURL: required.sourceURL) {
                reply["sourceURL"] = url
            }
            return reply
        }
        let stage: CombinedFailure.Stage
        switch kind {
        case "install", "installURL", "installSharedIPA", "update": stage = .installation
        case "refreshApp": stage = .refreshVerification
        default: stage = .command
        }
        // The structured failure crosses XPC as scalars only: the user-facing
        // message plus the fixed wire vocabulary (stage, code, correlation,
        // underlying domain/code, retryable). No arbitrary userInfo, file
        // paths, or auth secrets ever leave the SideStore process.
        // The session id is the end-to-end correlation identifier.
        let classifiedError = V3HeadlessPairingFailure.tagIfInvalidPairing(error)
        let failure = CombinedFailure.capture(classifiedError, operation: kind, stage: stage, id: id)
        var terminal: [String: Any] = ["state": "failed", "stage": failure.stage.rawValue,
            "code": failure.code.rawValue, "message": failure.message,
            "technical": failure.technicalDetails, "failure": failure.wire]
        if let retryable = failure.retryable { terminal["retryable"] = retryable }
        return terminal
    }

    private struct V3OpDriver: @unchecked Sendable {
        let kind: String
        let run: @MainActor () async throws -> Void
    }

    private func makeDriver(id: String, kind: String, target: String) async throws -> V3OpDriver {
        let handler = V3HeadlessPipelineHandler(sessionID: id)
        let background = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let baseContext = StandaloneOperationContext(steps: .signIn, dbBackgroundContext: background)
        switch kind {
        case "install", "installURL", "installSharedIPA":
            let installTarget = try await resolveInstallTarget(id: id, kind: kind, target: target)
            let app: AppProtocol
            switch installTarget {
            case .app(let protocolApp):
                app = protocolApp
                if let storeApp = protocolApp.storeApp, let source = storeApp.source {
                    guard try await source.isAdded() else {
                        throw V3RequiresSourceError(sourceID: source.identifier, sourceName: source.name,
                            sourceURL: source.sourceURL.absoluteString)
                    }
                }
            case .url(_):
                throw V3SideStoreServiceError.invalidRequest
            }
            let route: V3InstallInputRoute = kind == "installSharedIPA" ? .localIPA :
                (kind == "installURL" ? .remoteURL : .catalog)
            return makeInstallDriver(id: id, kind: kind, route: route, app: app,
                                     handler: handler, context: baseContext)
        case "update":
            let app: InstalledApp = try v3Resolve(target)
            guard app.bundleIdentifier != StoreApp.altstoreAppID else { throw V3SideStoreServiceError.unsupported }
            guard let appVersion = app.storeApp?.latestSupportedVersion else { throw V3SideStoreServiceError.unsupported }
            guard appVersion as AnyObject !== app else {
                throw OperationError.invalidParameters("Make sure we never accidentally 'update' to already installed app.")
            }
            return V3OpDriver(kind: kind) {
                try await self.single(id: id, operation: .update(appVersion, customBundleIdentifier: app.customBundleIdentifier),
                                      handler: handler, context: baseContext)
            }
        case "refreshApp":
            let app: InstalledApp = try v3Resolve(target)
            guard app.isActive, app.bundleIdentifier != StoreApp.altstoreAppID else { throw V3SideStoreServiceError.unsupported }
            return V3OpDriver(kind: kind) {
                let group = RefreshGroup(context: baseContext)
                self.sessions[id]?.group = group
                V3SideStoreService.shared.cancellations[id] = { group.cancel(); group.progress.cancel() }
                do {
                    try await AppManager.shared.pipelineRunner.perform([.refresh(app)], handler: handler, group: group)
                } catch {
                    group.context.error = error
                    group.set(.failure(error), forAppWithBundleIdentifier: app.bundleIdentifier)
                    throw error
                }
                // PipelineRunner.perform returns only after every app result is
                // recorded. Its completion callback is an observer and cannot
                // race drive() into writing a second terminal result.
                _ = try V3RefreshResultVerifier.verified(expectedBundleID: app.bundleIdentifier,
                    results: group.results, bundleIdentifier: { $0.bundleIdentifier })
            }
        case "delete":
            let app: InstalledApp = try v3Resolve(target)
            guard app.bundleIdentifier != StoreApp.altstoreAppID else { throw V3SideStoreServiceError.unsupported }
            return V3OpDriver(kind: kind) {
                try await self.deleteAndReconcile(id: id, app: app, handler: handler, context: baseContext)
            }
        case "activate", "deactivate", "backup", "restore":
            let app: InstalledApp = try v3Resolve(target)
            if kind == "deactivate", app.bundleIdentifier == StoreApp.altstoreAppID {
                throw V3SideStoreServiceError.unsupported
            }
            let operation: AppOperation
            switch kind {
            case "activate": operation = .activate(app)
            case "deactivate": operation = .deactivate(app)
            case "backup": operation = .backup(app)
            default: operation = .restore(app)
            }
            return V3OpDriver(kind: kind) {
                try await self.single(id: id, operation: operation, handler: handler, context: baseContext)
            }
        case "remove":
            let app: InstalledApp = try v3Resolve(target)
            guard app.bundleIdentifier != StoreApp.altstoreAppID else { throw V3SideStoreServiceError.unsupported }
            return V3OpDriver(kind: kind) {
                try await self.single(id: id, operation: .removeApp(app), handler: handler, context: baseContext)
            }
        default:
            throw V3SideStoreServiceError.invalidRequest
        }
    }

    private func single(id: String, operation: AppOperation, handler: V3HeadlessPipelineHandler,
                        context: StandaloneOperationContext) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = V3ServiceCallbackGate(continuation)
                let group = AppManager.shared.pipelineRunner.performSingleOperation(operation, handler: handler, context: context) { result in
                    gate.settle(result.map { _ in () })
                }
                Task { @MainActor in
                    guard var session = self.sessions[id], session.terminal.isEmpty else { return }
                    session.group = group
                    let cancellationRequested = session.terminal.isCancellationRequested
                    self.sessions[id] = session
                    V3SideStoreService.shared.cancellations[id] = { group.cancel(); group.progress.cancel() }
                    if cancellationRequested { group.cancel(); group.progress.cancel() }
                }
            }
        }, onCancel: {
            Task { @MainActor in
                self.sessions[id]?.group?.cancel()
                if let cancel = V3SideStoreService.shared.cancellations[id] { cancel() }
            }
        })
    }

    private func isDeleteCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let failure = error as? CombinedFailure { return failure.code == .cancelled }
        return false
    }

    private func deleteAndReconcile(id: String, app: InstalledApp,
                                    handler: V3HeadlessPipelineHandler,
                                    context: StandaloneOperationContext) async throws {
        let callback = V3DeleteBackendResultBox()
        let bundleIdentifier = app.bundleIdentifier
        let group = AppManager.shared.pipelineRunner.performSingleOperation(
            .deleteApp(app), handler: handler, context: context
        ) { result in
            switch result {
            case .success: callback.record(.success(()))
            case .failure(let error): callback.record(.failure(error))
            }
        }
        guard var session = sessions[id], session.terminal.isEmpty else {
            group.cancel()
            group.progress.cancel()
            throw CancellationError()
        }
        session.group = group
        sessions[id] = session
        V3SideStoreService.shared.cancellations[id] = { group.cancel(); group.progress.cancel() }
        defer {
            V3DeleteNativeSuccessRegistry.shared.remove(sessionID: id)
            V3SideStoreService.shared.cancellations[id] = nil
        }

        let deadline = Date().addingTimeInterval(30)
        var cancellationRequestedAt: Date?
        var missingCallbackReconcileDeadline: Date?
        var lastLibraryPresence: Bool?
        var lastLibraryCheckAt: Date?
        var authoritativeAbsenceConfirmed = false
        var callbackPollDelay: TimeInterval = 0.25
        var verifiedDeleteCompletionPublished = false
        var contract = V3DeleteCompletionContract()
        debugLog("[V3_OP] DELETE_RECONCILE_START session=\(id)")
        while !Task.isCancelled {
            try Task.checkCancellation()
            let callbackResult = callback.result
            let cancellationWasRequested = cancellationRequestedAt != nil ||
                sessions[id]?.terminal.isCancellationRequested == true
            let callbackCancellationIsPending: Bool
            if case .failure(let error)? = callbackResult {
                callbackCancellationIsPending = V3DeleteCancellationPolicy.callbackCancellationRemainsPending(
                    isCancellation: isDeleteCancellationError(error),
                    cancellationRequested: cancellationWasRequested)
                if !callbackCancellationIsPending { throw error }
            } else {
                callbackCancellationIsPending = false
            }
            let now = Date()
            if cancellationRequestedAt == nil,
               sessions[id]?.terminal.isCancellationRequested == true {
                cancellationRequestedAt = now
            }
            let shouldThrottleLibrary = V3DeleteReconciliationPolicy.shouldThrottleLibraryChecks(
                authoritativeAbsenceConfirmed: authoritativeAbsenceConfirmed,
                cancellationRequested: cancellationRequestedAt != nil)
            let shouldCheckLibrary = !shouldThrottleLibrary ||
                V3DeleteReconciliationPolicy.shouldCheckLibrary(lastCheck: lastLibraryCheckAt, now: now)
            var appIsPresent: Bool
            if shouldCheckLibrary {
                appIsPresent = try await authoritativeLibraryContains(bundleIdentifier: bundleIdentifier)
                lastLibraryCheckAt = now
            } else {
                // After verified absence, or after cancellation was requested
                // for an unresolved delete, avoid repeated Core Data counts in
                // the callback wait. Recheck periodically and retain the last
                // observed library state between those authoritative reads.
                appIsPresent = lastLibraryPresence ?? true
            }
            let nativeUninstallSucceeded = V3DeleteNativeSuccessRegistry.shared.contains(sessionID: id)
            if appIsPresent || !nativeUninstallSucceeded {
                authoritativeAbsenceConfirmed = false
                if appIsPresent || !nativeUninstallSucceeded {
                    missingCallbackReconcileDeadline = nil
                }
            } else {
                authoritativeAbsenceConfirmed = true
            }
            if lastLibraryPresence != appIsPresent {
                lastLibraryPresence = appIsPresent
                debugLog("[V3_OP] DELETE_LIBRARY_RECONCILE session=\(id) app_present=\(appIsPresent)")
            }
            let backendState: V3DeleteCompletionContract.BackendResult
            switch callbackResult {
            case .success?: backendState = .succeeded
            case .failure?: backendState = callbackCancellationIsPending ? .pending : .failed
            case nil: backendState = .pending
            }
            let missingCallbackDeadlineElapsed =
                missingCallbackReconcileDeadline.map { now >= $0 } ?? false
            if backendState == .pending && nativeUninstallSucceeded &&
               missingCallbackDeadlineElapsed && !verifiedDeleteCompletionPublished {
                // The earlier absence observation starts the bounded callback
                // window. Recheck the library at its end before treating the
                // verified native result as complete.
                appIsPresent = try await authoritativeLibraryContains(bundleIdentifier: bundleIdentifier)
                lastLibraryCheckAt = Date()
                lastLibraryPresence = appIsPresent
                authoritativeAbsenceConfirmed = !appIsPresent && nativeUninstallSucceeded
                if appIsPresent { missingCallbackReconcileDeadline = nil }
            }
            if !appIsPresent, backendState == .pending, nativeUninstallSucceeded,
               missingCallbackReconcileDeadline == nil {
                missingCallbackReconcileDeadline = now.addingTimeInterval(5)
            }
            let deadlineElapsed = now >= deadline ||
                (missingCallbackReconcileDeadline.map { now >= $0 } ?? false)
            if V3DeleteReconciliationPolicy.shouldRequestCancellation(
                deadlineElapsed: deadlineElapsed,
                backendPending: backendState == .pending,
                cancellationAlreadyRequested: cancellationRequestedAt != nil) {
                cancellationRequestedAt = now
                group.cancel()
                group.progress.cancel()
                debugLog("[V3_OP] DELETE_RECONCILE_CANCEL session=\(id)")
            }
            let reconciliationExpired: Bool
            if let cancellationRequestedAt, backendState == .pending {
                // Give the native callback a bounded grace period after
                // cancellation. A timed-out local observation does not release
                // mutation ownership while InstallationProxy may still be active.
                reconciliationExpired = V3DeleteReconciliationPolicy.callbackGraceElapsed(
                    requestedAt: cancellationRequestedAt, now: now)
            } else {
                reconciliationExpired = deadlineElapsed
            }
            let terminal = contract.resolve(
                backend: backendState,
                nativeUninstallSucceeded: nativeUninstallSucceeded,
                appStillInAuthoritativeLibrary: appIsPresent,
                deadlineExpired: reconciliationExpired,
                progress: group.progress.fractionCompleted
            )
            switch terminal {
            case .completed?:
                if backendState == .pending {
                    if !verifiedDeleteCompletionPublished &&
                       V3DeleteReconciliationPolicy.mayPublishVerifiedDeleteCompletion(
                        backendPending: true, nativeUninstallSucceeded: nativeUninstallSucceeded,
                        appStillInLibrary: appIsPresent,
                        reconciliationDeadlineElapsed: missingCallbackReconcileDeadline.map({ now >= $0 }) == true) {
                        finish(id: id, response: [
                            "operation": "delete", "state": "completed",
                            "outcomeUnknown": false, "backendSettled": false,
                            "verifiedDeleteCompletion": true,
                            "sourceStep": "native_uninstall+authoritative_library_absence"
                        ])
                        verifiedDeleteCompletionPublished = true
                        // The native delete is verified for the UI, but SideStore
                        // still has backup/Core Data/widget/cellular cleanup after
                        // InstallationProxy. Keep the mutation owner until the
                        // high-level pipeline callback settles.
                        debugLog("[V3_OP] DELETE_RECONCILE_COMPLETED session=\(id) evidence=native_success+library_absent callback=pending backend_ownership=retained")
                    }
                    callbackPollDelay = V3DeleteReconciliationPolicy.nextCallbackPollDelay(
                        current: callbackPollDelay, backendPending: true,
                        nativeUninstallSucceeded: nativeUninstallSucceeded,
                        appStillInLibrary: appIsPresent,
                        cancellationRequested: cancellationRequestedAt != nil)
                    try await Task.sleep(nanoseconds: UInt64(callbackPollDelay * 1_000_000_000))
                    continue
                }
                let resolution = backendState == .succeeded ? "pipeline_callback" : "native_success_reconciled"
                debugLog("[V3_OP] DELETE_RECONCILE_COMPLETED session=\(id) evidence=\(resolution)+library_absent")
                return
            case .outcomeUnknown?:
                if V3DeleteReconciliationPolicy.shouldPublishOutcomeUnknown(
                    backendPending: backendState == .pending,
                    requestedAt: cancellationRequestedAt, now: now) {
                    let failure = CombinedFailure(operation: "delete", stage: .command,
                                                  code: .timedOut, id: id)
                    let response: [String: Any] = [
                        "state": "reconciling", "outcomeUnknown": true, "backendSettled": false,
                        "stage": failure.stage.rawValue, "code": failure.code.rawValue,
                        "message": failure.safeMessage, "technical": failure.technicalDetails,
                        "failure": failure.wire
                    ]
                    finish(id: id, response: response)
                    debugLog("[V3_OP] DELETE_RECONCILE_OUTCOME_UNKNOWN session=\(id) ownership=retained")
                    // The timeout is a provisional observation, not the
                    // operation's terminal result. Keep this driver and its
                    // mutation registry alive until the native callback settles.
                    callbackPollDelay = V3DeleteReconciliationPolicy.nextCallbackPollDelay(
                        current: callbackPollDelay, backendPending: true,
                        nativeUninstallSucceeded: nativeUninstallSucceeded,
                        appStillInLibrary: appIsPresent,
                        cancellationRequested: cancellationRequestedAt != nil)
                    try await Task.sleep(nanoseconds: UInt64(callbackPollDelay * 1_000_000_000))
                    continue
                }
                break
            case .failed?:
                debugLog("[V3_OP] DELETE_RECONCILE_FAILED session=\(id) backend=\(backendState) native_uninstall=\(nativeUninstallSucceeded) library_present=\(appIsPresent)")
                throw CombinedFailure(operation: "delete", stage: .command, code: .timedOut,
                                      id: id, retryable: false)
            case nil:
                break
            }
            if reconciliationExpired { continue }
            callbackPollDelay = V3DeleteReconciliationPolicy.nextCallbackPollDelay(
                current: callbackPollDelay, backendPending: backendState == .pending,
                nativeUninstallSucceeded: nativeUninstallSucceeded,
                appStillInLibrary: appIsPresent,
                cancellationRequested: cancellationRequestedAt != nil)
            try await Task.sleep(nanoseconds: UInt64(callbackPollDelay * 1_000_000_000))
        }
        throw CancellationError()
    }

    private func authoritativeLibraryContains(bundleIdentifier: String) async throws -> Bool {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "InstalledApp")
            request.predicate = NSPredicate(format: "bundleIdentifier == %@", bundleIdentifier)
            request.fetchLimit = 1
            return try context.count(for: request) > 0
        }
    }

    // The first convergence point for local IPA and URL installs is a resolved
    // AppProtocol. Both then create the same .install operation and use the
    // same PipelineRunner callback, prompt handler, and terminal result path.
    private func makeInstallDriver(id: String, kind: String, route: V3InstallInputRoute,
                                   app: AppProtocol, handler: V3HeadlessPipelineHandler,
                                   context: StandaloneOperationContext) -> V3OpDriver {
        let built = V3InstallPipelineParity.makeOperation(route: route, app) {
            AppOperation.install($0)
        }
        debugLog("[V3_INSTALL_ROUTE] input=\(built.route.rawValue) convergence=AppProtocol pipeline=.install")
        return V3OpDriver(kind: kind) {
            try await self.single(id: id, operation: built.operation, handler: handler, context: context)
        }
    }

    private final class V3DeleteBackendResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<Void, Error>?

        func record(_ result: Result<Void, Error>) {
            lock.lock()
            if stored == nil { stored = result }
            lock.unlock()
        }

        var result: Result<Void, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private func resolveInstallTarget(id: String, kind: String, target: String) async throws -> InstallTarget {
        if kind == "install" {
            let app: StoreApp = try v3Resolve(target)
            guard app.latestSupportedVersion != nil else { throw V3SideStoreServiceError.unsupported }
            return .app(app)
        }
        if kind == "installSharedIPA" {
            let token = try V3IPAStaging.canonicalToken(target)
            guard let root = V3IPAStaging.sideStoreContainerRoot() else {
                throw CombinedIPAFileError(.fileAccess)
            }
            let metadata = try V3IPAStaging.inspect(token: token, containerRoot: root) { url in
                try AppManager.readAppMetadata(from: url, packageType: .ipa)
            }
            let file = try V3IPAStaging.resolve(token: token, containerRoot: root)
            return .app(AnyApp(name: metadata.name, bundleIdentifier: metadata.bundleIdentifier,
                               url: file, storeApp: nil))
        }
        guard let url = URL(string: target), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else {
            throw V3SideStoreServiceError.invalidRequest
        }
        return try await ipaTarget(url: url, scoped: false, sessionID: id)
    }

    private func ipaTarget(url: URL, scoped: Bool, sessionID: String) async throws -> InstallTarget {
        var localURL = url
        var scopedURL: URL?
        defer { scopedURL?.stopAccessingSecurityScopedResource() }
        if !url.isFileURL {
            guard let packageType = PackageType(url: url), packageType == .ipa else {
                throw OperationError.invalidApp(reason: "Unsupported package format '.\(url.pathExtension)'. Expected '.ipa'.")
            }
            let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            sessions[sessionID]?.temporaryIPADirectory = temporaryDirectory
            V3HeadlessRuntime.shared.operations.setPhase(sessionID: sessionID, phase: .downloadingIPA)
            localURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let downloadTask = URLSession.shared.downloadTask(with: url) { (fileURL, response, error) in
                    do {
                        let (fileURL, _) = try Result((fileURL, response), error).get()
                        let dest = temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                        try FileManager.default.moveItem(at: fileURL, to: dest)
                        continuation.resume(returning: dest)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                sessions[sessionID]?.preparation.installCancellation { downloadTask.cancel() }
                downloadTask.resume()
            }
            guard sessions[sessionID]?.terminal.isEmpty == true,
                  sessions[sessionID]?.terminal.isCancellationRequested != true else {
                cleanupTemporaryIPA(id: sessionID)
                throw CancellationError()
            }
        }
        if scoped, localURL.startAccessingSecurityScopedResource() { scopedURL = localURL }
        let packageType = PackageType(url: localURL) ?? .ipa
        let (bundleIdentifier, appName): (String, String)
        do { (bundleIdentifier, appName) = try AppManager.readAppMetadata(from: localURL, packageType: packageType) }
        catch { throw CombinedIPAFileError(.invalidPackage) }
        guard sessions[sessionID]?.terminal.isEmpty == true,
              sessions[sessionID]?.terminal.isCancellationRequested != true else {
            cleanupTemporaryIPA(id: sessionID)
            throw CancellationError()
        }
        return .app(AnyApp(name: appName, bundleIdentifier: bundleIdentifier, url: localURL, storeApp: nil))
    }

}

struct V3RequiresSourceError: Error {
    let sourceID: String
    let sourceName: String
    let sourceURL: String
}

enum V3SideStoreServiceError: String, Error {
    case notReady, invalidRequest, notFound, unsupported, busy, authRequired, persistenceUnverified
    // V3_CATALOG_SOURCE_MISSING_V1: the requested Source row no longer exists.
    // Distinct from a valid source that happens to publish zero apps, and never
    // reported as a manifest problem.
    case catalogSourceUnavailable
}

struct V3SourceCommandError: Error {
    enum Kind { case network, invalidManifest, validation }
    let kind: Kind
    let domain: String
    let code: Int
    let safeCause: CombinedFailure.SafeCause
    let sourceStep: CombinedFailure.SourceStep

    static func classify(_ error: Error) -> V3SourceCommandError? {
        let native = error as NSError
        if error is CancellationError ||
            CombinedFailure.isURLCancellation(domain: native.domain, code: native.code) {
            return nil
        }
        // Prefer the typed SideStore source code over NSError domain/code.
        if let sourceError = error as? SourceError {
            let safeCause: CombinedFailure.SafeCause
            switch sourceError.code {
            case .blocked: safeCause = .sourceBlocked
            case .changedID: safeCause = .sourceChangedID
            case .duplicate: safeCause = .sourceDuplicate
            case .unsupported, .marketplaceNotSupported: safeCause = .sourceUnsupported
            case .duplicateBundleID, .duplicateVersion, .missingPermissionUsageDescription,
                 .missingScreenshotSize, .marketplaceRequired:
                safeCause = .sourceValidationFailed
            default:
                // Future pinned SourceError codes remain unknown until their
                // meaning is reviewed; never forward associated values.
                return nil
            }
            return V3SourceCommandError(kind: .validation, domain: native.domain, code: native.code,
                safeCause: safeCause, sourceStep: .sourceValidation)
        }
        // URLSession also uses URL error domains for local download-file I/O.
        // Only SideStore's shared typed transport-code policy proves network loss.
        if CombinedFailure.knownURLTransportCause(domain: native.domain, code: native.code) != nil {
            return V3SourceCommandError(kind: .network, domain: native.domain, code: native.code,
                safeCause: .sourceNetworkFailure, sourceStep: .sourceDownload)
        }
        if error is DecodingError || native.domain == "io.sidestore.SideStore.DecodingError" {
            return V3SourceCommandError(kind: .invalidManifest, domain: native.domain, code: native.code,
                safeCause: .sourceInvalidManifest, sourceStep: .manifestParsing)
        }
        return nil
    }
}

func v3Resolve<T: NSManagedObject>(_ identifier: String) throws -> T {
    guard let url = URL(string: identifier),
          let id = DatabaseManager.shared.persistentContainer.persistentStoreCoordinator.managedObjectID(forURIRepresentation: url),
          let object = try DatabaseManager.shared.viewContext.existingObject(with: id) as? T else {
        throw V3SideStoreServiceError.notFound
    }
    return object
}

// MARK: - Backend data commands (certificates, developer services, sources,
// pairing, settings, anisette, SideSign, logs, health, account backup)

// The context contains public certificate data and account/team identity only.
// Its digest is an observation key, not a credential or a durable refresh claim.
struct V3HostSigningContext: Sendable {
    let digest: String
    let certificateDER: Data
    let team: ALTTeam
}

@MainActor
func v3CurrentHostSigningContext() -> V3HostSigningContext? {
    let auth = AuthManager.shared
    let stamp = auth.v3IdentityStamp
    guard auth.v3IdentityIsStable, !V3HeadlessRuntime.shared.auth.hasActiveSession,
          let credentials = auth.authenticationSnapshot, credentials.isAuthenticated,
          let account = DatabaseManager.shared.activeAccount(),
          let team = DatabaseManager.shared.activeTeam(),
          team.account?.identifier == account.identifier,
          V3AuthIdentityBindingPolicy.mayUseTeam(sessionOwner: credentials.appleIDEmailAddress,
              teamOwner: account.appleID),
          let owner = V3AuthIdentityBindingPolicy.normalizedOwner(account.appleID),
          !account.identifier.isEmpty, !team.identifier.isEmpty,
          let der = CertificateManager.shared.activeCertificate?.certificate.x509.data, !der.isEmpty,
          let bytes = try? PropertyListSerialization.data(fromPropertyList:
            ["V3HostSigningContext1", account.identifier, owner, team.identifier,
             String(team.type.rawValue), der] as [Any], format: .binary, options: 0),
          auth.v3IdentityIsStable, auth.v3IdentityStamp == stamp else { return nil }
    return V3HostSigningContext(
        digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
        certificateDER: der,
        team: ALTTeam(identifier: team.identifier, name: team.name, type: team.type,
            account: ALTAccount(appleID: owner, identifier: account.identifier)))
}

// An actor keeps Mach-O/profile reads off MainActor and serializes overlapping
// health requests. The single-entry cache also expires before the local profile
// or leaf certificate does. Snapshot never invokes this parser.
actor V3InstalledHostSigningReader {
    static let maximumCacheAge: TimeInterval = 60
    static let shared = V3InstalledHostSigningReader()
    private var cacheKey: String?
    private var cached: V3HostSigningObservation?

    private func fileIdentity(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let file = attributes[.systemFileNumber] as? NSNumber,
              let system = attributes[.systemNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let created = attributes[.creationDate] as? Date else { return nil }
        return [url.standardizedFileURL.path, system.stringValue, file.stringValue,
                size.stringValue, String(modified.timeIntervalSince1970),
                String(created.timeIntervalSince1970)].joined(separator: "|")
    }

    func observe(_ context: V3HostSigningContext, now: Date = Date()) -> V3HostSigningObservation {
        let url = Bundle.Info.activeBundleURL
        let unknown = V3HostSigningObservation(context: context.digest, checkedAt: now,
            validUntil: now.addingTimeInterval(V3HostSigningObservation.maximumAge))
        guard let executable = Bundle(url: url)?.executableURL,
              let executableIdentity = fileIdentity(executable),
              let profileIdentity = fileIdentity(url.appendingPathComponent("embedded.mobileprovision")) else {
            cacheKey = nil; cached = nil
            return unknown
        }
        let key = context.digest + "|" + executableIdentity + "|" + profileIdentity
        if cacheKey == key, let cached,
           now >= cached.checkedAt, now < cached.validUntil,
           now.timeIntervalSince(cached.checkedAt) < Self.maximumCacheAge {
            return cached
        }
        guard let certificate = ALTX509Certificate(data: context.certificateDER),
              let profile = ALTApplication(fileURL: url)?.provisioningProfile,
              let runningCertificate = CertificateManager.shared.getSigningCertificate(at: url) else { return unknown }
        let result = CodeSignValidator.validate(runningProfile: profile,
            observedRunningCertificate: runningCertificate, portalCertificates: nil, signerCertificate: certificate, signerTeam: context.team)
        // The validator owns the local semantics. Paid mismatches are not
        // definitely re-sign-required: upstream tolerates them after a portal
        // check, and this deliberately local observation performs no such check.
        let state: V3HostSigningState
        switch result {
        case .success: state = .compatible
        case .failure(.missingProfile), .failure(.missingCertificate): state = .unknown
        case .failure(.privateKeyLost), .failure(.externalSigner):
            state = context.team.type == .free ? .refreshRequired : .paidSignerUnverified
        case .failure: state = .refreshRequired
        }
        // Only successful evidence expires at certificate/profile expiry.
        // An already-expired profile remains a definite refresh-needed fact.
        let deadline = now.addingTimeInterval(V3HostSigningObservation.maximumAge)
        let validUntil = state == .compatible
            ? min(deadline, profile.expirationDate, certificate.expiryDate, runningCertificate.expiryDate)
            : deadline
        let observation = V3HostSigningObservation(context: context.digest, state: state,
            checkedAt: now, validUntil: validUntil)
        // Replacement while reading is not a valid cached observation.
        guard fileIdentity(executable) == executableIdentity,
              fileIdentity(url.appendingPathComponent("embedded.mobileprovision")) == profileIdentity else {
            cacheKey = nil; cached = nil
            return unknown
        }
        cacheKey = key; cached = observation
        return observation
    }
}

@MainActor
enum V3BackendCommands {
    private static var activeCertificateValidationCache: (fingerprint: String, result: String, checkedAt: Date)?

    static func certificateRow(_ x509: ALTX509Certificate, activeSerial: String?) -> [String: Any] {
        var row: [String: Any] = ["serial": x509.serialNumber, "name": x509.name,
                                  "active": x509.serialNumber == activeSerial]
        row["machineName"] = x509.machineName ?? ""
        row["machineID"] = x509.machineIdentifier ?? ""
        row["requesterEmail"] = x509.requesterEmail ?? ""
        row["created"] = x509.creationDate
        row["expiry"] = x509.expiryDate
        return row
    }

    static func certificates() -> [[String: Any]] {
        let activeSerial = CertificateManager.shared.activeCertificate?.certificate.serialNumber
        return CertificateManager.shared.getAllLocalX509Certificates().map { certificateRow($0, activeSerial: activeSerial) }
    }

    static func portalAccount() async throws -> ALTAccount {
        guard let appleID = DatabaseManager.shared.activeAccount()?.appleID else {
            throw V3SideStoreServiceError.authRequired
        }
        return ALTAccount(appleID: appleID, identifier: appleID, firstName: "", lastName: "")
    }

    static func portalCertificates() async throws -> [[String: Any]] {
        _ = try await AuthManager.shared.getAuthenticatedSession()
        let team = try await AuthManager.shared.getAuthenticatedTeam()
        let certificates = try await DeveloperPortalProxy.shared.fetchCertificates(team: team)
        let activeSerial = CertificateManager.shared.activeCertificate?.certificate.serialNumber
        return certificates.map { certificateRow($0, activeSerial: activeSerial) }
    }

    static func teamRow(_ team: ALTTeam) -> [String: Any] {
        ["identifier": team.identifier, "name": team.name, "type": "\(team.type)"]
    }

    static func developerTeams() async throws -> [[String: Any]] {
        let account = try await portalAccount()
        return try await DeveloperPortalProxy.shared.fetchTeams(for: account).map(teamRow)
    }

    static func developerDevices() async throws -> [[String: Any]] {
        _ = try await AuthManager.shared.getAuthenticatedSession()
        return try await DeveloperPortalProxy.shared.fetchDevices().map {
            ["identifier": $0.identifier, "name": $0.name, "type": "\($0.type)"]
        }
    }

    static func developerAppIDs() async throws -> [[String: Any]] {
        _ = try await AuthManager.shared.getAuthenticatedSession()
        return try await DeveloperPortalProxy.shared.fetchAppIDs().map {
            ["identifier": $0.identifier, "name": $0.name, "bundleID": $0.bundleIdentifier]
        }
    }

    static func developerGroups() async throws -> [[String: Any]] {
        _ = try await AuthManager.shared.getAuthenticatedSession()
        return try await DeveloperPortalProxy.shared.fetchAppGroups().map {
            ["identifier": $0.identifier, "name": $0.name]
        }
    }

    static func profileRow(_ profile: ALTListedProvisioningProfile) -> [String: Any] {
        // The portal list shape is upstream-owned; reflect scalar members instead
        // of hard-coding them so portal changes cannot break compilation.
        var row: [String: Any] = [:]
        for child in Mirror(reflecting: profile).children {
            guard let label = child.label else { continue }
            switch child.value {
            case let value as String: row[label] = value
            case let value as Bool: row[label] = value
            case let value as Int: row[label] = value
            case let value as Date: row[label] = value
            case let value as UUID: row[label] = value.uuidString
            default: row[label] = String(describing: child.value)
            }
        }
        return row
    }

    static func developerProfiles() async throws -> [[String: Any]] {
        _ = try await AuthManager.shared.getAuthenticatedSession()
        return try await DeveloperPortalProxy.shared.listProvisioningProfiles().map(profileRow)
    }

    static func sourcePreview(urlString: String) async throws -> [String: Any] {
        guard let url = V3SourceAddPersistencePolicy.validatedURL(urlString) else {
            throw V3SideStoreServiceError.invalidRequest
        }
        let background = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let source: Source
        do {
            source = try await AppManager.shared.fetchSource(sourceURL: url, managedObjectContext: background)
        } catch {
            if let classified = V3SourceCommandError.classify(error) { throw classified }
            throw error
        }
        let name = try await background.performAsync { source.name }
        let identifier = try await background.performAsync { source.identifier }
        let added = try await source.isAdded()
        let title = "Would you like to add the source \"\(name)\"?"
        return ["identifier": identifier, "name": name, "alreadyAdded": added,
                "title": title, "message": "Make sure to only add sources that you trust."]
    }

    static func sourceAddConfirmed(urlString: String) async throws -> [String: Any] {
        guard let url = V3SourceAddPersistencePolicy.validatedURL(urlString) else {
            throw V3SideStoreServiceError.invalidRequest
        }
        let addResult: (identifier: String, alreadyAdded: Bool)
        do {
            addResult = try await AppManager.shared.addConfirmed(sourceURL: url)
        } catch {
            if let classified = V3SourceCommandError.classify(error) { throw classified }
            throw error
        }
        let identifier = addResult.identifier
        let verificationContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let query = NSFetchRequest<Source>(entityName: "Source")
        query.predicate = NSPredicate(format: "%K == %@", #keyPath(Source.identifier), identifier)
        let authoritativeCount = try await verificationContext.performAsync {
            try verificationContext.count(for: query)
        }
        guard let result = V3SourceAddPersistencePolicy.verifiedResult(
            identifier: identifier, alreadyAdded: addResult.alreadyAdded,
            authoritativeCount: authoritativeCount) else {
            throw V3SideStoreServiceError.persistenceUnverified
        }
        return result
    }

    static func authoritativeSourceRows() async throws -> [[String: Any]] {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        return try await context.performAsync {
            try context.fetch(NSFetchRequest<Source>(entityName: "Source")).map { source in
                ["identifier": source.identifier, "name": source.name,
                 "subtitle": source.subtitle ?? "", "url": source.sourceURL.absoluteString,
                 "appCount": source.apps.count,
                 "canRemove": source.identifier != Source.altStoreIdentifier] as [String: Any]
            }
        }
    }

    static func sourceRemoveConfirmed(identifier: String) async throws {
        try await AppManager.shared.removeConfirmed(identifier: identifier)
    }

    static func pairingImportData(token: String) throws {
        let data = try consumeSharedFile(token: token, purpose: "pairing")
        guard let contents = String(data: data, encoding: .utf8), !contents.isEmpty,
              (try? PairingFileParser.parse(content: contents)) != nil else {
            throw OperationError.invalidPairingFile(reason: "the pairing file is missing required device-pairing fields")
        }
        try PairingFileManager.shared.savePairingFile(contents: contents)
    }

    static func pairingFileStatus() -> String {
        guard let contents = PairingFileManager.shared.fetchPairingFile(), !contents.isEmpty else {
            return "Pairing file required"
        }
        guard (try? PairingFileParser.parse(content: contents)) != nil else {
            return "Pairing file invalid"
        }
        return "Pairing file available"
    }

    static func prepareSignOut() throws {
        do {
            try Keychain.shared.clearSignInInfoChecked()
        } catch {
            let cause: CombinedFailure.SafeCause = (error as NSError).code == 1010
                ? .keychainSignOutOutcomeUnknown : .keychainSignOutFailed
            throw CombinedFailure(operation: "signOut", stage: .authentication,
                code: .failed, id: UUID().uuidString, underlying: error, retryable: true,
                safeCause: cause)
        }
    }

    static let boolSettings: Set<String> = ["isCellularRefreshEnabled", "isSideJITServerEnabled",
        "alwaysShowWireGuardConfig", "acceptIPv6ConnectionConfig", "enableEMPforWireguard",
        "useOnDeviceAnisette", "customizeAppId", "customizeAppExtensions", "autoFixAppGroupIDs",
        "preferResignedIPA", "isExportResignedAppEnabled", "skipNonCopyableBackupFiles",
        "appVerificationDisabled", "isBundleIDVerificationEnabled", "isiOSVersionVerificationEnabled",
        "isAppVersionVerificationEnabled", "isChecksumVerificationEnabled", "isFileSizeVerificationEnabled",
        "permissionCheckingDisabled", "responseCachingDisabled", "isVerboseOperationsLoggingEnabled",
        "isSideStoreVerboseLoggingEnabled", "isAltSignVerboseLoggingEnabled", "isMinimuxerVerboseLoggingEnabled",
        "isRotateLogsOnStartupEnabled", "recreateDatabaseOnNextStart", "isAnisetteOfflineMode",
        "disableAnisetteRotation", "useLocalVPN", "isBetaUpdatesEnabled", "isIdleTimeoutDisableEnabled",
        "isBackgroundRefreshEnabled", "keepSigningCertsAfterLogout", "keepAnisetteDataAfterLogout",
        "keepAnisetteHeadersAfterLogout", "keepSideSignHeadersAfterLogout"]
    static let stringSettings: Set<String> = ["textInputSideJITServerurl", "menuAnisetteURL", "menuAnisetteList",
        "betaUdpatesTrack", "minimuxerGatewayBackend", "textInputAnisetteURL"]
    static let intSettings: Set<String> = ["remotePairingPortOverride", "deviceProbeTimeoutOverride"]

    static func settingsGet() -> [String: Any] {
        var bools: [String: Bool] = [:]
        for key in boolSettings { bools[key] = UserDefaults.standard.bool(forKey: key) }
        // These upstream preferences have computed defaults (including the
        // active team's extension policy), not registered raw bool defaults.
        // Project their effective values rather than showing false for an
        // unset key while the install pipeline observes true.
        bools["customizeAppExtensions"] = UserDefaults.standard.customizeAppExtensions
        bools["autoFixAppGroupIDs"] = UserDefaults.standard.autoFixAppGroupIDs
        bools["widgetVerboseLogging"] = WidgetDataManager.shared.isVerboseLoggingEnabled
        var strings: [String: String] = [:]
        for key in stringSettings { strings[key] = UserDefaults.standard.string(forKey: key) ?? "" }
        var ints: [String: Int] = [:]
        for key in intSettings { ints[key] = UserDefaults.standard.integer(forKey: key) }
        return ["bools": bools, "strings": strings, "ints": ints]
    }

    static func settingsSet(payload: [String: Any]) throws {
        guard let key = payload["key"] as? String else { throw V3SideStoreServiceError.invalidRequest }
        if boolSettings.contains(key) {
            guard let value = V3WireContract.strictBool(payload["bool"]) else { throw V3SideStoreServiceError.invalidRequest }
            UserDefaults.standard.set(value, forKey: key)
        } else if key == "widgetVerboseLogging" {
            guard let value = V3WireContract.strictBool(payload["bool"]) else { throw V3SideStoreServiceError.invalidRequest }
            WidgetDataManager.shared.isVerboseLoggingEnabled = value
        } else if stringSettings.contains(key) {
            guard let value = payload["string"] as? String else { throw V3SideStoreServiceError.invalidRequest }
            if value.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set(value, forKey: key) }
        } else if intSettings.contains(key) {
            guard let value = V3WireContract.strictInt(payload["int"]) else {
                throw V3SideStoreServiceError.invalidRequest
            }
            // Match the retained connection editor: zero means automatic,
            // while explicit ports must fit UInt16. Never save an invalid
            // value that the transport silently replaces with its default.
            guard value >= 0,
                  key != "remotePairingPortOverride" || value <= Int(UInt16.max) else {
                throw V3SideStoreServiceError.invalidRequest
            }
            UserDefaults.standard.set(value, forKey: key)
            // Match upstream's effective integer settings without calling its
            // whole-config sync: that also activates a separately saved backend
            // change, which upstream applies only through an explicit restart.
            if key == "remotePairingPortOverride" {
                remotePairingPortCache = value > 0 ? UInt16(value) : AppConstants.Minimuxer.remotePairingPort
            } else {
                deviceProbeTimeoutCache = value > 0 ? value : AppConstants.Minimuxer.defaultTCPProbeTimeoutMs
            }
        } else {
            throw V3SideStoreServiceError.invalidRequest
        }
    }

    static func anisetteList() async -> [[String: Any]] {
        let items = await AnisetteServersManager.shared.loadLocalServers()
        let active = await AnisetteServersManager.shared.getActiveServerURLs()
        return items.map { ["id": $0.id, "name": $0.name, "address": $0.address,
                            "hidden": $0.isHidden, "active": active.contains($0.address)] }
    }

    static func sidesignJSON() async throws -> String {
        let config = await SideSignConfigManager.shared.loadConfig()
        guard let data = try? JSONEncoder().encode(config),
              let text = String(data: data, encoding: .utf8), text.utf8.count <= 8192 else {
            throw V3SideStoreServiceError.invalidRequest
        }
        return text
    }

    // The SideSign configuration is not a credential, so it travels in the
    // reply rather than through a shared-storage token that no re-signer lets
    // this extension read back.
    static func sidesignConfigText() async throws -> String {
        try await sidesignJSON()
    }

    static func sidesignSet(config json: String) async throws {
        guard let data = json.data(using: .utf8),
              let config = try? JSONDecoder().decode(SideSignHeaders.self, from: data) else {
            throw V3SideStoreServiceError.invalidRequest
        }
        await SideSignConfigManager.shared.saveConfig(config)
    }

    static func sidesignImport(token: String) async throws {
        let data = try consumeSharedFile(token: token, purpose: "sidesign")
        guard let config = try? JSONDecoder().decode(SideSignHeaders.self, from: data) else {
            throw V3SideStoreServiceError.invalidRequest
        }
        await SideSignConfigManager.shared.saveConfig(config)
    }

    static func sidesignExportText() async throws -> String {
        guard let data = await SideSignConfigManager.shared.exportConfigData(),
              let text = String(data: data, encoding: .utf8), text.utf8.count <= 8192 else {
            throw V3SideStoreServiceError.invalidRequest
        }
        return text
    }

    static func consumeSharedFile(token: String, purpose: String) throws -> Data {
        guard let containerRoot = V3IPAStaging.sideStoreContainerRoot(),
              let data = V3SharedFileRecord.consume(token, purpose: purpose,
                containerRoot: containerRoot) else {
            throw V3SideStoreServiceError.invalidRequest
        }
        return data
    }

    static func logTail(limit: Int = 262_144) -> [String: Any] {
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else { return ["tail": ""] }
        let url = delegate.consoleLog.logFileURL
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ["tail": ""] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let rawTail = String(decoding: data, as: UTF8.self)
        return ["tail": formatLogMessage(rawTail)]
    }

    static func hostSigningHealth() async -> [String: Any] {
        let stamp = AuthManager.shared.v3IdentityStamp
        guard let context = v3CurrentHostSigningContext() else {
            return ["hostSigning": V3HostSigningObservation().wire, "identityStamp": stamp]
        }
        let observed = await V3InstalledHostSigningReader.shared.observe(context)
        guard AuthManager.shared.v3IdentityIsStable, AuthManager.shared.v3IdentityStamp == stamp,
              v3CurrentHostSigningContext()?.digest == context.digest else {
            return ["hostSigning": V3HostSigningObservation().wire, "identityStamp": stamp]
        }
        return ["hostSigning": observed.wire, "identityStamp": stamp]
    }

    static func health() async -> [String: Any] {
        let hostSigning = await hostSigningHealth()
        let account = DatabaseManager.shared.activeAccount()?.appleID ?? "Not signed in"
        let team = DatabaseManager.shared.activeTeam()
        var anisette: [String: Any] = ["servers": 0, "offline": UserDefaults.standard.bool(forKey: "isAnisetteOfflineMode")]
        let servers = await AnisetteServersManager.shared.loadLocalServers()
        anisette["servers"] = servers.count
        anisette["active"] = await AnisetteServersManager.shared.getActiveServerURLs()
        return ["account": account, "team": team?.name ?? "No active team",
                "certificate": CertificateManager.shared.activeCertificate == nil ? "No active certificate" : "Active certificate available",
                "pairing": pairingFileStatus(),
                "anisette": anisette,
                "sidesign": ["configured": SideSignConfigManager.shared.hasConfigFile()],
                "service": ["ready": DatabaseManager.shared.isStarted],
                "certificateState": await certificateState()].merging(hostSigning) { _, local in local }
    }

    // Facts about the certificate the refresh/signing pipeline actually uses
    // (CertificateManager.activeCertificate). Only the serial suffix and a
    // public certificate DER fingerprint cross XPC; no private key, p12, or
    // password is returned. The LiveContainer JIT-Less copy stays host-side.
    static func certificateState() async -> [String: Any] {
        guard let active = CertificateManager.shared.activeCertificate else {
            return ["active": false]
        }
        var state: [String: Any] = [
            "active": true,
            "serialSuffix": String(active.serialNumber.suffix(4)),
            "team": DatabaseManager.shared.activeTeam()?.identifier ?? "",
            "expiry": active.certificate.x509.expiryDate,
        ]
        let fingerprint: String
        if let certificateDER = active.certificate.x509.data {
            fingerprint = SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
            state["certificateIdentitySHA256"] = fingerprint
        } else {
            fingerprint = ""
        }
        if let cached = activeCertificateValidationCache,
           cached.fingerprint == fingerprint, Date().timeIntervalSince(cached.checkedAt) < 60 {
            state["validation"] = cached.result
        } else {
            let validation: String
            do {
                try await OCSPValidator.validate(active.certificate.x509)
                validation = "valid"
            } catch let error as OCSPValidationError {
                switch error {
                case .revoked: validation = "revoked"
                case .expired: validation = "expired"
                default: validation = "unknown"
                }
            } catch {
                validation = "unknown"
            }
            activeCertificateValidationCache = (fingerprint, validation, Date())
            state["validation"] = validation
        }
        return state
    }

    static func accountExport(password: String, includeApplePassword: Bool) throws -> String {
        guard !password.isEmpty else { throw V3SideStoreServiceError.invalidRequest }
        let data = try ImportExport.exportAccount(password: password, includeApplePassword: includeApplePassword)
        return data.base64EncodedString()
    }

    static func accountImport(token: String, password: String) throws -> [String: Any] {
        let data = try consumeSharedFile(token: token, purpose: "accountImport")
        let account = try ImportExport.importAccount(data, filePassword: password)
        return ["email": account.email]
    }
}

// V3_EXTERNAL_URL_LOG_REDACTION_V1: file URLs and pairing callback payloads are never logged.
import Foundation
import CoreFoundation

public struct CombinedFailure: Error, LocalizedError {
    public struct LaunchContext: Equatable {
        public static let bridgeErrorDomain = "io.sidestore.LiveContainer.ExtensionLaunch"
        public static let bridgeNoIdentifierCode = 1
        public enum Step: String {
            case hostBundleUnavailable, missingPluginDirectory, liveProcessBundleMissing, liveProcessBundleUnreadable
            case bundleIdentifierMissing, executableMetadataMissing, executableFileMissing
            case extensionFactory, extensionFactoryNil, listenerCreation
            case requestCallbackNoIdentifier, requestCancellation, requestInterruption
            case requestCallbackError, processIdentifierUnavailable, xpcRemoteObjectError
            case xpcInvalidation, xpcPeerRejected, readinessProbe, startupTimeout, connectionStopped, unknown
        }
        public enum Kind: String {
            case extensionNotFound = "extension_not_found"
            case executableLoadFailure = "executable_load_failure"
            case signatureOrEntitlementRejection = "signature_or_entitlement_rejection"
            case dependencyLoadFailure = "dependency_load_failure"
            case bootstrapFailure = "bootstrap_failure"
            case xpcConnectionFailure = "xpc_connection_failure"
            case unknown
        }
        public struct Cause: Equatable {
            public let domain: String
            public let code: Int?
        }

        public let observerRole: String
        public let targetRole: String
        public let osVersion: String
        public let runtimeArchitecture: String
        public let sourceStep: Step
        public let kind: Kind
        public let requestIdentifierObserved: String
        public let pidObserved: String
        public let xpcAccepted: String
        public let applicationReadyObserved: String
        public let peerPIDRejected: String
        public private(set) var errorChain: [Cause]

        public init(error: Error? = nil, sourceStep: Step,
                    requestIdentifierObserved: Bool? = nil, pidObserved: Bool? = nil,
                    xpcAccepted: Bool? = nil, applicationReadyObserved: Bool? = nil,
                    peerPIDRejected: Bool? = nil) {
            observerRole = "host"
            targetRole = "LiveProcess"
            let version = ProcessInfo.processInfo.operatingSystemVersion
            osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            #if arch(arm64e)
            runtimeArchitecture = "arm64e"
            #elseif arch(arm64)
            runtimeArchitecture = "arm64"
            #elseif arch(x86_64)
            runtimeArchitecture = "x86_64"
            #elseif arch(i386)
            runtimeArchitecture = "i386"
            #else
            runtimeArchitecture = "unknown"
            #endif
            self.sourceStep = sourceStep

            self.requestIdentifierObserved = Self.observation(requestIdentifierObserved)
            self.pidObserved = Self.observation(pidObserved)
            self.xpcAccepted = Self.observation(xpcAccepted)
            self.applicationReadyObserved = Self.observation(applicationReadyObserved)
            self.peerPIDRejected = Self.observation(peerPIDRejected)

            let causes = Self.safeErrorChain(error)
            errorChain = causes
            kind = Self.classify(sourceStep: sourceStep, errorChain: causes)
        }

        public var technicalDetails: String {
            let causes = errorChain.map { cause in
                cause.code.map { "\(cause.domain):\($0)" } ?? "\(cause.domain):unknown"
            }.joined(separator: ">")
            return " launch_observer_role=\(observerRole) launch_target_role=\(targetRole) launch_os=\(osVersion) launch_arch=\(runtimeArchitecture)" +
                " launch_source_step=\(sourceStep.rawValue) launch_failure_kind=\(kind.rawValue)" +
                " launch_request_id_observed=\(requestIdentifierObserved) launch_pid_observed=\(pidObserved)" +
                " launch_xpc_accepted=\(xpcAccepted) launch_application_ready=\(applicationReadyObserved)" +
                " launch_peer_pid_rejected=\(peerPIDRejected) launch_error_chain=\(causes.isEmpty ? "none" : causes)"
        }

        private static func observation(_ value: Bool?) -> String {
            guard let value else { return "unknown" }
            return value ? "yes" : "no"
        }

        public func retainingErrorChain(from prior: LaunchContext?) -> LaunchContext {
            guard let prior, !prior.errorChain.isEmpty else { return self }
            guard !errorChain.isEmpty else {
                var enriched = self
                enriched.errorChain = prior.errorChain
                return enriched
            }
            let limit = min(errorChain.count, prior.errorChain.count)
            let overlap = (0...limit).reversed().first { count in
                Array(errorChain.suffix(count)) == Array(prior.errorChain.prefix(count))
            } ?? 0
            let combined = Array((errorChain + Array(prior.errorChain.dropFirst(overlap))).prefix(5))
            guard combined != errorChain else { return self }
            var enriched = self
            enriched.errorChain = combined
            return enriched
        }

        private static func safeErrorChain(_ error: Error?) -> [Cause] {
            if let known = error as? CombinedFailure {
                if let context = known.launchContext { return context.errorChain }
                guard known.underlyingDomain != "none" || known.underlyingCode != 0 else { return [] }
                let safe = CombinedFailure.safeDiagnosticUnderlying(domain: known.underlyingDomain, code: known.underlyingCode)
                return [Cause(domain: safe.domain, code: safe.code == "unknown" ? nil : known.underlyingCode)]
            }
            guard var current = error as NSError? else { return [] }
            var result: [Cause] = []
            var seen = Set<ObjectIdentifier>()
            for _ in 0..<5 {
                let identity = ObjectIdentifier(current)
                guard seen.insert(identity).inserted else { break }
                let safe = CombinedFailure.safeDiagnosticUnderlying(domain: current.domain, code: current.code)
                result.append(Cause(domain: safe.domain, code: safe.code == "unknown" ? nil : current.code))
                guard let next = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
                current = next
            }
            return result
        }

        private static func classify(sourceStep: Step, errorChain: [Cause]) -> Kind {
            switch sourceStep {
            case .missingPluginDirectory, .liveProcessBundleMissing:
                return .extensionNotFound
            case .executableFileMissing:
                return .executableLoadFailure
            case .listenerCreation, .xpcRemoteObjectError, .xpcInvalidation:
                return .xpcConnectionFailure
            case .requestCancellation:
                if errorChain.contains(where: { $0.domain == NSCocoaErrorDomain && $0.code == NSExecutableLoadError }) {
                    return .executableLoadFailure
                }
            default:
                break
            }
            return .unknown
        }

        public static func launchFailure(_ error: Error? = nil, stage: Stage, code: Code = .failed,
                                         id: String, sourceStep: Step,
                                         requestIdentifierObserved: Bool? = nil, pidObserved: Bool? = nil,
                                         xpcAccepted: Bool? = nil, applicationReadyObserved: Bool? = nil,
                                         peerPIDRejected: Bool? = nil, retryable: Bool? = nil) -> CombinedFailure {
            let context = LaunchContext(error: error, sourceStep: sourceStep,
                requestIdentifierObserved: requestIdentifierObserved, pidObserved: pidObserved,
                xpcAccepted: xpcAccepted, applicationReadyObserved: applicationReadyObserved,
                peerPIDRejected: peerPIDRejected)
            return CombinedFailure(operation: "connect", stage: stage, code: code, id: id,
                underlying: error, retryable: retryable, launchContext: context)
        }
    }

    public enum SafeCause: String, CaseIterable {
        case networkConnectionLost
        case networkTimedOut
        case networkUnavailable
        case anisetteServerUnavailable
        case anisetteServerRejected
        case anisetteRequestTimedOut
        case anisetteRateLimited
        case anisetteInvalidResponse
        case anisetteUnknownFailure
        case signingNetworkConnectionLost
        case signingNetworkTimedOut
        case signingNetworkUnavailable
        case developerPortalRejectedRequest
        case appIDLimitReached
        case developerPortalInvalidResponse
        case provisioningProfileUnavailable
        case certificateUnavailable
        case signingStorageUnverified
        case wifiUnavailable
        case localDevVPNUnavailable
        case unknownSigningCause
        case sourceNetworkFailure
        case sourceInvalidManifest
        case sourcePersistenceUnverified
        case sourceInvalidURL
        case sourceBlocked
        case sourceChangedID
        case sourceDuplicate
        case sourceUnsupported
        case sourceValidationFailed
        case sourceRemoveFailed
        case sourceRemoveBusy
        case sourceAddBusy
        case operationInProgress
        case responseCapacityUnavailable
        // V3_RUNTIME_SHARED_STORE_CAUSE_V1: the host and the embedded service must
        // read and write refresh state through one App Group. When that store
        // cannot be opened the run is refused rather than written somewhere the
        // other process cannot see, and retrying after a reinstall can succeed.
        case sharedStoreUnavailable
        // V3_SECRET_HANDOFF_FAILURE_TYPED_V1: the secure channel between the two
        // signed processes failed. The payload never reached Apple, so this is
        // not an authentication failure and must not be reported as one. It is
        // retryable only when the cause is transient; an unauthorized or missing
        // access group needs a different re-sign, not another attempt.
        case secretHandoffUnavailable
        case staleRefreshAttempt
        case knownSourcePolicyNetworkFailure
        case knownSourcePolicyInvalidResponse
        case catalogUnavailable
        case catalogSourceUnavailable
        // V3_RESPONSE_ENCODING_CLASSIFICATION_V1: the service built a reply it
        // could not serialize. Distinct from an oversized reply.
        case responseEncodingFailed
        // V3_RESPONSE_ENCODING_CLASSIFICATION_V1: the reply serialized cleanly
        // but exceeded the transport limit. This is a third defect, distinct
        // from both an encoding failure and a reply that could not be parsed,
        // and it must not be reported as any of them.
        case responseTooLarge
        case pairingRequired
        case invalidPairingFile
        case pairingFilePreparationFailed
        case authAttemptNotDispatched
        case authProvisioningRetryNotDispatched
        case authSessionUnavailable
        case authResponseCapacityUnavailable
        case credentialCommitFailed, credentialCommitOutcomeUnknown, accountActivationFailed, provisioningStorageFailed
        case keychainSignOutFailed
        case keychainSignOutOutcomeUnknown
        case operationPersistenceFailed
        case recoveryMalformedRecord, recoveryIncompatibleRecord
        case recoveryStorageUnavailable, recoveryLockUnavailable
        case recoveryReadFailure, recoveryDeleteFailure

        fileprivate var inferredRetryable: Bool? {
            switch self {
            case .networkConnectionLost, .networkTimedOut, .networkUnavailable,
                 .signingNetworkConnectionLost, .signingNetworkTimedOut, .signingNetworkUnavailable,
                 .wifiUnavailable, .localDevVPNUnavailable:
                return true
            case .anisetteServerUnavailable:
                return true
            case .anisetteRequestTimedOut, .anisetteRateLimited:
                return true
            case .anisetteServerRejected:
                return false
            case .anisetteInvalidResponse, .anisetteUnknownFailure:
                return nil
            case .appIDLimitReached, .provisioningProfileUnavailable, .certificateUnavailable, .signingStorageUnverified:
                return false
            case .developerPortalRejectedRequest, .developerPortalInvalidResponse:
                return nil
            case .unknownSigningCause:
                return nil
            case .sourceNetworkFailure:
                return true
            case .sourceInvalidManifest, .sourcePersistenceUnverified, .sourceInvalidURL,
                 .sourceBlocked, .sourceChangedID, .sourceDuplicate, .sourceUnsupported,
                 .sourceValidationFailed,
                 .sourceRemoveFailed, .catalogUnavailable:
                return false
            case .sourceRemoveBusy, .sourceAddBusy:
                return true
            case .operationInProgress, .knownSourcePolicyNetworkFailure:
                return true
            case .responseCapacityUnavailable:
                return true
            case .sharedStoreUnavailable:
                return true
            // Retrying the same answer cannot grant an access group or recreate
            // an absent item. Only a transient read or lock failure may repeat.
            case .secretHandoffUnavailable:
                return false
            case .staleRefreshAttempt:
                return false
            case .knownSourcePolicyInvalidResponse:
                return nil
            // The source is gone, so retrying the same request cannot succeed;
            // the recovery is to reload the source list, not to retry.
            case .catalogSourceUnavailable:
                return false
            // A reply that could not be serialized is not fixed by retrying the
            // same request; it needs a code fix or a smaller payload.
            case .responseEncodingFailed:
                return false
            // An oversized reply is not fixed by retrying the same request
            // either: the same data would serialize to the same size again.
            case .responseTooLarge:
                return false
            case .pairingRequired:
                return false
            case .invalidPairingFile:
                return false
            case .pairingFilePreparationFailed:
                return false
            case .authAttemptNotDispatched:
                return true
            case .authProvisioningRetryNotDispatched:
                return true
            case .authSessionUnavailable:
                return false
            case .authResponseCapacityUnavailable:
                return true
            case .credentialCommitFailed, .credentialCommitOutcomeUnknown, .accountActivationFailed, .provisioningStorageFailed:
                return false
            case .keychainSignOutFailed, .keychainSignOutOutcomeUnknown:
                return true
            case .operationPersistenceFailed:
                return false
            case .recoveryMalformedRecord, .recoveryIncompatibleRecord:
                return false
            case .recoveryStorageUnavailable, .recoveryLockUnavailable,
                 .recoveryReadFailure, .recoveryDeleteFailure:
                return true
            }
        }
    }

    public enum SourceStep: String, CaseIterable {
        case authenticate, anisetteFetch, appleAuthentication, accountLookup
        case credentialCommit, fetchTeams, saveAccount, fetchCertificate
        case activateCertificate, registerDevice, activateAccount, provisioningUnknown
        case provisioningProfileFetch, certificateValidation, localCodeSigning
        case appIDLookup, appIDRegistration, appIDCapabilitiesUpdate
        case appGroupLookup, appGroupRegistration, appGroupAssignment
        case provisioningProfileRetrieval, provisioningProfileCreation, provisioningProfileUpdate
        case sourceDownload, manifestParsing, sourceValidation, knownSourcePolicyFetch,
             knownSourcePolicyParsing, catalogRead
        var portalUserLabel: String? {
            switch self {
            case .appIDLookup: return "while looking up app identifiers"
            case .appIDRegistration: return "while registering an app identifier"
            case .appIDCapabilitiesUpdate: return "while updating the app's capabilities"
            case .appGroupLookup: return "while looking up app groups"
            case .appGroupRegistration: return "while registering an app group"
            case .appGroupAssignment: return "while assigning the app's groups"
            case .provisioningProfileRetrieval: return "while retrieving a provisioning profile"
            case .provisioningProfileCreation: return "while creating a provisioning profile"
            case .provisioningProfileUpdate: return "while updating a provisioning profile"
            default: return nil
            }
        }
    }

    public enum Stage: String, CaseIterable {
        case hostContainer, storagePreparation, bookmarkCreation, extensionDiscovery, extensionLaunch
        case xpcConnection, serviceReadiness, command, authentication, provisioning, signing, filePreparation, installation, persistence, refreshVerification
        case replyEncoding
        case endpointSelection, heartbeat, coreDevice, cdTunnel, rsdDiscovery, rsdService, lockdownConnection, uniqueDeviceID, pairing
        case network, source, catalog
    }
    public enum Code: String, CaseIterable {
        case unavailable, invalidConfiguration, permissionDenied, timedOut, cancelled, interrupted
        case notReady, busy, invalidResponse, unsupported, failed, missingResult, staleResult
        case invalidToken, missingFile, emptyFile, invalidPackage, fileAccess, stagingFailed
    }
    public let operation: String
    public let stage: Stage
    public let code: Code
    public let correlationID: String
    public let underlyingDomain: String
    public let underlyingCode: Int
    public let safeCause: SafeCause?
    public let sourceStep: SourceStep?
    public let signingContext: [String: String]
    public let retryable: Bool?
    // V3_CATALOG_OPERATION_CONTEXT_V1: host-only request context. It records
    // which request was waiting when a failure occurred before the service
    // received it, so a catalog read keeps its operation context even when the
    // failure is a connection problem. It is appended to the copied technical
    // line only and is never part of the wire envelope.
    public var requestContext: String?
    // Host-only extension startup details. This is intentionally omitted from
    // the service wire envelope and appended only to copied technical details.
    public let launchContext: LaunchContext?
    public init(operation: String, stage: Stage, code: Code = .failed, id: String,
                underlying: Error? = nil, retryable: Bool? = nil, safeCause: SafeCause? = nil,
                sourceStep: SourceStep? = nil, signingContext: [String: String] = [:],
                launchContext: LaunchContext? = nil) {
        let normalized = ["snapshot": "status", "refreshApp": "refresh", "refreshAdmissionBegin": "refresh", "refreshAdmissionEnd": "refresh", "installURL": "install", "installSharedIPA": "install",
                          "addSource": "source", "removeSource": "source", "refreshSources": "source", "syncAppIDs": "signIn",
                          "authBegin": "signIn", "authPoll": "signIn", "authRespond": "signIn", "authCancel": "signIn",
                          "authRetryProvisioning": "signIn", "authReconcileStorage": "signIn",
                          "opStart": "command", "opPoll": "command", "opAnswer": "command", "opCancel": "command",
                          "recoveryDiscardUnreadable": "recovery",
                          "sourcePreview": "source", "sourceAddConfirmed": "source", "sourceRemoveConfirmed": "source"][operation] ?? operation
        self.operation = Self.operations.contains(normalized) ? normalized : "command"
        self.stage = stage; self.code = code
        correlationID = UUID(uuidString: id) != nil ? id : UUID().uuidString
        let error = underlying as NSError?
        let safeUnderlying = Self.safeWireUnderlying(domain: error?.domain ?? "none", code: error?.code ?? 0)
        underlyingDomain = safeUnderlying.domain
        underlyingCode = safeUnderlying.code
        let inferredSourceAddBusy = operation == "sourceAddConfirmed" && code == .busy
            ? SafeCause.sourceAddBusy : nil
        self.safeCause = safeCause ?? inferredSourceAddBusy
        self.sourceStep = sourceStep
        self.signingContext = Self.validatedSigningContext(signingContext) ?? [:]
        self.retryable = retryable ?? self.safeCause?.inferredRetryable
        let launchStages: Set<Stage> = [.extensionDiscovery, .extensionLaunch, .xpcConnection, .serviceReadiness]
        self.launchContext = normalized == "connect" && launchStages.contains(stage) ? launchContext : nil
    }
    private static let operations: Set<String> = ["connect", "status", "command", "recovery", "refresh", "install", "update", "signIn", "signOut", "catalog", "source", "sign", "activate", "deactivate", "delete", "remove", "backup", "restore", "jit", "pairingImportData", "anisetteList", "anisetteReset", "anisetteSync"]
    private static let domains: Set<String> = ["none", "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "NSURLErrorDomain", "NSOSStatusErrorDomain", "ALTServerErrorDomain", "ALTAppleAPIErrorDomain", "ALTErrorDomain", "MinimuxerError", "DeviceGatewayError", "IdeviceGatewayError", "InstallationProxyErrorDomain", "com.apple.installd", "com.apple.mobile.installation_proxy", "V3IPAFileErrorDomain", "Foundation", "CoreData", "CoreFoundation", "IOKit", "Security", "CFNetwork", "kCFErrorDomainCFNetwork", "HTTPStatus", "io.sidestore.SideStore.DecodingError", "io.sidestore.LiveContainer.ExtensionLaunch", "com.SideStore.Keychain", "LiveContainerRefresh.Configuration", "SideSign.ServerError", "SideSign.DeveloperPortalError"]
    private static let verificationDomains: Set<String> = ["ALTServerErrorDomain", "ALTErrorDomain", "IdeviceGatewayError", "DeviceGatewayError", "InstallationProxyErrorDomain", "com.apple.installd", "com.apple.mobile.installation_proxy"]

    /// Only observations from the request/operation context are allowed here.
    /// Never accept provider messages, tokens, account names or device IDs.
    public static let signingCapabilityNames: Set<String> = [
        "APG3427HIY", "IAD53UNK2F", "gameCenter", "inAppPurchase", "push",
        "associatedDomains", "dataProtection", "siri", "applePay", "vpn", "networkExtensions",
        "multipath", "hotspot", "nfc", "classKit", "autoFillCredentialProvider",
        "accessWiFiInformation", "wirelessAccessoryConfiguration", "increasedMemoryLimit",
        "extendedVirtualAddressing", "increasedDebuggingMemoryLimit"
    ]
    public static func validatedSigningContext(_ value: [String: String]) -> [String: String]? {
        var fields = value
        if !V3TemporaryAnisetteTrace.temporaryAnisetteTraceEnabled {
            fields.removeValue(forKey: V3TemporaryAnisetteTrace.contextKey)
        }
        guard fields.count <= 20 else { return nil }
        for (key, text) in fields {
            if key == V3TemporaryAnisetteTrace.contextKey {
                guard V3TemporaryAnisetteTrace(encoded: text) != nil else { return nil }
                continue
            }
            guard text.utf8.count <= 512 else { return nil }
            switch key {
            case "team_sha256", "requested_bundle_sha256", "requested_app_group_sha256", "capabilities_sha256", "signing_certificate_serial_sha256":
                guard text.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
            case "provisioning_bundle_sha256":
                guard text.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
            case "session_generation", "capability_count", "app_group_count", "extension_count":
                guard !text.isEmpty, text.utf8.count <= 20,
                      text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), UInt64(text) != nil else { return nil }
            case "capability_names", "enabled_capability_names":
                let names = text.isEmpty ? [] : text.components(separatedBy: ",")
                guard names.count <= 32, Set(names).isSubset(of: signingCapabilityNames),
                      Set(names).count == names.count else { return nil }
            case "server_code":
                guard text == "unknown" || (text.utf8.count <= 20 && Int(text).map({ String($0) }) == text) else { return nil }
            case "native_code", "native_subcode", "probe_native_code", "probe_native_subcode":
                guard text == "unknown" || Int32(text).map({ String($0) }) == text else { return nil }
            case "anisette_blob_state":
                guard V3AnisetteAttemptContext.BlobState(rawValue: text) != nil else { return nil }
            case "anisette_recovery":
                guard V3AnisetteAttemptContext.Recovery(rawValue: text) != nil else { return nil }
            case "native_phase", "probe_native_phase":
                guard V3AnisetteNativeEvidence.Phase(rawValue: text) != nil else { return nil }
            case "http_status":
                guard text == "unavailable" || Int(text).map({ (100...599).contains($0) && String($0) == text }) == true else { return nil }
            case "provider_code":
                guard ["unavailable", "ENTITY_ERROR", "ENTITY_ERROR.INVALID", "ENTITY_ERROR.ATTRIBUTE.INVALID",
                    "ENTITY_ERROR.ATTRIBUTE.REQUIRED", "ENTITY_ERROR.ATTRIBUTE.UNKNOWN",
                    "ENTITY_ERROR.RELATIONSHIP.INVALID", "ENTITY_ERROR.RELATIONSHIP.INVALID_NOT_ALLOWED",
                    "ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE", "FORBIDDEN_ERROR", "NOT_FOUND",
                    "PARAMETER_ERROR.INVALID", "PARAMETER_ERROR.REQUIRED", "RATE_LIMIT_EXCEEDED",
                    "SERVICE_UNAVAILABLE", "UNEXPECTED_ERROR", "UNKNOWN_ERROR"].contains(text) else { return nil }
            case "account_binding", "team_binding":
                guard text == "verified" else { return nil }
            case "signing_certificate_present":
                guard text == "true" || text == "false" else { return nil }
            case "preferred_parent_id_match":
                guard text == "true" || text == "false" else { return nil }
            case "provisioning_bundle_role":
                guard text == "main" || text == "extension" else { return nil }
            case "profile_mode":
                guard text == "team" || text == "manual" else { return nil }
            case "device_registration":
                guard text == "unobserved" else { return nil }
            case "typed_error":
                guard ["sideSignServerReportedError", "sideSignBadResponse", "sideSignInvalidResponse", "sideSignMissingKey", "sideSignDeveloperPortalError", "keychainWrite", "keychainValidationFailed", "keychainOutcomeUnknown", "legacyMigrationConflict", "persistenceFailure", "persistenceOutcomeUnknown", "transportFailure", "anisetteFailure", "anisetteKitInvalidArgument", "anisetteKitLoaderFailed", "anisetteKitSymbolMissing", "anisetteKitReadFailure", "anisetteKitInvalidResponse", "anisetteKitADIError", "anisetteKitLibrariesNotFound", "anisetteKitHTTPError", "decodingTypeMismatch", "decodingValueNotFound", "decodingKeyNotFound", "decodingDataCorrupted", "archiveFileNotFound", "archiveCorrupt", "archiveReadFailed", "archiveWriteFailed", "archiveMissingApp", "unknownAccountFailure", "anisetteIdentityStateInvalid"].contains(text) else { return nil }
            default: return nil
            }
        }
        return fields
    }

    /// Copyable diagnostics may include a native code only when its domain is
    /// in the same fixed allowlist used by structured failures. Arbitrary NSError
    /// domains can contain endpoint or user supplied text, so both fields are
    /// suppressed together when provenance is not recognized.
    public static func safeDiagnosticUnderlying(domain: String, code: Int) -> (domain: String, code: String) {
        guard (Self.domains.contains(domain) && domain != "none") || (domain == "none" && code == 0) else {
            return ("redacted", "unknown")
        }
        return (domain, String(code))
    }

    /// Safe technical fields for the provisioning retry prompt. Preserve the
    /// area/correlation context, but never interpolate an untrusted NSError.
    public static func provisioningRetryTechnicalDetails(for error: Error,
                                                         correlationID: String) -> String {
        if let accountError = error as? V3AccountOperationError {
            let failure = accountError.failure(operation: "signIn", id: correlationID)
            return "area=provisioning " + failure.technicalDetails
        }
        let native = error as NSError
        let underlying = safeDiagnosticUnderlying(domain: native.domain, code: native.code)
        let safeID = UUID(uuidString: correlationID)?.uuidString ?? UUID().uuidString
        return "diagnostic_code=SS-PROV-C11 builder_commit=\(V3DiagnosticBuild.commit) domain=\(underlying.domain) code=\(underlying.code) area=provisioning correlation=\(safeID)"
    }

    /// The serialized wire keeps an integer field for compatibility. `none/0`
    /// means no underlying error; `redacted/0` means native details were hidden.
    /// The reserved `none` domain never authorizes a nonzero native code.
    fileprivate static func safeWireUnderlying(domain: String, code: Int) -> (domain: String, code: Int) {
        // `none` is reserved for absence of an underlying error; it does not
        // establish provenance for a caller-supplied numeric code.
        guard (Self.domains.contains(domain) && domain != "none") || (domain == "none" && code == 0) else {
            return ("redacted", 0)
        }
        return (domain, code)
    }

    private var timeoutAction: String {
        switch operation {
        case "connect": return "connect to SideStore"
        case "status": return "load status"
        case "refresh": return "refresh apps"
        case "install": return "install the app"
        case "update": return "update the app"
        case "delete": return "delete the app"
        case "signIn": return "sign in"
        case "signOut": return "sign out"
        case "source": return "load the source"
        case "catalog": return "load the catalog"
        default: return "complete the request"
        }
    }
    private var timeoutContext: String {
        switch stage {
        case .hostContainer, .storagePreparation, .bookmarkCreation:
            return "using the shared app container"
        case .extensionDiscovery, .extensionLaunch:
            return "starting the LiveProcess extension"
        case .xpcConnection:
            return "connecting to the SideStore service"
        case .serviceReadiness:
            return "waiting for SideStore to finish starting"
        case .authentication:
            return "checking the Apple account"
        case .provisioning:
            return "preparing provisioning data"
        case .signing:
            return "signing the app"
        case .filePreparation:
            return "preparing the selected IPA"
        case .installation:
            return "installing the app"
        case .persistence:
            return "saving the operation result"
        case .refreshVerification:
            return "verifying the refresh result"
        case .replyEncoding:
            return "preparing the service response"
        case .endpointSelection, .heartbeat, .coreDevice, .cdTunnel, .rsdDiscovery,
             .rsdService, .lockdownConnection, .uniqueDeviceID:
            return "connecting to the device"
        case .pairing:
            return "checking the pairing data"
        case .network:
            return "checking the network connection"
        case .source:
            return "loading the source"
        case .catalog:
            return "loading the source catalog"
        case .command:
            return "waiting for SideStore to finish the request"
        }
    }
    public var message: String {
        if signingContext["typed_error"] == "anisetteIdentityStateInvalid" { return LCAnisettePairError.safeMessage }
        if operation == "delete", code == .timedOut {
            return "SideStore could not confirm that the deleted app disappeared from its installed library."
        }
        // V3_CATALOG_FAILURE_VOCABULARY_V1: a catalog read must never surface as
        // the generic command-stage message. It can fail at a stage that is not
        // the catalog stage, so the operation selects this wording first.
        //
        // V3_RESPONSE_CLASSIFICATION_CARRIER_V1: the two reply-level causes are
        // the exception. They describe the reply itself rather than the catalog,
        // and the catalog vocabulary covered both of them with one sentence, so
        // a reply that could not be encoded and a reply that was too large read
        // identically to a user. The specific cause outranks it.
        if operation == "catalog", safeCause != .responseEncodingFailed,
           safeCause != .responseTooLarge, let catalog = catalogFailureMessage { return catalog }
        if code == .cancelled { return "The \(operation) request was cancelled. Its result may need reconciliation." }
        if code == .timedOut { return "SideStore could not \(timeoutAction) in time while \(timeoutContext)." }
        if let safeCause {            switch safeCause {
            case .networkConnectionLost: return "The network connection was lost during \(operation)."
            case .networkTimedOut: return "The network request timed out during \(operation)."
            case .networkUnavailable: return "A network connection was unavailable during \(operation)."
            case .anisetteServerUnavailable: return "The configured Anisette server is temporarily unavailable."
            case .anisetteServerRejected: return "The configured Anisette server returned an unsuccessful response."
            case .anisetteRequestTimedOut: return "The configured Anisette server timed out while synchronizing."
            case .anisetteRateLimited: return "The configured Anisette server is temporarily rate-limiting synchronization requests."
            case .anisetteInvalidResponse: return "The configured Anisette server returned data SideStore could not read."
            case .anisetteUnknownFailure: return "Anisette server synchronization failed for an unknown reason."
            case .signingNetworkConnectionLost: return "The connection to the provisioning service was interrupted during signing."
            case .signingNetworkTimedOut: return "The provisioning service did not respond during signing."
            case .signingNetworkUnavailable: return "The signing flow could not reach the provisioning service."
            case .developerPortalRejectedRequest:
                return "Apple's developer service reported an error \(sourceStep?.portalUserLabel ?? "while preparing the app's provisioning data")."
            case .appIDLimitReached: return "App ID limit reached. Apple could not register another App ID for the selected team."
            case .developerPortalInvalidResponse: return "The provisioning service returned an invalid response during signing."
            case .provisioningProfileUnavailable: return "A required provisioning profile is not available for this app."
            case .certificateUnavailable: return "The selected signing certificate is not available."
            case .signingStorageUnverified: return "SideStore cannot change Apple certificates while saved signing state is unverified."
            case .wifiUnavailable: return "Wi-Fi was unavailable before refresh started."
            case .localDevVPNUnavailable: return "LocalDevVPN was unavailable before refresh started."
            case .unknownSigningCause: return "SideStore could not sign the selected app. The exact underlying cause could not be safely identified."
            case .sourceNetworkFailure: return "The source could not be downloaded because its network request failed."
            case .sourceInvalidManifest: return "The source returned data SideStore could not read as a valid source."
            case .sourcePersistenceUnverified: return "SideStore could not confirm that the source was saved."
            case .sourceInvalidURL: return "The source URL is invalid."
            case .sourceBlocked: return "SideStore blocked this source for security reasons."
            case .sourceChangedID: return "SideStore stopped updating this source because its identifier changed."
            case .sourceDuplicate: return "A source with the same identifier is already saved."
            case .sourceUnsupported: return "This source format is not supported by this version of SideStore."
            case .sourceValidationFailed: return "SideStore rejected metadata in this source."
            case .sourceRemoveFailed: return "SideStore could not confirm that the source was removed from its saved list."
            case .sourceRemoveBusy: return "SideStore was busy with another request, so it did not start removing this source."
            case .sourceAddBusy: return "SideStore was busy with another request, so it did not confirm adding this source."
            case .operationInProgress: return "Another SideStore operation is still active."
            case .responseCapacityUnavailable: return "SideStore cannot safely accept another state-changing request yet."
            case .sharedStoreUnavailable: return "LiveContainer could not open the shared store that its refresh state and the embedded SideStore service both use."
    // V3_SECRET_HANDOFF_FAILURE_TYPED_V1: say plainly that the response never
    // left the device, so an Apple password is never implicated.
    case .secretHandoffUnavailable: return "Your response could not be delivered to the embedded service through the secure channel, so it was never sent to Apple. This is not an authentication failure."
            case .staleRefreshAttempt: return "This refresh request belonged to an expired scheduler run and was not started."
            case .knownSourcePolicyNetworkFailure: return "SideStore could not update its own known-source safety list."
            case .knownSourcePolicyInvalidResponse: return "SideStore could not read its own known-source safety list."
            case .catalogUnavailable: return "SideStore could not read this source's saved catalog data."
            case .catalogSourceUnavailable: return "This source is no longer in the SideStore source list."
            case .responseEncodingFailed: return "SideStore could not encode the response for this request."
            case .responseTooLarge: return "SideStore produced a response that is too large to transfer."
            case .pairingRequired: return "A pairing file is required before this device can be refreshed."
            case .invalidPairingFile: return "SideStore could not read or validate the pairing file."
            case .pairingFilePreparationFailed: return "LiveContainer could not read or prepare the selected pairing file."
            case .authAttemptNotDispatched: return "SideStore did not start this sign-in attempt, so Apple authentication was not submitted."
            case .authProvisioningRetryNotDispatched: return "SideStore did not start the provisioning retry; the saved authentication session was not changed by this request."
            case .authSessionUnavailable: return "SideStore no longer has the active sign-in session."
            case .authResponseCapacityUnavailable: return "SideStore could not start sign-in because it cannot safely reserve a response slot yet."
            case .credentialCommitFailed:
                return "Apple authentication succeeded, but the sign-in credentials could not be saved on this device."
            case .credentialCommitOutcomeUnknown:
                return "Apple authentication succeeded, but the local credential save could not be confirmed."
            case .accountActivationFailed:
                return "Authentication succeeded, but SideStore could not confirm that account and team activation was saved."
            case .provisioningStorageFailed:
                return "Authentication succeeded, but provisioning could not save the account or certificate on this device."
            case .keychainSignOutFailed: return "SideStore could not confirm removal of the saved Apple sign-in data. Sign Out stopped, and any partial changes were rolled back."
            case .keychainSignOutOutcomeUnknown: return "SideStore could not confirm the Sign Out outcome. Reload Account & Signing to reconcile which Apple account is active before continuing."
            case .operationPersistenceFailed: return "The device operation may have completed, but SideStore could not confirm that its updated app state was saved."
            case .recoveryMalformedRecord: return "SideStore found a malformed recovery record. Changes remain paused."
            case .recoveryIncompatibleRecord: return "SideStore found a recovery record from an incompatible schema. Changes remain paused."
            case .recoveryStorageUnavailable: return "SideStore cannot access its shared recovery storage. It has not identified a corrupt record."
            case .recoveryLockUnavailable: return "SideStore could not acquire its recovery storage lock."
            case .recoveryReadFailure: return "SideStore could not read the recovery file. Its contents have not been classified."
            case .recoveryDeleteFailure: return "SideStore could not delete and confirm removal of the recovery record."
            }
        }
        switch stage {
        case .hostContainer: return "SideStore could not start because the authoritative host container is unavailable."
        case .storagePreparation: return "SideStore could not start because its existing data storage could not be prepared."
        case .bookmarkCreation: return "SideStore could not start because its data bookmark could not be created."
        case .extensionDiscovery: return "The embedded LiveProcess extension is missing or unavailable."
        case .extensionLaunch: return "The embedded SideStore process could not be launched."
        case .xpcConnection: return "The connection to the embedded SideStore service was interrupted or unavailable."
        case .serviceReadiness: return "The SideStore process has not finished preparing its service."
        case .endpointSelection: return "No usable device transport endpoint was selected."
        case .heartbeat: return "The device transport heartbeat is inactive."
        case .coreDevice: return "Could not connect to the device through CoreDevice."
        case .cdTunnel: return "The CoreDevice tunnel could not be established."
        case .rsdDiscovery: return "Device service discovery through RSD failed."
        case .rsdService: return "The requested RSD device service could not be connected."
        case .lockdownConnection: return "The device transport opened, but the lockdownd connection failed."
        case .uniqueDeviceID: return "The device connection opened, but the UniqueDeviceID request failed."
        case .pairing: return "Pairing parsing, validation, or a concrete device trust check failed."
        case .source:
            switch sourceStep {
            case .sourceDownload: return "The source could not be downloaded."
            case .manifestParsing: return "The source returned data SideStore could not read as a valid source."
            case .sourceValidation: return "SideStore rejected the source during validation."
            case .catalogRead: return "SideStore could not confirm that the source was saved or read from its catalog."
            default: return "SideStore could not complete the source request."
            }
        case .catalog:
            // The wording is supplied by catalogFailureMessage, which keys on the
            // operation rather than on this stage.
            return "SideStore could not load this source's catalog."
        case .authentication: return "SideStore could not complete account authentication."
        case .provisioning: return "Apple sign-in succeeded, but device provisioning did not complete."
        case .signing:
            switch sourceStep {
            case .provisioningProfileFetch:
                return "SideStore could not prepare provisioning data for signing. The exact failed request could not be safely identified."
            case .certificateValidation:
                return "SideStore could not validate the signing certificate. The exact underlying cause could not be safely identified."
            case .localCodeSigning:
                return "SideStore could not sign the app locally. The exact underlying cause could not be safely identified."
            default: break
            }
            return underlyingDomain == "redacted" && underlyingCode != 0
                ? "SideStore could not sign the application. The exact underlying cause could not be safely identified."
                : "SideStore could not sign the application."
        case .filePreparation:
            switch code {
            case .invalidToken: return "The staged IPA reference is invalid. Select the file again."
            case .missingFile: return "The staged IPA is no longer available. Select it again."
            case .emptyFile: return "The selected IPA is empty and could not be installed."
            case .invalidPackage: return "The selected file is not a valid IPA app package."
            case .fileAccess: return "The selected IPA could not be read. Check file access and select it again."
            default: return "The selected IPA could not be prepared for installation. Select it again."
            }
        case .installation:
            // Apple-side application verification rejections carry fixed installd
            // codes. These describe profile/identity rejection, never an account
            // ban, and they do not imply a pairing or LocalDevVPN problem.
            if hasApplicationVerificationEvidence && underlyingCode == 0xE8008024 {
                return "iOS reports that the provisioning profile is banned during application verification. Recreating pairing or changing LocalDevVPN settings is unlikely to address this specific error."
            }
            if hasApplicationVerificationEvidence && underlyingCode == 0xE8008018 {
                return "iOS reports that the identity used to sign the executable is no longer valid. The app must be re-signed with a current signing identity."
            }
            return "SideStore could not complete the application installation."
        case .persistence:
            return "SideStore could not confirm that the operation result was saved. The device may already have changed."
        case .refreshVerification: return "Refresh completion could not be verified from the installation results."
        case .network: return "Network error during the \(operation) operation."
        case .replyEncoding: return "SideStore could not encode its service response."
        case .command:
            if underlyingDomain == "redacted" && underlyingCode != 0 {
                return "SideStore could not start or complete the requested \(operation) action. The exact underlying cause could not be safely identified."
            }
            return "SideStore could not start or complete the requested \(operation) action."
        }
    }
    // V3_CATALOG_FAILURE_VOCABULARY_V1: the exact sentence for each boundary a
    // catalog read can fail at, selected by the real stage and code rather than
    // by a generic fallback. The source manifest is never blamed here, because
    // nothing on this path proves the manifest failed to parse.
    private var catalogFailureMessage: String? {
        if safeCause == .catalogSourceUnavailable {
            return "This source is no longer in the SideStore source list."
        }
        if code == .unavailable || code == .notReady || stage == .serviceReadiness {
            return "The SideStore service is not ready to load this source yet."
        }
        if stage == .xpcConnection && code == .interrupted {
            return "The connection to the SideStore service was interrupted while loading the source."
        }
        if code == .busy {
            return "SideStore is still finishing another operation. Wait a moment, then reload the source."
        }
        if code == .invalidResponse {
            return "SideStore returned an unreadable response while loading the source catalog."
        }
        if code == .timedOut {
            return "The SideStore service did not answer while loading this source catalog."
        }
        if stage == .catalog { return "SideStore could not read this source's saved catalog." }
        return nil
    }

    private var catalogFailureRecovery: String? {
        if safeCause == .catalogSourceUnavailable {
            return "Return to Sources and reload the source list, then open the source again if it is still present."
        }
        if code == .unavailable || code == .notReady || stage == .serviceReadiness {
            return "Wait for SideStore to finish starting, then reload the source."
        }
        if code == .busy {
            return "Wait for the current SideStore operation to finish, then reload the source."
        }
        if stage == .xpcConnection || code == .timedOut {
            return "Wait for the SideStore service to become available, then reload the source."
        }
        return "Reload the source catalog. If it continues, copy the safe diagnostics."
    }

    public var recovery: String {
        if signingContext["typed_error"] == "anisetteIdentityStateInvalid" { return LCAnisettePairError.recovery }
        // V3_RESPONSE_CLASSIFICATION_CARRIER_V1: the two reply-level causes
        // outrank the catalog recovery for the same reason they outrank its
        // message. Repeating an unencodable request, or the same oversized one,
        // fails identically, so the catalog advice to reload would send the user
        // in a circle.
        if operation == "catalog", safeCause != .responseEncodingFailed,
           safeCause != .responseTooLarge, let catalog = catalogFailureRecovery { return catalog }
        if let safeCause {
            switch safeCause {
            case .networkConnectionLost, .networkTimedOut, .networkUnavailable:
                return "Check the network used by this request, then retry when the connection is stable. If a device operation still fails, run Connection Check."
            case .anisetteServerUnavailable:
                return "Try syncing again later or choose another configured Anisette server."
            case .anisetteServerRejected:
                return "Check the configured Anisette server address, then sync again after correcting it."
            case .anisetteRequestTimedOut:
                return "Retry once. If the configured Anisette server times out again, choose another server."
            case .anisetteRateLimited:
                return "Wait before retrying once. If the server is still rate-limiting requests, choose another configured Anisette server."
            case .anisetteInvalidResponse:
                return "Choose another configured Anisette server or report that its response could not be read."
            case .anisetteUnknownFailure:
                return "The exact Anisette synchronization cause could not be safely identified. Check the configured server and copy Diagnostics."
            case .signingNetworkConnectionLost, .signingNetworkTimedOut, .signingNetworkUnavailable:
                return "Your current connection may still be healthy. Retry once. If this happens again, open Connection Settings."
            case .developerPortalRejectedRequest, .developerPortalInvalidResponse:
                return "Copy Diagnostics, including the failed request step and server code. The correct recovery action is not yet known."
            case .appIDLimitReached:
                return "Apps with extensions may need multiple App IDs. Check App IDs for the selected team and retry when capacity is available. Repeating the install immediately or changing certificates will not free an App ID slot."
            case .provisioningProfileUnavailable:
                return "The requested provisioning profile was unavailable. Keep the diagnostics before trying the install again."
            case .certificateUnavailable:
                return "Open Certificates and inspect the selected signing certificate before retrying."
            case .wifiUnavailable:
                return "Restore Wi-Fi, then start a new refresh."
            case .localDevVPNUnavailable:
                return "Restore LocalDevVPN, then start a new refresh."
            case .unknownSigningCause:
                return "The exact underlying cause was not safely identified. Copy Diagnostics before trying this action again."
            case .sourceNetworkFailure:
                return "Check the network connection and retry the source request."
            case .sourceInvalidManifest:
                return "Check the source provider's manifest format, then preview it again."
            case .sourceBlocked:
                return "Do not add this source. Verify with the provider that it is safe before trying again."
            case .sourceChangedID:
                return "Contact the source provider before removing the saved source or adding it again."
            case .sourceDuplicate:
                return "Return to Sources and use the existing source. Remove it only after confirming which entry is correct."
            case .sourceUnsupported:
                return "Update SideStore or use a source format supported by this version."
            case .sourceValidationFailed:
                return "Ask the source provider to correct its metadata, then preview it again."
            case .sourcePersistenceUnverified:
                return "Return to Sources and reload the list. Confirm whether the source is present before submitting another add; copy Diagnostics if its status remains unclear."
            case .sourceInvalidURL:
                return "Enter a valid HTTP or HTTPS source URL, then preview it again."
            case .sourceRemoveFailed:
                return "Reload Sources and confirm whether the source is gone. If it remains, remove it again."
            case .sourceRemoveBusy:
                return "Wait for the current SideStore request to finish, reload Sources, then confirm removal again."
            case .sourceAddBusy:
                return "Wait for the current SideStore request to finish, reload Sources, then preview and confirm the add again."
            case .operationInProgress:
                return "Wait for the active SideStore request to finish, check the action's current state, then retry that action if needed."
            case .responseCapacityUnavailable:
                return "Wait for SideStore to release earlier request results, check the current state, then retry this action."
            case .sharedStoreUnavailable:
                return "Relaunch LiveContainer after reinstalling or re-signing it. Nothing was written to a private store, and the next launch can retry this run."
            // V3_SECRET_HANDOFF_FAILURE_TYPED_V1: the recovery is a re-sign that
            // grants every part of the app the same secure group, not another
            // attempt with the same password.
            case .secretHandoffUnavailable:
                return "Your response never left this device, so no Apple password was sent. Re-sign or reinstall LiveContainer so its embedded service shares the app's secure storage group, then submit the response again."
            case .staleRefreshAttempt:
                return "Return to Refresh and start a new refresh. This stale request did not reach SideStore or the device."
            case .knownSourcePolicyNetworkFailure:
                return "Check the network, then retry from Sources. This error came from SideStore's known-source safety list, not the URL you entered."
            case .knownSourcePolicyInvalidResponse:
                return "Try again later. If SideStore keeps receiving unreadable safety-list data, copy Diagnostics and report it."
            case .catalogUnavailable:
                return "Reload the catalog. If it continues, copy the safe diagnostics."
            case .catalogSourceUnavailable:
                return "Return to Sources and reload the source list, then open the source again."
            case .responseEncodingFailed:
                return "The same request cannot fix this reply-encoding failure. Copy Diagnostics and report that the service could not encode its response."
            case .responseTooLarge:
                return "The service reply exceeded the transfer limit. Copy Diagnostics and report this response-size issue; repeating the same request will fail again."
            case .pairingRequired:
                return "Add the pairing file, then retry the refresh."
            case .invalidPairingFile:
                return "Open Pairing File and replace the saved pairing file with a valid one, then retry."
            case .pairingFilePreparationFailed:
                return "Choose the pairing file again and make sure it is accessible to LiveContainer."
            case .authAttemptNotDispatched:
                if code == .busy {
                    return "Wait for the active SideStore operation to finish, then start sign-in again."
                }
                if stage == .serviceReadiness {
                    return "Wait for SideStore to finish starting, then start sign-in again."
                }
                return "Resolve the displayed prerequisite, then start sign-in again."
            case .authProvisioningRetryNotDispatched:
                if code == .busy {
                    return "Wait for the active SideStore operation to finish, then retry provisioning."
                }
                if stage == .serviceReadiness {
                    return "Wait for SideStore to finish starting, then retry provisioning."
                }
                return "Retry provisioning when the displayed prerequisite is ready."
            case .authSessionUnavailable:
                return "Open Account & Signing and start a new sign-in. SideStore will reconcile the current account before proceeding."
            case .authResponseCapacityUnavailable:
                return "Wait for SideStore to release earlier request results, reload account status, then try again. No Apple credentials were submitted."
            case .signingStorageUnverified:
                return "Open Account & Signing and choose Check Saved Signing State. Creating or revoking Apple certificates stays blocked until local storage is verified."
            case .credentialCommitFailed, .credentialCommitOutcomeUnknown:
                return "Reload Account & Signing to reconcile local storage before starting another sign-in. Keep existing account data and copy Diagnostics if this continues."
            case .accountActivationFailed, .provisioningStorageFailed:
                return "Reload Account & Signing before continuing. Keep the authenticated account and certificate; do not repeat Apple resource creation to repair local storage."
            case .keychainSignOutFailed:
                return "Unlock the iPhone and try Sign Out again. If it still fails, copy Diagnostics."
            case .keychainSignOutOutcomeUnknown:
                return "Reload Account & Signing to reconcile which Apple account is active before continuing. Do not assume Sign Out completed."
            case .operationPersistenceFailed:
                return "Reload installed app status and verify the device before starting another mutation. Do not repeat this operation until its state is known."
            case .recoveryMalformedRecord, .recoveryIncompatibleRecord:
                return "Confirm no SideStore operation remains active on the device before clearing this saved record."
            case .recoveryStorageUnavailable:
                return "Keep changes paused. Check that the combined app can access its shared App Group; copy Diagnostics for support. Clearing a record cannot repair unavailable storage."
            case .recoveryLockUnavailable:
                return "Keep changes paused and allow the active SideStore process to finish. Copy Diagnostics if the lock stays unavailable."
            case .recoveryReadFailure:
                return "Keep changes paused. Check device storage access and copy Diagnostics; do not clear an unclassified record."
            case .recoveryDeleteFailure:
                return "Keep changes paused and copy Diagnostics. The record was not confirmed removed."
            }
        }
        switch stage {
        case .command where operation == "delete" && code == .timedOut:
            return "Reload the installed app list and verify the deletion before trying another delete."
        case .hostContainer:
            return "Reopen LiveContainer and check that it can access its shared App Group container. Keep existing data intact and copy diagnostics if the host container is still unavailable."
        case .storagePreparation:
            return "Check available storage and access to LiveContainer's shared App Group container. Keep existing data intact and copy diagnostics if preparation still fails."
        case .bookmarkCreation:
            return "LiveContainer could not create access to its internal shared SideStore folder. Check that the App Group container is available; copy diagnostics if the folder still cannot be accessed."
        case .extensionDiscovery:
            return "The combined app could not find its embedded LiveProcess extension. Confirm that the installed app is the combined LiveContainer + SideStore package; do not reset SideStore or guest data. Copy diagnostics if it continues."
        case .serviceReadiness:
            return "Wait for SideStore to finish starting, then retry the request."
        case .authentication, .provisioning, .signing: return "Review Account and Signing, then explicitly retry. Never share credentials or private keys."
        case .source:
            if operation == "sourceAddConfirmed" {
                return "Return to Sources and reload the source list. Check whether it was added before retrying; copy Diagnostics if its status is still unclear."
            }
            return "Return to Sources and review the source result. Copy Diagnostics before retrying if its status is unclear."
        case .catalog:
            // The wording is supplied by catalogFailureRecovery, which keys on
            // the operation rather than on this stage.
            return "Reload the source catalog. If it continues, copy the safe diagnostics."
        case .replyEncoding:
            return "Copy Diagnostics and report the service reply-encoding failure. Repeating the same request will not fix it."
        case .filePreparation: return "Choose the IPA again. SideStore will copy it into private shared staging before starting installation."
        case .installation, .persistence, .refreshVerification: return "Reload authoritative app status and expiration before taking another action. Completion may be uncertain."
        case .endpointSelection, .heartbeat, .coreDevice, .cdTunnel, .rsdDiscovery, .rsdService, .lockdownConnection, .uniqueDeviceID, .network:
            return "Check LocalDevVPN and the device connection, then retry explicitly. This failure alone does not prove invalid pairing."
        default: return "Reload the current status to check the result. If the cause remains unclear, copy Diagnostics before deciding whether to try again."
        }
    }
    public var safeMessage: String { messageWithoutDiagnosticCode + "\n" + diagnosticLabel }
    private var messageWithoutDiagnosticCode: String {
        if operation == "refresh", safeCause == nil {
            return "Refresh failed during \(stage.rawValue), but no safe underlying cause was available."
        }
        if underlyingDomain == "redacted", underlyingCode != 0, safeCause == nil {
            return message + " The exact underlying cause could not be safely identified."
        }
        return message
    }
    public var technicalDetails: String {
        let displayedUnderlyingCode = underlyingDomain == "redacted" ? "unknown" : String(underlyingCode)
        let signingDetails = signingContext.filter { $0.key != V3TemporaryAnisetteTrace.contextKey }.sorted(by: { $0.key < $1.key }).map { " \($0.key)=\($0.value)" }.joined()
        return "schema=1 diagnostic_code=\(diagnosticCode) builder_commit=\(V3DiagnosticBuild.commit) operation=\(operation) stage=\(stage.rawValue) code=\(code.rawValue) correlation=\(correlationID) underlying_domain=\(underlyingDomain) underlying_code=\(displayedUnderlyingCode) retryable=\(retryable.map(String.init) ?? "unknown") source_step=\(sourceStep?.rawValue ?? "unknown") safe_cause=\(safeCause?.rawValue ?? "unknown")" + signingDetails + installVerdict + requestContextSuffix + (launchContext?.technicalDetails ?? "") + (temporaryAnisetteTrace?.technicalDetails ?? "")
    }
    public var temporaryAnisetteTrace: V3TemporaryAnisetteTrace? {
        signingContext[V3TemporaryAnisetteTrace.contextKey].flatMap(V3TemporaryAnisetteTrace.init(encoded:))
    }
    // Request context is appended only when it was observed.
    private var requestContextSuffix: String {
        guard let requestContext, !requestContext.isEmpty else { return "" }
        return " " + requestContext
    }
    public mutating func annotatingRequest(requestedOperation: String, requestID: String) {
        requestContext = "request_operation=\(requestedOperation) request_correlation=\(requestID)"
    }
    // V3_CATALOG_DIAGNOSTICS_V1: host-only catalog page context. Only the page
    // offset and the returned row count are recorded; never the source
    // identifier, app names, bundle identifiers, or response content.
    public mutating func annotatingCatalogPage(cursor: Int) {
        requestContext = "source_step=catalogRead page_cursor=\(cursor)"
    }
    // Bounded machine classification for Apple-side application verification
    // rejections (InstallationProxy/installd). Only the two fixed installd
    // codes produce a token; every other failure keeps the existing
    // diagnostics byte-identical. Never an account-ban claim.
    private var installVerdict: String {
        guard hasApplicationVerificationEvidence else { return "" }
        if underlyingCode == 0xE8008024 { return " installVerdict=profileBanned" }
        if underlyingCode == 0xE8008018 { return " installVerdict=signingIdentityRejected" }
        return ""
    }
    private var hasApplicationVerificationEvidence: Bool {
        ["install", "update"].contains(operation) && stage == .installation && Self.verificationDomains.contains(underlyingDomain)
    }
    public var errorDescription: String? { safeMessage + "\n" + recovery + "\n" + technicalDetails }
    /// Bind this semantic failure to the request/reply transaction carrying it.
    /// Session IDs and request IDs are distinct: an auth poll can discover a
    /// missing session while answering a different, current XPC request.
    public func correlating(to id: String) -> CombinedFailure {
        CombinedFailure(operation: operation, stage: stage, code: code, id: id,
            underlying: NSError(domain: underlyingDomain, code: underlyingCode),
            retryable: retryable, safeCause: safeCause, sourceStep: sourceStep, signingContext: signingContext,
            launchContext: launchContext)
    }
    public var wire: [String: Any] {
        let safeUnderlying = Self.safeWireUnderlying(domain: underlyingDomain, code: underlyingCode)
        var result: [String: Any] = ["version": 1, "operation": operation, "stage": stage.rawValue, "code": code.rawValue,
            "correlationID": correlationID, "underlyingDomain": safeUnderlying.domain,
            "underlyingCode": safeUnderlying.code]
        if let safeCause { result["safeCause"] = safeCause.rawValue }
        if let sourceStep { result["sourceStep"] = sourceStep.rawValue }
        if !signingContext.isEmpty { result["signingContext"] = signingContext }
        if let retryable { result["retryable"] = retryable }
        return result
    }
    public var encodedString: String {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: wire, format: .binary, options: 0), data.count <= 4096 else { return "LCFAILURE1:invalid" }
        return "LCFAILURE1:" + data.base64EncodedString()
    }
    public static func fromEncodedString(_ text: String, expectedID: String) -> CombinedFailure? {
        guard text.hasPrefix("LCFAILURE1:"), text.utf8.count <= 6000,
              let data = Data(base64Encoded: String(text.dropFirst(11))), data.count <= 4096,
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return decode(value, expectedID: expectedID)
    }
    public static func decode(_ value: [String: Any], expectedID: String) -> CombinedFailure? {
        guard Set(value.keys).isSubset(of: ["version", "operation", "stage", "code", "correlationID", "underlyingDomain", "underlyingCode", "retryable", "safeCause", "sourceStep", "signingContext"]),
              Self.strictInteger(value["version"]) == 1,
              Self.uuidCorrelationMatches(value["correlationID"] as? String, expectedID: expectedID),
              let operation = value["operation"] as? String, operations.contains(operation),
              let stageName = value["stage"] as? String, let stage = Stage(rawValue: stageName),
              let codeName = value["code"] as? String, let code = Code(rawValue: codeName),
              let domain = value["underlyingDomain"] as? String, domains.contains(domain) || domain == "redacted",
              let number = Self.strictInteger(value["underlyingCode"]) else { return nil }
        let safeCause: SafeCause?
        if let rawCause = value["safeCause"] {
            guard let causeName = rawCause as? String, let cause = SafeCause(rawValue: causeName) else { return nil }
            safeCause = cause
        } else { safeCause = nil }
        let sourceStep: SourceStep?
        if let rawStep = value["sourceStep"] {
            guard let stepName = rawStep as? String, let step = SourceStep(rawValue: stepName) else { return nil }
            sourceStep = step
        } else { sourceStep = nil }
        let signingContext: [String: String]
        if let raw = value["signingContext"] {
            guard let fields = raw as? [String: String],
                  let validated = Self.validatedSigningContext(fields) else { return nil }
            signingContext = validated
        } else { signingContext = [:] }
        if let retry = value["retryable"] {
            guard let bool = retry as? NSNumber, CFGetTypeID(bool) == CFBooleanGetTypeID() else { return nil }
        }
        return CombinedFailure(operation: operation, stage: stage, code: code, id: expectedID,
            underlying: NSError(domain: domain, code: number), retryable: value["retryable"] as? Bool,
            safeCause: safeCause, sourceStep: sourceStep, signingContext: signingContext)
    }

    private static func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let type = String(cString: number.objCType)
        guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) else {
            return nil
        }
        if ["C", "S", "I", "L", "Q"].contains(type) {
            return Int(exactly: number.uint64Value)
        }
        return Int(exactly: number.int64Value)
    }

    public static func preserving(_ error: Error?, operation: String, stage: Stage, code: Code = .failed, id: String, retryable: Bool? = nil,
                                  launchContext: LaunchContext? = nil) -> CombinedFailure {
        if let known = error as? CombinedFailure {
            guard let launchContext else { return known }
            let retainedContext = launchContext.retainingErrorChain(from: known.launchContext)
            return CombinedFailure(operation: known.operation, stage: known.stage, code: known.code,
                id: known.correlationID, underlying: NSError(domain: known.underlyingDomain, code: known.underlyingCode),
                retryable: known.retryable, safeCause: known.safeCause, sourceStep: known.sourceStep,
                signingContext: known.signingContext, launchContext: retainedContext)
        }
        if let launchContext {
            return CombinedFailure(operation: operation, stage: stage, code: code, id: id,
                underlying: error, retryable: retryable, launchContext: launchContext)
        }
        return CombinedFailure(operation: operation, stage: stage, code: code, id: id, underlying: error, retryable: retryable)
    }
    private static func networkSafeCauseForURLCode(_ code: Int, signing: Bool) -> SafeCause? {
        switch code {
        case NSURLErrorNetworkConnectionLost:
            return signing ? .signingNetworkConnectionLost : .networkConnectionLost
        case NSURLErrorTimedOut:
            return signing ? .signingNetworkTimedOut : .networkTimedOut
        case NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return signing ? .signingNetworkUnavailable : .networkUnavailable
        default:
            return nil
        }
    }

    /// Returns network evidence only for URL transport errors SideStore knows
    /// how to explain. URL-loading domains also carry local file I/O failures,
    /// so domain membership alone is not a network classification.
    public static func knownURLTransportCause(domain: String, code: Int,
                                               signing: Bool = false) -> SafeCause? {
        guard domain == NSURLErrorDomain || domain == "kCFErrorDomainCFNetwork" else { return nil }
        return networkSafeCauseForURLCode(code, signing: signing)
    }

    /// URL cancellation is terminal lifecycle evidence, not network failure.
    public static func isURLCancellation(domain: String, code: Int) -> Bool {
        (domain == NSURLErrorDomain || domain == "kCFErrorDomainCFNetwork") &&
            code == NSURLErrorCancelled
    }

    /// Correlation IDs are UUIDs. Compare their parsed identity so equivalent
    /// uppercase and lowercase UUID spellings stay bound to the same request.
    public static func uuidCorrelationMatches(_ receivedID: String?, expectedID: String) -> Bool {
        guard let receivedID,
              let received = UUID(uuidString: receivedID),
              let expected = UUID(uuidString: expectedID) else { return false }
        return received == expected
    }

    public static func capture(_ error: Error, operation: String, stage: Stage, id: String,
                               retryable: Bool? = nil) -> CombinedFailure {
        if let known = error as? CombinedFailure { return known }
        if let attempt = error as? V3AnisetteAttemptError {
            let known = capture(attempt.underlying, operation: operation, stage: stage,
                                id: id, retryable: retryable)
            var context = known.signingContext
            context.merge(attempt.context.diagnosticFields) { _, observed in observed }
            return CombinedFailure(operation: known.operation, stage: known.stage, code: known.code,
                id: id, underlying: NSError(domain: known.underlyingDomain, code: known.underlyingCode),
                retryable: known.retryable, safeCause: known.safeCause, sourceStep: known.sourceStep,
                signingContext: context, launchContext: known.launchContext)
        }
        if error is LCAnisettePairError {
            return V3AccountOperationError(step: .anisetteFetch, kind: .anisetteIdentityStateInvalid,
                underlying: error, serverCode: nil).failure(operation: operation, id: id)
        }
        // Generic non-auth consumers still see the original native evidence;
        // headless auth captures finite typed/phase detail before arriving here.
        if let phase = error as? V3AuthenticationPhaseError {
            return capture(phase.underlying, operation: operation, stage: stage,
                           id: id, retryable: retryable)
        }
        // Typed account boundaries bypass all provider-description parsing.
        if let accountError = error as? V3AccountOperationError {
            return accountError.failure(operation: operation, id: id)
        }
        if let refreshError = error as? CombinedRefreshVerificationError {
            let code: Code = refreshError == .missingResult ? .missingResult : .staleResult
            return CombinedFailure(operation: operation, stage: .refreshVerification, code: code, id: id, retryable: retryable)
        }
        if let fileFailure = error as? CombinedIPAFileError {
            return CombinedFailure(operation: operation, stage: .filePreparation,
                                  code: fileFailure.combinedCode, id: id, underlying: fileFailure, retryable: retryable)
        }
        var cause = error as NSError
        var resolved = stage
        var resolvedCode: Code = error is CancellationError ? .cancelled : .failed
        var resolvedRetryable: Bool? = error is CancellationError ? false : retryable
        var nativeCode: Int?
        var nativeDomain: String?
        var safeCause: SafeCause?
        var sourceStep: SourceStep?
        var signingContext: [String: String] = [:]
        var ppqLocked = false
        var explicitStageMarker = false
        // Only an allowlisted stage is inspected locally. No arbitrary userInfo is serialized.
        for _ in 0..<5 {
            let fingerprint = cause.localizedDescription.lowercased()
            let tokens = cause.localizedDescription.split(whereSeparator: { $0.isWhitespace })
            if let name = cause.userInfo["LCStructuredFailureStageV1"] as? String,
               let found = Stage(rawValue: name) {
                resolved = found
                explicitStageMarker = true
            } else if signingContext["typed_error"]?.hasPrefix("sideSign") != true,
                      let token = tokens.first(where: { $0.hasPrefix("lc_stage=") }),
                      let found = Stage(rawValue: String(token.dropFirst(9))) {
                resolved = found
                explicitStageMarker = true
            }
            if let name = cause.userInfo["LCStructuredFailureCauseV1"] as? String,
               let found = SafeCause(rawValue: name) {
                safeCause = found
            }
            if isURLCancellation(domain: cause.domain, code: cause.code) {
                resolvedCode = .cancelled
                resolvedRetryable = false
            }
            if let name = cause.userInfo["LCStructuredFailureSourceV1"] as? String,
               let found = SourceStep(rawValue: name) {
                sourceStep = found
            }
            if let fields = cause.userInfo["LCStructuredSigningContextV1"] as? [String: String],
               let safeFields = Self.validatedSigningContext(fields) {
                signingContext.merge(safeFields) { _, deeper in deeper }
            }
            // Domain-specific classification. Only map a numeric code to a
            // stage when the (domain, code) pair has an established meaning.
            // Otherwise preserve the caller stage and keep the underlying
            // domain/code for diagnostics. Unknown stays unknown.
            // Explicit stage markers from SideStore's pipeline take precedence
            // over a broader gateway domain.
            if !ppqLocked && !explicitStageMarker {
                switch cause.domain {
                case "com.SideStore.Authentication":
                    resolved = .authentication
                case NSURLErrorDomain, "kCFErrorDomainCFNetwork":
                    // Only transport-specific URL errors establish network
                    // failure. URLSession also uses this domain for local
                    // download-file and cancellation errors.
                    if let urlCause = knownURLTransportCause(
                        domain: cause.domain, code: cause.code, signing: resolved == .signing) {
                        if resolved != .signing { resolved = .network }
                        if safeCause == nil { safeCause = urlCause }
                    }
                case "MinimuxerError", "DeviceGatewayError", "IdeviceGatewayError":
                    resolved = .command
                default:
                    break
                }
            }
            // Apple-side installation rejection (InstallationProxy/installd
            // application verification). The hex installer codes are matched
            // case-insensitively alongside the verification marker; the stage
            // is installation and the numeric code is preserved with the
            // cause's own allowlisted domain (never a fabricated one).
            // 0xE8008024: provisioning profile banned. 0xE8008018: signing
            // identity no longer valid. Neither implies pairing, network,
            // CoreDevice, or account-ban conditions.
            let installContext = ["install", "installURL", "installSharedIPA", "update"].contains(operation)
                && (stage == .installation || stage == .command)
            let explicitContextAllowsVerification = !explicitStageMarker || resolved == .command || resolved == .installation
            let typedVerificationSource = verificationDomains.contains(cause.domain)
            let profileRejectionEvidence = fingerprint.contains("e8008024")
                && fingerprint.contains("applicationverificationfailed")
                && fingerprint.contains("provisioning profile")
                && (fingerprint.contains("banned") || fingerprint.contains("revoked")
                    || fingerprint.contains("invalid") || fingerprint.contains("failed to verify"))
            let signingIdentityEvidence = fingerprint.contains("e8008018")
                && fingerprint.contains("applicationverificationfailed")
                && fingerprint.contains("identity used to sign")
                && (fingerprint.contains("no longer valid") || fingerprint.contains("invalid")
                    || fingerprint.contains("expired") || fingerprint.contains("revoked"))
            if installContext && explicitContextAllowsVerification && typedVerificationSource {
                if profileRejectionEvidence {
                    resolved = .installation
                    nativeCode = 0xE8008024
                    if nativeDomain == nil, domains.contains(cause.domain) { nativeDomain = cause.domain }
                    ppqLocked = true
                } else if signingIdentityEvidence {
                    resolved = .installation
                    nativeCode = 0xE8008018
                    if nativeDomain == nil, domains.contains(cause.domain) { nativeDomain = cause.domain }
                    ppqLocked = true
                }
            }
            // Upstream gateway/Minimuxer typed errors carry a reason string. Inspect only
            // our fixed machine tokens locally; never forward the reason itself.
            // A preserved numeric code keeps the domain it was actually observed
            // in: gateway tokens stay in their gateway domain, HTTP statuses use
            // the fixed HTTPStatus domain, and POSIX errnos stay in
            // NSPOSIXErrorDomain. No unrelated code is ever relabelled as a
            // gateway error.
            for (index, token) in tokens.enumerated() {
                guard !ppqLocked else { continue }
                // A provider body is not evidence of an HTTP status or errno.
                // Typed SideSign code evidence was captured before NSError bridging.
                if signingContext["typed_error"]?.hasPrefix("sideSign") == true { continue }
                if token.hasPrefix("lc_native_code="), let code = Int(token.dropFirst(15)) {
                    nativeCode = code
                    if ["MinimuxerError", "DeviceGatewayError", "IdeviceGatewayError"].contains(cause.domain) {
                        nativeDomain = cause.domain
                    }
                }
                // HTTP status in "HTTP 503" form (tokens are whitespace-split).
                if (token == "HTTP" || token == "http"), index + 1 < tokens.count,
                   let code = Int(tokens[index + 1]) {
                    nativeCode = code
                    nativeDomain = "HTTPStatus"
                }
                // POSIX errno in "errno=20" / "errno:20" form.
                if token.hasPrefix("errno=") || token.hasPrefix("errno:") {
                    if let code = Int(token.dropFirst(6)) {
                        nativeCode = code
                        nativeDomain = "NSPOSIXErrorDomain"
                    }
                }
            }
            if let next = cause.userInfo[NSUnderlyingErrorKey] as? NSError { cause = next } else { break }
        }
        let underlying: NSError
        if let code = nativeCode {
            if let domain = nativeDomain {
                underlying = NSError(domain: domain, code: code)
            } else if domains.contains(cause.domain) {
                underlying = NSError(domain: cause.domain, code: code)
            } else {
                underlying = NSError(domain: "redacted", code: code)
            }
        } else {
            underlying = cause
        }
        if safeCause == nil && (resolved == .signing || resolved == .network) {
            safeCause = knownURLTransportCause(
                domain: cause.domain, code: cause.code, signing: resolved == .signing)
        }
        return CombinedFailure(operation: operation, stage: resolved,
            code: resolvedCode, id: id,
            underlying: underlying, retryable: resolvedRetryable, safeCause: safeCause,
            sourceStep: sourceStep, signingContext: signingContext)
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

// DEBUG TEMPORARY: remove this finite, per-attempt diagnostic with the investigation.
// One release-visible switch also controls the native patcher. No TaskLocal/global
// mutable state and no raw provider text, paths, identifiers, blobs or headers.
public struct V3TemporaryAnisetteTrace: Equatable, Sendable {
    public static let temporaryAnisetteTraceEnabled = true
    public static let contextKey = "debug_temporary_anisette_trace"
    public static let maximumEvents = 64
    public static let maximumBytes = 2048
    public enum Step: String, CaseIterable, Sendable {
        case keychainRead, pairValidation, blobPresence, requestHeaders, primaryProvider
        case currentProbe, currentProof, currentSnapshot, legacyRead, legacyCandidate
        case legacyProbe, legacyProof, identityCommit, freshBlobCommit
    }
    public enum Outcome: String, CaseIterable, Sendable { case started, succeeded, failed, skipped }
    public enum Scope: String, CaseIterable, Sendable { case primary, current, legacy }
    private enum NativeEvent: String, CaseIterable, Sendable {
        case argumentsOk = "arguments.ok"
        case argumentsFailed = "arguments.failed"
        case rootOk = "root.ok"
        case rootFailed = "root.failed"
        case uuidDirCreated = "uuid_dir.created"
        case uuidDirExists = "uuid_dir.exists"
        case uuidDirFailed = "uuid_dir.failed"
        case fileOpenOk = "file.open.ok"
        case fileOpenFailed = "file.open.failed"
        case fileStreamOk = "file.stream.ok"
        case fileStreamFailed = "file.stream.failed"
        case fileWriteOk = "file.write.ok"
        case fileWriteFailed = "file.write.failed"
        case fileFlushOk = "file.flush.ok"
        case fileFlushFailed = "file.flush.failed"
        case fileFlushNotChecked = "file.flush.not_checked"
        case fileCloseOk = "file.close.ok"
        case fileCloseFailed = "file.close.failed"
        case fileReadOpenOk = "file.read_open.ok"
        case fileReadOpenFailed = "file.read_open.failed"
        case fileReadbackOk = "file.readback.ok"
        case fileReadbackFailed = "file.readback.failed"
        case fileReadbackNotChecked = "file.readback.not_checked"
        case fileReadCloseOk = "file.read_close.ok"
        case fileReadCloseFailed = "file.read_close.failed"
        case fileRenameOk = "file.rename.ok"
        case fileRenameFailed = "file.rename.failed"
        case vmInitOk = "vm.init.ok"
        case vmInitFailed = "vm.init.failed"
        case vmReused = "vm.reused"
        case setupBegin = "setup.begin"
        case setupOk = "setup.ok"
        case setupFailed = "setup.failed"
        case libraryLoadOk = "library.load.ok"
        case libraryLoadFailed = "library.load.failed"
        case libraryCached = "library.cached"
        case libraryInitOk = "library.init.ok"
        case libraryInitFailed = "library.init.failed"
        case provisioningPathOk = "provisioning_path.ok"
        case provisioningPathFailed = "provisioning_path.failed"
        case provisioningPathCached = "provisioning_path.cached"
        case androidIdOk = "android_id.ok"
        case androidIdFailed = "android_id.failed"
        case androidIdCached = "android_id.cached"
        case nativeSymbolOk = "native.symbol.ok"
        case nativeSymbolFailed = "native.symbol.failed"
        case nativeOtpOk = "native.otp.ok"
        case nativeOtpFailed = "native.otp.failed"
        case nativeOutputOk = "native.output.ok"
        case nativeOutputFailed = "native.output.failed"
        case nativeOutputNotChecked = "native.output.not_checked"
        case cleanupOk = "cleanup.ok"
        case cleanupFailed = "cleanup.failed"
        case cleanupNotNeeded = "cleanup.not_needed"
        case cleanupNotRequested = "cleanup.not_requested"
        case responseAllocationFailed = "response.allocation.failed"
        case traceTruncated = "trace.truncated"
    }
    private enum Event: Equatable, Sendable {
        case step(Step, Outcome)
        case native(Scope, NativeEvent)
        case truncated

        var token: String {
            switch self {
            case .step(let step, let outcome): return "swift.\(step.rawValue).\(outcome.rawValue)"
            case .native(let scope, let event): return "native.\(scope.rawValue).\(event.rawValue)"
            case .truncated: return "trace.truncated"
            }
        }
        init?(token: String) {
            if token == "trace.truncated" { self = .truncated; return }
            let parts = token.components(separatedBy: ".")
            if parts.count == 3, parts[0] == "swift",
               let step = Step(rawValue: parts[1]), let outcome = Outcome(rawValue: parts[2]) {
                self = .step(step, outcome); return
            }
            if parts.count >= 3, parts[0] == "native", let scope = Scope(rawValue: parts[1]),
               let event = NativeEvent(rawValue: parts.dropFirst(2).joined(separator: ".")) {
                self = .native(scope, event); return
            }
            return nil
        }
    }
    private var events: [Event] = []
    public init() {}

    public mutating func record(step: Step, outcome: Outcome) {
        append(.step(step, outcome))
    }
    public mutating func appendNative(errorDescription: String, scope: Scope) {
        guard Self.temporaryAnisetteTraceEnabled,
              let suffix = Self.nativeSuffix(errorDescription) else { return }
        for event in suffix.events { append(.native(scope, event)) }
    }
    private mutating func append(_ event: Event) {
        guard Self.temporaryAnisetteTraceEnabled else { return }
        events.append(event)
        if events.count > Self.maximumEvents || Self.encode(events).utf8.count > Self.maximumBytes {
            if events.first != .truncated { events.insert(.truncated, at: 0) }
            // Drop the oldest observation, keeping the final failure and a
            // finite marker that makes the missing prefix explicit.
            while events.count > Self.maximumEvents || Self.encode(events).utf8.count > Self.maximumBytes {
                events.remove(at: 1)
            }
        }
    }
    private static func encode(_ events: [Event]) -> String {
        "v1;" + events.map(\.token).joined(separator: ";")
    }
    public var snapshot: String? {
        guard Self.temporaryAnisetteTraceEnabled, !events.isEmpty else { return nil }
        return Self.encode(events)
    }
    public init?(encoded: String) {
        guard Self.temporaryAnisetteTraceEnabled, encoded.utf8.count <= Self.maximumBytes,
              encoded.hasPrefix("v1;") else { return nil }
        let tokens = encoded.dropFirst(3).components(separatedBy: ";")
        guard !tokens.isEmpty, tokens.count <= Self.maximumEvents else { return nil }
        var decoded: [Event] = []
        for (index, token) in tokens.enumerated() {
            guard let event = Event(token: token),
                  event != .truncated || index == 0 else { return nil }
            decoded.append(event)
        }
        events = decoded
    }

    // Native suffixes are accepted only in their entirety. Arbitrary leading
    // prose is never retained by the trace or passed to diagnostics.
    private static func nativeSuffix(_ description: String) -> (base: String, events: [NativeEvent])? {
        let marker = " [DEBUG_TEMPORARY_NATIVE_TRACE:"
        guard description.utf8.count <= 4096, description.hasSuffix("]"),
              let range = description.range(of: marker),
              description[range.upperBound...].range(of: marker) == nil else { return nil }
        let body = description[range.upperBound...].dropLast()
        guard !body.isEmpty, body.utf8.count <= 1024 else { return nil }
        let tokens = body.components(separatedBy: ",")
        guard tokens.count <= 32 else { return nil }
        var decoded: [NativeEvent] = []
        for (index, token) in tokens.enumerated() {
            guard let event = NativeEvent(rawValue: token),
                  event != .traceTruncated || index == tokens.count - 1 else { return nil }
            decoded.append(event)
        }
        return (String(description[..<range.lowerBound]), decoded)
    }
    static func nativeDescriptionWithoutTrace(_ description: String) -> String {
        // Stripping valid metadata preserves the pre-existing native phase/code
        // classifier even if a trace-enabled service meets a disabled host.
        nativeSuffix(description)?.base ?? description
    }
    public var technicalDetails: String {
        guard let snapshot else { return "" }
        return "\nDEBUG TEMPORARY anisette_trace=\(snapshot)"
    }
    public var failedStep: String? {
        guard Self.temporaryAnisetteTraceEnabled else { return nil }
        for event in events.reversed() {
            switch event {
            case .step(let step, .failed):
                let scope: Scope?
                switch step {
                case .primaryProvider: scope = .primary
                case .currentProbe: scope = .current
                case .legacyProbe: scope = .legacy
                default: scope = nil
                }
                if let scope, let native = nativeFailedStep(scope: scope) { return native }
                return step.rawValue
            case .native(let scope, let native) where native.rawValue.hasSuffix(".failed"):
                return nativeFailedStep(scope: scope)
            default: continue
            }
        }
        return nil
    }
    private func nativeFailedStep(scope: Scope) -> String? {
        // Setup wrappers and cleanup can also fail after the causal native
        // step. Keep the first failure from this invocation visible; the full
        // ordered trace still includes every subsequent failure.
        for event in events {
            if case .native(let observedScope, let native) = event,
               observedScope == scope, native.rawValue.hasSuffix(".failed") {
                return "\(scope.rawValue).\(native.rawValue.dropLast(7))"
            }
        }
        return nil
    }

}

// Recovery evidence is finite and contains no identity, blob or provider text.
struct V3AnisetteAttemptContext {
    enum BlobState: String { case existing, fresh, unknown }
    enum Recovery: String {
        case notAttempted, noLegacyCandidate, legacyReadFailed, ambiguousLegacyIdentity
        case invalidLegacyPair, legacyBlobMismatch, probeRejected, invalidNativeProof
        case restoreFailed, stateChanged, temporaryStorageUnavailable, currentProbeRejected
        case automaticRecoveryDisabled
    }
    let blobState: BlobState
    let recovery: Recovery
    var probeEvidence: V3AnisetteNativeEvidence? = nil
    var trace: V3TemporaryAnisetteTrace? = nil
    var diagnosticFields: [String: String] {
        var fields = ["anisette_blob_state": blobState.rawValue, "anisette_recovery": recovery.rawValue]
        if let snapshot = trace?.snapshot { fields[V3TemporaryAnisetteTrace.contextKey] = snapshot }
        if let probeEvidence {
            fields["probe_native_code"] = String(probeEvidence.code)
            fields["probe_native_phase"] = probeEvidence.phase.rawValue
            fields["probe_native_subcode"] = probeEvidence.subcode.map(String.init) ?? "unknown"
        }
        return fields
    }
}
struct V3AnisetteAttemptError: Error {
    let underlying: Error
    let context: V3AnisetteAttemptContext
}

// V3_ANISETTE_NATIVE_EVIDENCE_V1: the associated ADI Int32 is not an Apple
// server result or Swift's NSError enum discriminator. Only exact producers in
// AnisetteKit 1f5a7e36553cc865b873f222b87a6486c0bcc7bf Native/anisette_core_{mac,uc}.cpp
// identify a native phase. Descriptions (including paths) never leave here.
struct V3AnisetteNativeEvidence {
    enum Phase: String {
        case unknown, nativeOTP, provisionStart, provisionEnd
        case setupLibraries, setupLoadLibrary, setupProvisioningPath, setupAndroidID
        case readProvisioningData, nativeStorage
    }
    let code: Int32
    let phase: Phase
    let subcode: Int32?

    static func capture(code: Int32, description: String) -> Self {
        let unknown = Self(code: code, phase: .unknown, subcode: nil)
        // Bound inspection before matching. Never scan arbitrary messages for
        // keywords, URLs, digits or error-like substrings.
        let description = V3TemporaryAnisetteTrace.nativeDescriptionWithoutTrace(description)
        guard description.utf8.count <= 256 else { return unknown }
        // Exact fixed producers in the reviewed native staging patch. Numeric
        // equality alone never assigns a storage phase to arbitrary errors.
        if code == -6 && (description == "Checked OTP staging failed" || description == "Isolated OTP staging failed") {
            return Self(code: code, phase: .nativeStorage, subcode: nil)
        }
        let storagePrefix = "Checked OTP staging failed (errno "
        if code == -6 {
            let value = String(description.dropFirst(storagePrefix.count).dropLast())
            if let observedErrno = Int32(value), observedErrno > 0, observedErrno <= 4095,
               description == "\(storagePrefix)\(observedErrno))" {
                // For nativeStorage only, subcode is the failed POSIX call's
                // immediately captured errno, not an ADI or Apple server code.
                return Self(code: code, phase: .nativeStorage, subcode: observedErrno)
            }
        }
        for (symbol, phase) in [("ADIOTPRequest", Phase.nativeOTP),
                                ("ADIProvisioningStart", .provisionStart),
                                ("ADIProvisioningEnd", .provisionEnd)] {
            if (code == -3 && description == "Symbol \(symbol) missing") ||
               (code != 0 && description == failureDescription(symbol, code: code)) {
                return Self(code: code, phase: phase, subcode: nil)
            }
        }
        if code == -4 && description == "Failed to read generated adi.pb" {
            return Self(code: code, phase: .readProvisioningData, subcode: nil)
        }
        // All setup failures return wrapper -2, even when a setup ADI call
        // reports another number. Keep that nested scalar separate as well.
        guard code == -2 else { return unknown }
        let setupSymbols: [(String, String, Phase)] = [
            ("ADILoadLibraryWithPath", "ADILoadLibraryWithPath (kq56gsgHG6)", .setupLoadLibrary),
            ("ADISetProvisioningPath", "ADISetProvisioningPath", .setupProvisioningPath),
            ("ADISetAndroidID", "ADISetAndroidID", .setupAndroidID)
        ]
        if let tail = description.components(separatedBy: ": ").last,
           let subcode = Int32(tail), subcode != 0, String(subcode) == tail {
            for (ucSymbol, macSymbol, phase) in setupSymbols {
                if description == "\(ucSymbol) failed: \(subcode)" ||
                   description == failureDescription(macSymbol, code: subcode) {
                    return Self(code: code, phase: phase, subcode: subcode)
                }
            }
        }
        let fixedSetup: [String: Phase] = [
            "Library directory path is null.": .setupLibraries,
            "Failed to load libraries into VM": .setupLibraries,
            "Required ADI setup symbol missing in VM": .setupLoadLibrary,
            "Symbol ADILoadLibraryWithPath (kq56gsgHG6) missing from libraries": .setupLoadLibrary,
            "Symbol ADISetProvisioningPath missing in VM": .setupProvisioningPath,
            "Symbol ADISetProvisioningPath (nf92ngaK92) missing": .setupProvisioningPath,
            "Symbol ADISetAndroidID missing in VM": .setupAndroidID,
            "Symbol ADISetAndroidID (Sph98paBcz) missing": .setupAndroidID
        ]
        return Self(code: code, phase: fixedSetup[description] ?? .unknown, subcode: nil)
    }

    private static func failureDescription(_ symbol: String, code: Int32) -> String {
        // Exact finite labels from Native/anisette_base.cpp at the same pin.
        // Matching the label against its code rejects even plausible-looking
        // injected descriptions. Unknown numeric results remain observable.
        let labels: [Int32: String] = [
            -1: "Invalid argument passed", -2: "ELF Loader failed to map dependencies",
            -3: "Required ADI symbol missing", -4: "Failed to read generated file",
            -5: "Failed to parse response JSON",
            -45001: "Invalid ADI parameters (-45001)", -45002: "Invalid ADI decipher params (-45002)",
            -45003: "Invalid ADI trust key (-45003)", -45006: "PTM and TK mismatch (-45006)",
            -45018: "Invalid input header (-45018)", -45019: "Unknown ADI function (-45019)",
            -45020: "Invalid input body (-45020)", -45025: "Unknown ADI session (-45025)",
            -45026: "Empty ADI session (-45026)", -45031: "Invalid data header (-45031)",
            -45032: "Data too short (-45032)", -45033: "Invalid data body (-45033)",
            -45034: "Unknown call flags (-45034)", -45036: "ADI time error (-45036)",
            -45046: "Empty hardware IDs (-45046)", -45054: "ADI filesystem error (-45054)",
            -45061: "Device not provisioned (-45061)", -45062: "Cannot erase unprovisioned device (-45062)",
            -45063: "Pending ADI session (-45063)", -45066: "ADI session already done (-45066)",
            -45075: "Library loading failed (-45075)"
        ]
        return "\(symbol) failed (\(labels[code] ?? "Unknown ADI error")): \(code)"
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

public struct CombinedIPAFileError: Error, LocalizedError, CustomNSError {
    public enum Problem: String, Equatable {
        case invalidToken, missingFile, emptyFile, invalidPackage, fileAccess, stagingFailed
    }
    public let problem: Problem
    public static let errorDomain = "V3IPAFileErrorDomain"
    public var errorCode: Int {
        switch problem {
        case .invalidToken: return 1
        case .missingFile: return 2
        case .emptyFile: return 3
        case .invalidPackage: return 4
        case .fileAccess: return 5
        case .stagingFailed: return 6
        }
    }
    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? "IPA file preparation failed."] }
    public init(_ problem: Problem) { self.problem = problem }
    public var combinedCode: CombinedFailure.Code {
        switch problem {
        case .invalidToken: return .invalidToken
        case .missingFile: return .missingFile
        case .emptyFile: return .emptyFile
        case .invalidPackage: return .invalidPackage
        case .fileAccess: return .fileAccess
        case .stagingFailed: return .stagingFailed
        }
    }
    public var errorDescription: String? {
        switch problem {
        case .invalidToken: return "The staged IPA reference is invalid."
        case .missingFile: return "The staged IPA is no longer available."
        case .emptyFile: return "The selected IPA is empty."
        case .invalidPackage: return "The selected file is not a valid IPA app package."
        case .fileAccess: return "The selected IPA could not be read."
        case .stagingFailed: return "The selected IPA could not be staged."
        }
    }
}

private func v3StrictPlistInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        return nil
    }
    let type = String(cString: number.objCType)
    guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) else {
        return nil
    }
    if ["C", "S", "I", "L", "Q"].contains(type) {
        return Int(exactly: number.uint64Value)
    }
    return Int(exactly: number.int64Value)
}

enum V3NotDispatchedReplyPolicy {
    static func confirms(_ data: Data, requestID: String, maximumBytes: Int) -> Bool {
        guard maximumBytes > 0, !data.isEmpty, data.count <= maximumBytes,
              let reply = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              v3StrictPlistInteger(reply["version"]) == 1,
              CombinedFailure.uuidCorrelationMatches(reply["id"] as? String, expectedID: requestID),
              reply["error"] as? String != nil,
              reply["result"] == nil,
              reply["ok"] == nil,
              let notDispatched = reply["operationNotDispatched"] as? NSNumber,
              CFGetTypeID(notDispatched) == CFBooleanGetTypeID(), notDispatched.boolValue,
              let failure = reply["failure"] as? [String: Any],
              CombinedFailure.decode(failure, expectedID: requestID) != nil else { return false }
        return true
    }
}

enum V3AnisetteSyncFailurePolicy {
    /// Converts only evidence exposed by the pinned Anisette sync path into a
    /// semantic failure. URL transport errors and AnisetteServersManager's
    /// explicit HTTP/invalid-response errors are distinct; every other error
    /// remains unknown rather than being called a network failure.
    static func failure(_ error: Error, id: String) -> CombinedFailure {
        if error is CancellationError {
            return CombinedFailure(operation: "anisetteSync", stage: .command,
                code: .cancelled, id: id, retryable: false)
        }
        let native = error as NSError
        if native.domain == NSURLErrorDomain && native.code == NSURLErrorCancelled {
            return CombinedFailure(operation: "anisetteSync", stage: .command,
                code: .cancelled, id: id, underlying: native, retryable: false)
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                return CombinedFailure(operation: "anisetteSync", stage: .command,
                    code: .cancelled, id: id, underlying: native, retryable: false)
            }
            if let cause = networkCause(urlError.code) {
                return CombinedFailure(operation: "anisetteSync", stage: .network,
                    code: .failed, id: id, underlying: error, retryable: true, safeCause: cause)
            }
        }
        if native.domain == NSURLErrorDomain,
           let cause = networkCause(URLError.Code(rawValue: native.code)) {
            return CombinedFailure(operation: "anisetteSync", stage: .network,
                code: .failed, id: id, underlying: native, retryable: true, safeCause: cause)
        }
        if native.domain == "AnisetteServersManager" {
            if native.code == -1 {
                return CombinedFailure(operation: "anisetteSync", stage: .command,
                    code: .invalidResponse, id: id, underlying: native,
                    safeCause: .anisetteInvalidResponse)
            }
            if native.code == 408 {
                return CombinedFailure(operation: "anisetteSync", stage: .command,
                    code: .failed, id: id, underlying: native, retryable: true,
                    safeCause: .anisetteRequestTimedOut)
            }
            if native.code == 429 {
                return CombinedFailure(operation: "anisetteSync", stage: .command,
                    code: .busy, id: id, underlying: native, retryable: true,
                    safeCause: .anisetteRateLimited)
            }
            if (500..<600).contains(native.code) {
                return CombinedFailure(operation: "anisetteSync", stage: .command,
                    code: .failed, id: id, underlying: native, retryable: true,
                    safeCause: .anisetteServerUnavailable)
            }
            if (100..<500).contains(native.code), !(200..<300).contains(native.code) {
                return CombinedFailure(operation: "anisetteSync", stage: .command,
                    code: .failed, id: id, underlying: native,
                    safeCause: .anisetteServerRejected)
            }
        }
        return CombinedFailure(operation: "anisetteSync", stage: .command,
            code: .failed, id: id, underlying: error, safeCause: .anisetteUnknownFailure)
    }

    private static func networkCause(_ code: URLError.Code) -> CombinedFailure.SafeCause? {
        switch code {
        case .networkConnectionLost: return .networkConnectionLost
        case .timedOut: return .networkTimedOut
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return .networkUnavailable
        default: return nil
        }
    }
}


// V3_STABLE_DIAGNOSTIC_CODE_V1: identifiers classify finite evidence, never attempts.
// Values are append-only. See docs/ERROR_CODES_V1.json; never renumber existing cases.
extension CombinedFailure {
    public var diagnosticCode: String {
        var parts = ["SS", stage.diagnosticToken, code.diagnosticToken]
        if let sourceStep { parts.append(sourceStep.diagnosticToken) }
        if let safeCause { parts.append(safeCause.diagnosticToken) }
        if let typed = signingContext["typed_error"], let token = Self.typedDiagnosticToken(typed) { parts.append(token) }
        if let launchContext { parts.append(launchContext.sourceStep.diagnosticToken) }
        if hasApplicationVerificationEvidence && underlyingCode == 0xE8008024 { parts.append("V01") }
        if hasApplicationVerificationEvidence && underlyingCode == 0xE8008018 { parts.append("V02") }
        if sourceStep == .fetchTeams && signingContext["typed_error"] == "sideSignServerReportedError" && signingContext["server_code"] == "1100" { parts.append("P01") }
        return parts.joined(separator: "-")
    }
    public var diagnosticLabel: String { "Error ID: \(diagnosticCode)" }
    fileprivate static func typedDiagnosticToken(_ value: String) -> String? {
        switch value {
        case "sideSignServerReportedError": return "T01"
        case "sideSignBadResponse": return "T02"
        case "sideSignInvalidResponse": return "T03"
        case "sideSignMissingKey": return "T04"
        case "sideSignDeveloperPortalError": return "T05"
        case "keychainWrite": return "T06"
        case "keychainValidationFailed": return "T07"
        case "keychainOutcomeUnknown": return "T08"
        case "legacyMigrationConflict": return "T09"
        case "persistenceFailure": return "T10"
        case "persistenceOutcomeUnknown": return "T11"
        case "transportFailure": return "T12"
        case "anisetteFailure": return "T13"
        case "anisetteKitInvalidArgument": return "T14"
        case "anisetteKitLoaderFailed": return "T15"
        case "anisetteKitSymbolMissing": return "T16"
        case "anisetteKitReadFailure": return "T17"
        case "anisetteKitInvalidResponse": return "T18"
        case "anisetteKitADIError": return "T19"
        case "anisetteKitLibrariesNotFound": return "T20"
        case "anisetteKitHTTPError": return "T21"
        case "decodingTypeMismatch": return "T22"
        case "decodingValueNotFound": return "T23"
        case "decodingKeyNotFound": return "T24"
        case "decodingDataCorrupted": return "T25"
        case "archiveFileNotFound": return "T26"
        case "archiveCorrupt": return "T27"
        case "archiveReadFailed": return "T28"
        case "archiveWriteFailed": return "T29"
        case "archiveMissingApp": return "T30"
        case "unknownAccountFailure": return "T31"
        case "anisetteIdentityStateInvalid": return "T32"
        default: return nil
        }
    }
}
extension CombinedFailure.Stage {
    fileprivate var diagnosticToken: String {
        switch self {
        case .hostContainer: return "HOST"
        case .storagePreparation: return "STORE"
        case .bookmarkCreation: return "BOOK"
        case .extensionDiscovery: return "DISC"
        case .extensionLaunch: return "LAUNCH"
        case .xpcConnection: return "XPC"
        case .serviceReadiness: return "READY"
        case .command: return "CMD"
        case .authentication: return "AUTH"
        case .provisioning: return "PROV"
        case .signing: return "SIGN"
        case .filePreparation: return "IPA"
        case .installation: return "INSTALL"
        case .persistence: return "SAVE"
        case .refreshVerification: return "VERIFY"
        case .replyEncoding: return "REPLY"
        case .endpointSelection: return "ENDPOINT"
        case .heartbeat: return "HEART"
        case .coreDevice: return "CORE"
        case .cdTunnel: return "TUNNEL"
        case .rsdDiscovery: return "RSD"
        case .rsdService: return "SERVICE"
        case .lockdownConnection: return "LOCK"
        case .uniqueDeviceID: return "UDID"
        case .pairing: return "PAIR"
        case .network: return "NET"
        case .source: return "SOURCE"
        case .catalog: return "CAT"
        }
    }
}
extension CombinedFailure.Code {
    fileprivate var diagnosticToken: String {
        switch self {
        case .unavailable: return "C01"
        case .invalidConfiguration: return "C02"
        case .permissionDenied: return "C03"
        case .timedOut: return "C04"
        case .cancelled: return "C05"
        case .interrupted: return "C06"
        case .notReady: return "C07"
        case .busy: return "C08"
        case .invalidResponse: return "C09"
        case .unsupported: return "C10"
        case .failed: return "C11"
        case .missingResult: return "C12"
        case .staleResult: return "C13"
        case .invalidToken: return "C14"
        case .missingFile: return "C15"
        case .emptyFile: return "C16"
        case .invalidPackage: return "C17"
        case .fileAccess: return "C18"
        case .stagingFailed: return "C19"
        }
    }
}
extension CombinedFailure.SafeCause {
    fileprivate var diagnosticToken: String {
        switch self {
        case .networkConnectionLost: return "F01"
        case .networkTimedOut: return "F02"
        case .networkUnavailable: return "F03"
        case .anisetteServerUnavailable: return "F04"
        case .anisetteServerRejected: return "F05"
        case .anisetteRequestTimedOut: return "F06"
        case .anisetteRateLimited: return "F07"
        case .anisetteInvalidResponse: return "F08"
        case .anisetteUnknownFailure: return "F09"
        case .signingNetworkConnectionLost: return "F10"
        case .signingNetworkTimedOut: return "F11"
        case .signingNetworkUnavailable: return "F12"
        case .developerPortalRejectedRequest: return "F13"
        case .appIDLimitReached: return "F14"
        case .developerPortalInvalidResponse: return "F15"
        case .provisioningProfileUnavailable: return "F16"
        case .certificateUnavailable: return "F17"
        case .signingStorageUnverified: return "F18"
        case .wifiUnavailable: return "F19"
        case .localDevVPNUnavailable: return "F20"
        case .unknownSigningCause: return "F21"
        case .sourceNetworkFailure: return "F22"
        case .sourceInvalidManifest: return "F23"
        case .sourcePersistenceUnverified: return "F24"
        case .sourceInvalidURL: return "F25"
        case .sourceBlocked: return "F26"
        case .sourceChangedID: return "F27"
        case .sourceDuplicate: return "F28"
        case .sourceUnsupported: return "F29"
        case .sourceValidationFailed: return "F30"
        case .sourceRemoveFailed: return "F31"
        case .sourceRemoveBusy: return "F32"
        case .sourceAddBusy: return "F33"
        case .operationInProgress: return "F34"
        case .responseCapacityUnavailable: return "F35"
        case .sharedStoreUnavailable: return "F36"
        case .secretHandoffUnavailable: return "F37"
        case .staleRefreshAttempt: return "F38"
        case .knownSourcePolicyNetworkFailure: return "F39"
        case .knownSourcePolicyInvalidResponse: return "F40"
        case .catalogUnavailable: return "F41"
        case .catalogSourceUnavailable: return "F42"
        case .responseEncodingFailed: return "F43"
        case .responseTooLarge: return "F44"
        case .pairingRequired: return "F45"
        case .invalidPairingFile: return "F46"
        case .pairingFilePreparationFailed: return "F47"
        case .authAttemptNotDispatched: return "F48"
        case .authProvisioningRetryNotDispatched: return "F49"
        case .authSessionUnavailable: return "F50"
        case .authResponseCapacityUnavailable: return "F51"
        case .credentialCommitFailed: return "F52"
        case .credentialCommitOutcomeUnknown: return "F53"
        case .accountActivationFailed: return "F54"
        case .provisioningStorageFailed: return "F55"
        case .keychainSignOutFailed: return "F56"
        case .keychainSignOutOutcomeUnknown: return "F57"
        case .operationPersistenceFailed: return "F58"
        case .recoveryMalformedRecord: return "F59"
        case .recoveryIncompatibleRecord: return "F60"
        case .recoveryStorageUnavailable: return "F61"
        case .recoveryLockUnavailable: return "F62"
        case .recoveryReadFailure: return "F63"
        case .recoveryDeleteFailure: return "F64"
        }
    }
}
extension CombinedFailure.SourceStep {
    fileprivate var diagnosticToken: String {
        switch self {
        case .authenticate: return "S01"
        case .anisetteFetch: return "S02"
        case .appleAuthentication: return "S03"
        case .accountLookup: return "S04"
        case .credentialCommit: return "S05"
        case .fetchTeams: return "S06"
        case .saveAccount: return "S07"
        case .fetchCertificate: return "S08"
        case .activateCertificate: return "S09"
        case .registerDevice: return "S10"
        case .activateAccount: return "S11"
        case .provisioningUnknown: return "S12"
        case .provisioningProfileFetch: return "S13"
        case .certificateValidation: return "S14"
        case .localCodeSigning: return "S15"
        case .appIDLookup: return "S16"
        case .appIDRegistration: return "S17"
        case .appIDCapabilitiesUpdate: return "S18"
        case .appGroupLookup: return "S19"
        case .appGroupRegistration: return "S20"
        case .appGroupAssignment: return "S21"
        case .provisioningProfileRetrieval: return "S22"
        case .provisioningProfileCreation: return "S23"
        case .provisioningProfileUpdate: return "S24"
        case .sourceDownload: return "S25"
        case .manifestParsing: return "S26"
        case .sourceValidation: return "S27"
        case .knownSourcePolicyFetch: return "S28"
        case .knownSourcePolicyParsing: return "S29"
        case .catalogRead: return "S30"
        }
    }
}
extension CombinedFailure.LaunchContext.Step {
    fileprivate var diagnosticToken: String {
        switch self {
        case .hostBundleUnavailable: return "L01"
        case .missingPluginDirectory: return "L02"
        case .liveProcessBundleMissing: return "L03"
        case .liveProcessBundleUnreadable: return "L04"
        case .bundleIdentifierMissing: return "L05"
        case .executableMetadataMissing: return "L06"
        case .executableFileMissing: return "L07"
        case .extensionFactory: return "L08"
        case .extensionFactoryNil: return "L09"
        case .listenerCreation: return "L10"
        case .requestCallbackNoIdentifier: return "L11"
        case .requestCancellation: return "L12"
        case .requestInterruption: return "L13"
        case .requestCallbackError: return "L14"
        case .processIdentifierUnavailable: return "L15"
        case .xpcRemoteObjectError: return "L16"
        case .xpcInvalidation: return "L17"
        case .xpcPeerRejected: return "L18"
        case .readinessProbe: return "L19"
        case .startupTimeout: return "L20"
        case .connectionStopped: return "L21"
        case .unknown: return "L22"
        }
    }
}

// These diagnostic APIs are consumed by the separate LiveContainer app module
// through SideStoreSupport. Keep implementation-only helpers internal.
// Public build provenance only. Reject unexpected metadata rather than copying
// arbitrary Info.plist values into a diagnostic payload.
public enum V3DiagnosticBuild {
    public static var commit: String { validatedCommit(Bundle.main.object(forInfoDictionaryKey: "LCBuilderCommit")) }
    static func validatedCommit(_ value: Any?) -> String {
        guard let value = value as? String, value.utf8.count == 40,
              value.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil else { return "unknown" }
        return value.lowercased()
    }
}

// Local UI conditions can accompany a more specific underlying failure. Copy
// both classifications without copying message prose or guessing its cause.
public enum V3DiagnosticCopy {
    private static let localCodes: Set<String> = [
        "SS-PROV-D099",
        "SS-PROV-D100",
        "SS-PROV-D101",
        "SS-PROV-D102",
        "SS-PROV-D103",
        "SS-PROV-D104",
        "SS-PROV-D105",
        "SS-PROV-D106",
        "SS-PROV-D107",
        "SS-REFRESH-UNKNOWN", "SS-OPERATION-UNKNOWN", "SS-UI-UNKNOWN",
        "SS-AUTH-D024",
        "SS-AUTH-D032",
        "SS-AUTH-D033",
        "SS-AUTH-D034",
        "SS-AUTH-D035",
        "SS-AUTH-D036",
        "SS-AUTH-D037",
        "SS-AUTH-D038",
        "SS-AUTH-D039",
        "SS-AUTH-D040",
        "SS-AUTH-D041",
        "SS-AUTH-D060",
        "SS-AUTH-D069",
        "SS-AUTH-D070",
        "SS-AUTH-D071",
        "SS-AUTH-D072",
        "SS-AUTH-D073",
        "SS-AUTH-D074",
        "SS-AUTH-D075",
        "SS-AUTH-D076",
        "SS-AUTH-D077",
        "SS-AUTH-D078",
        "SS-AUTH-D079",
        "SS-AUTH-D080",
        "SS-AUTH-D081",
        "SS-AUTH-D082",
        "SS-AUTH-D083",
        "SS-AUTH-D089",
        "SS-AUTH-D092",
        "SS-AUTH-D093",
        "SS-AUTH-D094",
        "SS-AUTH-D095",
        "SS-CAT-D001",
        "SS-CAT-D017",
        "SS-CMD-D002",
        "SS-CMD-D004",
        "SS-CMD-D009",
        "SS-CMD-D010",
        "SS-CMD-D012",
        "SS-CMD-D013",
        "SS-CMD-D014",
        "SS-CMD-D015",
        "SS-CMD-D016",
        "SS-CMD-D019",
        "SS-CMD-D020",
        "SS-CMD-D021",
        "SS-CMD-D022",
        "SS-CMD-D023",
        "SS-CMD-D026",
        "SS-CMD-D027",
        "SS-CMD-D029",
        "SS-CMD-D045",
        "SS-CMD-D047",
        "SS-CMD-D050",
        "SS-CMD-D051",
        "SS-CMD-D055",
        "SS-CMD-D056",
        "SS-CMD-D064",
        "SS-CMD-D065",
        "SS-CMD-D066",
        "SS-CMD-D067",
        "SS-CMD-D068",
        "SS-CMD-D084",
        "SS-CMD-D085",
        "SS-CMD-D087",
        "SS-CMD-D088",
        "SS-IPA-D006",
        "SS-IPA-D007",
        "SS-IPA-D008",
        "SS-IPA-D011",
        "SS-NET-D061",
        "SS-NET-D096",
        "SS-PAIR-D043",
        "SS-READY-D005",
        "SS-SAVE-D018",
        "SS-SAVE-D030",
        "SS-SAVE-D031",
        "SS-SAVE-D042",
        "SS-SAVE-D059",
        "SS-SAVE-D086",
        "SS-SAVE-D090",
        "SS-SAVE-D091",
        "SS-SIGN-D097",
        "SS-SOURCE-D025",
        "SS-VERIFY-D003",
        "SS-VERIFY-D044",
        "SS-VERIFY-D046",
        "SS-VERIFY-D048",
        "SS-VERIFY-D049",
        "SS-VERIFY-D052",
        "SS-VERIFY-D053",
        "SS-VERIFY-D054",
        "SS-VERIFY-D057",
        "SS-VERIFY-D058",
        "SS-VERIFY-D062",
        "SS-VERIFY-D063",
        "SS-VERIFY-D098",
        "SS-XPC-D028",
    ]
    public static func details(visibleMessage: String, technical: String) -> String {
        let line = visibleMessage.components(separatedBy: "\n").last ?? ""
        let prefix = "Error ID: "
        let value = line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : ""
        let labels = localCodes.contains(value) ? "visible_error_id=\(value)" : ""
        let build = technical.contains("builder_commit=") ? "" : "builder_commit=\(V3DiagnosticBuild.commit)\n"
        return build + (labels.isEmpty ? "" : labels + "\n") + technical
    }
}

// Historical/plain messages have no recoverable typed cause. This fallback
// identifies only the known presentation flow and leaves original text intact.
public enum V3DiagnosticPresentation {
    public enum Context: String {
        case refresh = "SS-REFRESH-UNKNOWN"
        case operation = "SS-OPERATION-UNKNOWN"
        case global = "SS-UI-UNKNOWN"
    }
    public static func label(_ message: String, context: Context) -> String {
        guard !message.contains("\nError ID: SS-") else { return message }
        return message + "\nError ID: " + context.rawValue
    }
}
