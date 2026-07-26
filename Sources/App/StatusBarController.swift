import AppKit

// MARK: - Status Bar Controller

/// Manages the menu bar icon, popover dashboard, right-click menu, and polling.
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let smc: SMCConnection
    private let tempMonitor: TemperatureMonitor
    private let fanReader: FanReader
    private let dashboardVC: DashboardViewController
    private var pollTimer: DispatchSourceTimer?
    private var eventMonitor: Any?

    init(smc: SMCConnection) {
        self.smc = smc
        self.tempMonitor = TemperatureMonitor(smc: smc)
        self.fanReader = FanReader(smc: smc)
        self.dashboardVC = DashboardViewController()

        // Status bar item
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Popover
        self.popover = NSPopover()
        self.popover.contentViewController = dashboardVC
        self.popover.behavior = .transient

        super.init()

        // Configure button
        if let button = statusItem.button {
            button.title = "--°C"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Close popover when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }

        startPolling()
    }

    func shutdown() {
        pollTimer?.cancel()
        pollTimer = nil
        smc.close()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Click Handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Bring popover to front
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    // MARK: - Right-Click Menu

    private func showMenu() {
        let menu = NSMenu()

        // Temperature summary
        let temps = tempMonitor.readAll()
        if let hottest = tempMonitor.hottest(from: temps) {
            let tempItem = NSMenuItem(
                title: "\(hottest.label): \(String(format: "%.0f", hottest.celsius))°C",
                action: nil,
                keyEquivalent: ""
            )
            tempItem.isEnabled = false
            menu.addItem(tempItem)
        }

        // Fan summary
        let fans = fanReader.readAllFans()
        for fan in fans {
            let rpmStr = fan.actual.map { String(format: "%.0f RPM", $0) } ?? "-- RPM"
            let fanItem = NSMenuItem(
                title: "Fan \(fan.index): \(rpmStr)",
                action: nil,
                keyEquivalent: ""
            )
            fanItem.isEnabled = false
            menu.addItem(fanItem)
        }

        menu.addItem(NSMenuItem.separator())

        // About
        let aboutItem = NSMenuItem(title: "About MySMC", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(
            title: "Quit MySMC",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        // Show menu — temporarily assign to status item
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // Reset so left-click works again
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "MySMC"
        alert.informativeText = "Open-source SMC Fan Control for Intel Macs\nVersion 1.0.0"
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Polling

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.pollTimer = timer
    }

    private func poll() {
        let temps = tempMonitor.readAll()
        let fans = fanReader.readAllFans()
        let hottestTemp = temps.map(\.celsius).max() ?? 0

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Update menu bar title
            if hottestTemp > 0 {
                self.statusItem.button?.title = String(format: "%.0f°C", hottestTemp)
            }

            // Color the title based on temperature
            if let button = self.statusItem.button {
                let color: NSColor
                if hottestTemp >= 90 {
                    color = .systemRed
                } else if hottestTemp >= 75 {
                    color = .systemOrange
                } else {
                    color = .labelColor
                }
                button.attributedTitle = NSAttributedString(
                    string: button.title,
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
}
