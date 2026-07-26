import Foundation

// MARK: - CLI Entry Point

let args = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    let usage = """
    MySMC — SMC Fan Control for Intel Macs

    USAGE:
      mysmc status                          Show fan speeds and temperatures
      mysmc set <fan> <rpm>                 Set fan target RPM
      mysmc auto [fan]                      Reset fan (or all) to automatic mode
      mysmc monitor [-i <seconds>]          Live monitor (Ctrl-C to stop)
      mysmc profile <name>                  Apply a built-in profile
      mysmc profile --list                  List available profiles
      mysmc curve <fan> <sensor> <t:rpm>... Set a custom fan curve

    PROFILES:
      auto        All fans under SMC automatic control
      quiet       All fans at minimum RPM
      balanced    Gentle temperature-reactive curve
      cool        Aggressive temperature-reactive curve
      max         All fans at maximum RPM

    EXAMPLES:
      mysmc status
      mysmc set 0 3500
      mysmc auto
      mysmc monitor -i 1
      mysmc profile balanced
      mysmc curve 0 TC0D 40:1200 55:2000 70:4000 85:6200
    """
    print(usage)
}

// MARK: - Commands

func cmdStatus(smc: SMCConnection) {
    let tempMonitor = TemperatureMonitor(smc: smc)
    let fanReader = FanReader(smc: smc)

    let temps = tempMonitor.readAll()
    let fans = fanReader.readAllFans()

    // Hottest temp
    if let hottest = tempMonitor.hottest(from: temps) {
        print("Hottest: \(hottest.label) (\(hottest.key)) = \(String(format: "%.0f", hottest.celsius))°C")
    }
    print()

    // Fans
    for fan in fans {
        print("Fan \(fan.index):")
        print("  Actual:  \(fan.actual.map { String(format: "%.0f RPM", $0) } ?? "? RPM")")
        print("  Target:  \(fan.target.map { String(format: "%.0f RPM", $0) } ?? "? RPM")")
        print("  Min:     \(fan.minimum.map { String(format: "%.0f RPM", $0) } ?? "? RPM")")
        print("  Max:     \(fan.maximum.map { String(format: "%.0f RPM", $0) } ?? "? RPM")")
        print()
    }

    // Temperatures
    if !temps.isEmpty {
        print("Temperatures:")
        // Group by component
        for group in SensorGroup.allCases {
            let groupTemps = temps.filter { reading in
                TemperatureMonitor.sensorInfo(for: reading.key)?.group == group
            }
            if !groupTemps.isEmpty {
                print("  \(group.rawValue):")
                for t in groupTemps {
                    print("    \(t.key) (\(t.label)): \(String(format: "%.0f", t.celsius))°C")
                }
            }
        }
    }
}

