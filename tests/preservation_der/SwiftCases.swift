// Synthetic decoder fixture. CMS authentication is covered separately.
import Foundation
struct Case: Decodable { let name: String; let outer: String; let inner: String; let accept: Bool; let group: String?; let differentFrom: String? }
struct Cases: Decodable { let schema: String; let cases: [Case] }
let input = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
precondition(input.schema == "scratch-parser-only-v1" && input.cases.count == 45)
var groups: [String: [String: Data]] = [:]
var names = Set<String>()
for test in input.cases {
    precondition(names.insert(test.name).inserted)
    guard let outer = Data(base64Encoded: test.outer), let inner = Data(base64Encoded: test.inner) else { fatalError("fixture encoding") }
    if test.name == "legacy-character-whitespace-reproduces-lf" {
        // Source-local reproduction of the original bug, before corrected decode.
        precondition(Array(" \t\r\n") == [" ", "\t", "\r\n"])
        let legacy = "\nQQ==\n".filter { !" \t\r\n".contains($0) }
        precondition(legacy == "\nQQ==\n" && Data(base64Encoded: legacy) == nil)
    }
    do {
        let result = try PreservedProfileDecoder.decode(verifiedOuterXML: outer, verifiedInnerDER: inner)
        precondition(test.accept, "unexpected parser acceptance: \(test.name)")
        precondition(result.rawInner == inner)
        if let group = test.differentFrom {
            guard let previous = groups[group] else { fatalError("missing comparison fixture") }
            precondition(previous != result.normalizedInnerAuthority, "authorization change erased")
        }
        if let group = test.group {
            if let previous = groups[group] { precondition(previous == result.normalizedInnerAuthority, "renewal authority drift") }
            else { groups[group] = result.normalizedInnerAuthority }
        }
    } catch {
        precondition(!test.accept, "unexpected parser rejection: \(test.name)")
    }
}
let report: [String: Any] = ["schema":"preservation-der-parser-v1", "status":"PASS", "cases":input.cases.map { $0.name }, "cms_verified":false, "device_executed":false]
let reportData = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(data: reportData, encoding: .utf8)!)
