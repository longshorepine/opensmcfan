import AppKit

// MARK: - Dashboard Delegate

/// Callback protocol for user actions in the dashboard popover.
protocol DashboardDelegate: AnyObject {
    func dashboardDidChangeFanMode(fanIndex: Int, mode: FanMode)
    func dashboardDidChangeFanRPM(fanIndex: Int, rpm: Double)
    func dashboardDidSelectProfile(id: String)
    func availableProfiles() -> [(id: String, name: String)]
    func activeProfileId() -> String
    func fanMode(for index: Int) -> FanMode
    func fanTargetRPM(for index: Int) -> Double?
}

// MARK: - Status Bar Controller

/// Manages the menu bar icon, popover dashboard, fan control, and profile switching.
final class StatusBarController: NSObject, DashboardDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let smc: SMCConnection
    private let engine: ThermalEngine
    private let fanReader: FanReader
    private let tempMonitor: TemperatureMonitor
    private let dashboardVC: DashboardViewController
    private var eventMonitor: Any?

    // Profile state
    private var profiles: [(id: String, name: String)] = []
    private var currentProfileId: String = "auto"
    private var workingProfile: Profile!

    // Fan state (working copy — overrides from user interaction)
    private var fanModes: [Int: FanMode] = [:]
    private var fanTargetRPMs: [Int: Double] = [:]
    private var fanCount: Int = 0
    private var minRPM: Double = 1200
    private var maxRPM: Double = 6200

    init(smc: SMCConnection) {
        self.smc = smc
        self.engine = ThermalEngine(smc: smc)
        self.fanReader = FanReader(smc: smc)
        self.tempMonitor = TemperatureMonitor(smc: smc)
        self.dashboardVC = DashboardViewController()

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.popover.contentViewController = dashboardVC
        self.popover.behavior = .transient

        super.init()

        dashboardVC.delegate = self

        // Read hardware info
        let fans = fanReader.readAllFans()
        fanCount = fans.count
        if let first = fans.first {
            minRPM = first.minimum ?? 1200
            maxRPM = first.maximum ?? 6200
        }

        // Build profile list
        profiles = [
            (id: "auto",     name: "Auto"),
            (id: "quiet",    name: "Quiet"),
            (id: "balanced", name: "Balanced"),
            (id: "cool",     name: "Cool"),
            (id: "max",      name: "Max"),
        ]

        // Start with Auto profile
        workingProfile = makeProfile(id: "auto")
        for i in 0..<fanCount {
            fanModes[i] = .auto
        }

        // Configure status bar button
        if let button = statusItem.button {
            button.title = "--°C"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Close popover on outside click
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            if let self = self, self.popover.isShown {
                self.popover.performClose(nil)
            }
        }

        // Start thermal engine
        engine.onUpdate = { [weak self] temps, fans in
            self?.handleEngineUpdate(temps: temps, fans: fans)
        }
        engine.start(profile: workingProfile)
    }

    func shutdown() {
        engine.stop(resetToAuto: true)
        smc.close()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Engine Update → UI

    private func handleEngineUpdate(temps: [TemperatureReading], fans: [Fan]) {
        let hottestTemp = temps.map(\.celsius).max() ?? 0

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Update menu bar
            if hottestTemp > 0 {
                let color: NSColor
                if hottestTemp >= 90 { color = .systemRed }
                else if hottestTemp >= 75 { color = .systemOrange }
                else { color = .labelColor }

                self.statusItem.button?.attributedTitle = NSAttributedString(
                    string: String(format: "%.0f°C", hottestTemp),
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: color,
                    ]
                )
            }

            // Update dashboard
            self.dashboardVC.update(temps: temps, fans: fans)
        }
    }

    // MARK: - Click Handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Right-Click Menu

    private func showMenu() {
        let menu = NSMenu()

        // Profile submenu
        let profileMenu = NSMenu()
        for profile in profiles {
            let item = NSMenuItem(
                title: profile.name,
                action: #selector(menuProfileSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == currentProfileId ? .on : .off
            profileMenu.addItem(item)
        }
        let profileItem = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        profileItem.submenu = profileMenu
        menu.addItem(profileItem)

        menu.addItem(NSMenuItem.separator())

        // Temperature + fan summary
        let temps = tempMonitor.readAll()
        if let hottest = tempMonitor.hottest(from: temps) {
            let item = NSMenuItem(
                title: "\(hottest.label): \(String(format: "%.0f", hottest.celsius))°C",
                action: nil, keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }
        let fans = fanReader.readAllFans()
        for fan in fans {
            let rpmStr = fan.actual.map { String(format: "%.0f RPM", $0) } ?? "-- RPM"
            let item = NSMenuItem(title: "Fan \(fan.index): \(rpmStr)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About MySMC", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit MySMC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuProfileSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        applyProfile(id: id)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "MySMC"
        alert.informativeText = "Open-source SMC Fan Control for Intel Macs\nVersion 1.0.0"
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Profile Management

    private func makeProfile(id: String) -> Profile {
        switch id {
        case "auto":     return .autoProfile(fanCount: fanCount)
        case "quiet":    return .quietProfile(fanCount: fanCount, minRPM: minRPM)
        case "balanced": return .balancedProfile(fanCount: fanCount, minRPM: minRPM, maxRPM: maxRPM)
        case "cool":     return .coolProfile(fanCount: fanCount, minRPM: minRPM, maxRPM: maxRPM)
        case "max":      return .maxProfile(fanCount: fanCount, maxRPM: maxRPM)
        default:         return .autoProfile(fanCount: fanCount)
        }
    }

    private func applyProfile(id: String) {
        currentProfileId = id
        workingProfile = makeProfile(id: id)

        // Sync local fan state from profile
        for config in workingProfile.fans {
            fanModes[config.fanIndex] = config.mode
            if let rpm = config.fixedRPM {
                fanTargetRPMs[config.fanIndex] = rpm
            }
        }

        // Apply to engine (full switch — resets ramp state)
        engine.switchProfile(workingProfile)

        // Refresh dashboard controls
        DispatchQueue.main.async { [weak self] in
            self?.dashboardVC.refreshControls()
        }
    }

    // MARK: - DashboardDelegate

    func dashboardDidChangeFanMode(fanIndex: Int, mode: FanMode) {
        fanModes[fanIndex] = mode

        guard let i = workingProfile.fans.firstIndex(where: { $0.fanIndex == fanIndex }) else { return }

        workingProfile.fans[i].mode = mode
        if mode == .fixed {
            let rpm = fanTargetRPMs[fanIndex] ?? workingProfile.fans[i].fixedRPM ?? minRPM
            workingProfile.fans[i].fixedRPM = rpm
            fanTargetRPMs[fanIndex] = rpm
        }

        engine.updateFanConfig(fanIndex: fanIndex, config: workingProfile.fans[i])
    }

    func dashboardDidChangeFanRPM(fanIndex: Int, rpm: Double) {
        fanTargetRPMs[fanIndex] = rpm

        guard let i = workingProfile.fans.firstIndex(where: { $0.fanIndex == fanIndex }) else { return }
        workingProfile.fans[i].fixedRPM = rpm
        workingProfile.fans[i].mode = .fixed
        fanModes[fanIndex] = .fixed

        engine.updateFanConfig(fanIndex: fanIndex, config: workingProfile.fans[i])
    }

    func dashboardDidSelectProfile(id: String) {
        applyProfile(id: id)
    }

    func availableProfiles() -> [(id: String, name: String)] {
        profiles
    }

    func activeProfileId() -> String {
        currentProfileId
    }

    func fanMode(for index: Int) -> FanMode {
        fanModes[index] ?? .auto
    }

    func fanTargetRPM(for index: Int) -> Double? {
        fanTargetRPMs[index]
    }
}
