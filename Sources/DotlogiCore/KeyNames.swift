import Foundation

/// Key names used in config strings ("cmd+shift+z") and their macOS virtual key codes (kVK_*).
public enum KeyNames {
    public static let codes: [String: UInt16] = {
        var table: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        table["plus"] = 24
        table["minus"] = 27
        return table
    }()

    /// Modifier names in the order they are written.
    public static let modifiers = ["ctrl", "opt", "shift", "cmd"]
    public static let symbols = ["ctrl": "⌃", "opt": "⌥", "shift": "⇧", "cmd": "⌘"]
    static let keySymbols = ["delete": "⌫", "forwarddelete": "⌦", "return": "↩", "tab": "⇥", "escape": "⎋", "space": "␣",
                             "left": "←", "right": "→", "up": "↑", "down": "↓", "plus": "=", "minus": "-"]

    /// "cmd+shift+z" -> "⇧⌘Z" for display.
    public static func display(_ text: String) -> String {
        let parts = text.lowercased().split(separator: "+").map(String.init)
        let mods = modifiers.filter { parts.contains($0) || ($0 == "opt" && parts.contains("alt")) }.compactMap { symbols[$0] }.joined()
        let key = parts.last(where: { codes[$0] != nil }) ?? ""
        return mods + (keySymbols[key] ?? key.uppercased())
    }

    /// The config name of a virtual key code, for the shortcut recorder.
    public static func name(for code: UInt16) -> String? {
        let preferred = codes.filter { $0.value == code }.map(\.key).sorted { $0.count < $1.count }
        return preferred.first(where: { $0 != "plus" && $0 != "minus" }) ?? preferred.first
    }
}
