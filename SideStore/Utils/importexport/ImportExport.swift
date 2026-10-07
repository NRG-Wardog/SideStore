//
//  ImportExport.swift
//  SideStore
//
//  Created by Magesh K on 07/01/25.
//  Copyright © 2025 SideStore. All rights reserved.
//


import Foundation
import Security
import SideSign
import CryptoKit
import CommonCrypto

enum BackupEncryptionError: Error, LocalizedError {
    case invalidPassword
    case decryptionFailed
    case exportPasswordMatchesApplePassword
    case invalidDataFormat
    
    var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return "Invalid password."
        case .decryptionFailed:
            return "Incorrect password or corrupted backup file."
        case .exportPasswordMatchesApplePassword:
            return "File password cannot be the same as Apple ID password stored in secure keychain."
        case .invalidDataFormat:
            return "The backup file format is invalid."
        }
    }
}

class ImportExport {
    // LC_HEADLESS_IMPORT_EXPORT_UI_REMOVED_V1: account backup encryption remains available to the host pipeline.
    
    private static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derivedKeyData = Data(count: 32)
        
        _ = derivedKeyData.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        10000,
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        return SymmetricKey(data: derivedKeyData)
    }

    public static func exportAccount(password: String, includeApplePassword: Bool) throws -> Data {
        // LC_IMPORT_EXPORT_CREDENTIAL_SNAPSHOT_V1
        let authSnapshot = AuthManager.shared.authenticationSnapshot
        guard let email = authSnapshot?.appleIDEmailAddress,
              let activeCert = CertificateManager.shared.activeCertificate,
              let identifier = AnisetteConfigManager.shared.anisetteIdentifier,
              let adiPB = AnisetteConfigManager.shared.anisetteAdiBlob else {
            throw OperationError.invalidParameters("Account or signing data is missing.")
        }
        
        if let applePass = authSnapshot?.appleIDPassword, password == applePass {
            throw BackupEncryptionError.exportPasswordMatchesApplePassword
        }

        let applePasswordToInclude = includeApplePassword ? authSnapshot?.appleIDPassword : nil
        let account: ImportedAccount
        if let certPass = activeCert.password {
            account = ImportedAccount(version: ImportedAccount.currentVersion, email: email, password: applePasswordToInclude, certificateData: activeCert.p12Data, certificatePassword: certPass, anisetteIdentifier: identifier, anisetteAdiBlob: adiPB)
        } else {
            account = ImportedAccount(version: ImportedAccount.currentVersion, email: email, password: applePasswordToInclude, certificateData: activeCert.p12Data, anisetteIdentifier: identifier, anisetteAdiBlob: adiPB)
        }

        let jsonData = try Foundation.JSONEncoder().encode(account)
        
        var salt = Data(count: 16)
        let result = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard result == errSecSuccess else {
            throw OperationError.invalidParameters("Failed to generate random salt.")
        }
        
        let key = deriveKey(password: password, salt: salt)
        let sealedBox = try AES.GCM.seal(jsonData, using: key)
        guard let combinedData = sealedBox.combined else {
            throw OperationError.invalidParameters("Encryption payload failed.")
        }
        
        var finalData = Data()
        finalData.append(salt)
        finalData.append(combinedData)
        return finalData
    }

    public static func importAccount(_ encryptedData: Data, filePassword: String) throws -> ImportedAccount {
        guard encryptedData.count > 16 else {
            throw BackupEncryptionError.invalidDataFormat
        }
        
        let salt = encryptedData.prefix(16)
        let ciphertext = encryptedData.dropFirst(16)
        
        let key = deriveKey(password: filePassword, salt: salt)
        
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            let account = try Foundation.JSONDecoder().decode(ImportedAccount.self, from: decryptedData)
            
            AuthManager.shared.signOut()
            AuthManager.shared.currentAppleID = account.email
            if let pass = account.password, !pass.isEmpty {
                AuthManager.shared.password = pass
            }
            AnisetteConfigManager.shared.anisetteAdiBlob = account.anisetteAdiBlob
            AnisetteConfigManager.shared.anisetteIdentifier = account.anisetteIdentifier
            
            let altCert = try CertificateManager.parse(account.certificateData, password: account.certificatePassword)
            try CertificateManager.shared.setActiveCertificate(altCert)
            
            return account
        } catch {
            throw BackupEncryptionError.decryptionFailed
        }
    }
    

}

#if DEBUG
extension ImportExport {
    static func exportAccountJSON(password: String) -> ImportedAccount? {
        // LC_IMPORT_EXPORT_CREDENTIAL_SNAPSHOT_V1
        let authSnapshot = AuthManager.shared.authenticationSnapshot
        guard let email = authSnapshot?.appleIDEmailAddress,
              let passwordStr = authSnapshot?.appleIDPassword,
              let activeCert = CertificateManager.shared.activeCertificate,
              let identifier = AnisetteConfigManager.shared.anisetteIdentifier,
              let adiPB = AnisetteConfigManager.shared.anisetteAdiBlob else {
            return nil
        }
        if let certPass = activeCert.password {
            return ImportedAccount(version: ImportedAccount.currentVersion, email: email, password: passwordStr, certificateData: activeCert.p12Data, certificatePassword: certPass, anisetteIdentifier: identifier, anisetteAdiBlob: adiPB)
        } else {
            return ImportedAccount(version: ImportedAccount.currentVersion, email: email, password: passwordStr, certificateData: activeCert.p12Data, anisetteIdentifier: identifier, anisetteAdiBlob: adiPB)
        }
    }

    static func importAccountJSON(from file: URL) throws {
        _ = file.startAccessingSecurityScopedResource()
        defer { file.stopAccessingSecurityScopedResource() }
        
        let accountData = try Data(contentsOf: file)
        let account = try Foundation.JSONDecoder().decode(ImportedAccount.self, from: accountData)
        
        AuthManager.shared.signOut()
        AuthManager.shared.currentAppleID = account.email
        AuthManager.shared.password = account.password
        AnisetteConfigManager.shared.anisetteAdiBlob = account.anisetteAdiBlob
        AnisetteConfigManager.shared.anisetteIdentifier = account.anisetteIdentifier
        
        let altCert = try CertificateManager.parse(account.certificateData, password: account.certificatePassword)
        try CertificateManager.shared.setActiveCertificate(altCert)
    }
}
#endif
