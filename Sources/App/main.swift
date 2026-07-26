import AppKit

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let smc = try SMCConnection()
            statusBarController = StatusBarController(smc: smc)
        } catch {
            let alert = NSAlert()
            alert.messageText = "MySMC Error"
            alert.informativeText = """
                \(error.localizedDescription)

                MySMC requires root access to read SMC sensors.
                Run with: sudo open MySMC.app
                """
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.shutdown()
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
