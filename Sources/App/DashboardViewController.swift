import AppKit

// MARK: - Dashboard View Controller

/// Main popover content: temperatures, fan controls, profile switching.
final class DashboardViewController: NSViewController {
    weak var delegate: DashboardDelegate?

    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()

    // Profile controls
    private var profilePopup: NSPopUpButton?

    // Temperature references
    private var tempValueLabels: [String: NSTextField] = [:]
    private var tempKeyLabels: [String: NSTextField] = [:]
    private var hottestKey: String = ""

    // Fan control references
    private var fanActualLabels: [Int: NSTextField] = [:]
    private var fanBars: [Int: NSProgressIndicator] = [:]
    private var fanModeControls: [Int: NSSegmentedControl] = [:]
    private var fanSliders: [Int: NSSlider] = [:]
    private var fanSliderLabels: [Int: NSTextField] = [:]
    private var fanDetailLabels: [Int: NSTextField] = [:]

    // Layout state
    private var currentSensorKeys: [String] = []
    private var currentFanCount: Int = -1

    // MARK: - Load View

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        scrollView.documentView = contentStack
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        self.view = container
        self.preferredContentSize = NSSize(width: 320, height: 460)
    }

    // MARK: - Public API

    /// Called by StatusBarController on each engine tick.
    func update(temps: [TemperatureReading], fans: [Fan]) {
        let sensorKeys = temps.map(\.key)
        let fanCount = fans.count

        if sensorKeys != currentSensorKeys || fanCount != currentFanCount {
            rebuildViews(temps: temps, fans: fans)
            currentSensorKeys = sensorKeys
            currentFanCount = fanCount
        } else {
            updateValues(temps: temps, fans: fans)
        }
    }

    /// Refresh control states (mode toggles, sliders) after profile switch.
    func refreshControls() {
        guard let delegate = delegate else { return }

        // Update profile dropdown
        if let popup = profilePopup {
            let activeId = delegate.activeProfileId()
            let profiles = delegate.availableProfiles()
            for (i, profile) in profiles.enumerated() {
                if profile.id == activeId {
                    popup.selectItem(at: i)
                    break
                }
            }
        }

        // Update fan controls
        for (index, modeControl) in fanModeControls {
            let mode = delegate.fanMode(for: index)
            modeControl.selectedSegment = mode == .auto ? 0 : 1

            let isManual = mode == .fixed || mode == .curve
            fanSliders[index]?.isEnabled = isManual
            fanSliderLabels[index]?.isHidden = !isManual

            if isManual, let rpm = delegate.fanTargetRPM(for: index) {
                fanSliders[index]?.doubleValue = rpm
                fanSliderLabels[index]?.stringValue = String(format: "%.0f", rpm)
            }
        }
    }

    // MARK: - Rebuild Views

    private func rebuildViews(temps: [TemperatureReading], fans: [Fan]) {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tempValueLabels.removeAll()
        tempKeyLabels.removeAll()
        fanActualLabels.removeAll()
        fanBars.removeAll()
        fanModeControls.removeAll()
        fanSliders.removeAll()
        fanSliderLabels.removeAll()
        fanDetailLabels.removeAll()

        // ── Header + Profile ──
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.widthAnchor.constraint(equalToConstant: 288).isActive = true

        let title = makeLabel("MySMC", font: .systemFont(ofSize: 16, weight: .semibold))

        let popup = NSPopUpButton()
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.target = self
        popup.action = #selector(profileChanged(_:))

        if let delegate = delegate {
            let profiles = delegate.availableProfiles()
            let activeId = delegate.activeProfileId()
            for (i, profile) in profiles.enumerated() {
                popup.addItem(withTitle: profile.name)
                if profile.id == activeId {
                    popup.selectItem(at: i)
                }
            }
        }
        profilePopup = popup

        headerRow.addArrangedSubview(title)
        headerRow.addArrangedSubview(popup)
        title.setContentHuggingPriority(.required, for: .horizontal)
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        contentStack.addArrangedSubview(headerRow)
        contentStack.addArrangedSubview(makeSpacer(8))

        // ── Temperature Section ──
        contentStack.addArrangedSubview(makeSectionHeader("Temperatures"))
        contentStack.addArrangedSubview(makeSpacer(4))

        let hottestReading = temps.max(by: { $0.celsius < $1.celsius })
        hottestKey = hottestReading?.key ?? ""

        for group in SensorGroup.allCases {
            let groupTemps = temps.filter { reading in
                TemperatureMonitor.sensorInfo(for: reading.key)?.group == group
            }
            guard !groupTemps.isEmpty else { continue }

            let header = makeLabel(group.rawValue, font: .systemFont(ofSize: 11, weight: .medium),
                                   color: .secondaryLabelColor)
            contentStack.addArrangedSubview(header)

            for reading in groupTemps {
                let row = makeTempRow(reading: reading, isHottest: reading.key == hottestKey)
                contentStack.addArrangedSubview(row)
            }
            contentStack.addArrangedSubview(makeSpacer(4))
        }

        // ── Separator ──
        contentStack.addArrangedSubview(makeDivider())
        contentStack.addArrangedSubview(makeSpacer(4))

        // ── Fan Section ──
        contentStack.addArrangedSubview(makeSectionHeader("Fans"))
        contentStack.addArrangedSubview(makeSpacer(4))

        for fan in fans {
            let fanView = makeFanView(fan: fan)
            contentStack.addArrangedSubview(fanView)
            contentStack.addArrangedSubview(makeSpacer(8))
        }

        let contentHeight = contentStack.fittingSize.height + 24
        preferredContentSize = NSSize(width: 320, height: min(contentHeight, 550))
    }

    // MARK: - Update Values

    private func updateValues(temps: [TemperatureReading], fans: [Fan]) {
        let hottestReading = temps.max(by: { $0.celsius < $1.celsius })
        let newHottestKey = hottestReading?.key ?? ""

        for reading in temps {
            if let label = tempValueLabels[reading.key] {
                label.stringValue = String(format: "%.0f°C", reading.celsius)
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

    // MARK: - Actions

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        guard let delegate = delegate else { return }
        let profiles = delegate.availableProfiles()
        let selectedIndex = sender.indexOfSelectedItem
        guard selectedIndex >= 0 && selectedIndex < profiles.count else { return }
        delegate.dashboardDidSelectProfile(id: profiles[selectedIndex].id)
    }

    @objc private func fanModeChanged(_ sender: NSSegmentedControl) {
        let fanIndex = sender.tag
        let mode: FanMode = sender.selectedSegment == 0 ? .auto : .fixed
        let isManual = mode == .fixed

        fanSliders[fanIndex]?.isEnabled = isManual
        fanSliderLabels[fanIndex]?.isHidden = !isManual

        delegate?.dashboardDidChangeFanMode(fanIndex: fanIndex, mode: mode)
    }

    @objc private func fanSliderChanged(_ sender: NSSlider) {
        let fanIndex = sender.tag
        let rpm = sender.doubleValue
        fanSliderLabels[fanIndex]?.stringValue = String(format: "%.0f", rpm)
        delegate?.dashboardDidChangeFanRPM(fanIndex: fanIndex, rpm: rpm)
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
            String(format: "%.0f°C", reading.celsius),
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
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        row.widthAnchor.constraint(equalToConstant: 288).isActive = true

        return row
    }

    private func makeFanView(fan: Fan) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 288).isActive = true

        // Row 1: Fan name + actual RPM
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .lastBaseline
        headerRow.spacing = 8

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
        rpmLabel.setContentHuggingPriority(.required, for: .horizontal)
        headerRow.widthAnchor.constraint(equalToConstant: 288).isActive = true

        // Row 2: Progress bar (actual RPM gauge)
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = fan.minimum ?? 0
        bar.maxValue = fan.maximum ?? 6500
        bar.doubleValue = fan.actual ?? 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 288).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        bar.controlSize = .small
        fanBars[fan.index] = bar

        // Row 3: Detail line
        let target = fan.target.map { String(format: "%.0f", $0) } ?? "--"
        let minStr = fan.minimum.map { String(format: "%.0f", $0) } ?? "--"
        let maxStr = fan.maximum.map { String(format: "%.0f", $0) } ?? "--"
        let detailLabel = makeLabel(
            "Target: \(target)  Min: \(minStr)  Max: \(maxStr)",
            font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            color: .secondaryLabelColor
        )
        fanDetailLabels[fan.index] = detailLabel

        // Row 4: Mode toggle (Auto / Manual)
        let modeRow = NSStackView()
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = 8
        modeRow.translatesAutoresizingMaskIntoConstraints = false
        modeRow.widthAnchor.constraint(equalToConstant: 288).isActive = true

        let modeControl = NSSegmentedControl(labels: ["Auto", "Manual"], trackingMode: .selectOne,
                                              target: self, action: #selector(fanModeChanged(_:)))
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.controlSize = .small
        modeControl.font = .systemFont(ofSize: 11)
        modeControl.tag = fan.index
        modeControl.segmentStyle = .rounded

        let currentMode = delegate?.fanMode(for: fan.index) ?? .auto
        modeControl.selectedSegment = currentMode == .auto ? 0 : 1
        fanModeControls[fan.index] = modeControl

        modeRow.addArrangedSubview(modeControl)
        modeControl.setContentHuggingPriority(.required, for: .horizontal)

        // Row 5: RPM slider + value label (manual mode only)
        let sliderRow = NSStackView()
        sliderRow.orientation = .horizontal
        sliderRow.alignment = .centerY
        sliderRow.spacing = 8
        sliderRow.translatesAutoresizingMaskIntoConstraints = false
        sliderRow.widthAnchor.constraint(equalToConstant: 288).isActive = true

        let sliderMin = fan.minimum ?? 1200
        let sliderMax = fan.maximum ?? 6200
        let sliderValue = delegate?.fanTargetRPM(for: fan.index) ?? fan.actual ?? sliderMin

        let slider = NSSlider(value: sliderValue, minValue: sliderMin, maxValue: sliderMax,
                              target: self, action: #selector(fanSliderChanged(_:)))
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.controlSize = .small
        slider.tag = fan.index
        slider.isContinuous = true
        fanSliders[fan.index] = slider

        let sliderLabel = makeLabel(
            String(format: "%.0f", sliderValue),
            font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            color: .secondaryLabelColor
        )
        sliderLabel.alignment = .right
        sliderLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        fanSliderLabels[fan.index] = sliderLabel

        sliderRow.addArrangedSubview(slider)
        sliderRow.addArrangedSubview(sliderLabel)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sliderLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Show/hide slider based on mode
        let isManual = currentMode == .fixed || currentMode == .curve
        slider.isEnabled = isManual
        sliderLabel.isHidden = !isManual

        container.addArrangedSubview(headerRow)
        container.addArrangedSubview(bar)
        container.addArrangedSubview(detailLabel)
        container.addArrangedSubview(modeRow)
        container.addArrangedSubview(sliderRow)

        return container
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
        divider.widthAnchor.constraint(equalToConstant: 288).isActive = true
        return divider
    }

    private func tempColor(for celsius: Double) -> NSColor {
        if celsius >= 90 { return .systemRed }
        if celsius >= 75 { return .systemOrange }
        if celsius >= 60 { return .systemYellow }
        return .systemGreen
    }
}
