
@main struct ColdVPNCases {
    static func check(_ condition: Bool, _ name: String) { precondition(condition, name) }
    static let ready = MinimuxerOwnedReadinessObservation(result: .success(true), transient: nil)
    static let pending = MinimuxerOwnedReadinessObservation(result: .failure(.waiting), transient: .peerAddressPending)
    static func main() async throws {
        var time = 0.0, probes = 0, mutations = 0
        try await V3OwnedRefreshReadinessWait.run(probe: {
            probes += 1; return probes < 4 ? pending : ready
        }, checkOwnership: {}, now: { time }, sleep: { time += Double($0) / 1e9 })
        mutations += 1
        check(probes == 4 && mutations == 1, "cold endpoint readiness joins same attempt, mutation once")

        probes = 0; time = 0
        do {
            try await V3OwnedRefreshReadinessWait.run(probe: {
                probes += 1; return .init(result: .failure(.terminal), transient: nil)
            }, checkOwnership: {}, now: { time }, sleep: { _ in fatalError("terminal must not sleep") })
            fatalError("terminal error accepted")
        } catch MinimuxerError.terminal {}
        check(probes == 1 && mutations == 1, "terminal pairing/backend failure never retried")

        probes = 0; time = 0
        do {
            try await V3OwnedRefreshReadinessWait.run(probe: {
                probes += 1; return .init(result: .success(false), transient: nil)
            }, checkOwnership: {}, now: { time }, sleep: { _ in fatalError("UI false must not retry") })
            fatalError("nonowned UI observation accepted")
        } catch OperationError.minimuxerNotStarted {}
        check(probes == 1 && mutations == 1, "only true grants readiness")

        probes = 0; time = 0
        do {
            try await V3OwnedRefreshReadinessWait.run(probe: {
                probes += 1; return pending
            }, checkOwnership: {}, now: { time }, sleep: { time += Double($0) / 1e9 })
            fatalError("deadline bypassed")
        } catch OperationError.timedOut {}
        check(probes <= 12 && mutations == 1, "bounded probes, no mutation at deadline")

        probes = 0; time = 0
        do {
            try await V3OwnedRefreshReadinessWait.run(probe: {
                probes += 1; time = 11; return ready
            }, checkOwnership: {}, now: { time }, sleep: { _ in fatalError("late success cannot sleep/retry") })
            fatalError("late probe accepted")
        } catch OperationError.timedOut {}
        check(probes == 1 && mutations == 1, "inflight probe awaited then rejected, not detached")

        let lifetime = V3RefreshReadinessLifetime()
        time = 0; probes = 0
        do {
            try await V3OwnedRefreshReadinessWait.run(probe: {
                probes += 1; lifetime.expire(); return ready
            }, checkOwnership: { try lifetime.check() }, now: { time }, sleep: { _ in })
            fatalError("expired owner accepted")
        } catch OperationError.timedOut {}
        check(probes == 1 && lifetime.claimEnd() && !lifetime.claimEnd(), "expiry fences late result and ends once")

        time = 0; probes = 0; var ownershipChecks = 0
        do {
            try await V3OwnedRefreshReadinessWait.run(probe: { probes += 1; return ready }, checkOwnership: {
                ownershipChecks += 1
                if ownershipChecks == 2 { throw CancellationError() }
            }, now: { time }, sleep: { _ in })
            fatalError("changed lease admitted mutation")
        } catch is CancellationError {}
        check(probes == 1 && mutations == 1, "post-probe generation cancellation blocks success")

        let cancelled = Task {
            try await V3OwnedRefreshReadinessWait.run(probe: {
                withUnsafeCurrentTask { $0?.cancel() }; return ready
            }, checkOwnership: {}, now: { 0 }, sleep: { _ in })
        }
        do { try await cancelled.value; fatalError("cancelled probe accepted") }
        catch is CancellationError {}
        check(mutations == 1, "cancellation never enters mutation")
        for badClock in [Double.nan, Double.infinity, -1] {
            do {
                try await V3OwnedRefreshReadinessWait.run(probe: { fatalError("bad clock probed") },
                    checkOwnership: {}, now: { badClock }, sleep: { _ in })
                fatalError("invalid clock accepted")
            } catch OperationError.timedOut {}
        }
        var clockCalls = 0
        do {
            try await V3OwnedRefreshReadinessWait.run(probe: { ready }, checkOwnership: {},
                now: { clockCalls += 1; return clockCalls < 3 ? 1 : .nan }, sleep: { _ in })
            fatalError("invalid post-probe clock accepted")
        } catch OperationError.timedOut {}
        let endedFirst = V3RefreshReadinessLifetime()
        check(endedFirst.claimEnd(), "normal completion claims end")
        endedFirst.expire()
        check(!endedFirst.claimEnd(), "late expiry cannot end twice")
        do { try endedFirst.check(); fatalError("late expiry ignored") } catch OperationError.timedOut {}
        let raced = V3RefreshReadinessLifetime()
        let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<64 { group.addTask { raced.expire(); return raced.claimEnd() } }
            var count = 0
            for await won in group { if won { count += 1 } }
            return count
        }
        check(winners == 1, "concurrent expiry/completion ends exactly once")

