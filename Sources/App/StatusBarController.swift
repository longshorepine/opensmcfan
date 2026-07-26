import AppKit

// MARK: - Status Bar Controller

/// Manages the menu bar icon, dropdown menu (WiFi-style), preferences window,
/// fan control, and profile switching.
final class StatusBarController: NSObject, PreferencesDelegate {
    private let statusItem: NSStatusItem
    private let smc: SMCConnection
    private let engine: ThermalEngine
    private let fanReader: FanReader
    private let tempMonitor: TemperatureMonitor
    private let prefsController: PreferencesWindowController
    private let profileStore: ProfileStore

    // Cached sensor data for menu display
    private var lastTemps: [TemperatureReading] = []
    private var lastFans: [Fan] = []

    // Profile state
    private var profiles: [Profile] = []
    private var currentProfileId: String = "auto"
    private var workingProfile: Profile!

    // Fan state (working copy)
    private var fanModes: [Int: FanMode] = [:]
    private var fanTargetRPMs: [Int: Double] = [:]
    private var fanCurves: [Int: FanCurve] = [:]
    private var fanSensors: [Int: String?] = [:]
    private var _fanCount: Int = 0
    private var _fans: [Fan] = []           // hardware fan data, keyed by fan.index

    init(smc: SMCConnection) {
        self.smc = smc
        self.engine = ThermalEngine(smc: smc)
        self.fanReader = FanReader(smc: smc)
        self.tempMonitor = TemperatureMonitor(smc: smc)
        self.prefsController = PreferencesWindowController()
        self.profileStore = ProfileStore()

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        prefsController.prefsDelegate = self

        // Read hardware info (includes per-fan labels, min, max)
        let fans = fanReader.readAllFans()
        _fanCount = fans.count
        _fans = fans

        // Initialize profile store and load profiles
        profileStore.createDefaultsIfNeeded(fans: _fans)
        reloadProfiles()

        // Restore last active profile (or default to auto)
        let lastId = UserDefaults.standard.string(forKey: "MySMC.lastProfileId") ?? "auto"
        currentProfileId = lastId
        workingProfile = profileForId(lastId)
        for config in workingProfile.fans {
            fanModes[config.fanIndex] = config.mode
            if let rpm = config.fixedRPM { fanTargetRPMs[config.fanIndex] = rpm }
            fanCurves[config.fanIndex] = config.curve
            fanSensors[config.fanIndex] = config.referenceSensor
        }

        // Configure status bar button
        if let button = statusItem.button {
            button.title = "--\u{00B0}C"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.action = #selector(handleClick(_:))
            button.target = self
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
    }

    // MARK: - Profile Loading

    private func reloadProfiles() {
        profiles = profileStore.loadAll()

        // Ensure built-in profiles exist
        let ids = Set(profiles.map(\.id))
        let builtInIds = ["auto", "quiet", "balanced", "cool", "max"]
        for id in builtInIds where !ids.contains(id) {
            let p = makeBuiltInProfile(id: id)
            try? profileStore.save(p)
            profiles.append(p)
        }

        profiles.sort { a, b in
            // Built-in first (in fixed order), then custom alphabetically
            let order = ["auto", "quiet", "balanced", "cool", "max"]
            let ai = order.firstIndex(of: a.id)
            let bi = order.firstIndex(of: b.id)
            if let ai = ai, let bi = bi { return ai < bi }
            if ai != nil { return true }
            if bi != nil { return false }
            return a.name < b.name
        }
    }

    private func profileForId(_ id: String) -> Profile {
        if let stored = profiles.first(where: { $0.id == id }) {
            return stored
        }
        return makeBuiltInProfile(id: id)
    }

    private func makeBuiltInProfile(id: String) -> Profile {
        switch id {
        case "auto":     return .autoProfile(fans: _fans)
        case "quiet":    return .quietProfile(fans: _fans)
        case "balanced": return .balancedProfile(fans: _fans)
        case "cool":     return .coolProfile(fans: _fans)
        case "max":      return .maxProfile(fans: _fans)
        default:         return .autoProfile(fans: _fans)
        }
    }

    // MARK: - Engine Update

    private func handleEngineUpdate(temps: [TemperatureReading], fans: [Fan]) {
        let avgTemp: Double
        if !temps.isEmpty {
            avgTemp = temps.map(\.celsius).reduce(0, +) / Double(temps.count)
        } else {
            avgTemp = 0
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.lastTemps = temps
            self.lastFans = fans

            // Update menu bar with average temperature
            if avgTemp > 0 {
                let color: NSColor
                if avgTemp >= 85 { color = .systemRed }
                else if avgTemp >= 70 { color = .systemOrange }
                else { color = .labelColor }

                self.statusItem.button?.attributedTitle = NSAttributedString(
                    string: String(format: "%.0f\u{00B0}C", avgTemp),
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: color,
                    ]
                )
            }

            // Update preferences window (full telemetry)
            self.prefsController.update(temps: temps, fans: fans)
        }
    }

