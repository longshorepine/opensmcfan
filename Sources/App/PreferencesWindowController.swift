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
    func fanMinRPM(for index: Int) -> Double
    func fanMaxRPM(for index: Int) -> Double
}

// MARK: - Preferences Window Controller

/// Single-view dashboard: fans (left), scrollable sensors (right), MFC-style.
final class PreferencesWindowController: NSWindowController {
    weak var prefsDelegate: PreferencesDelegate?

    // Profile controls
    private var profilePopup: NSPopUpButton?
    private var saveButton: NSButton?
    private var deleteButton: NSButton?

    // Fan column (left)
    private let fanColumn = NSStackView()
    private var fanRangeLabels: [Int: NSTextField] = [:]
    private var fanSegments: [Int: NSSegmentedControl] = [:]

    // Sensor column (right, scrollable)
    private let sensorStack = NSStackView()
    private let sensorScroll = NSScrollView()
    private var tempValueLabels: [String: NSTextField] = [:]
    private var tempNameLabels: [String: NSTextField] = [:]
    private var hottestKey: String = ""

    // Update tracking
    private var currentSensorKeys: [String] = []
    private var currentFanCount: Int = -1
    private var lastFans: [Fan] = []

    // Custom fan dialog controls (active during modal)
    private var dialogRPMRadio: NSButton?
    private var dialogSensorRadio: NSButton?
    private var dialogRPMSlider: NSSlider?
    private var dialogRPMLabel: NSTextField?
    private var dialogSensorPopup: NSPopUpButton?
    private var dialogMinTempField: NSTextField?
    private var dialogMaxTempField: NSTextField?

    // MARK: - Init

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MySMC"
        window.center()
        window.minSize = NSSize(width: 560, height: 340)
        window.isReleasedWhenClosed = false

