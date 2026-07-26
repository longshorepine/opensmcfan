import Foundation

// MARK: - Fan Configuration (per-fan within a profile)

/// Configuration for a single fan within a profile.
public struct FanConfig: Codable {
    public var fanIndex: Int
    public var label: String
    public var mode: FanMode
    public var fixedRPM: Double?           // used when mode == .fixed
    public var referenceSensor: String?    // used when mode == .curve
    public var curve: FanCurve?            // used when mode == .curve

    public init(
        fanIndex: Int,
        label: String = "",
        mode: FanMode = .auto,
        fixedRPM: Double? = nil,
        referenceSensor: String? = nil,
        curve: FanCurve? = nil
    ) {
        self.fanIndex = fanIndex
        self.label = label.isEmpty ? "Fan \(fanIndex)" : label
        self.mode = mode
        self.fixedRPM = fixedRPM
        self.referenceSensor = referenceSensor
        self.curve = curve
    }
}

// MARK: - Profile

/// A named collection of per-fan configurations.
public struct Profile: Codable, Identifiable {
    public var id: String          // unique identifier (filename stem)
    public var name: String
    public var icon: String        // SF Symbol name or emoji
    public var description: String
    public var builtIn: Bool       // built-in profiles can't be deleted
    public var created: Date
    public var modified: Date
    public var fans: [FanConfig]

    public init(
        id: String? = nil,
        name: String,
        icon: String = "fan",
        description: String = "",
        builtIn: Bool = false,
        fans: [FanConfig] = []
    ) {
        self.id = id ?? name.lowercased().replacingOccurrences(of: " ", with: "_")
        self.name = name
        self.icon = icon
        self.description = description
        self.builtIn = builtIn
        self.created = Date()
        self.modified = Date()
        self.fans = fans
    }

    // MARK: - Built-in profiles
    //
    // All factories take the actual [Fan] list read from hardware so each fan
    // gets its own min/max limits rather than inheriting from fan 0.
    // referenceSensor is nil for curve profiles → engine falls back to hottest
    // sensor, which works correctly on any Mac model.

    /// All fans under SMC automatic control.
    public static func autoProfile(fans: [Fan]) -> Profile {
        Profile(
            id: "auto",
            name: "Auto",
            icon: "a.circle",
            description: "All fans under SMC automatic control",
            builtIn: true,
            fans: fans.map { FanConfig(fanIndex: $0.index, label: $0.label, mode: .auto) }
        )
    }

    /// All fans at their individual hardware minimum.
    public static func quietProfile(fans: [Fan]) -> Profile {
        Profile(
            id: "quiet",
            name: "Quiet",
            icon: "speaker.slash",
            description: "All fans at minimum RPM — nearly silent",
            builtIn: true,
            fans: fans.map {
                FanConfig(fanIndex: $0.index, label: $0.label,
                          mode: .fixed, fixedRPM: $0.minimum ?? 1200)
            }
        )
    }

    /// Gentle curve ramp, tuned per-fan.
    public static func balancedProfile(fans: [Fan]) -> Profile {
        Profile(
            id: "balanced",
            name: "Balanced",
            icon: "dial.min",
            description: "Gentle ramp — moderate cooling with low noise",
            builtIn: true,
            fans: fans.map {
                let lo = $0.minimum ?? 1200
                let hi = $0.maximum ?? 6200
                return FanConfig(
                    fanIndex: $0.index, label: $0.label,
                    mode: .curve, referenceSensor: nil,   // nil → hottest sensor on any Mac
                    curve: .balanced(minRPM: lo, maxRPM: hi)
                )
            }
        )
    }

    /// Aggressive curve ramp, tuned per-fan.
    public static func coolProfile(fans: [Fan]) -> Profile {
        Profile(
            id: "cool",
            name: "Cool",
            icon: "snowflake",
            description: "Aggressive ramp — maximum cooling priority",
            builtIn: true,
            fans: fans.map {
                let lo = $0.minimum ?? 1200
                let hi = $0.maximum ?? 6200
                return FanConfig(
                    fanIndex: $0.index, label: $0.label,
                    mode: .curve, referenceSensor: nil,   // nil → hottest sensor on any Mac
                    curve: .cool(minRPM: lo, maxRPM: hi)
                )
            }
        )
    }

    /// All fans at their individual hardware maximum.
    public static func maxProfile(fans: [Fan]) -> Profile {
        Profile(
            id: "max",
            name: "Max",
            icon: "flame",
            description: "All fans at maximum RPM — full blast",
            builtIn: true,
            fans: fans.map {
                FanConfig(fanIndex: $0.index, label: $0.label,
                          mode: .fixed, fixedRPM: $0.maximum ?? 6200)
            }
        )
    }
}
