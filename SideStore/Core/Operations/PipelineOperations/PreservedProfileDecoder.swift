// Strict bounded outer/inner representation binding; this decoder grants no authority.
// Callers must cryptographically check both envelopes. Historical results may only
// restrict a candidate; candidate authority independently requires exact Apple-origin
// provenance. Inner inspection alone is never a signer-role endorsement.
import Foundation
import CoreFoundation
import CryptoKit
#if canImport(FoundationXML)
import FoundationXML
#endif

enum PreservedProfileDecoder {
    enum Failure: Error { case malformed, unsupported, inconsistent }
    struct Result {
        let rawOuter: [String: Any]
        let rawInner: Data
        let normalizedInnerAuthority: [String: Data]
    }
    private struct Node {
        let tag: UInt8
        let raw: Data
        let body: Data
        let children: [Node]
    }
    private indirect enum Value: Equatable {
        case string(String), data(Data), bool(Bool), integer(Int64), date(Date)
        case array([Value]), dictionary([String: Value])
        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case let (.string(a), .string(b)): return a.utf8.elementsEqual(b.utf8)
            case let (.data(a), .data(b)): return a == b
            case let (.bool(a), .bool(b)): return a == b
            case let (.integer(a), .integer(b)): return a == b
            case let (.date(a), .date(b)): return a == b
            case let (.array(a), .array(b)): return a == b
            case let (.dictionary(a), .dictionary(b)):
                guard Set(a.keys.map { Data($0.utf8) }) == Set(b.keys.map { Data($0.utf8) }) else { return false }
                return a.allSatisfy { key, value in b[key] == value }
            default: return false
            }
        }
    }
    private static func check(_ condition: Bool) throws {
        if !condition { throw Failure.malformed }
    }
    private static func bindingCheck(_ condition: Bool) throws {
        if !condition { throw Failure.inconsistent }
    }
    private static func parse(_ input: Data) throws -> Node {
        try check(!input.isEmpty && input.count <= 1_048_576)
        let bytes = [UInt8](input)
        var count = 0
        func read(_ offset: inout Int, _ end: Int, _ depth: Int) throws -> Node {
            count += 1
            try check(depth <= 24 && count <= 8192 && offset <= end - 2)
            let start = offset
            let tag = bytes[offset]; offset += 1
            try check([UInt8(1),2,4,5,12,18,23,24,48,49,112,176].contains(tag))
            let first = bytes[offset]; offset += 1
            var length = Int(first)
            if first & 128 != 0 {
                let width = Int(first & 127)
                try check(width >= 1 && width <= 4 && width <= end - offset)
                try check(bytes[offset] != 0)
                length = 0
                for _ in 0..<width { length = length * 256 + Int(bytes[offset]); offset += 1 }
                try check(length >= 128)
            }
            try check(length <= end - offset)
            let bodyStart = offset, stop = offset + length
            let body = Data(bytes[bodyStart..<stop])
            var children: [Node] = []
            if tag & 32 != 0 {
                while offset < stop { children.append(try read(&offset, stop, depth + 1)) }
                if tag == 49 {
                    for i in 1..<max(1, children.count) {
                        try check(!children[i].raw.lexicographicallyPrecedes(children[i-1].raw))
                    }
                }
            } else {
                offset = stop
                if tag == 1 { try check(body == Data([0]) || body == Data([255])) }
                if tag == 2 {
                    try check(!body.isEmpty)
                    if body.count > 1 {
                        let b = [UInt8](body)
                        try check(!(b[0] == 0 && b[1] < 128) && !(b[0] == 255 && b[1] >= 128))
                    }
                }
                if tag == 5 { try check(body.isEmpty) }
                if tag == 18 { try check(body.allSatisfy { $0 == 32 || (48...57).contains($0) }) }
                if tag == 12 || tag == 18 { try check(String(data: body, encoding: tag == 12 ? .utf8 : .ascii) != nil) }
            }
            let node = Node(tag: tag, raw: Data(bytes[start..<stop]), body: body, children: children)
            if tag == 23 || tag == 24 { _ = try date(node) }
            return node
        }
        var offset = 0
        let result = try read(&offset, bytes.count, 0)
        try check(offset == bytes.count)
        return result
    }
    private static func date(_ node: Node) throws -> Date {
        try check(node.tag == 23 || node.tag == 24)
        guard var text = String(data: node.body, encoding: .ascii) else { throw Failure.malformed }
        let digits = node.tag == 23 ? 12 : 14
        try check(text.utf8.count == digits + 1 && text.last == "Z" && text.dropLast().utf8.allSatisfy { (48...57).contains($0) })
        if node.tag == 23 {
            guard let year = Int(text.prefix(2)) else { throw Failure.malformed }
            text = String(year >= 50 ? 1900 + year : 2000 + year) + text.dropFirst(2)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { throw Failure.malformed }
        return date
    }
    private static func pairs(_ node: Node, tag: UInt8) throws -> [String: Node] {
        try check(node.tag == tag)
        var result: [String: Node] = [:]
        for pair in node.children {
            try check(pair.tag == 48 && pair.children.count == 2)
            let keyNode = pair.children[0]
            guard keyNode.tag == 12, let key = String(data: keyNode.body, encoding: .utf8), !key.isEmpty else { throw Failure.malformed }
            try check(result[key] == nil)
            result[key] = pair.children[1]
        }
        return result
    }
    private static func scalar(_ node: Node) throws -> Value {
        switch node.tag {
        case 12:
            guard let value = String(data: node.body, encoding: .utf8) else { throw Failure.malformed }
            return .string(value)
        case 4: return .data(node.body)
        case 1: return .bool(node.body == Data([255]))
        case 2:
            try check(!node.body.isEmpty && node.body.count <= 8)
            var bits: UInt64 = node.body.first! & 128 != 0 ? UInt64.max : 0
            for byte in node.body { bits = (bits << 8) | UInt64(byte) }
            return .integer(Int64(bitPattern: bits))
        case 23,24: return .date(try date(node))
        case 48: return .array(try node.children.map(scalar))
        case 49: return .dictionary(try pairs(node, tag: 49).mapValues(scalar))
        case 112:
            try check(node.children.count == 2)
            let version = node.children[0]
            try check(version.tag == 2 && version.body == Data([1]))
            return .dictionary(try pairs(node.children[1], tag: 176).mapValues(scalar))
        default: throw Failure.unsupported
        }
    }
    private static func outerValue(_ object: Any) throws -> Value {
        if let value = object as? String { return .string(value) }
        if let value = object as? Data { return .data(value) }
        if let value = object as? Date { return .date(value) }
        if let value = object as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            guard let integer = Int64(value.stringValue) else { throw Failure.unsupported }
            return .integer(integer)
        }
        if let value = object as? [Any] { return .array(try value.map(outerValue)) }
        if let value = object as? [String: Any] { return .dictionary(try value.mapValues(outerValue)) }
        throw Failure.unsupported
    }
    static func decodeOuter(verifiedOuterXML: Data) throws -> [String: Any] {
        try XMLClosure.validate(verifiedOuterXML)
        guard let outer = try PropertyListSerialization.propertyList(from: verifiedOuterXML, options: [], format: nil) as? [String: Any] else { throw Failure.malformed }
        return outer
    }
    static func decode(verifiedOuterXML: Data, verifiedInnerDER: Data) throws -> Result {
        // Authentication is performed by the caller's separately qualified CMS facade.
        let outer = try decodeOuter(verifiedOuterXML: verifiedOuterXML)
        let root = try parse(verifiedInnerDER)
        let fields = try pairs(root, tag: 49)
        try check(Set(["Entitlements","DeveloperCertificates","ExpirationDate","CreationDate","UUID","Version"]).isSubset(of: Set(fields.keys)))
        try check(fields["Version"]!.tag == 2 && fields["Version"]!.body == Data([1]))
        try bindingCheck(Set(fields.keys.map { Data($0.utf8) }).subtracting(outer.keys.map { Data($0.utf8) }).isSubset(of: [Data("ProfileDistributionType".utf8)]))
        try bindingCheck(Set(outer.keys.map { Data($0.utf8) }).subtracting(fields.keys.map { Data($0.utf8) }).isSubset(of: [Data("DER-Encoded-Profile".utf8)]))
        if let distribution = fields["ProfileDistributionType"] { try check(distribution.tag == 12 && !distribution.body.isEmpty) }
        for (key,node) in fields where !["DeveloperCertificates","Entitlements"].contains(key) && !(key == "ProfileDistributionType" && outer[key] == nil) {
            guard let value = outer[key] else { throw Failure.inconsistent }
            try bindingCheck(try scalar(node) == outerValue(value))
        }
        guard case let .dictionary(entitlements) = try scalar(fields["Entitlements"]!), let outerEntitlements = outer["Entitlements"] else { throw Failure.inconsistent }
        try bindingCheck(try .dictionary(entitlements) == outerValue(outerEntitlements))
        for key in ["application-identifier","com.apple.developer.team-identifier"] {
            guard case let .string(value)? = entitlements[key], !value.isEmpty else { throw Failure.inconsistent }
        }
        guard case let .array(hashes) = try scalar(fields["DeveloperCertificates"]!), let certificates = outer["DeveloperCertificates"] as? [Data], !hashes.isEmpty else { throw Failure.inconsistent }
        var seen = Set<Data>()
        for hash in hashes {
            guard case let .data(data) = hash, data.count == 32, seen.insert(data).inserted else { throw Failure.inconsistent }
        }
        try check(certificates.allSatisfy { !$0.isEmpty })
        try bindingCheck(hashes == certificates.map { .data(Data(SHA256.hash(data: $0))) })
        for key in ["ProvisionedDevices","ProvisionsAllDevices"] { try bindingCheck((fields[key] == nil) == (outer[key] == nil)) }
        let creation = try date(fields["CreationDate"]!), expiration = try date(fields["ExpirationDate"]!)
        try bindingCheck(creation < expiration)
        guard fields["UUID"]!.tag == 12, let text = outer["UUID"] as? String, let uuid = UUID(uuidString: text), uuid.uuidString == text.uppercased() else { throw Failure.inconsistent }
        let lifecycle: Set<String> = ["UUID","CreationDate","ExpirationDate"]
        return Result(rawOuter: outer, rawInner: verifiedInnerDER,
                      // Retain whole pair TLV, including original UTF8 key bytes: Swift String
                      // equality alone canonicalizes Unicode and must not erase key differences.
                      normalizedInnerAuthority: Dictionary(uniqueKeysWithValues: root.children.compactMap { pair in
                          let key = String(data: pair.children[0].body, encoding: .utf8)!
                          return lifecycle.contains(key) ? nil : (key, pair.raw)
                      }))
    }
    private final class XMLClosure: NSObject, XMLParserDelegate {
        private final class Element {
            let name: String
            let attributes: [String: String]
            var children: [Element] = []
            var text = ""
            init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
        }
        private var stack: [Element] = []
        private var root: Element?
        private var nodes = 0
        private var invalid = false
        private func fail(_ parser: XMLParser) { invalid = true; parser.abortParsing() }
        static func validate(_ data: Data) throws {
            try check(!data.isEmpty && data.count <= 1_048_576)
            guard let text = String(data: data, encoding: .utf8), !text.utf8.contains(0) else { throw Failure.unsupported }
            let upper = text.uppercased()
            try check(!upper.contains("<!ENTITY") && !upper.contains("<![CDATA["))
            if let declarationEnd = upper.range(of: "?>"), upper.hasPrefix("<?XML") {
                let declaration = String(upper[..<declarationEnd.lowerBound])
                if declaration.contains("ENCODING") {
                    let pattern = #"ENCODING\s*=\s*['\"]UTF-8['\"]"#
                    try check(declaration.range(of: pattern, options: .regularExpression) != nil)
                }
            }
            let delegate = XMLClosure()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            parser.delegate = delegate
            try check(parser.parse() && !delegate.invalid && delegate.stack.isEmpty)
            guard let root = delegate.root else { throw Failure.malformed }
            try check(root.name == "plist" && root.attributes == ["version":"1.0"] && root.children.count == 1 && root.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            try check(root.children[0].name == "dict")
            try delegate.validateElement(root.children[0])
        }
        private func validateElement(_ node: Element) throws {
            try check(node.attributes.isEmpty)
            if node.name == "dict" {
                try check(node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && node.children.count % 2 == 0)
                var keys = Set<String>()
                for i in stride(from: 0, to: node.children.count, by: 2) {
                    let key = node.children[i]
                    try check(key.name == "key" && key.attributes.isEmpty && key.children.isEmpty && !key.text.isEmpty && keys.insert(key.text).inserted)
                    try validateElement(node.children[i+1])
                }
            } else if node.name == "array" {
                try check(node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                for child in node.children { try validateElement(child) }
            } else {
                try check(node.children.isEmpty && ["string","data","date","integer","true","false"].contains(node.name))
                if node.name == "true" || node.name == "false" { try check(node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                if node.name == "integer" {
                    try check(node.text.range(of: #"^-?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil && Int64(node.text) != nil)
                }
                if node.name == "data" {
                    // Whitelist ASCII scalars, not Character graphemes: CRLF is one
                    // Character, so a Character whitelist can accidentally retain LF.
                    let compact = String(String.UnicodeScalarView(node.text.unicodeScalars.filter {
                        ![UInt32(0x20), 0x09, 0x0D, 0x0A].contains($0.value)
                    }))
                    guard let decoded = Data(base64Encoded: compact) else { throw Failure.malformed }
                    // Foundation may accept excess padding or nonzero unused bits.
                    // Only the canonical RFC 4648 spelling of these bytes is accepted.
                    try check(decoded.base64EncodedString().utf8.elementsEqual(compact.utf8))
                }
                if node.name == "date" {
                    try check(node.text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"#, options: .regularExpression) != nil)
                    let compact = node.text.filter { !"-:T".contains($0) }
                    _ = try date(Node(tag: 24, raw: Data(), body: Data(compact.utf8), children: []))
                }
            }
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String]) {
            nodes += 1
            guard nodes <= 8192, stack.count < 25 else { fail(parser); return }
            let element = Element(elementName, attributeDict)
            if let parent = stack.last { parent.children.append(element) }
            else if root == nil { root = element } else { fail(parser); return }
            stack.append(element)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard stack.last?.name == elementName else { fail(parser); return }
            stack.removeLast()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if let current = stack.last { current.text += string }
            else if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail(parser) }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { fail(parser) }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { fail(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { fail(parser) }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { fail(parser); return nil }
    }
}