        let handler = V3HeadlessPipelineHandler()
        let phaseLifetime = V3RefreshReadinessLifetime()
        handler.duringPhase = { phaseLifetime.expire() }
        do {
            try await extractedPhase(context: .init(handler: handler), downloadingApp: .init(), step: 0,
                                     appOperation: .refresh, refreshAdmission: { try phaseLifetime.check() })
            fatalError("phase await expiry admitted next step")
        } catch OperationError.timedOut {}
        try await extractedPhase(context: .init(handler: handler), downloadingApp: .init(), step: 0,
                                 appOperation: .install, refreshAdmission: { fatalError("nonrefresh changed") })

        let before = V3RefreshReadinessLifetime(), injection = InjectionEvidence.shared
        let blocked = InjectionHarness()
        CellularRefreshManager.shared.duringToggle = { before.expire() }
        do {
            _ = try await blocked.run(profiles: ["a": .init()], refreshAdmission: { try before.check() })
            fatalError("expired cellular await injected profile")
        } catch OperationError.timedOut {}
        check(injection.count == 0 && blocked.persisted == 0 && CellularRefreshManager.shared.restored == 1,
              "pre-injection expiry restores data without profile mutation")
        let after = V3RefreshReadinessLifetime(), admitted = InjectionHarness()
        CellularRefreshManager.shared.duringToggle = {}
        injection.afterInjection = { after.expire() }
        _ = try await admitted.run(profiles: ["a": .init(), "b": .init()], refreshAdmission: { try after.check() })
        check(injection.count == 2 && admitted.persisted == 1,
              "expiry after dispatch does not interrupt profile set or database persistence")

        let core = NativeCore()
        time = 0
        core.duringReadiness = { time = 30 }
        try await extractedNative(transportCore: core, checkReadinessOwnership: {})
        check(core.calls == 1 && time == 30, "native initialization once outside network grace deadline")
        let nativeLifetime = V3RefreshReadinessLifetime()
        core.duringReadiness = { nativeLifetime.expire() }
        do {
            try await extractedNative(transportCore: core, checkReadinessOwnership: { try nativeLifetime.check() })
            fatalError("expired native result admitted mutation")
        } catch OperationError.timedOut {}
        check(core.calls == 2, "native expiry never replays native initialization")
        core.duringReadiness = {}; core.result = .success(false)
        do {
            try await extractedNative(transportCore: core, checkReadinessOwnership: {})
            fatalError("false native readiness accepted")
        } catch OperationError.minimuxerNotStarted {}
        check(core.calls == 3, "false native readiness fails without retry")
        print("PASS owned readiness, exact native/phase/profile fragments and persistence; device networking not executed")
    }
}
