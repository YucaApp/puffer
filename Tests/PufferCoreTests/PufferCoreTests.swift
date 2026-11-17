import Foundation
import Testing
@testable import PufferCore

private func feed(_ matcher: inout Matcher, _ text: String) -> Expansion? {
    var result: Expansion?
    for character in text {
        result = matcher.type(character)
    }
    return result
}

@Suite struct MatcherTests {
    let entries = [
        Entry(title: "Sig", shortcode: ";sig", text: "Kind regards", trigger: .space),
        Entry(title: "Addr", shortcode: "addr", text: "1 High Street", trigger: .period),
        Entry(title: "Short", shortcode: "br", text: "Best regards", trigger: .space),
        Entry(title: "Long", shortcode: "xbr", text: "Extra best regards", trigger: .space),
    ]

    @Test func expandsOnSpace() {
        var matcher = Matcher(entries: entries)
        #expect(feed(&matcher, ";sig ") == Expansion(deleteCount: 4, text: "Kind regards "))
    }

    @Test func expandsOnPeriod() {
        var matcher = Matcher(entries: entries)
        // The period is always dropped, whatever keepsTrigger says.
        #expect(feed(&matcher, "send to addr.") == Expansion(deleteCount: 4, text: "1 High Street"))
        #expect(matcher.backspace() == Expansion(deleteCount: 13, text: "addr."))
    }

    @Test func wrongTriggerDoesNothing() {
        var matcher = Matcher(entries: entries)
        #expect(feed(&matcher, ";sig.") == nil)
        #expect(feed(&matcher, " addr ") == nil)
    }

    @Test func letterShortcodeMustStartAWord() {
        var matcher = Matcher(entries: entries)
        #expect(feed(&matcher, "zebr ") == nil)
        #expect(feed(&matcher, "br ") == Expansion(deleteCount: 2, text: "Best regards "))
    }

    @Test func punctuationShortcodeCanFollowAnything() {
        var matcher = Matcher(entries: entries)
        #expect(feed(&matcher, "word;sig ") == Expansion(deleteCount: 4, text: "Kind regards "))
    }

    @Test func longestShortcodeWins() {
        var matcher = Matcher(entries: [
            Entry(shortcode: ";a", text: "short", trigger: .space),
            Entry(shortcode: ";;a", text: "long", trigger: .space),
        ])
        #expect(feed(&matcher, ";;a ") == Expansion(deleteCount: 3, text: "long "))
    }

    @Test func firstEntryInTheLibraryWinsBetweenIdenticalShortcodes() {
        // Enough entries that an unstable sort would have room to reorder.
        var entries = (0..<40).map { Entry(shortcode: ";k\($0 % 10)", text: "filler \($0)", trigger: .space) }
        entries.insert(Entry(shortcode: ";dup", text: "first", trigger: .space), at: 7)
        entries.insert(Entry(shortcode: ";dup", text: "second", trigger: .space), at: 23)
        entries.append(Entry(shortcode: ";dup", text: "third", trigger: .space))
        var matcher = Matcher(entries: entries)
        #expect(feed(&matcher, ";dup ") == Expansion(deleteCount: 4, text: "first "))
        #expect(feed(&matcher, ";k3 ") == Expansion(deleteCount: 3, text: "filler 3 "))
    }

    @Test func backspaceCorrectsTypos() {
        var matcher = Matcher(entries: entries)
        _ = feed(&matcher, ";sih")
        #expect(matcher.backspace() == nil)
        #expect(matcher.backspace() == nil)
        #expect(feed(&matcher, "ig ") == Expansion(deleteCount: 4, text: "Kind regards "))
    }

    @Test func resetForgetsWhatWasTyped() {
        var matcher = Matcher(entries: entries)
        _ = feed(&matcher, ";si")
        matcher.reset()
        #expect(feed(&matcher, "g ") == nil)
    }

    @Test func bufferIsClearedAfterExpansion() {
        var matcher = Matcher(entries: entries)
        _ = feed(&matcher, ";sig ")
        #expect(matcher.bufferContents.isEmpty)
    }

    @Test func emptyShortcodeOrTextIsIgnored() {
        var matcher = Matcher(entries: [
            Entry(shortcode: "", text: "nothing", trigger: .space),
            Entry(shortcode: ";x", text: "", trigger: .space),
        ])
        #expect(feed(&matcher, " ") == nil)
        #expect(feed(&matcher, ";x ") == nil)
    }

