import Foundation

// MARK: - Fan Controller

/// Applies RPM targets to fans, respecting hardware limits.
public final class FanController {
    private let smc: SMCConnection
    private let reader: FanReader
    // Factory-minimum RPMs cached at startup — restored when returning to auto mode.
    // We cache these because setFixed writes to F{i}Mn, making future reads reflect
    // the forced value rather than the hardware floor.
    private var originalMins: [Int: Double] = [:]

    public init(smc: SMCConnection) {
        self.smc = smc
        self.reader = FanReader(smc: smc)
    }

    /// Cache each fan's factory-minimum RPM. Call once before any control operations.
    public func loadHardwareLimits(fanCount: Int) {
        for i in 0..<fanCount {
            let fan = reader.readFan(index: i)
            if let min = fan.minimum {
                originalMins[i] = min
            }
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
        let fan = reader.readFan(index: index)
        let clamped = clamp(rpm, for: fan, index: index)
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
        let fan = reader.readFan(index: index)
        var target = clamp(targetRPM, for: fan, index: index)

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

    // Clamp to hardware limits, using cached original min as the lower bound.
    // fan.minimum may reflect our own prior setFixed write, not the factory floor.
    private func clamp(_ rpm: Double, for fan: Fan, index: Int) -> Double {
        let lo = originalMins[index] ?? fan.minimum ?? 0
        let hi = fan.maximum ?? 6500
        return min(max(rpm, lo), hi)
    }
}
