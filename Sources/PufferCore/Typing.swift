import Foundation

/// Rules for inserting text as synthetic key events instead of pasting it.
///
/// A key event can carry a short Unicode string in place of its own
/// character, so text can be "typed" without touching the clipboard.
public enum Typing {
    /// Apps reliably accept about this many UTF-16 units per key event;
    /// anything beyond it tends to be dropped.
    public static let maxUnitsPerEvent = 20

    /// Expansions up to this many characters are typed. Longer ones are
    /// pasted, which is one step for the app however long the text is.
    public static let typedLimit = 200

    /// Whether `text` can be typed at all. Line breaks and tabs cannot: as
    /// key events they act as Return and Tab, which send the message or
    /// move the focus in many apps, where pasting them just inserts them.
    public static func isTypable(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { character in
            character.utf16.count <= maxUnitsPerEvent
                && character.unicodeScalars.allSatisfy { scalar in
                    switch scalar.value {
                    case 0..<0x20, 0x7F...0x9F: return false   // control characters
                    case 0x2028, 0x2029: return false          // line and paragraph separators
                    default: return true
                    }
                }
        }
    }

    /// Whether `text` should be typed in preference to being pasted.
    public static func prefersTyping(_ text: String) -> Bool {
        text.count <= typedLimit && isTypable(text)
    }

    /// Splits typable text into the strings to send, one per key event,
    /// without ever dividing a character (an emoji, a letter and its accent).
    public static func chunks(_ text: String) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var current: [UInt16] = []
        for character in text {
            let units = Array(character.utf16)
            if !current.isEmpty, current.count + units.count > maxUnitsPerEvent {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
