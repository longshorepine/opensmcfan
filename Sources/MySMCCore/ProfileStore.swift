import Foundation

// MARK: - Profile Store

/// Loads, saves, and manages profiles on disk.
///
/// Profiles are stored as individual JSON files in:
///   ~/Library/Application Support/MySMC/profiles/
public final class ProfileStore {
    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.directory = appSupport.appendingPathComponent("MySMC/profiles")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Ensure the profiles directory exists, owned by the console user.
    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        chownToConsoleUser(directory.path)
    }

    /// Sanitize a profile ID to prevent path traversal (we run as root).
    private func sanitizedFilename(for id: String) -> String {
        let safe = id.replacingOccurrences(of: "..", with: "")
                     .replacingOccurrences(of: "/", with: "_")
                     .replacingOccurrences(of: "\\", with: "_")
        return safe.isEmpty ? "untitled" : safe
    }

    /// Save a profile to disk, owned by the console user so the user
    /// can manage files even though the app runs as root.
    public func save(_ profile: Profile) throws {
        try ensureDirectory()
        let url = directory.appendingPathComponent("\(sanitizedFilename(for: profile.id)).json")
        var p = profile
        p.modified = Date()
        let data = try encoder.encode(p)
        try data.write(to: url, options: .atomic)
        chownToConsoleUser(url.path)
    }

    /// Transfer ownership of a path to the logged-in console user.
    /// No-op if the console user can't be determined or we're not root.
    private func chownToConsoleUser(_ path: String) {
        guard geteuid() == 0 else { return }
        // stat /dev/console gives the UID of whoever is at the keyboard.
        var st = stat()
        guard stat("/dev/console", &st) == 0 else { return }
        lchown(path, st.st_uid, st.st_gid)
    }

    /// Load a profile by ID.
    public func load(id: String) throws -> Profile {
        let url = directory.appendingPathComponent("\(sanitizedFilename(for: id)).json")
        let data = try Data(contentsOf: url)
        return try decoder.decode(Profile.self, from: data)
    }

    /// Load all profiles from disk.
    public func loadAll() -> [Profile] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Profile.self, from: data)
            }
            .sorted(by: { $0.name < $1.name })
    }

    /// Delete a profile by ID. Returns false if it was built-in.
    @discardableResult
    public func delete(id: String) -> Bool {
        if let profile = try? load(id: id), profile.builtIn {
            return false
        }
        let url = directory.appendingPathComponent("\(sanitizedFilename(for: id)).json")
        try? FileManager.default.removeItem(at: url)
        return true
    }

    /// Create (or regenerate) default built-in profiles.
    /// Regenerates any built-in profile whose stored fan count doesn't match
    /// the current hardware — handles stale profiles written before root access
    /// was available, or after hardware changes.
    public func createDefaultsIfNeeded(fans: [Fan]) {
        let existing = loadAll()
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        let defaults: [Profile] = [
            .autoProfile(fans: fans),
            .quietProfile(fans: fans),
            .balancedProfile(fans: fans),
            .coolProfile(fans: fans),
            .maxProfile(fans: fans),
        ]

        for profile in defaults {
            let stored = existingByID[profile.id]
            let missing = stored == nil
            let stale = stored.map { $0.fans.count != fans.count } ?? false
            if missing || stale {
                try? save(profile)
            }
        }
    }

}