    // MARK: - Click → Menu

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // ── Temperature header ──
        let avgTemp: Double
        if !lastTemps.isEmpty {
            avgTemp = lastTemps.map(\.celsius).reduce(0, +) / Double(lastTemps.count)
        } else {
            avgTemp = 0
        }

        let tempStr = avgTemp > 0 ? String(format: "%.0f\u{00B0}C", avgTemp) : "--\u{00B0}C"
        let headerItem = NSMenuItem(title: "Temperature: \(tempStr)", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        if let hottestReading = lastTemps.max(by: { $0.celsius < $1.celsius }) {
            let peakStr = String(format: "Peak: %.0f\u{00B0}C (%@)", hottestReading.celsius, hottestReading.label)
            let peakItem = NSMenuItem(title: peakStr, action: nil, keyEquivalent: "")
            peakItem.isEnabled = false
            peakItem.indentationLevel = 1
            menu.addItem(headerItem)
            menu.addItem(peakItem)
        } else {
            menu.addItem(headerItem)
        }

        // ── Fans ──
        if !lastFans.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for fan in lastFans {
                let rpmStr = fan.actual.map { String(format: "%.0f RPM", $0) } ?? "-- RPM"
                let item = NSMenuItem(title: "Fan \(fan.index): \(rpmStr)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // ── Profiles ──
        for profile in profiles {
            let item = NSMenuItem(
                title: profile.name,
                action: #selector(menuProfileSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == currentProfileId ? .on : .off
            if !profile.builtIn {
                item.indentationLevel = 1
            }
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // ── Preferences ──
        let prefsItem = NSMenuItem(title: "Preferences\u{2026}", action: #selector(openPreferences),
                                   keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        // ── Quit ──
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit MySMC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    // MARK: - Menu Actions

    @objc private func menuProfileSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        applyProfile(id: id)
    }

    @objc private func openPreferences() {
        prefsController.showWindow(nil)
        prefsController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        prefsController.refreshControls()
    }

    // MARK: - Profile Management

    private func applyProfile(id: String) {
        currentProfileId = id
        UserDefaults.standard.set(id, forKey: "MySMC.lastProfileId")
        workingProfile = profileForId(id)

        // Sync local fan state from profile
        for config in workingProfile.fans {
            fanModes[config.fanIndex] = config.mode
            if let rpm = config.fixedRPM {
                fanTargetRPMs[config.fanIndex] = rpm
            }
            fanCurves[config.fanIndex] = config.curve
            fanSensors[config.fanIndex] = config.referenceSensor
        }

        // Apply to engine
        engine.switchProfile(workingProfile)

        // Refresh preferences UI
        DispatchQueue.main.async { [weak self] in
            self?.prefsController.refreshControls()
        }
    }

    func saveCurrentProfile() {
        try? profileStore.save(workingProfile)
        reloadProfiles()
    }

    func createProfile(name: String, basedOn: Profile) -> Profile {
        let id = name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
            + "_\(Int(Date().timeIntervalSince1970) % 100000)"

        var newProfile = basedOn
        newProfile.id = id
        newProfile.name = name
        newProfile.builtIn = false
        newProfile.created = Date()
        newProfile.modified = Date()

        try? profileStore.save(newProfile)
        reloadProfiles()
        return newProfile
    }

    func deleteProfile(id: String) -> Bool {
        guard profileStore.delete(id: id) else { return false }
        reloadProfiles()
        if currentProfileId == id {
            applyProfile(id: "auto")
        }
        return true
    }

    func duplicateProfile(_ profile: Profile, name: String) -> Profile {
        return createProfile(name: name, basedOn: profile)
    }

    // MARK: - PreferencesDelegate

    func preferencesDidChangeFanMode(fanIndex: Int, mode: FanMode) {
        fanModes[fanIndex] = mode

        guard let i = workingProfile.fans.firstIndex(where: { $0.fanIndex == fanIndex }) else { return }

        workingProfile.fans[i].mode = mode
        if mode == .fixed {
            let rpm = fanTargetRPMs[fanIndex] ?? workingProfile.fans[i].fixedRPM ?? fanMinRPM(for: fanIndex)
            workingProfile.fans[i].fixedRPM = rpm
            fanTargetRPMs[fanIndex] = rpm
        } else if mode == .curve {
            let curve = fanCurves[fanIndex] ?? .balanced(minRPM: fanMinRPM(for: fanIndex),
                                                          maxRPM: fanMaxRPM(for: fanIndex))
            workingProfile.fans[i].curve = curve
            fanCurves[fanIndex] = curve
            workingProfile.fans[i].referenceSensor = fanSensors[fanIndex] ?? nil
        }

        engine.updateFanConfig(fanIndex: fanIndex, config: workingProfile.fans[i])
    }

    func preferencesDidChangeFanRPM(fanIndex: Int, rpm: Double) {
        fanTargetRPMs[fanIndex] = rpm

        guard let i = workingProfile.fans.firstIndex(where: { $0.fanIndex == fanIndex }) else { return }
        workingProfile.fans[i].fixedRPM = rpm
        workingProfile.fans[i].mode = .fixed
        fanModes[fanIndex] = .fixed

        engine.updateFanConfig(fanIndex: fanIndex, config: workingProfile.fans[i])
    }

    func preferencesDidChangeFanCurve(fanIndex: Int, curve: FanCurve) {
        fanCurves[fanIndex] = curve

        guard let i = workingProfile.fans.firstIndex(where: { $0.fanIndex == fanIndex }) else { return }
        workingProfile.fans[i].curve = curve
        workingProfile.fans[i].mode = .curve
        fanModes[fanIndex] = .curve

        engine.updateFanConfig(fanIndex: fanIndex, config: workingProfile.fans[i])
    }

    func preferencesDidChangeFanReferenceSensor(fanIndex: Int, sensorKey: String?) {
        fanSensors[fanIndex] = sensorKey

        guard let i = workingProfile.fans.firstIndex(where: { $0.fanIndex == fanIndex }) else { return }
        workingProfile.fans[i].referenceSensor = sensorKey

        engine.updateFanConfig(fanIndex: fanIndex, config: workingProfile.fans[i])
    }

    func preferencesDidSelectProfile(id: String) {
        applyProfile(id: id)
    }

    func preferencesDidSaveProfile() {
        saveCurrentProfile()
    }

    func preferencesDidCreateProfile(name: String) {
        let newProfile = createProfile(name: name, basedOn: workingProfile)
        applyProfile(id: newProfile.id)
    }

    func preferencesDidDuplicateProfile() {
        let name = workingProfile.name + " Copy"
        let newProfile = duplicateProfile(workingProfile, name: name)
        applyProfile(id: newProfile.id)
    }

    func preferencesDidDeleteProfile(id: String) {
        _ = deleteProfile(id: id)
        prefsController.refreshControls()
    }

    func currentProfile() -> Profile {
        workingProfile
    }

    func availableProfiles() -> [(id: String, name: String)] {
        profiles.map { (id: $0.id, name: $0.name) }
    }

    func activeProfileId() -> String {
        currentProfileId
    }

    func isProfileBuiltIn(id: String) -> Bool {
        profiles.first(where: { $0.id == id })?.builtIn ?? true
    }

    func fanMode(for index: Int) -> FanMode {
        fanModes[index] ?? .auto
    }

    func fanTargetRPM(for index: Int) -> Double? {
        fanTargetRPMs[index]
    }

    func fanCurve(for index: Int) -> FanCurve? {
        fanCurves[index]
    }

    func fanReferenceSensor(for index: Int) -> String? {
        fanSensors[index] ?? nil
    }

    func fanCount() -> Int {
        _fanCount
    }

    func fanMinRPM(for index: Int) -> Double {
        _fans.first(where: { $0.index == index })?.minimum ?? 1200
    }

    func fanMaxRPM(for index: Int) -> Double {
        _fans.first(where: { $0.index == index })?.maximum ?? 6200
    }
}
