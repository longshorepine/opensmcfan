import Foundation

// MARK: - Fan Controller

/// Applies RPM targets to fans, respecting hardware limits.
public final class FanController {
    private let smc: SMCConnection
    private let reader: FanReader

    public init(smc: SMCConnection) {
        self.smc = smc
        self.reader = FanReader(smc: smc)
    }

    /// Set a fan to automatic (SMC-controlled) mode.
    public func setAuto(fan index: Int) throws {
        try reader.setMode(fan: index, forced: false)
    }

    /// Set all fans to automatic mode.
    public func setAllAuto(fanCount: Int) {
        for i in 0..<fanCount {
            try? reader.setMode(fan: i, forced: false)
        }
    }

    /// Set a fan to a fixed RPM target, clamped to hardware min/max.
    public func setFixed(fan index: Int, rpm: Double) throws {
        let fan = reader.readFan(index: index)
        let clamped = clampRPM(rpm, fan: fan)
        try reader.setMode(fan: index, forced: true)
        try reader.setTarget(fan: index, rpm: clamped)
    }

    /// Apply a target RPM from curve evaluation, with ramp-rate limiting.
    /// Returns the actual RPM that was set.
    @discardableResult
    public func applyCurveTarget(
        fan index: Int,
        targetRPM: Double,
        lastRPM: Double?,
        rampRate: Double,
        deltaTime: TimeInterval
    ) throws -> Double {
        let fan = reader.readFan(index: index)
        var target = clampRPM(targetRPM, fan: fan)

        // Apply ramp rate limiting
        if let last = lastRPM {
            let maxDelta = rampRate * deltaTime
            let diff = target - last
            if abs(diff) > maxDelta {
                target = last + (diff > 0 ? maxDelta : -maxDelta)
            }
        }

        try reader.setMode(fan: index, forced: true)
        try reader.setTarget(fan: index, rpm: target)
        return target
    }

    /// Clamp RPM to the fan's hardware min/max.
    private func clampRPM(_ rpm: Double, fan: Fan) -> Double {
        let lo = fan.minimum ?? 0
        let hi = fan.maximum ?? 6500
        return min(max(rpm, lo), hi)
    }
}
