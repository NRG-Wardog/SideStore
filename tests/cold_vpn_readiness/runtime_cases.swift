
@main struct ColdVPNCases {
    static func check(_ condition: Bool, _ name: String) { precondition(condition, name) }
    static let ready = MinimuxerOwnedReadinessObservation(result: .success(true), transient: nil)
    static let pending = MinimuxerOwnedReadinessObservation(result: .failure(.waiting), transient: .peerAddressPending)
    static func main() async throws {
        try await typedGraceCases()
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
        } catch MinimuxerError.waiting {}
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

        let baselineLifetime = V3RefreshReadinessLifetime(), baselineBlocked = InjectionHarness()
        baselineBlocked.duringRead = { baselineLifetime.expire() }
        do {
            _ = try await baselineBlocked.run(profiles: ["a": .init()], refreshAdmission: { try baselineLifetime.check() })
            fatalError("expired baseline read injected profile")
        } catch OperationError.timedOut {}
        check(baselineBlocked.reads == 1 && InjectionEvidence.shared.count == 0 && baselineBlocked.persisted == 0 &&
              CellularRefreshManager.shared.restored == 0,
              "baseline read expiry blocks before cellular toggle and mutation")

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

extension ColdVPNCases {
    static func typedGraceCases() async throws {
        let observations: [(MinimuxerError, MinimuxerOwnedReadinessTransient)] = [
            (.noVPN, .vpnInterfacePending), (.noDevice, .peerAddressPending),
            (.invalidVPN, .peerProbePending), (.noConnection, .wifiPending)]
        for (expected, transient) in observations {
            var time = 0.0, count = 0
            do {
                try await V3OwnedRefreshReadinessWait.run(probe: {
                    count += 1; time += 0.097
                    if count == 11 { time = 9.466 }
                    return .init(result: .failure(expected), transient: transient)
                }, checkOwnership: {}, now: { time }, sleep: { time += Double($0) / 1e9 })
                fatalError("persistent typed negative accepted")
            } catch let error as MinimuxerError { check(error == expected, "fresh negative type retained") }
            check(count == 11 && time < 10, "eleven pending observations end without unproductive deadline sleep")
        }
        // The latest observation wins. In particular a newly lost Wi-Fi path
        // must not reuse an earlier VPN negative to authorize a handoff.
        var time = 0.0, count = 0
        do {
            try await V3OwnedRefreshReadinessWait.run(probe: {
                count += 1
                return .init(result: .failure(count == 1 ? .noVPN : .noConnection),
                             transient: count == 1 ? .vpnInterfacePending : .wifiPending)
            }, checkOwnership: {}, now: { time }, sleep: { time += Double($0) / 1e9 })
            fatalError("latest negative accepted")
        } catch MinimuxerError.noConnection {}
        check(count > 1, "no stale VPN reason")
        // Frozen monotonic time exercises the independent maximum-probe fence.
        count = 0
        do {
            try await V3OwnedRefreshReadinessWait.run(probe: {
                count += 1; return .init(result: .failure(.noVPN), transient: .vpnInterfacePending)
            }, checkOwnership: {}, now: { 0 }, sleep: { _ in })
            fatalError("maximum probes accepted")
        } catch MinimuxerError.noVPN {}
        check(count == 12, "maximum probes retain current typed negative")
        for remaining in [0.2 - 0.000001, 0.2, 0.2 + 0.000001] {
            time = 0; count = 0; var sleeps = 0
            do {
                try await V3OwnedRefreshReadinessWait.run(probe: {
                    count += 1; time = 10 - remaining
                    return .init(result: .failure(.noVPN), transient: .vpnInterfacePending)
                }, checkOwnership: {}, now: { time }, sleep: { _ in sleeps += 1; time = 11 })
                fatalError("boundary accepted")
            } catch MinimuxerError.noVPN { check(remaining <= 0.2, "typed boundary only while fresh") }
            catch OperationError.timedOut { check(remaining > 0.2, "oversleep retains generic timeout") }
            check(sleeps == (remaining > 0.2 ? 1 : 0), "nominal next delay admission boundary")
        }
        // A returned failure is no more authoritative than a returned success
        // after its probe has exceeded the grace deadline.
        for lateResult in [MinimuxerOwnedReadinessObservation(result: .failure(.noVPN), transient: .vpnInterfacePending), ready] {
            time = 0
            do {
                try await V3OwnedRefreshReadinessWait.run(probe: { time = 11; return lateResult },
                    checkOwnership: {}, now: { time }, sleep: { _ in fatalError("late result slept") })
                fatalError("late result accepted")
            } catch OperationError.timedOut {}
        }
        // Time can cross the deadline between the post-probe and scheduling
        // reads. No negative may then escape as fresh recovery evidence.
        var reads = 0
        do {
            try await V3OwnedRefreshReadinessWait.run(probe: {
                .init(result: .failure(.noVPN), transient: .vpnInterfacePending)
            }, checkOwnership: {}, now: { reads += 1; return reads < 4 ? 0 : 11 }, sleep: { _ in fatalError("expired scheduling slept") })
            fatalError("expired scheduling accepted")
        } catch OperationError.timedOut {}
        // A stale core/mode/configuration returns success(false) from the actual
        // producer; never retain a previous negative across that observation.
        count = 0; time = 0
        do {
            try await V3OwnedRefreshReadinessWait.run(probe: {
                count += 1
                return count == 1 ? .init(result: .failure(.noVPN), transient: .vpnInterfacePending)
                                  : .init(result: .success(false), transient: nil)
            }, checkOwnership: {}, now: { time }, sleep: { time += Double($0) / 1e9 })
            fatalError("stale observation reused")
        } catch OperationError.minimuxerNotStarted {}
        check(count == 2, "invalid ownership observation never becomes VPN evidence")
        for expire in [false, true] {
            let lifetime = V3RefreshReadinessLifetime()
            var checks = 0; time = 0
            do {
                try await V3OwnedRefreshReadinessWait.run(probe: {
                    time = 9.9
                    return .init(result: .failure(.noVPN), transient: .vpnInterfacePending)
                }, checkOwnership: {
                    checks += 1
                    if checks == 3 {
                        if expire { lifetime.expire() } else { throw CancellationError() }
                    }
                    try lifetime.check()
                }, now: { time }, sleep: { _ in fatalError("terminal negative slept") })
                fatalError("terminal ownership loss accepted")
            } catch is CancellationError { check(!expire, "cancel takes precedence") }
            catch OperationError.timedOut { check(expire, "expiry takes precedence") }
            check(checks == 3, "terminal negative rechecks ownership")
        }
        print("PASS fresh typed grace, eleven observations, four conditions, boundary and ownership races")
    }
}