    @Test func immediateExpandsOnLastCharacter() {
        var matcher = Matcher(entries: [Entry(shortcode: "kz", text: "me@example.com", trigger: .immediate)])
        // The final "z" is swallowed, so only the "k" needs deleting.
        #expect(feed(&matcher, "kz") == Expansion(deleteCount: 1, text: "me@example.com"))
    }

    @Test func immediateStillRespectsWordStart() {
        var matcher = Matcher(entries: [Entry(shortcode: "kz", text: "me@example.com", trigger: .immediate)])
        #expect(feed(&matcher, "blitzkz") == nil)
        #expect(feed(&matcher, " kz") == Expansion(deleteCount: 1, text: "me@example.com"))
    }

    @Test func triggerCanBeDropped() {
        var matcher = Matcher(entries: [
            Entry(shortcode: ";sig", text: "Kind regards", trigger: .space, keepsTrigger: false)
        ])
        #expect(feed(&matcher, ";sig ") == Expansion(deleteCount: 4, text: "Kind regards"))
    }

    @Test func deleteRightAfterExpansionRestoresWhatWasTyped() {
        var matcher = Matcher(entries: entries)
        _ = feed(&matcher, ";sig ")
        // "Kind regards " is 13 characters; put back ";sig ".
        #expect(matcher.backspace() == Expansion(deleteCount: 13, text: ";sig "))
        // Only once.
        #expect(matcher.backspace() == nil)
    }

    @Test func undoOfImmediateExpansion() {
        var matcher = Matcher(entries: [Entry(shortcode: "kz", text: "me@example.com", trigger: .immediate)])
        _ = feed(&matcher, "kz")
        #expect(matcher.backspace() == Expansion(deleteCount: 14, text: "kz"))
    }

    @Test func undoWithDroppedTriggerRestoresTrigger() {
        var matcher = Matcher(entries: [
            Entry(shortcode: ";sig", text: "Kind regards", trigger: .space, keepsTrigger: false)
        ])
        _ = feed(&matcher, ";sig ")
        #expect(matcher.backspace() == Expansion(deleteCount: 12, text: ";sig "))
    }

    @Test func undoIsForgottenOnceTypingContinues() {
        var matcher = Matcher(entries: entries)
        _ = feed(&matcher, ";sig ")
        _ = matcher.type("x")
        #expect(matcher.backspace() == nil)
    }

    @Test func undoIsForgottenOnReset() {
        var matcher = Matcher(entries: entries)
        _ = feed(&matcher, ";sig ")
        matcher.reset()
        #expect(matcher.backspace() == nil)
    }

    @Test func undoneShortcodeDoesNotReExpandByItself() {
        var matcher = Matcher(entries: [Entry(shortcode: "kz", text: "me@example.com", trigger: .immediate)])
        _ = feed(&matcher, "kz")
        _ = matcher.backspace()
        #expect(matcher.bufferContents.isEmpty)
        #expect(matcher.type("!") == nil)
    }

    @Test func veryLongExpansionsAreNotUndone() {
        // Undo is one backspace per character: too slow past a few hundred.
        let short = String(repeating: "x", count: Matcher.maxUndoLength)
        var matcher = Matcher(entries: [Entry(shortcode: ";s", text: short, trigger: .immediate)])
        _ = feed(&matcher, ";s")
        #expect(matcher.backspace() == Expansion(deleteCount: Matcher.maxUndoLength, text: ";s"))

        matcher = Matcher(entries: [Entry(shortcode: ";l", text: short + "x", trigger: .immediate)])
        #expect(feed(&matcher, ";l") != nil)
        #expect(matcher.backspace() == nil)
    }

    @Test func bufferStaysBounded() {
        var matcher = Matcher(entries: entries)
        _ = feed(&matcher, String(repeating: "a", count: 1000))
        #expect(matcher.bufferContents.count == Matcher.maxBufferLength)
    }
}

@Suite struct LibraryTests {
    @Test func detectsConflictingShortcodes() {
        let a = Entry(shortcode: ";a", text: "1", trigger: .space)
        let b = Entry(shortcode: ";a", text: "2", trigger: .space)
        let c = Entry(shortcode: ";a", text: "3", trigger: .period)
        let library = Library(folders: [Folder(name: "One", entries: [a]), Folder(name: "Two", entries: [b, c])])
        #expect(library.hasConflict(for: a))
        #expect(library.hasConflict(for: b))
        #expect(!library.hasConflict(for: c))
    }

