import Foundation

/// What fires an entry's expansion.
public enum Trigger: String, Codable, CaseIterable, Sendable {
    /// Typing a space straight after the shortcode.
    case space
    /// Typing a period straight after the shortcode.
    case period
    /// Nothing extra: expands the moment the shortcode's last character is typed.
    case immediate

    /// The key typed after the shortcode, or nil for `.immediate`.
    public var character: Character? {
        switch self {
        case .space: return " "
        case .period: return "."
        case .immediate: return nil
        }
    }

    public var label: String {
        switch self {
        case .space: return "Space"
        case .period: return "Period"
        case .immediate: return "Immediately"
        }
    }
}

public struct Entry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var shortcode: String
    public var text: String
    public var trigger: Trigger
    /// Whether the space that fired the expansion is typed after the expanded
    /// text. Only applies to `.space`: a trigger period is always dropped.
    public var keepsTrigger: Bool

    public init(
        id: UUID = UUID(),
        title: String = "",
        shortcode: String = "",
        text: String = "",
        trigger: Trigger = .space,
        keepsTrigger: Bool = true
    ) {
        self.id = id
        self.title = title
        self.shortcode = shortcode
        self.text = text
        self.trigger = trigger
        self.keepsTrigger = keepsTrigger
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        shortcode = try container.decodeIfPresent(String.self, forKey: .shortcode) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        // A trigger this version does not know (a hand-edited file, or one
        // from a newer Puffer) must not make the whole library unreadable.
        let rawTrigger = try container.decodeIfPresent(String.self, forKey: .trigger)
        trigger = rawTrigger.flatMap(Trigger.init(rawValue:)) ?? .space
        // Absent in files written before this option existed.
        keepsTrigger = try container.decodeIfPresent(Bool.self, forKey: .keepsTrigger) ?? true
    }

    /// Case-insensitive match against title, shortcode and text.
    public func matches(search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return true }
        return [title, shortcode, text].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

public struct Folder: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var entries: [Entry]

    public init(id: UUID = UUID(), name: String, entries: [Entry] = []) {
        self.id = id
        self.name = name
        self.entries = entries
    }
}

public struct Library: Codable, Equatable, Sendable {
    /// The file format this version of Puffer reads and writes. Raise it
    /// whenever a change would lose data if an older Puffer rewrote the
    /// file (a new trigger, a new field): older versions refuse to save
    /// over a file with a higher number.
    public static let currentVersion = 1

    public var version: Int
    public var folders: [Folder]

    public init(version: Int = Library.currentVersion, folders: [Folder] = []) {
        self.version = version
        self.folders = folders
    }

    public var allEntries: [Entry] {
        folders.flatMap(\.entries)
    }

    /// True when another entry would fire on exactly the same keystrokes.
    public func hasConflict(for entry: Entry) -> Bool {
        guard !entry.shortcode.isEmpty else { return false }
        return allEntries.contains {
            $0.id != entry.id && $0.shortcode == entry.shortcode && $0.trigger == entry.trigger
        }
    }

    /// What a brand new install starts with.
    public static var starter: Library {
        Library(folders: [
            Folder(name: "General", entries: [
                Entry(
                    title: "Sample",
                    shortcode: ";hello",
                    text: "Hello from Puffer!",
                    trigger: .space
                )
            ])
        ])
    }
}
