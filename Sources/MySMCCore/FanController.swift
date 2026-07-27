import Foundation

// MARK: - Fan Controller

/// Applies RPM targets to fans, respecting hardware limits.
public final class FanController {
    private let smc: SMCConnection
    private let reader: FanReader
    // Hardware limits cached at startup — min is restored when returning to auto mode.
    // We cache min because setFixed writes to F{i}Mn, making future reads reflect
    // the forced value rather than the hardware floor.
    // We cache max to avoid redundant SMC reads on every tick (max never changes).
    private var originalMins: [Int: Double] = [:]
    private var originalMaxs: [Int: Double] = [:]

    public init(smc: SMCConnection) {
        self.smc = smc
        self.reader = FanReader(smc: smc)
    }

    /// Cache each fan's factory min/max RPM. Call once before any control operations.
    public func loadHardwareLimits(fanCount: Int) {
        for i in 0..<fanCount {
            let fan = reader.readFan(index: i)
            if let min = fan.minimum { originalMins[i] = min }
            if let max = fan.maximum { originalMaxs[i] = max }
        }
    }

    /// Set a fan to automatic (SMC-controlled) mode, restoring its factory minimum.
    public func setAuto(fan index: Int) throws {
        // Restore original minimum so the SMC auto-algorithm has the right floor
        if let original = originalMins[index] {
            try? reader.setMinimum(fan: index, rpm: original)   // best-effort
        }
        try reader.setMode(fan: index, forced: false)
    }

    /// Set all fans to automatic mode.
    public func setAllAuto(fanCount: Int) {
        for i in 0..<fanCount {
            try? setAuto(fan: i)
        }
    }

    /// Set a fan to a fixed RPM target, clamped to hardware min/max.
    ///
    /// Uses both the minimum-RPM method (most compatible across Mac models) and
    /// forced-mode+target for belt-and-suspenders coverage.
    public func setFixed(fan index: Int, rpm: Double) throws {
        let clamped = clampToLimits(rpm, fan: index)
        try reader.setMinimum(fan: index, rpm: clamped)   // primary: works on all Intel Macs
        try? reader.setMode(fan: index, forced: true)      // secondary: direct override
        try? reader.setTarget(fan: index, rpm: clamped)    // secondary: target
    }

    /// Apply a curve-evaluated RPM with ramp-rate limiting.
    /// Returns the actual RPM written.
    @discardableResult
    public func applyCurveTarget(
        fan index: Int,
        targetRPM: Double,
        lastRPM: Double?,
        rampRate: Double,
        deltaTime: TimeInterval
    ) throws -> Double {
        var target = clampToLimits(targetRPM, fan: index)

        if let last = lastRPM {
            let maxDelta = rampRate * deltaTime
            let diff = target - last
            if abs(diff) > maxDelta {
                target = last + (diff > 0 ? maxDelta : -maxDelta)
            }
        }

        try reader.setMinimum(fan: index, rpm: target)    // primary
        try? reader.setMode(fan: index, forced: true)      // secondary
        try? reader.setTarget(fan: index, rpm: target)     // secondary
        return target
    }

    // Clamp to cached hardware limits. Uses startup-cached values so we don't
    // re-read from SMC on every tick, and so min reflects the factory floor
    // (not our own prior setMinimum write).
    private func clampToLimits(_ rpm: Double, fan index: Int) -> Double {
        let lo = originalMins[index] ?? 0
        let hi = originalMaxs[index] ?? 6500
        return min(max(rpm, lo), hi)
    }
}