    @Test func searchMatchesTitleShortcodeAndText() {
        let entry = Entry(title: "Signature", shortcode: ";sig", text: "Kind regards", trigger: .space)
        #expect(entry.matches(search: "signa"))
        #expect(entry.matches(search: ";SIG"))
        #expect(entry.matches(search: "regards"))
        #expect(entry.matches(search: "  "))
        #expect(!entry.matches(search: "invoice"))
    }

    @Test func readsFilesWrittenBeforeNewerFields() throws {
        let json = #"{"version":1,"folders":[{"id":"6B10F5F3-8625-4650-888C-601185712BA2","name":"G","entries":[{"id":"7C186251-E592-49CD-B698-A936420D7038","title":"t","shortcode":"s","text":"x","trigger":"space"}]}]}"#
        let library = try LibraryStore.decode(Data(json.utf8))
        #expect(library.folders[0].entries[0].keepsTrigger == true)
    }

    @Test func defaultLocationIsApplicationSupport() {
        let path = LibraryStore.default.fileURL.path
        #expect(path.hasSuffix("/Library/Application Support/Puffer/library.json"))
        #expect(LibraryStore.default.isDefault)
    }

    @Test func customFolderOverridesTheDefault() {
        #expect(LibraryStore.at(customFolder: nil).isDefault)
        #expect(LibraryStore.at(customFolder: "  ").isDefault)

        let custom = LibraryStore.at(customFolder: "/tmp/somewhere/Puffer")
        #expect(custom.fileURL.path == "/tmp/somewhere/Puffer/library.json")
        #expect(custom.directory.path == "/tmp/somewhere/Puffer")
        #expect(!custom.isDefault)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(LibraryStore.at(customFolder: "~/Shared/Puffer").fileURL.path == home + "/Shared/Puffer/library.json")
    }

    @Test func storeRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("puffer-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(fileURL: directory.appendingPathComponent("Puffer/library.json"))

        #expect(try store.load() == nil)
        try store.save(Library.starter)
        let loaded = try store.load()
        #expect(loaded?.folders.first?.entries.first?.shortcode == ";hello")
    }