func cmdSet(smc: SMCConnection, fanIndex: Int, rpm: Int) {
    let fanReader = FanReader(smc: smc)
    let controller = FanController(smc: smc)

    do {
        try controller.setFixed(fan: fanIndex, rpm: Double(rpm))
        print("Set Fan \(fanIndex) target → \(rpm) RPM")

        // Brief delay, then show actual
        Thread.sleep(forTimeInterval: 0.3)
        let fan = fanReader.readFan(index: fanIndex)
        print("  Now: Actual=\(fan.actual.map { String(format: "%.0f", $0) } ?? "?")  Target=\(fan.target.map { String(format: "%.0f", $0) } ?? "?")")
    } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdAuto(smc: SMCConnection, fanIndex: Int?) {
    let fanReader = FanReader(smc: smc)
    let controller = FanController(smc: smc)

    let indices: [Int]
    if let idx = fanIndex {
        indices = [idx]
    } else {
        let count = (try? fanReader.fanCount()) ?? 2
        indices = Array(0..<count)
    }

    for idx in indices {
        do {
            try controller.setAuto(fan: idx)
            print("Fan \(idx) set to AUTO mode")
            Thread.sleep(forTimeInterval: 0.3)
            let fan = fanReader.readFan(index: idx)
            print("  Now: Actual=\(fan.actual.map { String(format: "%.0f", $0) } ?? "?")  Target=\(fan.target.map { String(format: "%.0f", $0) } ?? "?")")
        } catch {
            print("Error setting Fan \(idx) to auto: \(error.localizedDescription)")
        }
    }
}

func cmdMonitor(smc: SMCConnection, interval: TimeInterval) {
    let tempMonitor = TemperatureMonitor(smc: smc)
    let fanReader = FanReader(smc: smc)

    // Handle Ctrl-C gracefully
    signal(SIGINT) { _ in
        print()
        exit(0)
    }

    print("Monitoring (Ctrl-C to stop)...\n")

    while true {
        let temps = tempMonitor.readAll()
        let fans = fanReader.readAllFans()
        let hottest = temps.map(\.celsius).max() ?? 0

        let fanStr = fans.map { fan in
            "F\(fan.index)=\(fan.actual.map { String(format: "%.0f", $0) } ?? "?")RPM"
        }.joined(separator: "  ")

        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("\r\(time)  \(String(format: "%.0f", hottest))°C  \(fanStr)", terminator: "")
        fflush(stdout)

        Thread.sleep(forTimeInterval: interval)
    }
}

func cmdProfile(smc: SMCConnection, name: String) {
    let fanReader = FanReader(smc: smc)
    let controller = FanController(smc: smc)

    let fans = fanReader.readAllFans()
    let fanCount = fans.count
    guard fanCount > 0 else {
        print("Error: No fans detected")
        exit(1)
    }

    let profile: Profile
    switch name {
    case "auto":      profile = .autoProfile(fans: fans)
    case "quiet":     profile = .quietProfile(fans: fans)
    case "balanced":  profile = .balancedProfile(fans: fans)
    case "cool":      profile = .coolProfile(fans: fans)
    case "max":       profile = .maxProfile(fans: fans)
    default:
        // Try loading from disk
        let store = ProfileStore()
        guard let loaded = try? store.load(id: name) else {
            print("Unknown profile '\(name)'. Available: auto, quiet, balanced, cool, max")
            print("Or use 'mysmc profile --list' to see saved profiles.")
            exit(1)
        }
        profile = loaded
    }

    print("Applying profile: \(profile.name)")
    print("  \(profile.description)")
    print()

    for config in profile.fans {
        switch config.mode {
        case .auto:
            try? controller.setAuto(fan: config.fanIndex)
            print("  Fan \(config.fanIndex): AUTO")
        case .fixed:
            let fanMin = fans.first(where: { $0.index == config.fanIndex })?.minimum ?? 1200
            let rpm = config.fixedRPM ?? fanMin
            try? controller.setFixed(fan: config.fanIndex, rpm: rpm)
            print("  Fan \(config.fanIndex): \(String(format: "%.0f", rpm)) RPM (fixed)")
        case .curve:
            // For CLI one-shot, evaluate curve at current temp
            let tempMonitor = TemperatureMonitor(smc: smc)
            let temps = tempMonitor.readAll()
            let refTemp: Double
            if let sensor = config.referenceSensor,
               let reading = temps.first(where: { $0.key == sensor }) {
                refTemp = reading.celsius
            } else {
                refTemp = temps.map(\.celsius).max() ?? 50
            }
            if let curve = config.curve {
                let rpm = curve.evaluate(at: refTemp)
                try? controller.setFixed(fan: config.fanIndex, rpm: rpm)
                print("  Fan \(config.fanIndex): \(String(format: "%.0f", rpm)) RPM (curve @ \(String(format: "%.0f", refTemp))°C)")
            }
        }
    }
}

func cmdProfileList() {
    let store = ProfileStore()
    let profiles = store.loadAll()

    print("Built-in profiles:")
    print("  auto       — All fans under SMC automatic control")
    print("  quiet      — All fans at minimum RPM")
    print("  balanced   — Gentle temperature-reactive curve")
    print("  cool       — Aggressive temperature-reactive curve")
    print("  max        — All fans at maximum RPM")

    let userProfiles = profiles.filter { !$0.builtIn }
    if !userProfiles.isEmpty {
        print()
        print("User profiles:")
        for p in userProfiles {
            print("  \(p.id.padding(toLength: 12, withPad: " ", startingAt: 0)) — \(p.description)")
        }
    }
}

func cmdCurve(smc: SMCConnection, fanIndex: Int, sensor: String, pointArgs: [String]) {
    let controller = FanController(smc: smc)

    // Parse points: "40:1200" "55:2000" ...
    var points: [FanCurvePoint] = []
    for arg in pointArgs {
        let parts = arg.split(separator: ":")
        guard parts.count == 2,
              let temp = Double(parts[0]),
              let rpm = Double(parts[1]) else {
            print("Error: Invalid curve point '\(arg)'. Expected format: <temp>:<rpm> (e.g., 40:1200)")
            exit(1)
        }
        points.append(FanCurvePoint(temperature: temp, rpm: rpm))
    }

    guard points.count >= 2 else {
        print("Error: Need at least 2 curve points")
        exit(1)
    }

    let curve = FanCurve(points: points)

    // Evaluate at current temp
    let tempMonitor = TemperatureMonitor(smc: smc)
    let temps = tempMonitor.readAll()
    let refTemp: Double
    if let reading = temps.first(where: { $0.key == sensor }) {
        refTemp = reading.celsius
    } else {
        print("Warning: Sensor '\(sensor)' not found, using hottest available")
        refTemp = temps.map(\.celsius).max() ?? 50
    }

    let rpm = curve.evaluate(at: refTemp)
    do {
        try controller.setFixed(fan: fanIndex, rpm: rpm)
        print("Fan \(fanIndex) curve set (sensor: \(sensor)):")
        for p in curve.points {
            let marker = (refTemp >= p.temperature - 1 && refTemp <= p.temperature + 1) ? " ←" : ""
            print("  \(String(format: "%5.0f", p.temperature))°C → \(String(format: "%5.0f", p.rpm)) RPM\(marker)")
        }
        print()
        print("Current: \(String(format: "%.0f", refTemp))°C → \(String(format: "%.0f", rpm)) RPM")
        print()
        print("Note: This is a one-shot evaluation. For continuous curve control,")
        print("use the MySMC GUI app or run 'mysmc profile' with a saved curve profile.")
    } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
    }
}

