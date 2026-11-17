import Foundation

/// Reads and writes the library as a single JSON file.
public struct LibraryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static let fileName = "library.json"

    /// A library kept in `directory`, which the user may have chosen so that
    /// a sync tool can carry the file between Macs.
    public init(directory: URL) {
        self.init(fileURL: directory.appendingPathComponent(Self.fileName))
    }

    public var directory: URL { fileURL.deletingLastPathComponent() }

    /// `~/Library/Application Support/Puffer`.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Puffer", isDirectory: true)
    }

    /// Where the library lives unless the user has chosen somewhere else.
    public static var `default`: LibraryStore {
        LibraryStore(directory: defaultDirectory)
    }

    /// The store for the user's chosen folder (a path, `~` allowed), or the
    /// default store when nothing has been chosen.
    public static func at(customFolder path: String?) -> LibraryStore {
        guard let path, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return .default }
        let expanded = (path as NSString).expandingTildeInPath
        return LibraryStore(directory: URL(fileURLWithPath: expanded, isDirectory: true))
    }

    public var isDefault: Bool {
        fileURL.standardizedFileURL == Self.default.fileURL.standardizedFileURL
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// What `read()` found on disk.
    public enum Contents: Equatable, Sendable {
        /// No file yet.
        case missing
        /// A library this version can read and may rewrite.
        case current(Library, data: Data)
        /// A file written by a newer Puffer. It must never be overwritten.
        /// `library` is as much of it as this version understands, if any.
        case newer(version: Int, library: Library?, data: Data)
        /// A file that is not a library at all, or only half written.
        case corrupt(data: Data)
    }

    /// Reads and classifies the file. Throws only when a file exists but
    /// could not be read (permissions, a disk or network error), which says
    /// nothing about its contents: the caller must not replace it.
    public func read() throws -> Contents {
        guard let data = try loadData() else { return .missing }
        return Self.classify(data)
    }

    public static func classify(_ data: Data) -> Contents {
        let library = try? decode(data)
        if let version = newerVersion(in: data) {
            return .newer(version: version, library: library, data: data)
        }
        guard let library else { return .corrupt(data: data) }
        return .current(library, data: data)
    }

    /// The file's format version, if it is higher than this version of
    /// Puffer writes. Reads nothing but the version number, so it works on
    /// files whose other contents are unfamiliar.
    public static func newerVersion(in data: Data) -> Int? {
        struct Header: Decodable { let version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data),
              header.version > Library.currentVersion
        else { return nil }
        return header.version
    }

    /// The file's raw bytes, or nil when no file exists yet.
    public func loadData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    public static func decode(_ data: Data) throws -> Library {
        try JSONDecoder().decode(Library.self, from: data)
    }

    public static func encode(_ library: Library) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(library)
    }

    /// Returns nil when no file exists yet.
    public func load() throws -> Library? {
        try loadData().map(Self.decode)
    }

    /// Writes the library and returns the bytes written.
    ///
    /// The file holds whatever the user chose to put in their expansions, so
    /// it is readable by the user only (0600), and a folder created for it is
    /// 0700. A folder that already exists is the user's to manage and is left
    /// as it is.
    @discardableResult
    public func save(_ library: Library) throws -> Data {
        let data = try Self.encode(library)
        try write(data)
        return data
    }

    /// Writes `data` as the library file, exactly as given. Used directly
    /// only to copy a file this version cannot fully read.
    public func write(_ data: Data) throws {
        let files = FileManager.default
        if !files.fileExists(atPath: directory.path) {
            try files.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        // Write a private temporary file next to the real one, then rename
        // it into place: readers never see a half-written or 0644 file.
        let temporary = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString).tmp")
        guard files.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            try? files.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, fileURL.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? files.removeItem(at: temporary)
            throw POSIXError(code, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
    }

    /// Moves an unreadable file aside so it is never overwritten by a fresh
    /// library. Returns where it went.
    @discardableResult
    public func quarantine() throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = fileURL.deletingLastPathComponent()
            .appendingPathComponent("library.unreadable-\(stamp).json")
        try FileManager.default.moveItem(at: fileURL, to: destination)
        return destination
    }
}