    private func temporaryStore() -> LibraryStore {
        LibraryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("puffer-tests-\(UUID().uuidString)"))
    }

    private func write(_ json: String, to store: LibraryStore) throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.fileURL)
    }

    private let entryJSON = #"{"id":"7C186251-E592-49CD-B698-A936420D7038","title":"t","shortcode":"s","text":"x","trigger":"TRIGGER"}"#

    private func libraryJSON(version: Int, trigger: String = "space") -> String {
        let entry = entryJSON.replacingOccurrences(of: "TRIGGER", with: trigger)
        return #"{"version":\#(version),"folders":[{"id":"6B10F5F3-8625-4650-888C-601185712BA2","name":"G","entries":[\#(entry)]}]}"#
    }

    @Test func readClassifiesWhatIsOnDisk() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        #expect(try store.read() == .missing)

        try write(libraryJSON(version: 1), to: store)
        guard case .current(let library, let data) = try store.read() else {
            Issue.record("expected a current library")
            return
        }
        #expect(library.folders[0].entries[0].shortcode == "s")
        #expect(data == Data(libraryJSON(version: 1).utf8))

        try write("not json", to: store)
        #expect(try store.read() == .corrupt(data: Data("not json".utf8)))
    }

    @Test func aFileFromANewerVersionIsRecognisedNotCalledCorrupt() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        // Readable by this version apart from its number.
        try write(libraryJSON(version: Library.currentVersion + 1), to: store)
        guard case .newer(let version, let library, _) = try store.read() else {
            Issue.record("expected a newer library")
            return
        }
        #expect(version == Library.currentVersion + 1)
        #expect(library?.folders.count == 1)

        // Not readable by this version at all: still newer, not corrupt.
        try write(#"{"version":7,"groups":{}}"#, to: store)
        guard case .newer(7, nil, _) = try store.read() else {
            Issue.record("expected an unreadable newer library")
            return
        }
    }

    @Test func newerVersionIsDetectedFromRawBytes() {
        #expect(LibraryStore.newerVersion(in: Data(libraryJSON(version: 1).utf8)) == nil)
        #expect(LibraryStore.newerVersion(in: Data(libraryJSON(version: 2).utf8)) == 2)
        #expect(LibraryStore.newerVersion(in: Data("half a fi".utf8)) == nil)
    }

    @Test func unknownTriggerDoesNotFailTheWholeFile() throws {
        let library = try LibraryStore.decode(Data(libraryJSON(version: 1, trigger: "tab").utf8))
        #expect(library.folders[0].entries[0].trigger == .space)
        #expect(library.folders[0].entries[0].text == "x")
    }

    @Test func aFileThatCannotBeReadIsAnErrorNotAMissingOrCorruptFile() throws {
        let store = temporaryStore()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
            try? FileManager.default.removeItem(at: store.directory)
        }
        try write(libraryJSON(version: 1), to: store)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)

        // The caller must be able to tell "could not read" from "nothing
        // there" and "garbage", because only the last two may be replaced.
        #expect(throws: (any Error).self) { try store.read() }
        #expect(store.exists)
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func savedFileIsPrivateToTheUser() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("puffer-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory.appendingPathComponent("Puffer"))

        try store.save(Library.starter)
        #expect(try permissions(store.fileURL) == 0o600)
        #expect(try permissions(store.directory) == 0o700)

        // A file left world-readable by an older version is tightened.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
        try store.save(Library.starter)
        #expect(try permissions(store.fileURL) == 0o600)

        // Nothing but the library is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path) == ["library.json"])
    }

    @Test func existingFolderPermissionsAreLeftAlone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("puffer-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // A folder the user chose (a shared or synced one) is theirs to manage.
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        let store = LibraryStore(directory: directory)
        try store.save(Library.starter)
        #expect(try permissions(directory) == 0o755)
        #expect(try permissions(store.fileURL) == 0o600)
    }

    @Test func unreadableFileIsMovedAsideNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("puffer-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LibraryStore(fileURL: directory.appendingPathComponent("library.json"))
        try Data("not json".utf8).write(to: store.fileURL)

        #expect(throws: (any Error).self) { try store.load() }
        let moved = try store.quarantine()
        #expect(try String(contentsOf: moved, encoding: .utf8) == "not json")
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}

@Suite struct TypingTests {
    @Test func plainTextIsTyped() {
        #expect(Typing.prefersTyping("Kind regards"))
        #expect(Typing.prefersTyping("me@example.com"))
        #expect(Typing.prefersTyping("café 👨‍👩‍👧‍👦 ok"))
    }

    @Test func lineBreaksAndTabsArePasted() {
        // As key events these would act as Return and Tab.
        #expect(!Typing.isTypable("Dear Sir,\nThank you"))
        #expect(!Typing.isTypable("a\r\nb"))
        #expect(!Typing.isTypable("a\tb"))
        #expect(!Typing.isTypable("a\u{2028}b"))
        #expect(!Typing.isTypable(""))
    }

    @Test func longTextIsPastedButStillTypable() {
        let long = String(repeating: "x", count: Typing.typedLimit + 1)
        #expect(Typing.isTypable(long))
        #expect(!Typing.prefersTyping(long))
        #expect(Typing.prefersTyping(String(long.dropLast())))
    }

    @Test func chunksFitInOneKeyEventEach() {
        let text = String(repeating: "abcdefghij", count: 7) + "!"
        let chunks = Typing.chunks(text)
        #expect(chunks.count == 4)
        #expect(chunks.allSatisfy { $0.count <= Typing.maxUnitsPerEvent })
        #expect(String(utf16CodeUnits: chunks.flatMap { $0 }, count: text.utf16.count) == text)
    }

    @Test func chunksNeverSplitACharacter() {
        // Each family emoji is 11 UTF-16 units: two do not fit in one event.
        let family = "👨‍👩‍👧‍👦"
        let text = "ab" + family + family + "e\u{301}"
        let chunks = Typing.chunks(text)
        #expect(chunks.allSatisfy { $0.count <= Typing.maxUnitsPerEvent })
        let pieces = chunks.map { String(utf16CodeUnits: $0, count: $0.count) }
        #expect(pieces == ["ab" + family, family + "e\u{301}"])
    }

    @Test func aCharacterTooBigForOneEventIsNotTypable() {
        let zalgo = "a" + String(repeating: "\u{301}", count: 30)
        #expect(!Typing.isTypable(zalgo))
    }
}
