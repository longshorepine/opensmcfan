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

    /// Ensure the profiles directory exists.
    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// Save a profile to disk.
    public func save(_ profile: Profile) throws {
        try ensureDirectory()
        let url = directory.appendingPathComponent("\(profile.id).json")
        var p = profile
        p.modified = Date()
        let data = try encoder.encode(p)
        try data.write(to: url, options: .atomic)
    }

    /// Load a profile by ID.
    public func load(id: String) throws -> Profile {
        let url = directory.appendingPathComponent("\(id).json")
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
        let url = directory.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
        return true
    }

    /// Create default built-in profiles if none exist.
    public func createDefaultsIfNeeded(fanCount: Int, minRPM: Double, maxRPM: Double) {
        let existing = loadAll()
        let existingIDs = Set(existing.map(\.id))

        let defaults: [Profile] = [
            .autoProfile(fanCount: fanCount),
            .quietProfile(fanCount: fanCount, minRPM: minRPM),
            .balancedProfile(fanCount: fanCount, minRPM: minRPM, maxRPM: maxRPM),
            .coolProfile(fanCount: fanCount, minRPM: minRPM, maxRPM: maxRPM),
            .maxProfile(fanCount: fanCount, maxRPM: maxRPM),
        ]

        for profile in defaults where !existingIDs.contains(profile.id) {
            try? save(profile)
        }
    }

    /// Export a profile to a .smcprofile file.
    public func exportProfile(_ profile: Profile, to url: URL) throws {
        let data = try encoder.encode(profile)
        try data.write(to: url, options: .atomic)
    }

    /// Import a profile from a .smcprofile file.
    public func importProfile(from url: URL) throws -> Profile {
        let data = try Data(contentsOf: url)
        var profile = try decoder.decode(Profile.self, from: data)
        profile.builtIn = false  // imported profiles are never built-in

        // Avoid ID collision
        let existing = Set(loadAll().map(\.id))
        if existing.contains(profile.id) {
            profile.id = profile.id + "_imported_\(Int(Date().timeIntervalSince1970))"
        }

        try save(profile)
        return profile
    }
}