// MARK: - Argument Parsing

guard !args.isEmpty else {
    printUsage()
    exit(0)
}

do {
    let smc = try SMCConnection()

    switch args[0] {
    case "status":
        cmdStatus(smc: smc)

    case "set":
        guard args.count >= 3,
              let fan = Int(args[1]),
              let rpm = Int(args[2]) else {
            print("Usage: mysmc set <fan> <rpm>")
            exit(1)
        }
        cmdSet(smc: smc, fanIndex: fan, rpm: rpm)

    case "auto":
        let fan = args.count >= 2 ? Int(args[1]) : nil
        cmdAuto(smc: smc, fanIndex: fan)

    case "monitor":
        var interval: TimeInterval = 2.0
        if let idx = args.firstIndex(of: "-i"), idx + 1 < args.count,
           let val = Double(args[idx + 1]) {
            interval = val
        }
        cmdMonitor(smc: smc, interval: interval)

    case "profile":
        if args.count >= 2 {
            if args[1] == "--list" {
                cmdProfileList()
            } else {
                cmdProfile(smc: smc, name: args[1])
            }
        } else {
            print("Usage: mysmc profile <name>  or  mysmc profile --list")
            exit(1)
        }

    case "curve":
        guard args.count >= 5 else {
            print("Usage: mysmc curve <fan> <sensor> <temp:rpm> <temp:rpm> ...")
            print("Example: mysmc curve 0 TC0D 40:1200 55:2000 70:4000 85:6200")
            exit(1)
        }
        guard let fan = Int(args[1]) else {
            print("Error: Invalid fan index '\(args[1])'")
            exit(1)
        }
        let sensor = args[2]
        let pointArgs = Array(args[3...])
        cmdCurve(smc: smc, fanIndex: fan, sensor: sensor, pointArgs: pointArgs)

    case "-h", "--help", "help":
        printUsage()

    default:
        print("Unknown command: \(args[0])")
        printUsage()
        exit(1)
    }

    smc.close()

} catch {
    print("Error: \(error.localizedDescription)")
    exit(1)
}
