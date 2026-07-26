import AppKit
import Security

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SMC fan control requires root. If we're not running as root,
        // ask the user to authenticate and re-launch with elevated privileges.
        if getuid() != 0 {
            requestPrivilegesAndRelaunch()
            return
        }

        // Running as root — normal startup.
        do {
            let smc = try SMCConnection()
            statusBarController = StatusBarController(smc: smc)
        } catch {
            fatalAlert(
                title: "MySMC — SMC Error",
                message: error.localizedDescription
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.shutdown()
    }

    // MARK: - Privilege Elevation

    private func requestPrivilegesAndRelaunch() {
        // Explain why before the password prompt appears.
        let info = NSAlert()
        info.messageText = "Administrator Access Required"
        info.informativeText = """
            MySMC needs administrator privileges to read and control fan speeds \
            via the System Management Controller (SMC).

            Click Authenticate to enter your password and continue.
            """
        info.addButton(withTitle: "Authenticate")
        info.addButton(withTitle: "Quit")
        info.alertStyle = .informational

        guard info.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return
        }

        var authRef: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess,
              let auth = authRef else {
            fatalAlert(title: "MySMC Error", message: "Could not initialize authorization.")
            return
        }
        defer { AuthorizationFree(auth, [.destroyRights]) }

        guard let execPath = Bundle.main.executablePath else {
            fatalAlert(title: "MySMC Error", message: "Cannot determine application executable path.")
            return
        }

        // mysmc_executeWithPrivileges is a C wrapper around the deprecated
        // AuthorizationExecuteWithPrivileges — Swift 5.3 marks it unavailable
        // directly but allows calling it through a C shim.
        // Passing NULL for args launches the binary with no extra arguments.
        let status: OSStatus = execPath.withCString { cPath in
            mysmc_executeWithPrivileges(auth, cPath, nil)
        }

        switch status {
        case errAuthorizationSuccess:
            // Root instance is now running; quit this user-level instance.
            NSApp.terminate(nil)
        case errAuthorizationCanceled, errAuthorizationDenied:
            // User cancelled or failed auth — just quit silently.
            NSApp.terminate(nil)
        default:
            fatalAlert(
                title: "MySMC — Authorization Failed",
                message: "Could not obtain administrator privileges (code \(status)).\n\n" +
                         "Alternative: run from Terminal with:\n  sudo \(execPath)"
            )
        }
    }

    // MARK: - Helpers

    private func fatalAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
