import CoreGraphics

// Carbon virtual key codes (kVK_*).
enum VirtualKey {
    static let space: CGKeyCode = 0x31
    static let returnKey: CGKeyCode = 0x24
    static let escape: CGKeyCode = 0x35
}

// A keyboard event carries at most 20 Unicode characters.
let maxCharactersPerKeyEvent = 20

func passwordChunks(_ password: String) -> [[UniChar]] {
    let chars = Array(password.utf16)
    return stride(from: 0, to: chars.count, by: maxCharactersPerKeyEvent).map {
        Array(chars[$0..<min($0 + maxCharactersPerKeyEvent, chars.count)])
    }
}

// Key down and up events for `key`. With `text`, the key down types that text instead of the key's own character.
func keyPress(_ key: CGKeyCode, text: [UniChar] = [], source: CGEventSource?) -> (down: CGEvent, up: CGEvent)? {
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return nil }
    if !text.isEmpty {
        down.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
    }
    return (down, up)
}
