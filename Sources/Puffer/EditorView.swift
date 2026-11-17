import CoreTransferable
import PufferCore
import SwiftUI
import UniformTypeIdentifiers

/// What travels when an entry is dragged onto a folder. It has its own
/// content type (declared in Info.plist) rather than plain text so that text
/// fields, including the folder-name fields in the sidebar, don't accept it.
struct EntryDrag: Codable, Transferable {
    let id: Entry.ID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "co.yuca.puffer.entry"))
    }
}

/// The three-pane editor: folders | entries | editor.
struct EditorView: View {
    // View state lives on the model rather than in @State: on current SDKs
    // @State is a macro whose plugin ships only with full Xcode, and this
    // package must build with just the Command Line Tools.
    @Bindable var model: LibraryModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            folderList
                .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 260)
        } content: {
            entryList
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 360)
        } detail: {
            detail
        }
        .frame(minWidth: 780, minHeight: 420)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let message = model.storageError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.yellow.opacity(0.25))
            }
        }
        .onChange(of: model.searchFocusRequests) {
            searchFocused = true
        }
    }

    // MARK: - Folders

    private var folderList: some View {
        List(selection: $model.selectedFolderID) {
            ForEach(model.library.folders) { folder in
                Label {
                    TextField("Folder name", text: model.folderName(folder.id))
                } icon: {
                    Image(systemName: "folder")
                }
                // Whole row width is the drop target, highlighted while an
                // entry is dragged over it.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(model.dropTargetFolderID == folder.id ? 0.3 : 0))
                        .padding(.horizontal, -4)
                )
                .dropDestination(for: EntryDrag.self) { drags, _ in
                    model.moveEntries(drags.map(\.id), toFolder: folder.id)
                } isTargeted: { targeted in
                    if targeted {
                        model.dropTargetFolderID = folder.id
                    } else if model.dropTargetFolderID == folder.id {
                        model.dropTargetFolderID = nil
                    }
                }
                .tag(folder.id)
            }
            .onMove { model.moveFolders(from: $0, to: $1) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PaneButtons(
                addHelp: "New folder",
                removeHelp: "Delete folder",
                canRemove: model.selectedFolder != nil,
                add: model.addFolder,
                remove: {
                    if model.selectedFolder?.entries.isEmpty == true {
                        model.deleteSelectedFolder()
                    } else {
                        model.confirmingFolderDelete = true
                    }
                }
            )
        }
        .confirmationDialog(
            "Delete “\(model.selectedFolder?.name ?? "")” and its \(model.selectedFolder?.entries.count ?? 0) entries?",
            isPresented: $model.confirmingFolderDelete
        ) {
            Button("Delete Folder", role: .destructive) { model.deleteSelectedFolder() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
    }

    // MARK: - Entries

    private var entryList: some View {
        Group {
            if model.isSearching {
                searchResultList
            } else if let folder = model.selectedFolder {
                List(selection: $model.selectedEntryID) {
                    ForEach(folder.entries) { entry in
                        EntryRow(entry: entry, hasConflict: model.library.hasConflict(for: entry))
                            .draggable(EntryDrag(id: entry.id))
                            .contextMenu { moveMenu(for: entry) }
                            .tag(entry.id)
                    }
                    .onMove { model.moveEntries(from: $0, to: $1) }
                }
                .overlay {
                    if folder.entries.isEmpty {
                        ContentUnavailableView("No Entries", systemImage: "text.badge.plus", description: Text("Press + to add one."))
                    }
                }
            } else {
                ContentUnavailableView("No Folder Selected", systemImage: "folder")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            searchField
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PaneButtons(
                addHelp: "New entry",
                removeHelp: "Delete entry",
                canAdd: model.selectedFolder != nil,
                canRemove: model.selectedEntry != nil,
                add: model.addEntry,
                remove: model.deleteSelectedEntry
            )
        }
    }

    /// Matches from every folder, each labelled with its folder.
    private var searchResultList: some View {
        let results = model.searchResults
        return List(selection: $model.selectedEntryID) {
            ForEach(results, id: \.entry.id) { result in
                EntryRow(
                    entry: result.entry,
                    hasConflict: model.library.hasConflict(for: result.entry),
                    folderName: result.folder.name
                )
                .draggable(EntryDrag(id: result.entry.id))
                .contextMenu { moveMenu(for: result.entry) }
                .tag(result.entry.id)
            }
        }
        .overlay {
            if results.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }

    /// Right-click alternative to dragging an entry onto a folder.
    @ViewBuilder
    private func moveMenu(for entry: Entry) -> some View {
        let current = model.folder(containing: entry.id)?.id
        Menu("Move to") {
            ForEach(model.library.folders.filter { $0.id != current }) { folder in
                Button(folder.name.isEmpty ? "Untitled" : folder.name) {
                    model.moveEntries([entry.id], toFolder: folder.id)
                }
            }
        }
        .disabled(model.library.folders.count < 2)
    }

    private var searchField: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search all entries", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { model.searchText = "" }
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .padding(8)
            Divider()
        }
        .background(.bar)
    }

    // MARK: - Editor

    @ViewBuilder
    private var detail: some View {
        if let entry = model.selectedEntry {
            EntryEditor(
                entry: model.entry(entry.id, fallback: entry),
                hasConflict: model.library.hasConflict(for: entry)
            )
            .id(entry.id)
        } else {
            ContentUnavailableView("No Entry Selected", systemImage: "character.cursor.ibeam")
        }
    }
}

private struct EntryRow: View {
    let entry: Entry
    let hasConflict: Bool
    /// Shown in search results, where entries from several folders mix.
    var folderName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title.isEmpty ? "Untitled" : entry.title)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(entry.shortcode.isEmpty ? "no shortcode" : entry.shortcode)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                if hasConflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                if let folderName {
                    Spacer(minLength: 4)
                    Label(folderName, systemImage: "folder")
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct EntryEditor: View {
    @Binding var entry: Entry
    let hasConflict: Bool

    private var warning: String? {
        let code = entry.shortcode
        if code.isEmpty { return "Add a shortcode to make this entry expand." }
        if code.contains(where: \.isWhitespace) { return "A shortcode with a space in it can never be typed in one go." }
        if entry.trigger == .period, code.contains(".") { return "This shortcode contains the trigger character." }
        if hasConflict { return "Another entry uses this shortcode with the same trigger." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Title").gridColumnAlignment(.trailing)
                    TextField("Title", text: $entry.title)
                }
                GridRow {
                    Text("Shortcode")
                    TextField("e.g. ;sig", text: $entry.shortcode)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .frame(maxWidth: 220)
                }
                GridRow {
                    Text("Expand on")
                    Picker("Expand on", selection: $entry.trigger) {
                        ForEach(Trigger.allCases, id: \.self) { trigger in
                            Text(trigger.label).tag(trigger)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                // The period that fires an expansion is always dropped.
                if entry.trigger == .space {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Toggle("Keep the space after the text", isOn: $entry.keepsTrigger)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Text")
                TextEditor(text: $entry.text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                Text("Pressing delete straight after an expansion puts the shortcode back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}

/// The + / − strip at the foot of a list pane.
private struct PaneButtons: View {
    let addHelp: String
    let removeHelp: String
    var canAdd = true
    var canRemove = true
    let add: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 2) {
                Button(action: add) {
                    Image(systemName: "plus").frame(width: 24, height: 22)
                }
                .disabled(!canAdd)
                .help(addHelp)
                Button(action: remove) {
                    Image(systemName: "minus").frame(width: 24, height: 22)
                }
                .disabled(!canRemove)
                .help(removeHelp)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .background(.bar)
    }
}
