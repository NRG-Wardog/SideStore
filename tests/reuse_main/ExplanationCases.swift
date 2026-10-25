import Foundation

@main struct ExplanationCases {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    static func main() {
        let offer = V3ReuseMainExplanation.offer(extensionCount: 3)
        require(offer.contains("up to 3 additional App IDs"), "Compatible estimate retains upper bound")
        require(offer.contains("avoiding 0 additional App IDs"), "Group fallback has no savings")
        require(offer.contains("not measured savings"), "No measured portal claim")
        let details = ["example.app.widget": ["appGroupsMismatch"], "example.app.share": ["keychainGroupsMismatch"]]
        let fallback = V3ReuseMainExplanation.fallback(reasonCodes: ["appGroupsMismatch", "keychainGroupsMismatch"], extensionReasonCodes: details, extensionCount: 3)
        require(fallback.contains("example.app.widget: app groups differ") && fallback.contains("example.app.share: keychain groups differ"), "Each rejected extension has a non-secret reason")
        require(fallback.contains("all 3 extensions stay installed") && fallback.contains("avoids 0 additional App IDs"), "Mixed rejection remains group fallback")
        require(fallback.range(of: "example.app.share")!.lowerBound < fallback.range(of: "example.app.widget")!.lowerBound, "Stable deterministic order")
        let unsafe = V3ReuseMainExplanation.fallback(reasonCodes: ["secret-value"], extensionReasonCodes: ["example.app\nsecret-value": ["secret-value"]], extensionCount: 1)
        require(!unsafe.contains("secret-value") && unsafe.contains("[unrecognized extension identifier]"), "Unrecognized values never leak")
        require(V3ReuseMainExplanation.identifier(String(repeating: "a", count: 256)) == "[unrecognized extension identifier]", "Identifier output bounded")
        require(V3ReuseMainExplanation.identifier("com.example.Widget-1_test") == "com.example.Widget-1_test", "Valid bundle identifier preserved")
        require(V3ReuseMainExplanation.reasonText(["appGroupsMismatch", "appGroupsMismatch"]) == "app groups differ", "Duplicate reason deterministic")
        require(V3ReuseMainExplanation.offer(extensionCount: -1).contains("all 0 extensions"), "Malformed count cannot advertise negative savings")
        print("PASS 11 ReuseMain explanation assertions; formatting only, no signing or device execution")
    }
}
