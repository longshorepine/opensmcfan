import AppKit

// MARK: - Dashboard View Controller

/// Main popover content showing temperatures and fan speeds.
/// Read-only for Phase 4 — fan control UI comes in Phase 5.
final class DashboardViewController: NSViewController {
    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()

    // Stored references for efficient updates
    private var tempValueLabels: [String: NSTextField] = [:]
    private var tempKeyLabels: [String: NSTextField] = [:]
    private var fanActualLabels: [Int: NSTextField] = [:]
    private var fanDetailLabels: [Int: NSTextField] = [:]
    private var fanBars: [Int: NSProgressIndicator] = [:]
    private var hottestKey: String = ""

    // Track layout state
    private var currentSensorKeys: [String] = []
    private var currentFanCount: Int = -1

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // Content stack
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
        self.preferredContentSize = NSSize(width: 320, height: 420)
    }

    // MARK: - Update

    func update(temps: [TemperatureReading], fans: [Fan]) {
        let sensorKeys = temps.map(\.key)
        let fanCount = fans.count

        // Rebuild views if sensor set or fan count changed
        if sensorKeys != currentSensorKeys || fanCount != currentFanCount {
            rebuildViews(temps: temps, fans: fans)
            currentSensorKeys = sensorKeys
            currentFanCount = fanCount
        } else {
            updateValues(temps: temps, fans: fans)
        }
    }

    // MARK: - Build Views

    private func rebuildViews(temps: [TemperatureReading], fans: [Fan]) {
        // Clear everything
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tempValueLabels.removeAll()
        tempKeyLabels.removeAll()
        fanActualLabels.removeAll()
        fanDetailLabels.removeAll()
        fanBars.removeAll()

        // Title
        let title = makeLabel("MySMC", font: .systemFont(ofSize: 16, weight: .semibold))
        contentStack.addArrangedSubview(title)
        contentStack.addArrangedSubview(makeSpacer(8))

        // ── Temperature Section ──
        contentStack.addArrangedSubview(makeSectionHeader("Temperatures"))
        contentStack.addArrangedSubview(makeSpacer(4))

        // Group sensors
        let hottestReading = temps.max(by: { $0.celsius < $1.celsius })
        hottestKey = hottestReading?.key ?? ""

        for group in SensorGroup.allCases {
            let groupTemps = temps.filter { reading in
                TemperatureMonitor.sensorInfo(for: reading.key)?.group == group
            }
            guard !groupTemps.isEmpty else { continue }

            // Group header
            let header = makeLabel(group.rawValue, font: .systemFont(ofSize: 11, weight: .medium),
                                   color: .secondaryLabelColor)
            contentStack.addArrangedSubview(header)

            // Sensor rows
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
            contentStack.addArrangedSubview(makeSpacer(4))
        }

        // Update preferred size based on content
        let contentHeight = contentStack.fittingSize.height + 24
        preferredContentSize = NSSize(width: 320, height: min(contentHeight, 500))
    }

    // MARK: - Update Values Only

    private func updateValues(temps: [TemperatureReading], fans: [Fan]) {
        let hottestReading = temps.max(by: { $0.celsius < $1.celsius })
        let newHottestKey = hottestReading?.key ?? ""

        for reading in temps {
            if let label = tempValueLabels[reading.key] {
                label.stringValue = String(format: "%.0f°C", reading.celsius)
                label.textColor = tempColor(for: reading.celsius)
            }
            // Update hottest highlight
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
            if let detail = fanDetailLabels[fan.index] {
                let target = fan.target.map { String(format: "%.0f", $0) } ?? "--"
                let min = fan.minimum.map { String(format: "%.0f", $0) } ?? "--"
                let max = fan.maximum.map { String(format: "%.0f", $0) } ?? "--"
                detail.stringValue = "Target: \(target)  Min: \(min)  Max: \(max)"
            }
            if let bar = fanBars[fan.index] {
                bar.minValue = fan.minimum ?? 0
                bar.maxValue = fan.maximum ?? 6500
                bar.doubleValue = fan.actual ?? 0
            }
        }
    }

    // MARK: - View Builders

    private func makeTempRow(reading: TemperatureReading, isHottest: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        // Key (monospaced, dim, highlights if hottest)
        let keyLabel = makeLabel(
            reading.key,
            font: .monospacedSystemFont(ofSize: 11, weight: .regular),
            color: isHottest ? .systemOrange : .tertiaryLabelColor
        )
        keyLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        tempKeyLabels[reading.key] = keyLabel

        // Friendly name
        let nameLabel = makeLabel(
            reading.label,
            font: .systemFont(ofSize: 12),
            color: .labelColor
        )

        // Temperature value (right-aligned, colored)
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

        // Make name expand to fill space
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
        container.spacing = 3
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 288).isActive = true

        // Fan name + RPM on same line
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .lastBaseline
        headerRow.spacing = 8

        let nameLabel = makeLabel(
            fan.label,
            font: .systemFont(ofSize: 13, weight: .semibold)
        )

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

        // Progress bar
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

        // Detail line
        let target = fan.target.map { String(format: "%.0f", $0) } ?? "--"
        let min = fan.minimum.map { String(format: "%.0f", $0) } ?? "--"
        let max = fan.maximum.map { String(format: "%.0f", $0) } ?? "--"
        let detailLabel = makeLabel(
            "Target: \(target)  Min: \(min)  Max: \(max)",
            font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            color: .secondaryLabelColor
        )
        fanDetailLabels[fan.index] = detailLabel

        container.addArrangedSubview(headerRow)
        container.addArrangedSubview(bar)
        container.addArrangedSubview(detailLabel)

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
        makeLabel(text, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
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
