import Foundation

@main struct RegistryCases {
    static func main() {
        let original = "fixture." + UUID().uuidString
        let resigned = original + ".TEAM"
        let profile = UUID()
        let oldGeneration = UUID().uuidString
        let newGeneration = UUID().uuidString
        func contains(_ generation: String?) -> Bool {
            V3ValidatedReuseMainRegistry.contains(original: original, resigned: resigned, profileUUID: profile, generation: generation)
        }
        precondition(!contains(nil), "legacy payload is not enrolled")
        // A failed ordinary install never calls didInstall, regardless of
        // whether it reuses an existing profile UUID or generates a new nonce.
        precondition(!contains(newGeneration), "failed opt-in remains unregistered")
        V3ValidatedReuseMainRegistry.didInstall(original: original, resigned: resigned, profileUUID: profile, generation: oldGeneration)
        precondition(contains(oldGeneration))
        precondition(V3ValidatedReuseMainRegistry.hasAssociation(original: original, resigned: resigned))
        for _ in 0..<10 {
            precondition(!contains(UUID().uuidString), "failed candidate remains unregistered")
        }
        precondition(contains(oldGeneration), "failed opt-out and candidates retain installed opt-in")
        precondition(!V3ValidatedReuseMainRegistry.contains(original: original, resigned: resigned + ".other", profileUUID: profile, generation: oldGeneration))
        V3ValidatedReuseMainRegistry.didInstall(original: original, resigned: resigned, profileUUID: profile, generation: nil)
        precondition(!contains(oldGeneration), "confirmed opt-out clears old association")
        precondition(!V3ValidatedReuseMainRegistry.hasAssociation(original: original, resigned: resigned))
        print("ReuseMain registry: legacy, same-profile failed opt-in, failed opt-out, repeated failures, signed generation and confirmed opt-out checks passed")
    }
}
