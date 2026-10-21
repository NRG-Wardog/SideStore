// Non-UI value declarations retained from excluded upstream views and dialogs.
// Copyright © 2026 SideStore. All rights reserved.

import Foundation
import SideSign

public struct InfoPlistTarget: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isExtension: Bool
    public let initialPlist: [String: any Sendable]

    public init(
        id: String,
        name: String? = nil,
        isExtension: Bool = false,
        initialPlist: [String: any Sendable]
    ) {
        let parser = InfoPlistParser(dictionary: initialPlist)
        self.id = id
        self.name = name ?? parser.displayName ?? parser.bundleName ?? id
        self.isExtension = isExtension
        self.initialPlist = initialPlist
    }
}

public struct EntitlementsTarget: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isExtension: Bool
    public let initialEntitlements: [String: any Sendable]

    public init(
        id: String,
        name: String,
        isExtension: Bool,
        initialEntitlements: [String: any Sendable]
    ) {
        self.id = id
        self.name = name
        self.isExtension = isExtension
        self.initialEntitlements = initialEntitlements
    }
}

public enum AppImportSourceMode: String, CaseIterable, Identifiable, Sendable {
    case prompt = "prompt"
    case files  = "files"
    case url    = "url"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .prompt:
            return "Prompt User"
        case .files:
            #if !os(tvOS)
            return "Files App"
            #else
            return "Web Upload"
            #endif
        case .url:
            return "URL"
        }
    }
}
