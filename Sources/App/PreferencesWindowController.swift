import AppKit

// MARK: - Preferences Delegate

/// Callback protocol for actions in the preferences window.
protocol PreferencesDelegate: AnyObject {
    func preferencesDidChangeFanMode(fanIndex: Int, mode: FanMode)
    func preferencesDidChangeFanRPM(fanIndex: Int, rpm: Double)
    func preferencesDidChangeFanCurve(fanIndex: Int, curve: FanCurve)
    func preferencesDidChangeFanReferenceSensor(fanIndex: Int, sensorKey: String?)
    func preferencesDidSelectProfile(id: String)
    func preferencesDidSaveProfile()
    func preferencesDidCreateProfile(name: String)
    func preferencesDidDuplicateProfile()
    func preferencesDidDeleteProfile(id: String)
    func currentProfile() -> Profile
    func availableProfiles() -> [(id: String, name: String)]
    func activeProfileId() -> String
    func isProfileBuiltIn(id: String) -> Bool
    func fanMode(for index: Int) -> FanMode
    func fanTargetRPM(for index: Int) -> Double?
    func fanCurve(for index: Int) -> FanCurve?
    func fanReferenceSensor(for index: Int) -> String?
    func fanCount() -> Int
    func minRPM() -> Double
    func maxRPM() -> Double
}

// MARK: - Preferences Window Controller

/// Two-tab preferences window: Monitor (telemetry) and Profiles (customization).
final class PreferencesWindowController: NSWindowController {
    weak var prefsDelegate: PreferencesDelegate?

    private let tabView = NSTabView()

    // Monitor tab
    private let monitorStack = NSStackView()
    private let monitorScroll = NSScrollView()
    private var tempValueLabels: [String: NSTextField] = [:]
    private var tempKeyLabels: [String: NSTextField] = [:]
    private var hottestKey: String = ""
    private var fanActualLabels: [Int: NSTextField] = [:]
    private var fanBars: [Int: NSProgressIndicator] = [:]
    private var fanDetailLabels: [Int: NSTextField] = [:]
    private var currentSensorKeys: [String] = []
    private var currentFanCount: Int = -1

    // Profiles tab
    private let profilesStack = NSStackView()
    private let profilesScroll = NSScrollView()
    private var profilePopup: NSPopUpButton?
    private var fanModePopups: [Int: NSPopUpButton] = [:]
    private var fanFixedSliders: [Int: NSSlider] = [:]
    private var fanFixedLabels: [Int: NSTextField] = [:]
    private var fanCurveEditors: [Int: FanCurveEditorView] = [:]
    private var fanSensorPopups: [Int: NSPopUpButton] = [:]
    private var fanConfigStacks: [Int: NSStackView] = [:]
    private var fanPointsLabels: [Int: NSTextField] = [:]
    private var hysteresisSlider: NSSlider?
    private var rampRateSlider: NSSlider?
    private var responseDelaySlider: NSSlider?
    private var hysteresisLabel: NSTextField?
    private var rampRateLabel: NSTextField?
    private var responseDelayLabel: NSTextField?
    private var curveParamsStack: NSStackView?
    private var selectedFanForCurve: Int = 0
    private var saveButton: NSButton?
    private var deleteButton: NSButton?

    // MARK: - Init

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MySMC Preferences"
        window.center()
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false

