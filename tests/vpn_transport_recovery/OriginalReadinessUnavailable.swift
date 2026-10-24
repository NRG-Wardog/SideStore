        if decision.transport == .unavailable {
            return .failure(.invalidVPN(decision.reason))
        }