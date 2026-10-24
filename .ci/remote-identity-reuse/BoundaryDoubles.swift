// Inert boundaries only. No live Security, network, provider, credential or native calls.
import Foundation
import Security

enum FixtureFailure: Error { case assertion(String), nativeBoundary, injected }

func fixtureCheck(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw FixtureFailure.assertion(label) }
}

func fixtureThrows(_ label: String, _ operation: () throws -> Void) throws {
    do { try operation() }
    catch is FixtureFailure { throw FixtureFailure.assertion(label + ": unexpected fixture boundary") }
    catch { return }
    throw FixtureFailure.assertion(label + ": expected failure")
}

func fixtureThrowsRemote(_ label: String, expected: V3RemoteIdentityError,
                         _ operation: () throws -> Void) throws {
    do { try operation() }
    catch let error as V3RemoteIdentityError {
        switch (error, expected) {
        case (.invalidRecord, .invalidRecord), (.storageUnverified, .storageUnverified),
             (.stateChanged, .stateChanged), (.manualSignInRequired, .manualSignInRequired): return
        default: throw FixtureFailure.assertion(label + ": wrong remote error")
        }
    }
    catch { throw FixtureFailure.assertion(label + ": unrelated error category") }
    throw FixtureFailure.assertion(label + ": expected failure")
}

final class FixtureSecurity: @unchecked Sendable {
    static let shared = FixtureSecurity()
    private let lock = NSRecursiveLock()
    private var items: [String: Data] = [:]
    private var seen: [NSDictionary] = []
    var failReads = false
    var failWrites = false
    var failRemoves = false
    var ignoreWrites = false
    var ignoreRemoves = false

    func reset() {
        lock.lock(); defer { lock.unlock() }
        items = [:]; seen = []; failReads = false; failWrites = false
        failRemoves = false; ignoreWrites = false; ignoreRemoves = false
    }

    private func key(_ query: NSDictionary) -> String {
        [kSecAttrService, kSecAttrAccessGroup, kSecAttrAccount].map {
            query[$0] as? String ?? "<missing>"
        }.joined(separator: "|")
    }

    func seed(service: String, group: String, account: String, bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        items[[service, group, account].joined(separator: "|")] = bytes
    }

    func queries() -> [NSDictionary] {
        lock.lock(); defer { lock.unlock() }; return seen
    }

    private func copy(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let query = query as NSDictionary; seen.append(query)
        if failReads { return errSecInteractionNotAllowed }
        guard let data = items[key(query)] else { return errSecItemNotFound }
        result?.pointee = data as CFData
        return errSecSuccess
    }

    private func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let query = query as NSDictionary; seen.append(query)
        if failWrites { return errSecInteractionNotAllowed }
        if items[key(query)] != nil { return errSecDuplicateItem }
        guard let data = query[kSecValueData] as? Data else { return errSecParam }
        if !ignoreWrites { items[key(query)] = data }
        return errSecSuccess
    }

    private func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let query = query as NSDictionary; seen.append(query)
        if failWrites { return errSecInteractionNotAllowed }
        guard items[key(query)] != nil else { return errSecItemNotFound }
        guard let data = (attributes as NSDictionary)[kSecValueData] as? Data else { return errSecParam }
        if !ignoreWrites { items[key(query)] = data }
        return errSecSuccess
    }

    private func delete(_ query: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let query = query as NSDictionary; seen.append(query)
        if failRemoves { return errSecInteractionNotAllowed }
        guard items[key(query)] != nil else { return errSecItemNotFound }
        if !ignoreRemoves { items.removeValue(forKey: key(query)) }
        return errSecSuccess
    }

    static func makeCalls() -> V3PendingCertificateKeychainCalls {
        let fake = shared
        return V3PendingCertificateKeychainCalls(
            copyMatching: { fake.copy($0, $1) }, add: { fake.add($0, $1) },
            update: { fake.update($0, $1) }, delete: { fake.delete($0) })
    }
}

enum KeychainAccess {
    final class Keychain: @unchecked Sendable {
        private let lock = NSRecursiveLock()
        private var items: [String: Data] = [:]
        func getData(_ key: String) throws -> Data? {
            lock.lock(); defer { lock.unlock() }; return items[key]
        }
        func set(_ value: Data, key: String) throws {
            lock.lock(); defer { lock.unlock() }; items[key] = value
        }
        func remove(_ key: String) throws {
            lock.lock(); defer { lock.unlock() }; items.removeValue(forKey: key)
        }
        func reset() { lock.lock(); defer { lock.unlock() }; items.removeAll() }
    }
}

final class Keychain: @unchecked Sendable {
    static let shared = Keychain()
    let keychain = KeychainAccess.Keychain()
}

enum LCSharedKeychainFileLock {
    static func withLock<T>(appGroup: String?, _ operation: () throws -> T) throws -> T {
        throw FixtureFailure.nativeBoundary
    }
}

enum LCEmbeddedSharedKeychain {
    static var installedGroup: String? = "fixture.entitled.group"
    static var installedAppGroup: String? = "fixture.app.group"
    static var service = "fixture.container"
    static var transactionOverride: (((() throws -> Void) throws -> Void))?
    static let fixtureTransactionLock = NSRecursiveLock()
    static func authenticationValuesLocked(_ client: KeychainAccess.Keychain) throws -> [String: Data]? {
        if try client.getData(LCSharedKeychainMigration.marker) == LCSharedKeychainMigration.signedOut { return nil }
        var values: [String: Data] = [:]
        for name in LCSharedKeychainMigration.authKeys { values[name] = try client.getData(name) }
        return values.isEmpty ? nil : values
    }
    static func note(_ key: String, status: Int) {}
    static func verifyRecoveryConflicts(group: String, values: [String: Data]) throws {
        throw FixtureFailure.nativeBoundary
    }
}

func fixtureInstallCredentials(_ credentials: LCEmbeddedAuthenticationSnapshot,
                               on keychain: Keychain = .shared) throws {
    for (key, value) in [("appleIDEmailAddress", credentials.appleIDEmailAddress),
                         ("appleIDPassword", credentials.appleIDPassword),
                         ("appleIDAdsid", credentials.appleIDAdsid),
                         ("appleIDXcodeToken", credentials.appleIDXcodeToken)] {
        if let value { try keychain.keychain.set(Data(value.utf8), key: key) }
        else { try keychain.keychain.remove(key) }
    }
    try keychain.keychain.remove(LCSharedKeychainMigration.marker)
}

func fixtureReset() {
    FixtureSecurity.shared.reset()
    Keychain.shared.keychain.reset()
    LCEmbeddedSharedKeychain.installedGroup = "fixture.entitled.group"
    LCEmbeddedSharedKeychain.service = "fixture.container"
    LCEmbeddedSharedKeychain.transactionOverride = { operation in
        LCEmbeddedSharedKeychain.fixtureTransactionLock.lock()
        defer { LCEmbeddedSharedKeychain.fixtureTransactionLock.unlock() }
        try operation()
    }
}
