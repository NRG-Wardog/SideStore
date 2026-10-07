// V3_CERTIFICATE_SERIAL_LOG_REDACTION_V1: certificate serials are password-equivalent and never logged.
//
//  CertificateManager.swift
//  SideStore
//
//  Created by Magesh K on 1/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign
import CodeSignKit

public struct ActiveSigningCertificate: Sendable {
    public let certificate: ALTCertificate
    public let p12Data: Data
    public let password: String?
    
    public var serialNumber: String {
        certificate.serialNumber
    }

    fileprivate init(certificate: ALTCertificate, p12Data: Data, password: String?) {
        self.certificate = certificate
        self.p12Data = p12Data
        self.password = password
    }
}

public final class CertificateManager: @unchecked Sendable {
    public static let shared = CertificateManager()
    
    private let serialsKey = "importedCertificateSerials"
    private let metadataPrefix = "certMetadata_"
    
    public private(set) var activeCertificate: ActiveSigningCertificate?
    
    private init() {
        _ = try? loadActiveCertificate()
    }
    
    public static func parse(_ data: Data, password: String?) throws -> ALTCertificate {
        if let password = password {
            return try ALTCertificate(p12Data: data, password: password)
        } else {
            return try ALTCertificate(p12Data: data)
        }
    }

    public static func convert(_ cert: ALTCertificate, password: String?) throws -> Data {
        if let password = password {
            return try cert.encryptedP12Data(password: password)
        } else {
            return try cert.unencryptedP12Data()
        }
    }

    // MARK: - Active Keychain Certificate Encapsulation
    
    /// Loads active signing certificate from Keychain into memory.
    // LC_VERIFIED_ACTIVE_CERTIFICATE_V1
    @discardableResult
    public func loadActiveCertificate() throws -> ActiveSigningCertificate? {
        do {
            guard let stored = try Keychain.shared.signingCertificateSnapshot() else {
                self.activeCertificate = nil
                return nil
            }
            let cert = try Self.parse(stored.p12Data, password: stored.password)
            let active = ActiveSigningCertificate(certificate: cert, p12Data: stored.p12Data, password: stored.password)
            self.activeCertificate = active
            return active
        } catch {
            self.activeCertificate = nil
            throw error
        }
    }

    public func getPassword(for cert: ALTCertificate) -> String? {
        return cert.serialNumber
    }

    public func getPassword(for serialNumber: String) -> String? {
        return serialNumber
    }

    /// Sets active signing certificate in memory cache, encrypts and persists to Keychain.
    public func setActiveCertificate(_ cert: ALTCertificate?) throws {
        do {
            if let cert {
                let password = getPassword(for: cert)
                let p12Data = try Self.convert(cert, password: password)
                try Keychain.shared.writeSigningCertificate(p12Data: p12Data, password: password,
                    serial: cert.serialNumber) { storedData, storedPassword in
                    let parsed = try Self.parse(storedData, password: storedPassword)
                    guard parsed.serialNumber == cert.serialNumber else {
                        throw NSError(domain: "com.SideStore.Keychain", code: 1009)
                    }
                }
                self.recordCertificateMetadata(cert)
                self.activeCertificate = ActiveSigningCertificate(certificate: cert, p12Data: p12Data, password: password)
            } else {
                try Keychain.shared.writeSigningCertificate(p12Data: nil, password: nil, serial: nil) { _, _ in }
                self.activeCertificate = nil
            }
        } catch {
            // Preserve the last proven certificate on a verified rollback;
            // an uncertain transaction must not remain advertised in memory.
            let native = error as NSError
            if native.domain == "com.SideStore.Keychain" && native.code == 1010 {
                self.activeCertificate = nil
            }
            throw error
        }
    }

    public func clearActiveCertificate() {
        do { try self.setActiveCertificate(nil) }
        catch { debugLog("[LC_KEYCHAIN] certificate_clear_failed") }
    }

    // MARK: - Certificate Encoding Helpers
    
