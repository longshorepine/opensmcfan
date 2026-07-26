import Foundation

// MARK: - Temperature Sensor

/// A temperature reading from one SMC sensor.
public struct TemperatureReading {
    public let key: String
    public let label: String
    public let celsius: Double
}

// MARK: - Sensor Registry

/// Known SMC temperature sensor keys grouped by component.
public enum SensorGroup: String, CaseIterable {
    case cpu       = "CPU"
    case gpu       = "GPU"
    case memory    = "Memory"
    case heatsink  = "Heatsink"
    case ambient   = "Ambient"
    case battery   = "Battery"
    case northbridge = "Northbridge"
}

public struct SensorInfo {
    public let key: String
    public let label: String
    public let group: SensorGroup
}

/// All known temperature sensor keys.
public let knownSensors: [SensorInfo] = [
    // CPU
    SensorInfo(key: "TC0P", label: "CPU Proximity",   group: .cpu),
    SensorInfo(key: "TC0D", label: "CPU Die",         group: .cpu),
    SensorInfo(key: "TC0H", label: "CPU Heatsink",    group: .cpu),
    SensorInfo(key: "TC1C", label: "CPU Core 1",      group: .cpu),
    SensorInfo(key: "TC2C", label: "CPU Core 2",      group: .cpu),
    SensorInfo(key: "TC3C", label: "CPU Core 3",      group: .cpu),
    SensorInfo(key: "TCGC", label: "CPU GPU Compute",  group: .cpu),
    // GPU
    SensorInfo(key: "TG0P", label: "GPU Proximity",   group: .gpu),
    SensorInfo(key: "TG0D", label: "GPU Die",         group: .gpu),
    SensorInfo(key: "TG0H", label: "GPU Heatsink",    group: .gpu),
    SensorInfo(key: "TG1D", label: "GPU Die 2",       group: .gpu),
    SensorInfo(key: "TG1H", label: "GPU Heatsink 2",  group: .gpu),
    // Memory
    SensorInfo(key: "Tm0P", label: "Memory Slot 0",   group: .memory),
    SensorInfo(key: "Tm1P", label: "Memory Slot 1",   group: .memory),
    // Heatsink
    SensorInfo(key: "Th0H", label: "Heatsink 0",      group: .heatsink),
    SensorInfo(key: "Th1H", label: "Heatsink 1",      group: .heatsink),
    SensorInfo(key: "Th2H", label: "Heatsink 2",      group: .heatsink),
    // Ambient
    SensorInfo(key: "TA0P", label: "Ambient",          group: .ambient),
    // Battery
    SensorInfo(key: "TB0T", label: "Battery 0",       group: .battery),
    SensorInfo(key: "TB1T", label: "Battery 1",       group: .battery),
    SensorInfo(key: "TB2T", label: "Battery 2",       group: .battery),
    // Northbridge
    SensorInfo(key: "TN0P", label: "Northbridge",     group: .northbridge),
]

// MARK: - Temperature Monitor

/// Reads temperature sensors from the SMC.
public final class TemperatureMonitor {
    private let smc: SMCConnection

    /// Recent history per sensor (key → last N readings).
    public private(set) var history: [String: [Double]] = [:]

    /// Maximum history entries per sensor.
    public var historySize: Int = 60

    public init(smc: SMCConnection) {
        self.smc = smc
    }

    /// Read all known sensors. Returns only those that respond.
    public func readAll() -> [TemperatureReading] {
        var readings: [TemperatureReading] = []
        for sensor in knownSensors {
            if let val = try? smc.read(key: sensor.key),
               let celsius = val.doubleValue,
               celsius > 0 && celsius < 150 {  // filter garbage readings
                readings.append(TemperatureReading(
                    key: sensor.key,
                    label: sensor.label,
                    celsius: celsius
                ))
                // Update history
                var h = history[sensor.key] ?? []
                h.append(celsius)
                if h.count > historySize { h.removeFirst() }
                history[sensor.key] = h
            }
        }
        return readings
    }

    /// Read a specific sensor.
    public func read(key: String) -> Double? {
        guard let val = try? smc.read(key: key),
              let celsius = val.doubleValue,
              celsius > 0 && celsius < 150 else {
            return nil
        }
        return celsius
    }

    /// The hottest reading from the last readAll() call.
    public func hottest(from readings: [TemperatureReading]) -> TemperatureReading? {
        readings.max(by: { $0.celsius < $1.celsius })
    }

    /// Find sensor info by key.
    public static func sensorInfo(for key: String) -> SensorInfo? {
        knownSensors.first(where: { $0.key == key })
    }
}
