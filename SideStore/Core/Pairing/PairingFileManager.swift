//
//  PairingFileManager.swift
//  SideStore
//
//  Created by Magesh K on 17/06/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import MinimuxerCommon

final class PairingFileManager: NSObject {
    static let shared = PairingFileManager()
    static let pairingFileName = AppConstants.Pairing.fileName

    nonisolated var pairingUDID: String? {
        guard let contents = fetchPairingFile() else {
            debugLog("[PairingFile] pairingUDID: fetchPairingFile() returned nil")
            return nil
        }
        do {
            let pairing = try PairingFileParser.parse(content: contents)
            guard let lockdown = pairing as? LockdownPairingFile else {
                debugLog("[PairingFile] pairingUDID: Remote Pairing files do not contain a hardware UDID")
                return nil
            }
            return lockdown.udid
        } catch {
            debugLog("[PairingFile] pairingUDID: failed to parse pairing file: \(error)")
            return nil
        }
    }

    nonisolated func fetchPairingFile() -> String? {
        let fm = FileManager.default
        let documentsPath = fm.documentsDirectory.appendingPathComponent("/\(Self.pairingFileName)")
        if fm.fileExists(atPath: documentsPath.path),
           let contents = try? String(contentsOf: documentsPath), !contents.isEmpty 
        {
            return contents
        }
        if let url = Bundle.main.url(forResource: AppConstants.Pairing.bundleResourceName, withExtension: AppConstants.Pairing.fileExtension),
           fm.fileExists(atPath: url.path),
           let data = fm.contents(atPath: url.path),
           let contents = String(data: data, encoding: .utf8),
           !contents.isEmpty, 
           !UserDefaults.standard.isPairingReset 
        { 
            return contents 
        }
        if let plistString = Bundle.main.object(forInfoDictionaryKey: AppConstants.Pairing.bundleResourceName) as? String,
           !plistString.isEmpty, 
           !plistString.contains(AppConstants.Pairing.placeholderString), 
           !UserDefaults.standard.isPairingReset 
        { 
            return plistString 
        }
        return nil
    }

    func savePairingFile(contents: String) throws {
        let fm = FileManager.default
        let documentsPath = fm.documentsDirectory.appendingPathComponent(Self.pairingFileName)
        if fm.fileExists(atPath: documentsPath.path) {
            try? fm.removeItem(at: documentsPath)
        }
        try contents.write(to: documentsPath, atomically: true, encoding: .utf8)
        debugLog("[PairingFile] Successfully copied and saved pairing file to: \(documentsPath.path)")
        UserDefaults.standard.isPairingReset = false
    }
}

// V3_HEADLESS_PAIRING_FILE_UI_REMOVED_V1: pairing bytes and persistence remain backend-owned.