    public var activeSigningCertificateBase64Encoded: String? {
        guard let data = activeCertificate?.p12Data else { return nil }
        let base64 = data.base64EncodedString()
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ";/?:@&=+$, ")
        return base64.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    public func saveCertificate(_ cert: ALTCertificate) {
        debugLog("[CertificateManager] Certificate identity details omitted.")
        defer { debugLog("[CertificateManager] Certificate identity details omitted.") }
        
        do {
            let password = getPassword(for: cert)
            let p12Data = try Self.convert(cert, password: password)
            debugLog("[CertificateManager] p12Data generated, size: \(p12Data.count)")
            Keychain.shared[certificateSerial: cert.serialNumber] = p12Data
            debugLog("[CertificateManager] Successfully saved p12 to keychain")
        } catch {
            debugLog("[CertificateManager] Failed to export/save p12 to keychain: \(error)")
        }
        
        self.recordCertificateMetadata(cert)
    }

    private func recordCertificateMetadata(_ cert: ALTCertificate) {
        let serials = getImportedCertificateSerials()
        if !serials.contains(cert.serialNumber) {
            var updatedSerials = serials
            updatedSerials.append(cert.serialNumber)
            setImportedCertificateSerials(updatedSerials)
        }
        
        var metadataDict: [String: String] = getCertificateMetadata(for: cert.serialNumber) ?? [:]
        metadataDict["name"] = cert.name
        metadataDict["serialNumber"] = cert.serialNumber
        if let v = cert.machineIdentifier { metadataDict["machineIdentifier"] = v }
        if let v = cert.machineName { metadataDict["machineName"] = v }
        if let v = cert.requesterEmail { metadataDict["requesterEmail"] = v }
        setCertificateMetadata(metadataDict, for: cert.serialNumber)
    }

    public func saveX509Certificate(_ x509: ALTX509Certificate) {
        debugLog("[CertificateManager] Certificate identity details omitted.")
        defer { debugLog("[CertificateManager] Certificate identity details omitted.") }
        
        if let derData = x509.data {
            debugLog("[CertificateManager] derData exists, size: \(derData.count)")
            Keychain.shared[certificateSerial: x509.serialNumber] = derData
            debugLog("[CertificateManager] Successfully saved der to keychain")
        }
        
        let serials = getImportedCertificateSerials()
        if !serials.contains(x509.serialNumber) {
            var updatedSerials = serials
            updatedSerials.append(x509.serialNumber)
            setImportedCertificateSerials(updatedSerials)
        }
        
        var metadataDict: [String: String] = getCertificateMetadata(for: x509.serialNumber) ?? [:]
        metadataDict["name"] = x509.name
        metadataDict["serialNumber"] = x509.serialNumber
        if let v = x509.machineIdentifier { metadataDict["machineIdentifier"] = v }
        if let v = x509.machineName { metadataDict["machineName"] = v }
        if let v = x509.requesterEmail { metadataDict["requesterEmail"] = v }
        setCertificateMetadata(metadataDict, for: x509.serialNumber)
    }
    
    public func getLocalCertificate(serialNumber: String) -> ALTCertificate? {
        if let active = self.activeCertificate, active.serialNumber == serialNumber {
            return active.certificate
        }
        if let data = Keychain.shared[certificateSerial: serialNumber] {
            if data.isPKCS12 {
                let savedPassword = getPassword(for: serialNumber)
                if var cert = try? Self.parse(data, password: savedPassword) {
                    if let metadata = getCertificateMetadata(for: serialNumber) {
                        cert.machineIdentifier = metadata["machineIdentifier"]
                        cert.machineName = metadata["machineName"]
                        cert.requesterEmail = metadata["requesterEmail"]
                    }
                    return cert
                }
            }
        }
        return nil
    }

    public func getLocalX509Certificate(serialNumber: String) -> ALTX509Certificate? {
        if let cert = getLocalCertificate(serialNumber: serialNumber) {
            return cert.x509
        }
        if let data = Keychain.shared[certificateSerial: serialNumber] {
            let x509: ALTX509Certificate? = data.isPKCS12
                ? (try? Self.parse(data, password: getPassword(for: serialNumber)))?.x509
                : ALTX509Certificate(data: data)
            if var x509 {
                if let metadata = getCertificateMetadata(for: serialNumber) {
                    x509.machineIdentifier = metadata["machineIdentifier"]
                    x509.machineName = metadata["machineName"]
                    x509.requesterEmail = metadata["requesterEmail"]
                }
                return x509
            }
        }
        return nil
    }
    
