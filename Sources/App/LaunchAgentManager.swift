import Foundation

// Installs/removes the LaunchAgent that auto-starts MySMC as root on login.
// Must be called from a root process (we're already root after elevation).
final class LaunchAgentManager {
    static let shared = LaunchAgentManager()
    private init() {}

    private let plistPath = "/Library/LaunchAgents/com.mysmc.app.plist"
    private let label    = "com.mysmc.app"

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    func install() throws {
        guard let execPath = Bundle.main.executablePath else { return }
        let content = plistXML(execPath: execPath)
        try content.write(toFile: plistPath, atomically: true, encoding: .utf8)
        chmod(plistPath, 0o644)
        shell("/bin/launchctl", ["bootstrap", "gui/\(consoleUID())", plistPath])
    }

    func uninstall() {
        shell("/bin/launchctl", ["bootout", "gui/\(consoleUID())", plistPath])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    // MARK: - Private

    private func plistXML(execPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>\(execPath)</string></array>
            <key>UserName</key><string>root</string>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><false/>
        </dict>
        </plist>
        """
    }

    private func consoleUID() -> String {
        let task = Process()
        task.launchPath = "/usr/bin/stat"
        task.arguments = ["-f", "%u", "/dev/console"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "501"
    }

    @discardableResult
    private func shell(_ path: String, _ args: [String]) -> Int32 {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        try? task.run(); task.waitUntilExit()
        return task.terminationStatus
    }
}