        self.init(window: window)
        buildUI()
    }

    // MARK: - Public API

    func update(temps: [TemperatureReading], fans: [Fan]) {
        guard window?.isVisible == true else { return }

        lastFans = fans
        let sensorKeys = temps.map(\.key)
        let fanCount = fans.count

        if fanCount != currentFanCount {
            rebuildFanColumn(fans: fans)
            currentFanCount = fanCount
        }

        if sensorKeys != currentSensorKeys {
            rebuildSensorColumn(temps: temps)
            currentSensorKeys = sensorKeys
        }

        updateValues(temps: temps, fans: fans)
    }

    func refreshControls() {
        refreshProfilePopup()
        // Force fan column rebuild on next update to reflect mode changes
        currentFanCount = -1
    }

    // MARK: - Build UI

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        let profileRow = buildProfileRow()
        cv.addSubview(profileRow)

        let topDiv = makeDivider()
        cv.addSubview(topDiv)

        // Fan column (left)
        fanColumn.orientation = .vertical
        fanColumn.alignment = .leading
        fanColumn.spacing = 6
        fanColumn.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(fanColumn)

        // Sensor scroll (right)
        sensorScroll.translatesAutoresizingMaskIntoConstraints = false
        sensorScroll.hasVerticalScroller = true
        sensorScroll.hasHorizontalScroller = false
        sensorScroll.drawsBackground = false
        sensorScroll.borderType = .noBorder
        sensorScroll.autohidesScrollers = true

        sensorStack.orientation = .vertical
        sensorStack.alignment = .leading
        sensorStack.spacing = 2
        sensorStack.translatesAutoresizingMaskIntoConstraints = false

        sensorScroll.documentView = sensorStack
        sensorStack.widthAnchor.constraint(equalTo: sensorScroll.contentView.widthAnchor).isActive = true
        cv.addSubview(sensorScroll)

        let bottomDiv = makeDivider()
        cv.addSubview(bottomDiv)

        let bottomRow = buildBottomRow()
        cv.addSubview(bottomRow)

        NSLayoutConstraint.activate([
            profileRow.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
            profileRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            profileRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),

            topDiv.topAnchor.constraint(equalTo: profileRow.bottomAnchor, constant: 8),
            topDiv.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            topDiv.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),

            fanColumn.topAnchor.constraint(equalTo: topDiv.bottomAnchor, constant: 8),
            fanColumn.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            fanColumn.widthAnchor.constraint(equalTo: cv.widthAnchor, multiplier: 0.45, constant: -24),

            sensorScroll.topAnchor.constraint(equalTo: topDiv.bottomAnchor, constant: 8),
            sensorScroll.leadingAnchor.constraint(equalTo: fanColumn.trailingAnchor, constant: 20),
            sensorScroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            sensorScroll.bottomAnchor.constraint(equalTo: bottomDiv.topAnchor, constant: -8),

            bottomDiv.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            bottomDiv.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),

            bottomRow.topAnchor.constraint(equalTo: bottomDiv.bottomAnchor, constant: 8),
            bottomRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            bottomRow.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -12),
        ])

        // Placeholders
        fanColumn.addArrangedSubview(makeSectionHeader("Fans"))
        fanColumn.addArrangedSubview(makeLabel("Waiting for data\u{2026}",
                                               font: .systemFont(ofSize: 12),
                                               color: .secondaryLabelColor))
        sensorStack.addArrangedSubview(makeSectionHeader("Temperature Sensors"))
        sensorStack.addArrangedSubview(makeLabel("Waiting for data\u{2026}",
                                                  font: .systemFont(ofSize: 12),
                                                  color: .secondaryLabelColor))
    }

    private func buildProfileRow() -> NSView {
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let label = makeLabel("Active preset:", font: .systemFont(ofSize: 12, weight: .medium))
        label.setContentHuggingPriority(.required, for: .horizontal)

        let popup = NSPopUpButton()
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.controlSize = .regular
        popup.font = .systemFont(ofSize: 12)
        popup.target = self
        popup.action = #selector(profileChanged(_:))
        profilePopup = popup

        let newBtn = makeSmallButton("New\u{2026}", action: #selector(newProfile))
        let dupBtn = makeSmallButton("Duplicate", action: #selector(duplicateProfile))
        let saveBtn = makeSmallButton("Save", action: #selector(saveProfile))
        saveButton = saveBtn
        let delBtn = makeSmallButton("Delete", action: #selector(deleteProfile))
        deleteButton = delBtn

        row.addArrangedSubview(label)
        row.addArrangedSubview(popup)
        row.addArrangedSubview(newBtn)
        row.addArrangedSubview(dupBtn)
        row.addArrangedSubview(saveBtn)
        row.addArrangedSubview(delBtn)

        return row
    }

    private func buildBottomRow() -> NSView {
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let prefsBtn = NSButton(title: "Preferences\u{2026}", target: self,
                                action: #selector(showPreferencesDialog))
        prefsBtn.bezelStyle = .rounded
        prefsBtn.controlSize = .regular
        prefsBtn.font = .systemFont(ofSize: 12)

        row.addArrangedSubview(spacer)
        row.addArrangedSubview(prefsBtn)

        return row
    }

    // MARK: - Rebuild Fan Column

    private func rebuildFanColumn(fans: [Fan]) {
        fanColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        fanRangeLabels.removeAll()
        fanSegments.removeAll()

        // Column headers matching MFC table style
        let header = makeFanColumnHeader()
        fanColumn.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: fanColumn.widthAnchor).isActive = true
        fanColumn.addArrangedSubview(makeDivider())

        for fan in fans {
            let fanView = makeFanView(fan: fan)
            fanColumn.addArrangedSubview(fanView)
            fanView.widthAnchor.constraint(equalTo: fanColumn.widthAnchor).isActive = true
        }

        if fans.isEmpty {
            fanColumn.addArrangedSubview(makeLabel("No fans detected",
                                                    font: .systemFont(ofSize: 12),
                                                    color: .secondaryLabelColor))
        }
    }

    // MARK: - Rebuild Sensor Column

    private func rebuildSensorColumn(temps: [TemperatureReading]) {
        sensorStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tempValueLabels.removeAll()
        tempNameLabels.removeAll()

        sensorStack.addArrangedSubview(makeSectionHeader("Temperature Sensors"))

        let colHeader = makeColumnHeader(left: "Sensor", right: "Value \u{00B0}C")
        sensorStack.addArrangedSubview(colHeader)
        colHeader.widthAnchor.constraint(equalTo: sensorStack.widthAnchor).isActive = true
        sensorStack.addArrangedSubview(makeDivider())

        let hottestReading = temps.max(by: { $0.celsius < $1.celsius })
        hottestKey = hottestReading?.key ?? ""

        for group in SensorGroup.allCases {
            let groupTemps = temps.filter { reading in
                TemperatureMonitor.sensorInfo(for: reading.key)?.group == group
            }
            guard !groupTemps.isEmpty else { continue }

            let header = makeLabel(group.rawValue,
                                   font: .systemFont(ofSize: 11, weight: .medium),
                                   color: .tertiaryLabelColor)
            sensorStack.addArrangedSubview(header)

            for reading in groupTemps {
                let row = makeSensorRow(reading: reading, isHottest: reading.key == hottestKey)
                sensorStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: sensorStack.widthAnchor).isActive = true
            }
            sensorStack.addArrangedSubview(makeSpacer(2))
        }
    }

    // MARK: - Update Values

    private func updateValues(temps: [TemperatureReading], fans: [Fan]) {
        let hottestReading = temps.max(by: { $0.celsius < $1.celsius })
        let newHottestKey = hottestReading?.key ?? ""

        for reading in temps {
            tempValueLabels[reading.key]?.stringValue = String(format: "%.0f", reading.celsius)
            tempValueLabels[reading.key]?.textColor = tempColor(for: reading.celsius)

            if let nameLabel = tempNameLabels[reading.key] {
                let isHottest = reading.key == newHottestKey
                let wasHottest = reading.key == hottestKey
                if isHottest != wasHottest {
                    nameLabel.textColor = isHottest ? .systemOrange : .labelColor
                }
            }
        }
        hottestKey = newHottestKey

        for fan in fans {
            fanRangeLabels[fan.index]?.attributedStringValue = makeRPMRangeString(
                min: fan.minimum, actual: fan.actual, max: fan.maximum)
        }
    }

    // MARK: - Profile Actions

    private func refreshProfilePopup() {
        guard let popup = profilePopup, let delegate = prefsDelegate else { return }

        popup.removeAllItems()
        let profiles = delegate.availableProfiles()
        let activeId = delegate.activeProfileId()
        for (i, profile) in profiles.enumerated() {
            popup.addItem(withTitle: profile.name)
            if profile.id == activeId { popup.selectItem(at: i) }
        }

        deleteButton?.isEnabled = !delegate.isProfileBuiltIn(id: activeId)
    }

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        guard let delegate = prefsDelegate else { return }
        let profiles = delegate.availableProfiles()
        let idx = sender.indexOfSelectedItem
        guard idx >= 0 && idx < profiles.count else { return }
        delegate.preferencesDidSelectProfile(id: profiles[idx].id)
        refreshProfilePopup()
        currentFanCount = -1  // force fan column rebuild
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

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            prefsDelegate?.preferencesDidCreateProfile(name: name)
            refreshProfilePopup()
            currentFanCount = -1
        }
    }

    @objc private func duplicateProfile() {
        prefsDelegate?.preferencesDidDuplicateProfile()
        refreshProfilePopup()
        currentFanCount = -1
    }

    @objc private func saveProfile() {
        prefsDelegate?.preferencesDidSaveProfile()
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
            currentFanCount = -1
        }
    }

    // MARK: - Fan Control Actions

    @objc private func fanControlChanged(_ sender: NSSegmentedControl) {
        let fanIndex = sender.tag
        if sender.selectedSegment == 0 {
            prefsDelegate?.preferencesDidChangeFanMode(fanIndex: fanIndex, mode: .auto)
        } else {
            showCustomFanDialog(fanIndex: fanIndex)
        }
    }

    // MARK: - Custom Fan Dialog

    /// Detected sensor list for the custom dialog popup (key, label pairs).
    private var detectedSensors: [(key: String, label: String)] = []

    private func showCustomFanDialog(fanIndex: Int) {
        guard let delegate = prefsDelegate else { return }

        let fanLabel = lastFans.first(where: { $0.index == fanIndex })?.label ?? "Fan \(fanIndex)"
        let minRPM = delegate.fanMinRPM(for: fanIndex)
        let maxRPM = delegate.fanMaxRPM(for: fanIndex)
        let currentMode = delegate.fanMode(for: fanIndex)
        let currentRPM = delegate.fanTargetRPM(for: fanIndex) ?? minRPM

        let currentSensor = delegate.fanReferenceSensor(for: fanIndex)
        var currentMinTemp: Double = 40
        var currentMaxTemp: Double = 90
        if let curve = delegate.fanCurve(for: fanIndex), curve.points.count >= 2 {
            currentMinTemp = curve.points.first!.temperature
            currentMaxTemp = curve.points.last!.temperature
        }

        // Build detected sensor list (only sensors present on this hardware)
        detectedSensors = currentSensorKeys.compactMap { key in
            guard let info = TemperatureMonitor.sensorInfo(for: key) else { return nil }
            return (key: key, label: info.label)
        }
        if detectedSensors.isEmpty {
            detectedSensors = knownSensors.map { (key: $0.key, label: $0.label) }
        }

        let alert = NSAlert()
        alert.messageText = "Change fan control for the '\(fanLabel)' fan"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        // ── Build accessory view (frame-based container for reliable sizing) ──
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 170))

        // Constant RPM row
        let rpmRadio = NSButton(radioButtonWithTitle: "Constant RPM value",
                                target: self, action: #selector(dialogModeToggled(_:)))
        rpmRadio.tag = 0
        rpmRadio.translatesAutoresizingMaskIntoConstraints = false
        dialogRPMRadio = rpmRadio

        let rpmSlider = NSSlider(value: currentRPM, minValue: minRPM, maxValue: maxRPM,
                                 target: self, action: #selector(dialogRPMChanged(_:)))
        rpmSlider.controlSize = .regular
        rpmSlider.isContinuous = true
        rpmSlider.translatesAutoresizingMaskIntoConstraints = false
        dialogRPMSlider = rpmSlider

        let rpmValueLabel = NSTextField(labelWithString: String(format: "%.0f", currentRPM))
        rpmValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        rpmValueLabel.alignment = .right
        rpmValueLabel.translatesAutoresizingMaskIntoConstraints = false
        rpmValueLabel.isBordered = true
        rpmValueLabel.drawsBackground = true
        dialogRPMLabel = rpmValueLabel

        container.addSubview(rpmRadio)
        container.addSubview(rpmSlider)
        container.addSubview(rpmValueLabel)

        // Sensor-based row
        let sensorRadio = NSButton(radioButtonWithTitle: "Sensor-based value",
                                   target: self, action: #selector(dialogModeToggled(_:)))
        sensorRadio.tag = 1
        sensorRadio.translatesAutoresizingMaskIntoConstraints = false
        dialogSensorRadio = sensorRadio

        let sensorPopup = NSPopUpButton()
        sensorPopup.translatesAutoresizingMaskIntoConstraints = false
        sensorPopup.controlSize = .regular
        sensorPopup.font = .systemFont(ofSize: 12)
        for sensor in detectedSensors {
            sensorPopup.addItem(withTitle: sensor.label)
        }
        if let key = currentSensor,
           let idx = detectedSensors.firstIndex(where: { $0.key == key }) {
            sensorPopup.selectItem(at: idx)
        }
        dialogSensorPopup = sensorPopup

        container.addSubview(sensorRadio)
        container.addSubview(sensorPopup)

        // Min temp row
        let minDescLabel = makeLabel("Temperature that the fan speed will\nstart to increase from:",
                                     font: .systemFont(ofSize: 12))
        container.addSubview(minDescLabel)

        let minField = NSTextField(string: String(format: "%.0f", currentMinTemp))
        minField.alignment = .right
        minField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        minField.translatesAutoresizingMaskIntoConstraints = false
        dialogMinTempField = minField
        container.addSubview(minField)

        let minUnit = makeLabel("\u{00B0}C", font: .systemFont(ofSize: 12))
        container.addSubview(minUnit)

        // Max temp row
        let maxDescLabel = makeLabel("Maximum temperature:",
                                     font: .systemFont(ofSize: 12))
        container.addSubview(maxDescLabel)

        let maxField = NSTextField(string: String(format: "%.0f", currentMaxTemp))
        maxField.alignment = .right
        maxField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        maxField.translatesAutoresizingMaskIntoConstraints = false
        dialogMaxTempField = maxField
        container.addSubview(maxField)

        let maxUnit = makeLabel("\u{00B0}C", font: .systemFont(ofSize: 12))
        container.addSubview(maxUnit)

        // ── Layout (Auto Layout inside frame-based container) ──
        NSLayoutConstraint.activate([
            // Row 1: Constant RPM — radio + slider + value
            rpmRadio.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            rpmRadio.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            rpmSlider.centerYAnchor.constraint(equalTo: rpmRadio.centerYAnchor),
            rpmSlider.leadingAnchor.constraint(equalTo: rpmRadio.trailingAnchor, constant: 8),
            rpmSlider.trailingAnchor.constraint(equalTo: rpmValueLabel.leadingAnchor, constant: -8),

            rpmValueLabel.centerYAnchor.constraint(equalTo: rpmRadio.centerYAnchor),
            rpmValueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rpmValueLabel.widthAnchor.constraint(equalToConstant: 54),

            // Row 2: Sensor-based — radio + popup
            sensorRadio.topAnchor.constraint(equalTo: rpmRadio.bottomAnchor, constant: 14),
            sensorRadio.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            sensorPopup.centerYAnchor.constraint(equalTo: sensorRadio.centerYAnchor),
            sensorPopup.leadingAnchor.constraint(equalTo: sensorRadio.trailingAnchor, constant: 8),
            sensorPopup.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            // Row 3: Min temp description + field + unit
            minDescLabel.topAnchor.constraint(equalTo: sensorRadio.bottomAnchor, constant: 12),
            minDescLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            minField.centerYAnchor.constraint(equalTo: minDescLabel.centerYAnchor),
            minField.trailingAnchor.constraint(equalTo: minUnit.leadingAnchor, constant: -4),
            minField.widthAnchor.constraint(equalToConstant: 46),

            minUnit.centerYAnchor.constraint(equalTo: minDescLabel.centerYAnchor),
            minUnit.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            // Row 4: Max temp description + field + unit
            maxDescLabel.topAnchor.constraint(equalTo: minDescLabel.bottomAnchor, constant: 10),
            maxDescLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            maxField.centerYAnchor.constraint(equalTo: maxDescLabel.centerYAnchor),
            maxField.trailingAnchor.constraint(equalTo: maxUnit.leadingAnchor, constant: -4),
            maxField.widthAnchor.constraint(equalToConstant: 46),

            maxUnit.centerYAnchor.constraint(equalTo: maxDescLabel.centerYAnchor),
            maxUnit.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // Set initial state
        let isSensor = currentMode == .curve
        rpmRadio.state = isSensor ? .off : .on
        sensorRadio.state = isSensor ? .on : .off
        setDialogControlsEnabled(sensorBased: isSensor)

        alert.accessoryView = container

        // ── Run dialog ──
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if rpmRadio.state == .on {
                let rpm = rpmSlider.doubleValue
                delegate.preferencesDidChangeFanMode(fanIndex: fanIndex, mode: .fixed)
                delegate.preferencesDidChangeFanRPM(fanIndex: fanIndex, rpm: rpm)
            } else {
                let sensorIdx = sensorPopup.indexOfSelectedItem
                let sensorKey: String? = (sensorIdx >= 0 && sensorIdx < detectedSensors.count)
                    ? detectedSensors[sensorIdx].key : nil
                let minTemp = Double(minField.stringValue) ?? 40
                let maxTemp = Double(maxField.stringValue) ?? 90

                let curve = FanCurve(points: [
                    FanCurvePoint(temperature: minTemp, rpm: minRPM),
                    FanCurvePoint(temperature: maxTemp, rpm: maxRPM),
                ])

                delegate.preferencesDidChangeFanMode(fanIndex: fanIndex, mode: .curve)
                delegate.preferencesDidChangeFanCurve(fanIndex: fanIndex, curve: curve)
                delegate.preferencesDidChangeFanReferenceSensor(fanIndex: fanIndex, sensorKey: sensorKey)
            }
            fanSegments[fanIndex]?.selectedSegment = 1
        } else {
            let mode = delegate.fanMode(for: fanIndex)
            fanSegments[fanIndex]?.selectedSegment = mode == .auto ? 0 : 1
        }

        dialogRPMRadio = nil
        dialogSensorRadio = nil
        dialogRPMSlider = nil
        dialogRPMLabel = nil
        dialogSensorPopup = nil
        dialogMinTempField = nil
        dialogMaxTempField = nil
    }

    private func setDialogControlsEnabled(sensorBased: Bool) {
        dialogRPMSlider?.isEnabled = !sensorBased
        dialogSensorPopup?.isEnabled = sensorBased
        dialogMinTempField?.isEnabled = sensorBased
        dialogMaxTempField?.isEnabled = sensorBased
    }

    @objc private func dialogModeToggled(_ sender: NSButton) {
        let isSensor = sender.tag == 1
        dialogRPMRadio?.state = isSensor ? .off : .on
        dialogSensorRadio?.state = isSensor ? .on : .off
        setDialogControlsEnabled(sensorBased: isSensor)
    }

    @objc private func dialogRPMChanged(_ sender: NSSlider) {
        dialogRPMLabel?.stringValue = String(format: "%.0f", sender.doubleValue)
    }

    // MARK: - Preferences Dialog

    @objc private func showPreferencesDialog() {
        let alert = NSAlert()
        alert.messageText = "Preferences"
        alert.addButton(withTitle: "Done")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let toggle = NSButton(checkboxWithTitle: "Start at Login (recommended)",
                              target: nil, action: nil)
        toggle.state = LaunchAgentManager.shared.isInstalled ? .on : .off
        stack.addArrangedSubview(toggle)

        let hint = makeLabel("MySMC will launch automatically as root when you log in,\n"
                             + "keeping your fan settings active without any extra steps.",
                             font: .systemFont(ofSize: 11),
                             color: .secondaryLabelColor)
        stack.addArrangedSubview(hint)

        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack

        alert.runModal()

        // Apply toggle state
        if toggle.state == .on && !LaunchAgentManager.shared.isInstalled {
            try? LaunchAgentManager.shared.install()
        } else if toggle.state == .off && LaunchAgentManager.shared.isInstalled {
            LaunchAgentManager.shared.uninstall()
        }
    }

    // MARK: - View Builders

    private func makeFanView(fan: Fan) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        // Fan name (fixed width to align with header)
        let nameLabel = makeLabel(fan.label, font: .systemFont(ofSize: 12, weight: .medium))
        nameLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
        nameLabel.lineBreakMode = .byTruncatingTail

        // RPM range: min — current — max
        let rangeLabel = NSTextField(labelWithString: "")
        rangeLabel.translatesAutoresizingMaskIntoConstraints = false
        rangeLabel.alignment = .center
        rangeLabel.attributedStringValue = makeRPMRangeString(
            min: fan.minimum, actual: fan.actual, max: fan.maximum)
        fanRangeLabels[fan.index] = rangeLabel

        // Auto/Custom segmented control
        let mode = prefsDelegate?.fanMode(for: fan.index) ?? .auto
        let segment = NSSegmentedControl(labels: ["Auto", "Custom\u{2026}"],
                                          trackingMode: .selectOne,
                                          target: self,
                                          action: #selector(fanControlChanged(_:)))
        segment.translatesAutoresizingMaskIntoConstraints = false
        segment.tag = fan.index
        segment.selectedSegment = mode == .auto ? 0 : 1
        segment.setContentHuggingPriority(.required, for: .horizontal)
        fanSegments[fan.index] = segment

        row.addArrangedSubview(nameLabel)
        row.addArrangedSubview(rangeLabel)
        row.addArrangedSubview(segment)

        return row
    }

    private func makeFanColumnHeader() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let color = NSColor.secondaryLabelColor

        let fanLabel = makeLabel("Fan", font: font, color: color)
        fanLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let rpmLabel = makeLabel("Min/Current/Max RPM", font: font, color: color)
        rpmLabel.alignment = .center

        let ctrlLabel = makeLabel("Control", font: font, color: color)
        ctrlLabel.alignment = .right
        ctrlLabel.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(fanLabel)
        row.addArrangedSubview(rpmLabel)
        row.addArrangedSubview(ctrlLabel)

        return row
    }

    private func makeSensorRow(reading: TemperatureReading, isHottest: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        // Colored indicator dot (MFC-style)
        let dot = makeLabel("\u{25CF}", font: .systemFont(ofSize: 8),
                            color: tempColor(for: reading.celsius))
        dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
        dot.alignment = .center

        let nameLabel = makeLabel(reading.label, font: .systemFont(ofSize: 12),
                                  color: isHottest ? .systemOrange : .labelColor)
        tempNameLabels[reading.key] = nameLabel

        let valueLabel = makeLabel(
            String(format: "%.0f", reading.celsius),
            font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            color: tempColor(for: reading.celsius))
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        tempValueLabels[reading.key] = valueLabel

        row.addArrangedSubview(dot)
        row.addArrangedSubview(nameLabel)
        row.addArrangedSubview(valueLabel)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        return row
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

    private func makeColumnHeader(left: String, right: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let leftLabel = makeLabel(left, font: .systemFont(ofSize: 11, weight: .medium),
                                  color: .secondaryLabelColor)
        let rightLabel = makeLabel(right, font: .systemFont(ofSize: 11, weight: .medium),
                                   color: .secondaryLabelColor)
        rightLabel.alignment = .right

        row.addArrangedSubview(leftLabel)
        row.addArrangedSubview(rightLabel)
        leftLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        return row
    }

    private func makeSmallButton(_ title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11)
        return btn
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

    /// MFC-style "min — **current** — max" with bolded current value.
    private func makeRPMRangeString(min: Double?, actual: Double?, max: Double?) -> NSAttributedString {
        let minStr = min.map { String(format: "%.0f", $0) } ?? "--"
        let actStr = actual.map { String(format: "%.0f", $0) } ?? "--"
        let maxStr = max.map { String(format: "%.0f", $0) } ?? "--"

        let normal: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let bold: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ]

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "\(minStr) \u{2014} ", attributes: normal))
        result.append(NSAttributedString(string: actStr, attributes: bold))
        result.append(NSAttributedString(string: " \u{2014} \(maxStr)", attributes: normal))
        return result
    }
}
