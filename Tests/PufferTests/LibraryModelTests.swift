import Foundation
import Testing
@testable import Puffer
import PufferCore

/// What the library model does with the file on disk: the cases where a
/// wrong move would destroy the user's library.
@MainActor
@Suite struct LibraryModelTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("puffer-model-tests-\(UUID().uuidString)")

    private var store: LibraryStore { LibraryStore(directory: directory) }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: store.fileURL)
    }

    private func onDisk() throws -> String {
        try String(contentsOf: store.fileURL, encoding: .utf8)
    }

    private func cleanUp() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func json(version: Int, shortcode: String = "s") -> String {
        #"{"version":\#(version),"folders":[{"id":"6B10F5F3-8625-4650-888C-601185712BA2","name":"G","entries":[{"id":"7C186251-E592-49CD-B698-A936420D7038","title":"t","shortcode":"\#(shortcode)","text":"x","trigger":"space"}]}]}"#
    }

    @Test func firstLaunchWritesTheStarterLibrary() throws {
        defer { cleanUp() }
        let model = LibraryModel(store: store)
        #expect(model.storageError == nil)
        #expect(try store.load()?.folders.first?.entries.first?.shortcode == ";hello")
    }

    @Test func aFileThatCannotBeReadIsNeverReplaced() throws {
        defer { cleanUp() }
        try write(json(version: 1))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)

        let model = LibraryModel(store: store)
        #expect(model.storageError != nil)

        // Neither launch nor a later edit may touch it.
        model.addFolder()
        model.saveNow()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        #expect(try onDisk() == json(version: 1))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["library.json"])
    }

    @Test func aDamagedFileIsMovedAsideAndReported() throws {
        defer { cleanUp() }
        try write("not json")
        let model = LibraryModel(store: store)
        #expect(model.storageError?.contains("moved to") == true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names.count == 2)
        #expect(names.contains { $0.hasPrefix("library.unreadable-") })
        #expect(try store.load() != nil)
    }

    @Test func aNewerFileAtLaunchIsUsedButNeverSavedOver() throws {
        defer { cleanUp() }
        let newer = json(version: Library.currentVersion + 1)
        try write(newer)

        let model = LibraryModel(store: store)
        #expect(model.library.allEntries.first?.shortcode == "s")
        #expect(model.storageError?.contains("newer version") == true)

        model.addFolder()
        model.saveNow()
        #expect(try onDisk() == newer)
    }

    @Test func aNewerFileArrivingLaterIsNotOverwrittenByTheNextEdit() throws {
        defer { cleanUp() }
        try write(json(version: 1))
        let model = LibraryModel(store: store)
        #expect(model.storageError == nil)

        // Another Mac running a newer Puffer syncs its file in, and the user
        // edits here before the two-second poll has noticed.
        let newer = json(version: Library.currentVersion + 1, shortcode: "fromnewer")
        try write(newer)
        model.addFolder()
        model.saveNow()

        #expect(try onDisk() == newer)
        #expect(model.storageError?.contains("newer version") == true)
        #expect(model.library.allEntries.first?.shortcode == "fromnewer")
    }

    @Test func anOrdinaryOutsideChangeStillLosesToALocalEdit() throws {
        defer { cleanUp() }
        try write(json(version: 1))
        let model = LibraryModel(store: store)
        try write(json(version: 1, shortcode: "other"))
        model.addFolder()
        model.saveNow()
        #expect(try store.load()?.folders.count == 2)
        #expect(model.storageError == nil)
    }

    @Test func anOutsideEditThatBreaksTheFileIsNotOverwritten() throws {
        defer { cleanUp() }
        try write(json(version: 1))
        let model = LibraryModel(store: store)

        // A hand edit leaves the file invalid, and the user then edits in
        // the app before noticing. Their outside edit must survive.
        let broken = json(version: 1, shortcode: "mine").dropLast() + ","
        try write(String(broken))
        model.addFolder()
        model.saveNow()
        #expect(try onDisk() == String(broken))
        #expect(model.storageError != nil)

        // Once the file is repaired it is picked up and saving resumes.
        try write(json(version: 1, shortcode: "mine"))
        model.reloadIfChangedOnDisk()
        #expect(model.storageError == nil)
        #expect(model.library.allEntries.first?.shortcode == "mine")
        model.addFolder()
        model.saveNow()
        #expect(try store.load()?.folders.count == 2)
    }

    @Test func aFileThatStaysBrokenIsReportedNotIgnored() throws {
        defer { cleanUp() }
        try write(json(version: 1))
        let model = LibraryModel(store: store)
        try write("{ half a fi")

        // One sighting could be a file caught mid-write.
        model.reloadIfChangedOnDisk()
        #expect(model.storageError == nil)
        // The same bytes again is a broken file.
        model.reloadIfChangedOnDisk()
        #expect(model.storageError != nil)
        #expect(try onDisk() == "{ half a fi")
        #expect(model.library.allEntries.first?.shortcode == "s")
    }

    @Test func aNewerLibraryThatDisappearsIsNotRewrittenFromMemory() throws {
        defer { cleanUp() }
        try write(json(version: Library.currentVersion + 1))
        let model = LibraryModel(store: store)

        try FileManager.default.removeItem(at: store.fileURL)
        model.reloadIfChangedOnDisk()
        model.addFolder()
        model.saveNow()
        // What is in memory is only the part this version understood.
        #expect(!store.exists)
    }

    @Test func movingANewerLibraryCopiesItByteForByte() throws {
        defer { cleanUp() }
        defer { UserDefaults.standard.removeObject(forKey: LibraryModel.customFolderKey) }
        let newer = json(version: Library.currentVersion + 1)
        try write(newer)
        let model = LibraryModel(store: store)

        let other = directory.appendingPathComponent("elsewhere")
        try model.relocate(to: other)
        let file = other.appendingPathComponent("library.json")
        #expect(try String(contentsOf: file, encoding: .utf8) == newer)

        model.addFolder()
        model.saveNow()
        #expect(try String(contentsOf: file, encoding: .utf8) == newer)
        #expect(model.storageError?.contains("newer version") == true)
    }

    @Test func movingToAFolderWithANewerLibraryDoesNotOverwriteIt() throws {
        defer { cleanUp() }
        let model = LibraryModel(store: store)
        let other = directory.appendingPathComponent("elsewhere")
        defer { UserDefaults.standard.removeObject(forKey: LibraryModel.customFolderKey) }
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let newer = json(version: Library.currentVersion + 1)
        let file = other.appendingPathComponent("library.json")
        try Data(newer.utf8).write(to: file)

        try model.relocate(to: other)
        model.addFolder()
        model.saveNow()
        #expect(try String(contentsOf: file, encoding: .utf8) == newer)
        #expect(model.storageError?.contains("newer version") == true)
    }
}