        self.init(window: window)
        buildUI()
    }

    // MARK: - Public API

    /// Called on each engine tick with fresh sensor data.
    func update(temps: [TemperatureReading], fans: [Fan]) {
        guard window?.isVisible == true else { return }

        let sensorKeys = temps.map(\.key)
        let fanCount = fans.count

        if sensorKeys != currentSensorKeys || fanCount != currentFanCount {
            rebuildMonitorTab(temps: temps, fans: fans)
            currentSensorKeys = sensorKeys
            currentFanCount = fanCount
        } else {
            updateMonitorValues(temps: temps, fans: fans)
        }

        // Update live crosshairs in curve editors
        let hottestTemp = temps.map(\.celsius).max()
        for (fanIndex, editor) in fanCurveEditors {
            // Use reference sensor if set, else hottest
            if let sensorKey = prefsDelegate?.fanReferenceSensor(for: fanIndex),
               let reading = temps.first(where: { $0.key == sensorKey }) {
                editor.liveTemperature = reading.celsius
            } else {
                editor.liveTemperature = hottestTemp
            }
            let fan = fans.first(where: { $0.index == fanIndex })
            editor.liveRPM = fan?.actual
        }
    }

    /// Refresh all profile-related controls after an external profile switch.
    func refreshControls() {
        refreshProfilePopup()
        rebuildFanConfigs()
    }

    // MARK: - Build UI

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])

        // Monitor tab
        let monitorTab = NSTabViewItem(identifier: "monitor")
        monitorTab.label = "Monitor"
        monitorTab.view = buildMonitorTab()
        tabView.addTabViewItem(monitorTab)

        // Profiles tab
        let profilesTab = NSTabViewItem(identifier: "profiles")
        profilesTab.label = "Profiles"
        profilesTab.view = buildProfilesTab()
        tabView.addTabViewItem(profilesTab)
    }

    // MARK: - Monitor Tab

    private func buildMonitorTab() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        monitorScroll.translatesAutoresizingMaskIntoConstraints = false
        monitorScroll.hasVerticalScroller = true
        monitorScroll.hasHorizontalScroller = false
        monitorScroll.drawsBackground = false
        monitorScroll.borderType = .noBorder

        monitorStack.orientation = .vertical
        monitorStack.alignment = .leading
        monitorStack.spacing = 4
        monitorStack.translatesAutoresizingMaskIntoConstraints = false
        monitorStack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        monitorScroll.documentView = monitorStack
        container.addSubview(monitorScroll)

        NSLayoutConstraint.activate([
            monitorScroll.topAnchor.constraint(equalTo: container.topAnchor),
            monitorScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            monitorScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            monitorScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            monitorStack.widthAnchor.constraint(equalTo: monitorScroll.widthAnchor),
        ])

        // Placeholder until first update
        let placeholder = makeLabel("Waiting for sensor data\u{2026}",
                                    font: .systemFont(ofSize: 12),
                                    color: .secondaryLabelColor)
        monitorStack.addArrangedSubview(placeholder)

        return container
    }

    // MARK: - Profiles Tab

    private func buildProfilesTab() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        profilesScroll.translatesAutoresizingMaskIntoConstraints = false
        profilesScroll.hasVerticalScroller = true
        profilesScroll.hasHorizontalScroller = false
        profilesScroll.drawsBackground = false
        profilesScroll.borderType = .noBorder

        profilesStack.orientation = .vertical
        profilesStack.alignment = .leading
        profilesStack.spacing = 8
        profilesStack.translatesAutoresizingMaskIntoConstraints = false
        profilesStack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        profilesScroll.documentView = profilesStack
        container.addSubview(profilesScroll)

        NSLayoutConstraint.activate([
            profilesScroll.topAnchor.constraint(equalTo: container.topAnchor),
            profilesScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            profilesScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            profilesScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            profilesStack.widthAnchor.constraint(equalTo: profilesScroll.widthAnchor),
        ])

        // Profile selector row
        let profileRow = NSStackView()
        profileRow.orientation = .horizontal
        profileRow.alignment = .centerY
        profileRow.spacing = 8
        profileRow.translatesAutoresizingMaskIntoConstraints = false

        let profileLabel = makeLabel("Active Profile:", font: .systemFont(ofSize: 12, weight: .medium))

        let popup = NSPopUpButton()
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.controlSize = .regular
        popup.font = .systemFont(ofSize: 12)
        popup.target = self
        popup.action = #selector(profileChanged(_:))
        profilePopup = popup

        profileRow.addArrangedSubview(profileLabel)
        profileRow.addArrangedSubview(popup)
        profileLabel.setContentHuggingPriority(.required, for: .horizontal)

        profilesStack.addArrangedSubview(profileRow)

        // Profile management buttons
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let newBtn = NSButton(title: "New\u{2026}", target: self, action: #selector(newProfile))
        newBtn.bezelStyle = .rounded
        newBtn.controlSize = .small
        newBtn.font = .systemFont(ofSize: 11)

        let dupBtn = NSButton(title: "Duplicate", target: self, action: #selector(duplicateProfile))
        dupBtn.bezelStyle = .rounded
        dupBtn.controlSize = .small
        dupBtn.font = .systemFont(ofSize: 11)

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveProfile))
        saveBtn.bezelStyle = .rounded
        saveBtn.controlSize = .small
        saveBtn.font = .systemFont(ofSize: 11)
        saveButton = saveBtn

        let delBtn = NSButton(title: "Delete", target: self, action: #selector(deleteProfile))
        delBtn.bezelStyle = .rounded
        delBtn.controlSize = .small
        delBtn.font = .systemFont(ofSize: 11)
        deleteButton = delBtn

        buttonRow.addArrangedSubview(newBtn)
        buttonRow.addArrangedSubview(dupBtn)
        buttonRow.addArrangedSubview(saveBtn)
        buttonRow.addArrangedSubview(delBtn)

        profilesStack.addArrangedSubview(buttonRow)
        profilesStack.addArrangedSubview(makeDivider())

        // Populate the popup and update button states
        refreshProfilePopup()

        // Fan config sections will be built dynamically
        rebuildFanConfigs()

        return container
    }

    private func refreshProfilePopup() {
        guard let popup = profilePopup, let delegate = prefsDelegate else { return }

        popup.removeAllItems()
        let profiles = delegate.availableProfiles()
        let activeId = delegate.activeProfileId()
        for (i, profile) in profiles.enumerated() {
            popup.addItem(withTitle: profile.name)
            if profile.id == activeId {
                popup.selectItem(at: i)
            }
        }

        // Enable/disable delete based on whether profile is built-in
        let isBuiltIn = delegate.isProfileBuiltIn(id: activeId)
        deleteButton?.isEnabled = !isBuiltIn
    }

    // MARK: - Rebuild Monitor Tab

    private func rebuildMonitorTab(temps: [TemperatureReading], fans: [Fan]) {
        monitorStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tempValueLabels.removeAll()
        tempKeyLabels.removeAll()
        fanActualLabels.removeAll()
        fanBars.removeAll()
        fanDetailLabels.removeAll()

        // Temperatures
        monitorStack.addArrangedSubview(makeSectionHeader("Temperatures"))
        monitorStack.addArrangedSubview(makeSpacer(4))

        let hottestReading = temps.max(by: { $0.celsius < $1.celsius })
        hottestKey = hottestReading?.key ?? ""

        for group in SensorGroup.allCases {
            let groupTemps = temps.filter { reading in
                TemperatureMonitor.sensorInfo(for: reading.key)?.group == group
            }
            guard !groupTemps.isEmpty else { continue }

            let header = makeLabel(group.rawValue, font: .systemFont(ofSize: 11, weight: .medium),
                                   color: .secondaryLabelColor)
            monitorStack.addArrangedSubview(header)

            for reading in groupTemps {
                let row = makeTempRow(reading: reading, isHottest: reading.key == hottestKey)
                monitorStack.addArrangedSubview(row)
            }
            monitorStack.addArrangedSubview(makeSpacer(4))
        }

        // Fans
        monitorStack.addArrangedSubview(makeDivider())
        monitorStack.addArrangedSubview(makeSpacer(4))
        monitorStack.addArrangedSubview(makeSectionHeader("Fans"))
        monitorStack.addArrangedSubview(makeSpacer(4))

        for fan in fans {
            let fanView = makeFanMonitorView(fan: fan)
            monitorStack.addArrangedSubview(fanView)
            monitorStack.addArrangedSubview(makeSpacer(4))
        }
    }

    private func updateMonitorValues(temps: [TemperatureReading], fans: [Fan]) {
        let hottestReading = temps.max(by: { $0.celsius < $1.celsius })
        let newHottestKey = hottestReading?.key ?? ""

        for reading in temps {
            if let label = tempValueLabels[reading.key] {
                label.stringValue = String(format: "%.0f\u{00B0}C", reading.celsius)
                label.textColor = tempColor(for: reading.celsius)
            }
            if let keyLabel = tempKeyLabels[reading.key] {
                let isHottest = reading.key == newHottestKey
                let wasHottest = reading.key == hottestKey
                if isHottest != wasHottest {
                    keyLabel.textColor = isHottest ? .systemOrange : .tertiaryLabelColor
                }
            }
        }
        hottestKey = newHottestKey

        for fan in fans {
            if let label = fanActualLabels[fan.index] {
                let rpmStr = fan.actual.map { String(format: "%.0f", $0) } ?? "--"
                label.stringValue = "\(rpmStr) RPM"
            }
            if let bar = fanBars[fan.index] {
                bar.minValue = fan.minimum ?? 0
                bar.maxValue = fan.maximum ?? 6500
                bar.doubleValue = fan.actual ?? 0
            }
            if let detail = fanDetailLabels[fan.index] {
                let target = fan.target.map { String(format: "%.0f", $0) } ?? "--"
                let min = fan.minimum.map { String(format: "%.0f", $0) } ?? "--"
                let max = fan.maximum.map { String(format: "%.0f", $0) } ?? "--"
                detail.stringValue = "Target: \(target)  Min: \(min)  Max: \(max)"
            }
        }
    }

    // MARK: - Rebuild Fan Configs (Profiles Tab)

    private func rebuildFanConfigs() {
        // Remove existing fan config views (everything after the divider following profile row)
        let existingFanViews = profilesStack.arrangedSubviews
        // Keep the first 2 views (profile row + divider)
        if existingFanViews.count > 2 {
            for view in existingFanViews[2...] {
                view.removeFromSuperview()
            }
        }

        fanModePopups.removeAll()
        fanFixedSliders.removeAll()
        fanFixedLabels.removeAll()
        fanCurveEditors.removeAll()
        fanSensorPopups.removeAll()
        fanConfigStacks.removeAll()
        fanPointsLabels.removeAll()

        guard let delegate = prefsDelegate else { return }
        let numFans = delegate.fanCount()

        for i in 0..<numFans {
            let fanSection = buildFanConfigSection(fanIndex: i)
            profilesStack.addArrangedSubview(fanSection)

            if i < numFans - 1 {
                profilesStack.addArrangedSubview(makeDivider())
            }
        }

        // Curve parameters section
        profilesStack.addArrangedSubview(makeDivider())
        let paramsSection = buildCurveParamsSection()
        profilesStack.addArrangedSubview(paramsSection)
    }

    private func buildFanConfigSection(fanIndex: Int) -> NSView {
        guard let delegate = prefsDelegate else { return NSView() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Fan header
        let header = makeLabel("Fan \(fanIndex)", font: .systemFont(ofSize: 13, weight: .semibold))
        stack.addArrangedSubview(header)

        // Mode selector
        let modeRow = NSStackView()
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = 8
        modeRow.translatesAutoresizingMaskIntoConstraints = false

        let modeLabel = makeLabel("Mode:", font: .systemFont(ofSize: 12))
        let modePopup = NSPopUpButton()
        modePopup.translatesAutoresizingMaskIntoConstraints = false
        modePopup.controlSize = .regular
        modePopup.font = .systemFont(ofSize: 12)
        modePopup.tag = fanIndex
        modePopup.target = self
        modePopup.action = #selector(fanModeChanged(_:))
        modePopup.addItems(withTitles: ["Auto", "Fixed RPM", "Custom Curve"])

        let currentMode = delegate.fanMode(for: fanIndex)
        switch currentMode {
        case .auto:  modePopup.selectItem(at: 0)
        case .fixed: modePopup.selectItem(at: 1)
        case .curve: modePopup.selectItem(at: 2)
        }
        fanModePopups[fanIndex] = modePopup

        modeRow.addArrangedSubview(modeLabel)
        modeRow.addArrangedSubview(modePopup)
        stack.addArrangedSubview(modeRow)

        // Conditional config views
        let configStack = NSStackView()
        configStack.orientation = .vertical
        configStack.alignment = .leading
        configStack.spacing = 6
        configStack.translatesAutoresizingMaskIntoConstraints = false
        fanConfigStacks[fanIndex] = configStack

        buildFanConfigDetails(fanIndex: fanIndex, mode: currentMode, into: configStack)
        stack.addArrangedSubview(configStack)

        return stack
    }

    private func buildFanConfigDetails(fanIndex: Int, mode: FanMode, into stack: NSStackView) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let delegate = prefsDelegate else { return }

        switch mode {
        case .auto:
            let note = makeLabel("Fan controlled by SMC firmware.",
                                 font: .systemFont(ofSize: 11),
                                 color: .secondaryLabelColor)
            stack.addArrangedSubview(note)

        case .fixed:
            let sliderRow = NSStackView()
            sliderRow.orientation = .horizontal
            sliderRow.alignment = .centerY
            sliderRow.spacing = 8
            sliderRow.translatesAutoresizingMaskIntoConstraints = false

            let min = delegate.minRPM()
            let max = delegate.maxRPM()
            let current = delegate.fanTargetRPM(for: fanIndex) ?? min

            let slider = NSSlider(value: current, minValue: min, maxValue: max,
                                  target: self, action: #selector(fanRPMChanged(_:)))
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.controlSize = .regular
            slider.tag = fanIndex
            slider.isContinuous = true
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            fanFixedSliders[fanIndex] = slider

            let valueLabel = makeLabel(
                String(format: "%.0f RPM", current),
                font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            )
            valueLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true
            valueLabel.alignment = .right
            fanFixedLabels[fanIndex] = valueLabel

            sliderRow.addArrangedSubview(slider)
            sliderRow.addArrangedSubview(valueLabel)
            stack.addArrangedSubview(sliderRow)

        case .curve:
            // Reference sensor selector
            let sensorRow = NSStackView()
            sensorRow.orientation = .horizontal
            sensorRow.alignment = .centerY
            sensorRow.spacing = 8
            sensorRow.translatesAutoresizingMaskIntoConstraints = false

            let sensorLabel = makeLabel("Reference Sensor:", font: .systemFont(ofSize: 12))
            let sensorPopup = NSPopUpButton()
            sensorPopup.translatesAutoresizingMaskIntoConstraints = false
            sensorPopup.controlSize = .regular
            sensorPopup.font = .systemFont(ofSize: 12)
            sensorPopup.tag = fanIndex
            sensorPopup.target = self
            sensorPopup.action = #selector(sensorChanged(_:))

            sensorPopup.addItem(withTitle: "Hottest Sensor")
            for sensor in knownSensors {
                sensorPopup.addItem(withTitle: "\(sensor.label) (\(sensor.key))")
            }

            let currentSensor = delegate.fanReferenceSensor(for: fanIndex)
            if let key = currentSensor,
               let idx = knownSensors.firstIndex(where: { $0.key == key }) {
                sensorPopup.selectItem(at: idx + 1) // +1 for "Hottest Sensor"
            } else {
                sensorPopup.selectItem(at: 0)
            }
            fanSensorPopups[fanIndex] = sensorPopup

            sensorRow.addArrangedSubview(sensorLabel)
            sensorRow.addArrangedSubview(sensorPopup)
            stack.addArrangedSubview(sensorRow)

            // Curve editor
            let editor = FanCurveEditorView()
            editor.translatesAutoresizingMaskIntoConstraints = false
            editor.delegate = self
            editor.minRPM = delegate.minRPM()
            editor.maxRPM = delegate.maxRPM()

            if let existingCurve = delegate.fanCurve(for: fanIndex) {
                editor.curve = existingCurve
            } else {
                editor.curve = .balanced(minRPM: delegate.minRPM(), maxRPM: delegate.maxRPM())
            }

            editor.fanIndex = fanIndex
            fanCurveEditors[fanIndex] = editor

            NSLayoutConstraint.activate([
                editor.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
                editor.heightAnchor.constraint(equalToConstant: 200),
            ])

            stack.addArrangedSubview(editor)

            // Control point list
            let pointsLabel = makeLabel(
                curvePointsSummary(editor.curve),
                font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                color: .secondaryLabelColor
            )
            fanPointsLabels[fanIndex] = pointsLabel
            stack.addArrangedSubview(pointsLabel)

            let hint = makeLabel(
                "Double-click to add point \u{2022} Right-click to remove \u{2022} Drag to adjust",
                font: .systemFont(ofSize: 10),
                color: .tertiaryLabelColor
            )
            stack.addArrangedSubview(hint)

            selectedFanForCurve = fanIndex
        }
    }

    private func buildCurveParamsSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        curveParamsStack = stack

        let header = makeSectionHeader("Curve Parameters")
        stack.addArrangedSubview(header)

        let note = makeLabel("Applied to all fans in Curve mode.",
                             font: .systemFont(ofSize: 10),
                             color: .tertiaryLabelColor)
        stack.addArrangedSubview(note)

        // Get current values from first fan's curve, or defaults
        var hyst: Double = 3.0
        var ramp: Double = 500.0
        var delay: Double = 2.0

        if let delegate = prefsDelegate {
            for i in 0..<delegate.fanCount() {
                if let curve = delegate.fanCurve(for: i) {
                    hyst = curve.hysteresis
                    ramp = curve.rampRate
                    delay = curve.responseDelay
                    break
                }
            }
        }

        // Hysteresis
        let (hystRow, hystSlider, hystLabel) = makeSliderRow(
            label: "Hysteresis:", min: 0, max: 10, value: hyst,
            format: "%.1f\u{00B0}C", action: #selector(curveParamChanged(_:)), tag: 100
        )
        hysteresisSlider = hystSlider
        hysteresisLabel = hystLabel
        stack.addArrangedSubview(hystRow)

        // Ramp rate
        let (rampRow, rampSlider_, rampLabel_) = makeSliderRow(
            label: "Ramp Rate:", min: 100, max: 2000, value: ramp,
            format: "%.0f RPM/s", action: #selector(curveParamChanged(_:)), tag: 101
        )
        rampRateSlider = rampSlider_
        rampRateLabel = rampLabel_
        stack.addArrangedSubview(rampRow)

        // Response delay
        let (delayRow, delaySlider_, delayLabel_) = makeSliderRow(
            label: "Response Delay:", min: 0, max: 10, value: delay,
            format: "%.1f s", action: #selector(curveParamChanged(_:)), tag: 102
        )
        responseDelaySlider = delaySlider_
        responseDelayLabel = delayLabel_
        stack.addArrangedSubview(delayRow)

        return stack
    }

    // MARK: - Actions

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        guard let delegate = prefsDelegate else { return }
        let profiles = delegate.availableProfiles()
        let idx = sender.indexOfSelectedItem
        guard idx >= 0 && idx < profiles.count else { return }
        delegate.preferencesDidSelectProfile(id: profiles[idx].id)
        refreshProfilePopup()
        rebuildFanConfigs()
    }

    @objc private func newProfile() {
        let alert = NSAlert()
        alert.messageText = "New Profile"
        alert.informativeText = "Enter a name for the new profile:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = "My Profile"
        alert.accessoryView = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            prefsDelegate?.preferencesDidCreateProfile(name: name)
            refreshProfilePopup()
            rebuildFanConfigs()
        }
    }

    @objc private func duplicateProfile() {
        prefsDelegate?.preferencesDidDuplicateProfile()
        refreshProfilePopup()
        rebuildFanConfigs()
    }

    @objc private func saveProfile() {
        prefsDelegate?.preferencesDidSaveProfile()

        // Brief visual feedback
        saveButton?.title = "Saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.saveButton?.title = "Save"
        }
    }

    @objc private func deleteProfile() {
        guard let delegate = prefsDelegate else { return }
        let activeId = delegate.activeProfileId()
        guard !delegate.isProfileBuiltIn(id: activeId) else { return }

        let profile = delegate.currentProfile()
        let alert = NSAlert()
        alert.messageText = "Delete Profile"
        alert.informativeText = "Are you sure you want to delete \"\(profile.name)\"?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            delegate.preferencesDidDeleteProfile(id: activeId)
            refreshProfilePopup()
            rebuildFanConfigs()
        }
    }

    @objc private func fanModeChanged(_ sender: NSPopUpButton) {
        let fanIndex = sender.tag
        let mode: FanMode
        switch sender.indexOfSelectedItem {
        case 0: mode = .auto
        case 1: mode = .fixed
        case 2: mode = .curve
        default: mode = .auto
        }

        // Rebuild the config details for this fan
        if let configStack = fanConfigStacks[fanIndex] {
            buildFanConfigDetails(fanIndex: fanIndex, mode: mode, into: configStack)
        }

        prefsDelegate?.preferencesDidChangeFanMode(fanIndex: fanIndex, mode: mode)
    }

    @objc private func fanRPMChanged(_ sender: NSSlider) {
        let fanIndex = sender.tag
        let rpm = sender.doubleValue
        fanFixedLabels[fanIndex]?.stringValue = String(format: "%.0f RPM", rpm)
        prefsDelegate?.preferencesDidChangeFanRPM(fanIndex: fanIndex, rpm: rpm)
    }

    @objc private func sensorChanged(_ sender: NSPopUpButton) {
        let fanIndex = sender.tag
        let idx = sender.indexOfSelectedItem
        let sensorKey: String?
        if idx == 0 {
            sensorKey = nil // "Hottest Sensor"
        } else {
            sensorKey = knownSensors[idx - 1].key
        }
        prefsDelegate?.preferencesDidChangeFanReferenceSensor(fanIndex: fanIndex, sensorKey: sensorKey)
    }

    @objc private func curveParamChanged(_ sender: NSSlider) {
        guard let delegate = prefsDelegate else { return }

        switch sender.tag {
        case 100:
            hysteresisLabel?.stringValue = String(format: "%.1f\u{00B0}C", sender.doubleValue)
        case 101:
            rampRateLabel?.stringValue = String(format: "%.0f RPM/s", sender.doubleValue)
        case 102:
            responseDelayLabel?.stringValue = String(format: "%.1f s", sender.doubleValue)
        default: break
        }

        // Apply to all fans in curve mode
        for i in 0..<delegate.fanCount() {
            guard delegate.fanMode(for: i) == .curve,
                  var curve = delegate.fanCurve(for: i) ?? fanCurveEditors[i]?.curve else { continue }

            curve.hysteresis = hysteresisSlider?.doubleValue ?? curve.hysteresis
            curve.rampRate = rampRateSlider?.doubleValue ?? curve.rampRate
            curve.responseDelay = responseDelaySlider?.doubleValue ?? curve.responseDelay

            delegate.preferencesDidChangeFanCurve(fanIndex: i, curve: curve)
        }
    }

    // MARK: - View Builders

    private func makeTempRow(reading: TemperatureReading, isHottest: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let keyLabel = makeLabel(
            reading.key,
            font: .monospacedSystemFont(ofSize: 11, weight: .regular),
            color: isHottest ? .systemOrange : .tertiaryLabelColor
        )
        keyLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        tempKeyLabels[reading.key] = keyLabel

        let nameLabel = makeLabel(reading.label, font: .systemFont(ofSize: 12))

        let valueLabel = makeLabel(
            String(format: "%.0f\u{00B0}C", reading.celsius),
            font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            color: tempColor(for: reading.celsius)
        )
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        tempValueLabels[reading.key] = valueLabel

        row.addArrangedSubview(keyLabel)
        row.addArrangedSubview(nameLabel)
        row.addArrangedSubview(valueLabel)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        return row
    }

    private func makeFanMonitorView(fan: Fan) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        container.translatesAutoresizingMaskIntoConstraints = false

        // Header: name + RPM
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .lastBaseline
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = makeLabel(fan.label, font: .systemFont(ofSize: 13, weight: .semibold))
        let rpmStr = fan.actual.map { String(format: "%.0f", $0) } ?? "--"
        let rpmLabel = makeLabel(
            "\(rpmStr) RPM",
            font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            color: .systemBlue
        )
        rpmLabel.alignment = .right
        fanActualLabels[fan.index] = rpmLabel

        headerRow.addArrangedSubview(nameLabel)
        headerRow.addArrangedSubview(rpmLabel)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Progress bar
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = fan.minimum ?? 0
        bar.maxValue = fan.maximum ?? 6500
        bar.doubleValue = fan.actual ?? 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        bar.controlSize = .small
        fanBars[fan.index] = bar

        // Detail line
        let target = fan.target.map { String(format: "%.0f", $0) } ?? "--"
        let minStr = fan.minimum.map { String(format: "%.0f", $0) } ?? "--"
        let maxStr = fan.maximum.map { String(format: "%.0f", $0) } ?? "--"
        let detailLabel = makeLabel(
            "Target: \(target)  Min: \(minStr)  Max: \(maxStr)",
            font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            color: .secondaryLabelColor
        )
        fanDetailLabels[fan.index] = detailLabel

        container.addArrangedSubview(headerRow)
        container.addArrangedSubview(bar)
        container.addArrangedSubview(detailLabel)

        return container
    }

    private func makeSliderRow(
        label: String, min: Double, max: Double, value: Double,
        format: String, action: Selector, tag: Int
    ) -> (NSStackView, NSSlider, NSTextField) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = makeLabel(label, font: .systemFont(ofSize: 12))
        titleLabel.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let slider = NSSlider(value: value, minValue: min, maxValue: max,
                              target: self, action: action)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.controlSize = .regular
        slider.tag = tag
        slider.isContinuous = true
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        let valueLabel = makeLabel(
            String(format: format, value),
            font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        )
        valueLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
        valueLabel.alignment = .right

        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(valueLabel)

        return (row, slider, valueLabel)
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeSectionHeader(_ text: String) -> NSTextField {
        makeLabel(text, font: .systemFont(ofSize: 13, weight: .semibold))
    }

    private func makeSpacer(_ height: CGFloat) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        return spacer
    }

    private func makeDivider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        return divider
    }

    private func tempColor(for celsius: Double) -> NSColor {
        if celsius >= 90 { return .systemRed }
        if celsius >= 75 { return .systemOrange }
        if celsius >= 60 { return .systemYellow }
        return .systemGreen
    }

    private func curvePointsSummary(_ curve: FanCurve) -> String {
        curve.points.map { String(format: "%.0f\u{00B0}C \u{2192} %.0f RPM", $0.temperature, $0.rpm) }
            .joined(separator: "  \u{2022}  ")
    }
}

// MARK: - FanCurveEditorDelegate

extension PreferencesWindowController: FanCurveEditorDelegate {
    func fanCurveEditorDidChange(_ editor: FanCurveEditorView, curve: FanCurve) {
        let fanIndex = editor.fanIndex

        // Update the points summary label
        fanPointsLabels[fanIndex]?.stringValue = curvePointsSummary(curve)

        // Apply hysteresis/ramp/delay from sliders
        var updatedCurve = curve
        updatedCurve.hysteresis = hysteresisSlider?.doubleValue ?? curve.hysteresis
        updatedCurve.rampRate = rampRateSlider?.doubleValue ?? curve.rampRate
        updatedCurve.responseDelay = responseDelaySlider?.doubleValue ?? curve.responseDelay

        prefsDelegate?.preferencesDidChangeFanCurve(fanIndex: fanIndex, curve: updatedCurve)
    }
}