    public func getAllLocalCertificates() -> [ALTCertificate] {
        let serials = getImportedCertificateSerials()
        debugLog("[CertificateManager] getAllLocalCertificates count: \(serials.count)")
        var certs: [ALTCertificate] = []
        for serial in serials {
            if let cert = getLocalCertificate(serialNumber: serial) {
                certs.append(cert)
            }
        }
        return certs
    }

    public func getAllLocalX509Certificates() -> [ALTX509Certificate] {
        let serials = getImportedCertificateSerials()
        var certs: [ALTX509Certificate] = []
        for serial in serials {
            if let x509 = getLocalX509Certificate(serialNumber: serial) {
                certs.append(x509)
            }
        }
        return certs
    }
    
    public func deleteCertificate(serialNumber: String) {
        debugLog("[CertificateManager] Certificate identity details omitted.")
        if self.activeCertificate?.serialNumber == serialNumber {
            clearActiveCertificate()
        }
        Keychain.shared[certificateSerial: serialNumber] = nil
        setCertificateMetadata(nil, for: serialNumber)
        var serials = getImportedCertificateSerials()
        serials.removeAll { $0 == serialNumber }
        setImportedCertificateSerials(serials)
    }

    public func getSignableCertificate(for serialNumber: String = "", fallbackPassword: String? = nil) -> ALTCertificate? {
        if let cert = getLocalCertificate(serialNumber: serialNumber) {
            return cert
        }
        
        if let cert = loadEmbeddedCertificate(for: serialNumber, fallbackPassword: fallbackPassword) {
            return cert
        }
        
        debugLog("[CertificateManager] Certificate identity details omitted.")
        return nil
    }

    private func loadEmbeddedCertificate(for serialNumber: String, fallbackPassword: String?) -> ALTCertificate? {
        let targetBundle = Bundle.main
        if FileManager.default.fileExists(atPath: targetBundle.certificateURL.path),
           let data = try? Data(contentsOf: targetBundle.certificateURL)
        {
            let possiblePasswords: [(name: String, value: String?)] = [
                ("incomingCertSerial", serialNumber),
                ("fallbackPassword", fallbackPassword),
                ("activeCertSerial", activeCertificate?.certificate.serialNumber),
                ("machineIdentifier", activeCertificate?.certificate.machineIdentifier),
                ("activeCertPassword", activeCertificate?.password),
                ("keychainPassword", Keychain.shared.signingCertificatePassword),
                ("nil", nil)
            ]

            var signableCert: ALTCertificate?
            for (pwdName, password) in possiblePasswords {
                verboseLog("[CertificateManager] getSignableCertificate: Attempting decryption with password source '\(pwdName)'...")
                if let cert = try? ALTCertificate(p12Data: data, password: password) {
                    signableCert = cert
                    if cert.serialNumber.lowercased() == serialNumber.lowercased() {
                        debugLog("[CertificateManager] Certificate identity details omitted.")
                        break
                    } else {
                        verboseLog("[CertificateManager] Certificate identity details omitted.")
                    }
                } else {
                    verboseLog("[CertificateManager] getSignableCertificate: Failed to decrypt embedded p12 using password source '\(pwdName)'.")
                }
            }

            if signableCert != nil || serialNumber.isEmpty {
                debugLog("[CertificateManager] Certificate identity details omitted.")
                return signableCert
            }
        }
        return nil
    }

