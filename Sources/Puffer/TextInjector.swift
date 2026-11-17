import AppKit
import Carbon.HIToolbox
import PufferCore

/// Replaces a just-typed shortcode with its expansion: backspaces over the
/// shortcode, then inserts the text.
///
/// Short single-line text is typed, as key events that carry the text, and
/// never touches the clipboard. Text that is long or has line breaks is
/// pasted: it goes on the clipboard, Command-V is pressed, and the previous
/// clipboard contents are put back.
final class TextInjector {
    // Every event Puffer posts is stamped so the event tap can recognise it:
    // "PUFF" in the top half of the user-data field. The last event of an
    // injection also carries that injection's serial number in the bottom
    // half, which is how the tap learns that the whole injection has been
    // posted.
    private static let tag: Int64 = 0x5055_4646 // "PUFF"

    static func marker(finalSerial: Int64 = 0) -> Int64 {
        (tag << 32) | (finalSerial & 0xFFFF_FFFF)
    }

    static func isOwnEvent(_ userData: Int64) -> Bool {
        userData >> 32 == tag
    }

    /// The injection this event is the last of, or nil for any other event.
    static func finalSerial(_ userData: Int64) -> Int64? {
        let serial = userData & 0xFFFF_FFFF
        return isOwnEvent(userData) && serial != 0 ? serial : nil
    }

    /// Serial: one injection at a time. Also the only place the pasteboard
    /// is touched, so that a large or slow clipboard can never hold up the
    /// main thread or the event tap.
    private let queue = DispatchQueue(label: "puffer.injector", qos: .userInteractive)
    private let pasteboard = NSPasteboard.general

    /// The key to press with Command to paste; depends on the layout.
    /// Injector queue only.
    private var pasteKeyCode = CGKeyCode(kVK_ANSI_V)

    func setPasteKeyCode(_ keyCode: CGKeyCode) {
        queue.async { [self] in pasteKeyCode = keyCode }
    }

    /// Deletes and inserts as `expansion` says. The very last event posted
    /// is stamped with `serial`.
    func perform(_ expansion: Expansion, serial: Int64) {
        queue.async { [self] in
            for _ in 0..<expansion.deleteCount {
                press(kVK_Delete)
                usleep(2_000)
            }

            if Typing.prefersTyping(expansion.text) {
                type(expansion.text, finalSerial: serial)
                return
            }

            guard let ourChangeCount = stage(expansion.text) else {
                // The clipboard holds something that must not be disturbed
                // and the text can be typed instead, if slowly.
                type(expansion.text, finalSerial: serial)
                return
            }
            usleep(30_000) // let the backspaces land and the pasteboard settle
            press(Int(pasteKeyCode), flags: .maskCommand, finalSerial: serial)

            // Give the target app time to read the pasteboard before restoring.
            queue.asyncAfter(deadline: .now() + 0.4) { [self] in
                // If something else has been copied meanwhile, leave it alone,
                // and do not keep the old clipboard in memory for nothing.
                // (A later expansion may have taken the snapshot over; then
                // it is that expansion's to restore.)
                guard pasteboard.changeCount == ourChangeCount else {
                    if borrowed?.changeCount == ourChangeCount { borrowed = nil }
                    return
                }
                restore()
            }
        }
    }

    // MARK: - Pasteboard (injector queue only)

    /// Each item's types in the order the owning app declared them, which
    /// is their order of preference.
    private typealias Snapshot = [[(type: NSPasteboard.PasteboardType, data: Data)]]

    /// A clipboard bigger than this is not copied and so not put back:
    /// reading it could take long enough to stall the expansion.
    static let snapshotLimit = 5 * 1024 * 1024

    /// Password managers mark what they copy with this type
    /// (nspasteboard.org) and clear it again after a while, but only if the
    /// clipboard has not changed in the meantime.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// The user's clipboard while ours is temporarily on the pasteboard.
    /// A nil snapshot means it could not be saved and will not be restored.
    private var borrowed: (snapshot: Snapshot?, changeCount: Int)?

    /// Puts `text` on the pasteboard, remembering what was there, and
    /// returns the pasteboard's change count with our text on it.
    ///
    /// Returns nil, leaving the pasteboard alone, when what is there cannot
    /// be saved and `text` could be typed instead.
    private func stage(_ text: String) -> Int? {
        let saved: Snapshot?
        if let borrowed, borrowed.changeCount == pasteboard.changeCount {
            // A previous expansion's text is still on the pasteboard (an undo
            // or second expansion came within the restore delay). What must
            // be restored is the user's clipboard, not that text.
            saved = borrowed.snapshot
        } else {
            saved = snapshot()
            if saved == nil, Typing.isTypable(text) { return nil }
        }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // nspasteboard.org markers: ask clipboard managers not to record this.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pasteboard.writeObjects([item])
        borrowed = (saved, pasteboard.changeCount)
        return pasteboard.changeCount
    }

    /// A copy of the clipboard, or nil if it should not be copied: it is
    /// over `snapshotLimit`, or it is a concealed item. Putting a concealed
    /// item back would count as a new copy, and the password manager that
    /// put it there would then never clear it.
    private func snapshot() -> Snapshot? {
        let current = pasteboard.pasteboardItems ?? []
        if current.contains(where: { $0.types.contains(Self.concealedType) }) { return nil }

        var total = 0
        var items: Snapshot = []
        for item in current {
            var contents: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > Self.snapshotLimit { return nil }
                contents.append((type, data))
            }
            items.append(contents)
        }
        return items
    }

    /// Takes our text off the pasteboard and puts back what was saved.
    private func restore() {
        let snapshot = borrowed?.snapshot ?? nil
        borrowed = nil
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = (snapshot ?? []).map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    // MARK: - Keystrokes

    /// Types `text` as key events that carry it as their Unicode string.
    private func type(_ text: String, finalSerial: Int64) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let chunks = Typing.chunks(text)
        for (index, units) in chunks.enumerated() {
            let isLast = index == chunks.count - 1
            for keyDown in [true, false] {
                // The key code is what an app sees if it ignores the string.
                // Space is the least harmful key to be mistaken for.
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Space), keyDown: keyDown) else {
                    continue
                }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                let marker = Self.marker(finalSerial: isLast && !keyDown ? finalSerial : 0)
                event.setIntegerValueField(.eventSourceUserData, value: marker)
                event.post(tap: .cgSessionEventTap)
            }
            usleep(2_000)
        }
    }

    private func press(_ keyCode: Int, flags: CGEventFlags = [], finalSerial: Int64 = 0) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown) else {
                continue
            }
            // Set flags explicitly so a modifier the user is still holding
            // (e.g. shift) doesn't turn our backspace into something else.
            event.flags = flags
            // Only the key-up, the last event of the pair, can be final.
            let marker = Self.marker(finalSerial: keyDown ? 0 : finalSerial)
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cgSessionEventTap)
        }
    }
}
