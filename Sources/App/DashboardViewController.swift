import AppKit

// MARK: - Dashboard Delegate

/// Minimal callback protocol for the lightweight popover.
protocol DashboardDelegate: AnyObject {
    func dashboardDidSelectProfile(id: String)
    func dashboardDidOpenPreferences()
    func availableProfiles() -> [(id: String, name: String)]
    func activeProfileId() -> String
}

// MARK: - Dashboard View Controller

/// Lightweight popover: current temperature, profile radio buttons,
/// Preferences button, Quit button.
final class DashboardViewController: NSViewController {
    weak var delegate: DashboardDelegate?

    // Temperature display
    private let tempLabel = NSTextField(labelWithString: "--")
    private let sensorLabel = NSTextField(labelWithString: "")

    // Profile radio buttons
    private var profileButtons: [NSButton] = []
    private let profileStack = NSStackView()

    // MARK: - Load View

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .centerX
        mainStack.spacing = 6
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 12, right: 20)

        // ── Title ──
        let title = NSTextField(labelWithString: "MySMC")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = .center

        // ── Temperature display ──
        tempLabel.font = .monospacedDigitSystemFont(ofSize: 48, weight: .light)
        tempLabel.textColor = .labelColor
        tempLabel.alignment = .center
        tempLabel.translatesAutoresizingMaskIntoConstraints = false

        sensorLabel.font = .systemFont(ofSize: 11)
        sensorLabel.textColor = .tertiaryLabelColor
        sensorLabel.alignment = .center
        sensorLabel.translatesAutoresizingMaskIntoConstraints = false

        // ── Separator ──
        let sep1 = NSBox()
        sep1.boxType = .separator
        sep1.translatesAutoresizingMaskIntoConstraints = false

        // ── Profile section ──
        let profileHeader = NSTextField(labelWithString: "Profile")
        profileHeader.font = .systemFont(ofSize: 11, weight: .medium)
        profileHeader.textColor = .secondaryLabelColor

        profileStack.orientation = .vertical
        profileStack.alignment = .leading
        profileStack.spacing = 2
        profileStack.translatesAutoresizingMaskIntoConstraints = false

        buildProfileButtons()

        // ── Separator ──
        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false

        // ── Bottom buttons ──
        let prefsButton = NSButton(title: "Preferences\u{2026}", target: self,
                                   action: #selector(openPreferences))
        prefsButton.bezelStyle = .inline
        prefsButton.controlSize = .regular
        prefsButton.font = .systemFont(ofSize: 12)
        prefsButton.translatesAutoresizingMaskIntoConstraints = false

        let quitButton = NSButton(title: "Quit MySMC", target: self,
                                  action: #selector(quitApp))
        quitButton.bezelStyle = .inline
        quitButton.controlSize = .regular
        quitButton.font = .systemFont(ofSize: 12)
        quitButton.translatesAutoresizingMaskIntoConstraints = false
        quitButton.keyEquivalent = "q"
        quitButton.keyEquivalentModifierMask = .command

        let buttonRow = NSStackView(views: [prefsButton, quitButton])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        // ── Assemble ──
        mainStack.addArrangedSubview(title)
        mainStack.addArrangedSubview(tempLabel)
        mainStack.addArrangedSubview(sensorLabel)
        mainStack.addArrangedSubview(sep1)
        mainStack.addArrangedSubview(profileHeader)
        mainStack.addArrangedSubview(profileStack)
        mainStack.addArrangedSubview(sep2)
        mainStack.addArrangedSubview(buttonRow)

        // Custom spacing
        mainStack.setCustomSpacing(0, after: tempLabel)
        mainStack.setCustomSpacing(12, after: sensorLabel)
        mainStack.setCustomSpacing(8, after: sep1)
        mainStack.setCustomSpacing(4, after: profileHeader)
        mainStack.setCustomSpacing(12, after: profileStack)
        mainStack.setCustomSpacing(10, after: sep2)

        container.addSubview(mainStack)

        // Width constraints for separators and button row
        for v: NSView in [sep1, sep2, buttonRow, profileStack] {
            v.widthAnchor.constraint(equalToConstant: 180).isActive = true
        }

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.view = container
        self.preferredContentSize = NSSize(width: 220, height: 320)
    }

    // MARK: - Public API

    /// Called by StatusBarController on each engine tick.
    func update(temps: [TemperatureReading], fans: [Fan]) {
        guard let hottest = temps.max(by: { $0.celsius < $1.celsius }) else { return }

        tempLabel.stringValue = String(format: "%.0f\u{00B0}C", hottest.celsius)
        tempLabel.textColor = tempColor(for: hottest.celsius)
        sensorLabel.stringValue = hottest.label
    }

    /// Refresh profile selection after external profile change.
    func refreshControls() {
        guard let delegate = delegate else { return }
        let activeId = delegate.activeProfileId()
        for button in profileButtons {
            guard let id = button.identifier?.rawValue else { continue }
            button.state = id == activeId ? .on : .off
        }
    }

    // MARK: - Profile Buttons

    private func buildProfileButtons() {
        profileStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        profileButtons.removeAll()

        guard let delegate = delegate else { return }
        let profiles = delegate.availableProfiles()
        let activeId = delegate.activeProfileId()

        for profile in profiles {
            let btn = NSButton(radioButtonWithTitle: profile.name,
                               target: self,
                               action: #selector(profileSelected(_:)))
            btn.identifier = NSUserInterfaceItemIdentifier(profile.id)
            btn.font = .systemFont(ofSize: 12)
            btn.state = profile.id == activeId ? .on : .off
            btn.translatesAutoresizingMaskIntoConstraints = false
            profileButtons.append(btn)
            profileStack.addArrangedSubview(btn)
        }
    }

    // MARK: - Actions

    @objc private func profileSelected(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        // Update radio button states
        for btn in profileButtons {
            btn.state = btn === sender ? .on : .off
        }
        delegate?.dashboardDidSelectProfile(id: id)
    }

    @objc private func openPreferences() {
        delegate?.dashboardDidOpenPreferences()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func tempColor(for celsius: Double) -> NSColor {
        if celsius >= 90 { return .systemRed }
        if celsius >= 75 { return .systemOrange }
        if celsius >= 60 { return .systemYellow }
        return .systemGreen
    }
}
