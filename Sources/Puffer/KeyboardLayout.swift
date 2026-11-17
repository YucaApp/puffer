import AppKit
import Carbon.HIToolbox

/// What Puffer needs to know about the keyboard layout in use.
struct KeyboardState: Equatable {
    /// The key that, held with Command, means Paste. It is the V key on
    /// QWERTY but sits elsewhere on layouts such as Dvorak.
    var pasteKeyCode = CGKeyCode(kVK_ANSI_V)

    /// False while an input method (Japanese, Chinese, Korean and so on) is
    /// selected. Its raw key presses are not the text being written: the
    /// input method composes them into something else, so matching
    /// shortcodes against them would fire in the middle of a word.
    var isPlainLayout = true
}

/// Reads the current keyboard layout and reports when it changes.
///
/// Main thread only: the Text Input Source functions crash when called
/// from any other thread.
final class KeyboardWatcher {
    private let onChange: (KeyboardState) -> Void
    private var observer: NSObjectProtocol?
    private(set) var state = KeyboardState()

    init(onChange: @escaping (KeyboardState) -> Void) {
        self.onChange = onChange
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    private func refresh() {
        var updated = KeyboardState()
        updated.pasteKeyCode = Self.keyCode(producing: "v") ?? CGKeyCode(kVK_ANSI_V)
        updated.isPlainLayout = Self.currentSourceIsKeyboardLayout()
        state = updated
        onChange(updated)
    }

    private static func currentSourceIsKeyboardLayout() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceType)
        else { return true }
        let type = Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue()
        return CFEqual(type, kTISTypeKeyboardLayout)
    }

    /// The key that types `character` in the current layout, looking first
    /// at what each key produces with Command held (how apps match keyboard
    /// shortcuts, and what makes layouts like "Dvorak - QWERTY ⌘" and
    /// non-Latin layouts work), then at the keys on their own.
    static func keyCode(producing character: Character) -> CGKeyCode? {
        guard let target = String(character).utf16.first,
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { bytes -> CGKeyCode? in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            // Try the usual V key first so an ordinary layout keeps it.
            let keyCodes = [UInt16(kVK_ANSI_V)] + (0..<128).map { UInt16($0) }
            for modifiers in [UInt32(cmdKey >> 8), 0] {
                for keyCode in keyCodes {
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var units = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                        OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeys, units.count, &length, &units
                    )
                    if status == noErr, length == 1, units[0] == target { return CGKeyCode(keyCode) }
                }
            }
            return nil
        }
    }
}
