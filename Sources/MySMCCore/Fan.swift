import Foundation

// MARK: - Fan Model

/// Snapshot of a single fan's state read from the SMC.
public struct Fan {
    public let index: Int
    public var label: String
    public var actual: Double?   // F{i}Ac — current RPM
    public var minimum: Double?  // F{i}Mn — hardware minimum RPM
    public var maximum: Double?  // F{i}Mx — hardware maximum RPM
    public var target: Double?   // F{i}Tg — target RPM

    public init(index: Int, label: String? = nil) {
        self.index = index
        self.label = label ?? "Fan \(index)"
    }
}

// MARK: - Fan Mode

public enum FanMode: String, Codable {
    case auto   = "auto"
    case fixed  = "fixed"
    case curve  = "curve"
}

// MARK: - Fan Reading

/// Reads all fan data from the SMC.
public struct FanReader {
    private let smc: SMCConnection

    public init(smc: SMCConnection) {
        self.smc = smc
    }

    /// Number of fans reported by the SMC.
    public func fanCount() throws -> Int {
        let val = try smc.read(key: "FNum")
        return val.intValue ?? 0
    }

    /// Read a single fan's state.
    public func readFan(index: Int) -> Fan {
        var fan = Fan(index: index)

        // Try to read the hardware-assigned fan name (e.g. "Left Fan", "Right Fan")
        if let val = try? smc.read(key: "F\(index)ID"),
           case .string(let name) = val {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { fan.label = trimmed }
        }

        let suffixes: [(String, WritableKeyPath<Fan, Double?>)] = [
            ("Ac", \.actual),
            ("Mn", \.minimum),
            ("Mx", \.maximum),
            ("Tg", \.target),
        ]
        for (suffix, keyPath) in suffixes {
            if let val = try? smc.read(key: "F\(index)\(suffix)"),
               let d = val.doubleValue {
                fan[keyPath: keyPath] = d
            }
        }
        return fan
    }

    /// Read all fans.
    public func readAllFans() -> [Fan] {
        guard let count = try? fanCount() else { return [] }
        return (0..<count).map { readFan(index: $0) }
    }

    /// Set target RPM for a fan.
    public func setTarget(fan index: Int, rpm: Double) throws {
        let bytes = SMCParser.encodeFPE2(rpm)
        try smc.writeRaw(key: "F\(index)Tg", bytes: bytes)
    }

    /// Set fan mode (0 = auto, 1 = forced/manual).
    public func setMode(fan index: Int, forced: Bool) throws {
        try smc.writeRaw(key: "F\(index)Md", bytes: [forced ? 1 : 0])
    }

    /// Set minimum RPM for a fan.
    public func setMinimum(fan index: Int, rpm: Double) throws {
        let bytes = SMCParser.encodeFPE2(rpm)
        try smc.writeRaw(key: "F\(index)Mn", bytes: bytes)
    }
}
