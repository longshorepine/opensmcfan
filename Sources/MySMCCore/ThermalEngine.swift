import Foundation

// MARK: - Thermal Engine

/// The core runtime loop: reads temps → evaluates curves → sets fans.
///
/// Runs on a GCD timer. Thread-safe — all state is accessed on the engine queue.
public final class ThermalEngine {
    private let smc: SMCConnection
    private let fanController: FanController
    private let tempMonitor: TemperatureMonitor
    private let fanReader: FanReader

    private let engineQueue = DispatchQueue(label: "com.mysmc.engine", qos: .utility)
    private var timer: DispatchSourceTimer?

    // State
    private var activeProfile: Profile?
    private var lastTargets: [Int: Double] = [:]      // fanIndex → last written RPM
    private var lastTickTime: Date?
    private var spikeTimers: [Int: Date] = [:]         // fanIndex → when temp first exceeded threshold

    // Configuration
    public var pollingInterval: TimeInterval = 2.0
    public var emergencyThreshold: Double = 95.0       // °C — force all fans to max

    // Callbacks (called on engine queue)
    public var onUpdate: ((_ temps: [TemperatureReading], _ fans: [Fan]) -> Void)?

    public init(smc: SMCConnection) {
        self.smc = smc
        self.fanController = FanController(smc: smc)
        self.tempMonitor = TemperatureMonitor(smc: smc)
        self.fanReader = FanReader(smc: smc)
    }

    // MARK: - Start / Stop

    /// Start the engine with a given profile.
    public func start(profile: Profile) {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            // Cache hardware minimums so setFixed/setAuto can use correct floor/restore values
            self.fanController.loadHardwareLimits(fanCount: profile.fans.count)
            self.activeProfile = profile
            self.lastTargets = [:]
            self.lastTickTime = nil
            self.spikeTimers = [:]

            let timer = DispatchSource.makeTimerSource(queue: self.engineQueue)
            timer.schedule(
                deadline: .now(),
                repeating: self.pollingInterval
            )
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            self.timer?.cancel()
            self.timer = timer
            timer.resume()
        }
    }

    /// Stop the engine and reset all fans to auto.
    public func stop(resetToAuto: Bool = true) {
        engineQueue.sync {
            timer?.cancel()
            timer = nil

            if resetToAuto, let profile = activeProfile {
                fanController.setAllAuto(fanCount: profile.fans.count)
            }

            activeProfile = nil
            lastTargets = [:]
            lastTickTime = nil
        }
    }

    /// Switch to a new profile without stopping.
    public func switchProfile(_ profile: Profile) {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            // Reset fans from old profile to auto before applying new one
            if let old = self.activeProfile {
                self.fanController.setAllAuto(fanCount: old.fans.count)
            }
            self.activeProfile = profile
            self.lastTargets = [:]
            self.spikeTimers = [:]
            // Next tick will apply the new profile
        }
    }

    /// Update a single fan's config within the active profile.
    public func updateFanConfig(fanIndex: Int, config: FanConfig) {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            if let i = self.activeProfile?.fans.firstIndex(where: { $0.fanIndex == fanIndex }) {
                self.activeProfile?.fans[i] = config
                // Clear ramp state for this fan so new setting applies immediately
                self.lastTargets.removeValue(forKey: fanIndex)
                self.spikeTimers.removeValue(forKey: fanIndex)
            }
        }
    }

    // MARK: - Tick

    private func tick() {
        guard let profile = activeProfile else { return }

        let now = Date()
        let deltaTime = lastTickTime.map { now.timeIntervalSince($0) } ?? pollingInterval
        lastTickTime = now

        // 1. Read temperatures
        let temps = tempMonitor.readAll()
        let hottestTemp = temps.map(\.celsius).max() ?? 0

        // 2. Emergency check
        if hottestTemp >= emergencyThreshold {
            forceAllMax(profile: profile)
            let fans = fanReader.readAllFans()
            onUpdate?(temps, fans)
            return
        }

        // 3. Apply each fan's configuration
        for config in profile.fans {
            applyFanConfig(config, temps: temps, deltaTime: deltaTime)
        }

        // 4. Read back actual fan states and notify
        let fans = fanReader.readAllFans()
        onUpdate?(temps, fans)
    }

    private func applyFanConfig(
        _ config: FanConfig,
        temps: [TemperatureReading],
        deltaTime: TimeInterval
    ) {
        switch config.mode {
        case .auto:
            try? fanController.setAuto(fan: config.fanIndex)

        case .fixed:
            guard let rpm = config.fixedRPM else { return }
            try? fanController.setFixed(fan: config.fanIndex, rpm: rpm)

        case .curve:
            guard let curve = config.curve else { return }
            applyCurve(config: config, curve: curve, temps: temps, deltaTime: deltaTime)
        }
    }

    private func applyCurve(
        config: FanConfig,
        curve: FanCurve,
        temps: [TemperatureReading],
        deltaTime: TimeInterval
    ) {
        // Get reference temperature
        let refTemp: Double
        if let sensor = config.referenceSensor,
           let reading = temps.first(where: { $0.key == sensor }) {
            refTemp = reading.celsius
        } else {
            // Fallback to hottest
            refTemp = temps.map(\.celsius).max() ?? 0
        }

        // Evaluate curve
        let rawTarget = curve.evaluate(at: refTemp)

        // Apply response delay (filter transient spikes)
        let effectiveTarget: Double
        let lastTarget = lastTargets[config.fanIndex] ?? rawTarget

        if rawTarget > lastTarget {
            // Ramping up — check response delay
            if let spikeStart = spikeTimers[config.fanIndex] {
                if Date().timeIntervalSince(spikeStart) >= curve.responseDelay {
                    effectiveTarget = rawTarget
                } else {
                    effectiveTarget = lastTarget  // hold during delay
                }
            } else {
                spikeTimers[config.fanIndex] = Date()
                effectiveTarget = lastTarget
            }
        } else {
            // Ramping down — apply hysteresis
            spikeTimers[config.fanIndex] = nil
            let hysteresisTemp = refTemp + curve.hysteresis
            let hysteresisTarget = curve.evaluate(at: hysteresisTemp)
            effectiveTarget = min(rawTarget, max(hysteresisTarget, lastTarget))
        }

        // Apply with ramp rate
        if let applied = try? fanController.applyCurveTarget(
            fan: config.fanIndex,
            targetRPM: effectiveTarget,
            lastRPM: lastTargets[config.fanIndex],
            rampRate: curve.rampRate,
            deltaTime: deltaTime
        ) {
            lastTargets[config.fanIndex] = applied
        }
    }

    private func forceAllMax(profile: Profile) {
        for config in profile.fans {
            let fan = fanReader.readFan(index: config.fanIndex)
            let maxRPM = fan.maximum ?? 6500
            try? fanController.setFixed(fan: config.fanIndex, rpm: maxRPM)
            lastTargets[config.fanIndex] = maxRPM
        }
    }
}
