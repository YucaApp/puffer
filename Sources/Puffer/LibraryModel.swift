import Foundation
import Observation
import PufferCore
import SwiftUI

/// The editor's state: the library plus what is selected. Saves to disk
/// shortly after every change, and picks up changes made to the file by
/// something else (a sync tool bringing in edits from another Mac).
@MainActor
@Observable
final class LibraryModel {
    var library: Library {
        didSet {
            guard library != oldValue else { return }
            onChange?(library)
            if !isApplyingDiskChange { scheduleSave() }
        }
    }

    var selectedFolderID: Folder.ID? {
        didSet {
            guard selectedFolderID != oldValue else { return }
            selectedEntryID = selectedFolder?.entries.first?.id
        }
    }

    var selectedEntryID: Entry.ID?

    /// Filters the entry list across every folder while non-empty.
    var searchText = "" {
        didSet {
            // Leaving search: show the folder the selected entry lives in.
            guard !isSearching, let entryID = selectedEntryID,
                  let folder = folder(containing: entryID), folder.id != selectedFolderID
            else { return }
            selectedFolderID = folder.id
            selectedEntryID = entryID
        }
    }

    /// Bumped to ask the editor to put the cursor in the search field.
    var searchFocusRequests = 0

    /// The sidebar folder an entry is currently being dragged over.
    var dropTargetFolderID: Folder.ID?

    /// Whether the "delete this folder and its entries?" dialog is showing.
    var confirmingFolderDelete = false

    /// Set when the saved library could not be read or written.
    var storageError: String?

    /// Why the library on disk must not be written to, if it must not.
    private enum SaveBlock {
        /// The file exists but could not be read. Its contents are unknown,
        /// so replacing it could destroy the user's library.
        case unreadable
        /// The file was written by a newer Puffer and may hold things this
        /// version would drop.
        case newerVersion
        /// Something outside Puffer changed the file and it is no longer a
        /// valid library. It may hold edits the user wants to keep.
        case damaged
    }

    @ObservationIgnored private var saveBlock: SaveBlock?
    /// A file that could not be decoded on the last poll. Seen once it may
    /// just be half written; seen twice with the same bytes it is damaged.
    @ObservationIgnored private var suspectData: Data?

    @ObservationIgnored var onChange: ((Library) -> Void)?
    @ObservationIgnored private var store: LibraryStore
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    @ObservationIgnored private var isApplyingDiskChange = false
    /// The file's contents as we last read or wrote them.
    @ObservationIgnored private var lastKnownData: Data?
    @ObservationIgnored private var diskWatcher: Timer?

    /// Changes whenever the library moves, so views showing the path update.
    private(set) var storageDirectory: URL

    /// UserDefaults key holding the folder the user chose for the library.
    /// Absent means the default folder.
    nonisolated static let customFolderKey = "libraryFolder"

    /// The store the user's settings point at.
    nonisolated static var configuredStore: LibraryStore {
        .at(customFolder: UserDefaults.standard.string(forKey: customFolderKey))
    }