    // Reads the Mach-O binary contents of an app bundle to extract its leaf signing certificate.
    public func readBinaryCertificate(at url: URL) -> ALTX509Certificate? {
        let executableURL: URL
        if url.pathExtension == "app" {
            guard let execURL = Bundle(url: url)?.executableURL else {
                debugLog("[CertificateManager] readBinaryCertificate: Failed to locate executable in bundle: \(url.path)")
                return nil
            }
            executableURL = execURL
        } else {
            executableURL = url
        }
        
        guard let parser = try? MachOParser(url: executableURL) else {
            debugLog("[CertificateManager] readBinaryCertificate: Failed to parse Mach-O at \(executableURL.path)")
            return nil
        }
        
        let certChain = parser.x509Certificates()

        debugLog("[CertificateManager] readBinaryCertificate: Found \(certChain.count) certificate(s) in Mach-O chain.")
        
        for (index, x509Cert) in certChain.enumerated() {
            guard let derData = x509Cert.data else { continue }
            let details = parseCertificate(derData: derData)
            
            // Filter out Root & Intermediate CA certificates
            let subjectDN = details.subject
            let isFilteredOut = subjectDN.contains("Root") || subjectDN.contains("Authority") || subjectDN.contains("Relations")
            
            verboseLog("[CertificateManager] Certificate identity details omitted.")
            
            if isFilteredOut {
                continue
            }
            
            debugLog("[CertificateManager] readBinaryCertificate: Extracted leaf signing certificate from Mach-O (\(executableURL.lastPathComponent))")
            return x509Cert
        }
        return nil
    }

    public func getSigningCertificate(at url: URL, withPlistFallback: Bool = true) -> ALTX509Certificate? {
        guard let appBundle = ALTApplication(fileURL: url) else {
            verboseLog("[CertificateManager] Could not resolve app bundle for \(url.path)")
            return nil
        }

        let bundleID = appBundle.bundleIdentifier
        let isSelf = appBundle.isAltStoreApp

        verboseLog("[CertificateManager] getSigningCertificate started for url: \(url.path), isSelf: \(isSelf), bundleID: \(bundleID)")

        // STEP 1: Mach-O Binary Check (Only for SideStore itself)
        if isSelf {
            let bundleURL = Bundle.Info.activeBundleURL
            verboseLog("[CertificateManager] Step 1 (Mach-O): Checking \(bundleURL.path)...")
            if let binaryX509 = readBinaryCertificate(at: bundleURL) {
                debugLog("[CertificateManager] Certificate identity details omitted.")
                return binaryX509
            } else {
                verboseLog("[CertificateManager] Step 1 (Mach-O): No valid leaf certificate extracted from Mach-O.")
            }
        } else {
            // STEP 2: App Group Cached Certificate Check (For third-party apps)
            let appDirectory = InstalledApp.appsDirectoryURL.appendingPathComponent(bundleID)
            let certURL = appDirectory.appendingPathComponent("signing_certificate.der")
            verboseLog("[CertificateManager] Step 2 (App Group Cached Cert): Checking \(appDirectory.path)...")

            if FileManager.default.fileExists(atPath: certURL.path) {
                if let derData = try? Data(contentsOf: certURL), let cert = ALTX509Certificate(data: derData) {
                    debugLog("[CertificateManager] Certificate identity details omitted.")
                    return cert
                } else {
                    verboseLog("[CertificateManager] Step 2 (App Group Cached Cert): File exists at \(certURL.path) but failed to parse.")
                }
            }
            verboseLog("[CertificateManager] Step 2 (App Group Cached Cert): No cached certificate found in App Group at \(appDirectory.path).")
        }

        verboseLog("[CertificateManager] getSigningCertificate: No signing certificate found for \(url.path)")
        return nil
    }

    public func isCertificateLocallyCached(serialNumber: String) -> Bool {
        if let activeCert = self.activeCertificate, activeCert.serialNumber == serialNumber {
            return true
        }
        return getImportedCertificateSerials().contains(serialNumber)
    }
}

// MARK: - Private Domain Persistence Boundary Extension

private extension CertificateManager {
    func getImportedCertificateSerials() -> [String] {
        return UserDefaults.standard.stringArray(forKey: serialsKey) ?? []
    }
    
    func setImportedCertificateSerials(_ serials: [String]) {
        UserDefaults.standard.set(serials, forKey: serialsKey)
    }
    
    func getCertificateMetadata(for serial: String) -> [String: String]? {
        return UserDefaults.standard.dictionary(forKey: metadataPrefix + serial) as? [String: String]
    }
    
    func setCertificateMetadata(_ metadata: [String: String]?, for serial: String) {
        if let metadata = metadata {
            UserDefaults.standard.set(metadata, forKey: metadataPrefix + serial)
        } else {
            UserDefaults.standard.removeObject(forKey: metadataPrefix + serial)
        }
    }
}