    init(store: LibraryStore = LibraryModel.configuredStore) {
        self.store = store
        storageDirectory = store.directory
        // Assigned to `library` once, below: a second assignment would count
        // as an edit and schedule a save.
        var initial = Library.starter
        var needsFirstSave = false
        var problem: (SaveBlock?, String)?
        do {
            switch try store.read() {
            case .missing:
                needsFirstSave = true
            case .current(let loaded, let data):
                initial = loaded
                lastKnownData = data
            case .newer(let version, let loaded, let data):
                if let loaded { initial = loaded }
                lastKnownData = data
                problem = (.newerVersion, Self.newerVersionMessage(version))
            case .corrupt:
                // Not a library. Keep it rather than overwrite it.
                if let moved = try? store.quarantine() {
                    needsFirstSave = true
                    problem = (nil, "The saved library was damaged and was moved to "
                        + "\(moved.lastPathComponent). Puffer started a new one.")
                } else {
                    problem = (.unreadable, "The saved library is damaged and could not be moved "
                        + "aside, so nothing will be saved.")
                }
            }
        } catch {
            // The file is there but could not be read just now. That says
            // nothing about what is in it, so leave it exactly as it is.
            problem = (.unreadable, Self.unreadableMessage(store, error))
        }
        library = initial
        saveBlock = problem?.0
        selectedFolderID = library.folders.first?.id
        selectedEntryID = library.folders.first?.entries.first?.id
        if needsFirstSave { saveNow() }
        // After the first save, which clears the message when it succeeds.
        if let problem { storageError = problem.1 }

        diskWatcher = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadIfChangedOnDisk() }
        }
    }

    private func block(_ reason: SaveBlock, _ message: String) {
        saveBlock = reason
        storageError = message
    }

    private static func newerVersionMessage(_ version: Int) -> String {
        "This library was saved by a newer version of Puffer (format \(version)). "
            + "Changes made here will not be saved. Update Puffer to edit it."
    }

    private static func damagedMessage(_ store: LibraryStore) -> String {
        "The library at \(store.fileURL.path) was changed outside Puffer and is no longer a valid library. "
            + "Nothing will be saved until it is repaired or removed; it has been left untouched."
    }

    private static func unreadableMessage(_ store: LibraryStore, _ error: Error) -> String {
        "The library at \(store.fileURL.path) could not be read (\(error.localizedDescription)). "
            + "It has been left untouched and nothing will be saved until it can be read."
    }

    // MARK: - Lookup

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var selectedFolder: Folder? {
        library.folders.first { $0.id == selectedFolderID }
    }

    /// The selected entry, wherever it lives: search results span folders.
    var selectedEntry: Entry? {
        guard let selectedEntryID else { return nil }
        return library.allEntries.first { $0.id == selectedEntryID }
    }

    func folder(containing entryID: Entry.ID) -> Folder? {
        library.folders.first { $0.entries.contains { $0.id == entryID } }
    }

    /// Entries matching the search, each with the folder it belongs to.
    var searchResults: [(entry: Entry, folder: Folder)] {
        library.folders.flatMap { folder in
            folder.entries.filter { $0.matches(search: searchText) }.map { ($0, folder) }
        }
    }

    private func folderIndex(_ id: Folder.ID?) -> Int? {
        library.folders.firstIndex { $0.id == id }
    }

    // MARK: - Bindings (looked up by id so a deleted row can't crash a view)

    func folderName(_ id: Folder.ID) -> Binding<String> {
        Binding(
            get: { self.library.folders.first { $0.id == id }?.name ?? "" },
            set: { newValue in
                guard let index = self.folderIndex(id) else { return }
                self.library.folders[index].name = newValue
            }
        )
    }

    func entry(_ id: Entry.ID, fallback: Entry) -> Binding<Entry> {
        Binding(
            get: { self.library.allEntries.first { $0.id == id } ?? fallback },
            set: { newValue in
                for folderIndex in self.library.folders.indices {
                    if let entryIndex = self.library.folders[folderIndex].entries.firstIndex(where: { $0.id == id }) {
                        self.library.folders[folderIndex].entries[entryIndex] = newValue
                        return
                    }
                }
            }
        )
    }

    // MARK: - Editing

    func addFolder() {
        let folder = Folder(name: "New Folder")
        library.folders.append(folder)
        searchText = ""
        selectedFolderID = folder.id
    }

    func deleteSelectedFolder() {
        guard let index = folderIndex(selectedFolderID) else { return }
        library.folders.remove(at: index)
        let neighbour = min(index, library.folders.count - 1)
        selectedFolderID = neighbour >= 0 ? library.folders[neighbour].id : nil
    }

    func addEntry() {
        guard let index = folderIndex(selectedFolderID) else { return }
        let entry = Entry(title: "New Entry")
        library.folders[index].entries.append(entry)
        // A new, empty entry would not match the search and so not be shown.
        searchText = ""
        selectedEntryID = entry.id
    }

    func deleteSelectedEntry() {
        guard let entryID = selectedEntryID,
              let folderIndex = library.folders.firstIndex(where: { $0.entries.contains { $0.id == entryID } }),
              let entryIndex = library.folders[folderIndex].entries.firstIndex(where: { $0.id == entryID })
        else { return }
        library.folders[folderIndex].entries.remove(at: entryIndex)
        if isSearching {
            selectedEntryID = searchResults.first?.entry.id
        } else {
            let remaining = library.folders[folderIndex].entries
            let neighbour = min(entryIndex, remaining.count - 1)
            selectedEntryID = neighbour >= 0 ? remaining[neighbour].id : nil
        }
    }

    /// Moves entries to the end of another folder. Entries already there
    /// stay put. Returns whether anything moved.
    @discardableResult
    func moveEntries(_ ids: [Entry.ID], toFolder folderID: Folder.ID) -> Bool {
        dropTargetFolderID = nil
        var updated = library
        guard let target = updated.folders.firstIndex(where: { $0.id == folderID }) else { return false }

        var moved: [Entry] = []
        for id in ids {
            guard let source = updated.folders.firstIndex(where: { $0.entries.contains { $0.id == id } }),
                  source != target,
                  let index = updated.folders[source].entries.firstIndex(where: { $0.id == id })
            else { continue }
            moved.append(updated.folders[source].entries.remove(at: index))
        }
        guard !moved.isEmpty else { return false }
        updated.folders[target].entries.append(contentsOf: moved)

        // If the selected entry just left the folder on show, select what
        // took its place rather than leaving the editor on a hidden entry.
        var nextSelection = selectedEntryID
        if !isSearching, let selected = selectedEntryID, moved.contains(where: { $0.id == selected }),
           let shown = folderIndex(selectedFolderID), shown != target {
            let before = library.folders[shown].entries
            let after = updated.folders[shown].entries
            let position = before.firstIndex { $0.id == selected } ?? 0
            nextSelection = after.isEmpty ? nil : after[min(position, after.count - 1)].id
        }

        library = updated // one assignment: one save, one engine update
        selectedEntryID = nextSelection
        return true
    }

    func moveFolders(from source: IndexSet, to destination: Int) {
        library.folders.move(fromOffsets: source, toOffset: destination)
    }

    func moveEntries(from source: IndexSet, to destination: Int) {
        guard let index = folderIndex(selectedFolderID) else { return }
        library.folders[index].entries.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Saving

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        // What is in memory from a newer Puffer's file is only the part
        // this version understood: never write it out.
        guard saveBlock == nil, library.version <= Library.currentVersion else { return }

        // The file may have been replaced since the last look. Local edits
        // win over an ordinary outside change, but never over a file that
        // cannot be read, a file from a newer Puffer, or one that is no
        // longer a valid library (it may hold edits made by hand).
        let onDisk: Data?
        do {
            onDisk = try store.loadData()
        } catch {
            storageError = Self.unreadableMessage(store, error)
            return
        }
        if let onDisk, onDisk != lastKnownData {
            switch LibraryStore.classify(onDisk) {
            case .newer:
                reloadIfChangedOnDisk()
                return
            case .corrupt:
                block(.damaged, Self.damagedMessage(store))
                return
            case .current, .missing:
                break
            }
        }

        do {
            lastKnownData = try store.save(library)
            storageError = nil
        } catch {
            storageError = "Could not save the library to \(store.fileURL.path): \(error.localizedDescription)"
        }
    }

    // MARK: - Moving the library

    var isAtDefaultLocation: Bool { store.isDefault }

    /// Switches to keeping the library in `directory` and remembers the
    /// choice. If that folder already holds a library, that library is
    /// loaded; otherwise the current one is written there. The file at the
    /// old location is left where it is.
    func relocate(to directory: URL) throws {
        let destination = LibraryStore(directory: directory)
        guard destination.fileURL.standardizedFileURL != store.fileURL.standardizedFileURL else { return }

        // Make sure the old location has the latest edits before leaving it.
        saveNow()

        let adopted: Library
        let data: Data
        var newBlock: (SaveBlock, String)?
        switch try destination.read() {
        case .missing:
            adopted = library
            if saveBlock == .newerVersion, let raw = lastKnownData {
                // Copy the newer file as it is; re-encoding it here would
                // drop whatever this version did not understand.
                try destination.write(raw)
                data = raw
                newBlock = (.newerVersion, storageError ?? "")
            } else if saveBlock != nil {
                throw RelocationError.currentUnreadable
            } else {
                data = try destination.save(library)
            }
        case .current(let existing, let existingData):
            adopted = existing
            data = existingData
        case .newer(let version, let existing, let existingData):
            guard let existing else { throw RelocationError.newerVersion(version) }
            adopted = existing
            data = existingData
            newBlock = (.newerVersion, Self.newerVersionMessage(version))
        case .corrupt:
            throw RelocationError.damaged(destination.fileURL)
        }

        store = destination
        storageDirectory = destination.directory
        lastKnownData = data
        saveBlock = newBlock?.0
        storageError = newBlock?.1
        if destination.isDefault {
            UserDefaults.standard.removeObject(forKey: Self.customFolderKey)
        } else {
            UserDefaults.standard.set(destination.directory.path, forKey: Self.customFolderKey)
        }
        apply(adopted)
    }

    enum RelocationError: LocalizedError {
        case newerVersion(Int)
        case damaged(URL)
        case currentUnreadable

        var errorDescription: String? {
            switch self {
            case .currentUnreadable:
                return "The current library cannot be read, so it cannot be copied. Choose a folder that already holds a library, or repair the current one first."
            case .newerVersion(let version):
                return "The library in that folder was saved by a newer version of Puffer (format \(version)). Update Puffer to use it."
            case .damaged(let url):
                return "\(url.path) is not a readable Puffer library. Move it out of the folder, or choose a different folder."
            }
        }
    }

    /// Replaces the in-memory library with one read from disk, without
    /// scheduling a save, and repairs the selection.
    private func apply(_ loaded: Library) {
        isApplyingDiskChange = true
        library = loaded
        isApplyingDiskChange = false

        if selectedFolder == nil {
            selectedFolderID = library.folders.first?.id
        }
        if selectedEntry == nil {
            selectedEntryID = selectedFolder?.entries.first?.id
        }
    }

    // MARK: - Changes from outside (a sync tool, a script, another Mac)

    func reloadIfChangedOnDisk() {
        // Unsaved local edits win; they are about to be written anyway.
        guard pendingSave == nil else { return }
        // A read that fails is tried again on the next tick.
        guard let contents = try? store.read() else { return }

        var suspect: Data?
        defer { suspectData = suspect }

        switch contents {
        case .missing:
            // The file that could not be read has gone: there is nothing
            // left to protect. (A newer Puffer's file that has gone stays
            // blocked: what is in memory is not all of it.)
            guard saveBlock == .unreadable || saveBlock == .damaged else { return }
            saveBlock = nil
            saveNow()
        case .corrupt(let data):
            guard saveBlock != .damaged else { return }
            if data == suspectData {
                block(.damaged, Self.damagedMessage(store))
            } else {
                // Possibly caught half written: look again on the next tick.
                suspect = data
            }
        case .current(let loaded, let data):
            guard data != lastKnownData || saveBlock != nil else { return }
            lastKnownData = data
            saveBlock = nil
            storageError = nil
            apply(loaded)
        case .newer(let version, let loaded, let data):
            guard data != lastKnownData || saveBlock != .newerVersion else { return }
            lastKnownData = data
            block(.newerVersion, Self.newerVersionMessage(version))
            if let loaded { apply(loaded) }
        }
    }
}
