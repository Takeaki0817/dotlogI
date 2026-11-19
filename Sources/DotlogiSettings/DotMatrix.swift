import SwiftUI

/// Colour roles. Dark is black with white ink; light inverts. Red marks only what is live or overridden.
struct Palette {
    let background, ink, line, dotOff, body, muted, red: Color

    static func of(_ scheme: ColorScheme) -> Palette {
        scheme == .dark
            ? Palette(background: .black, ink: .white, line: Color(white: 0.16), dotOff: Color(white: 0.12), body: Color(white: 0.24),
                      muted: Color(white: 0.56), red: Color(red: 0xD7 / 255, green: 0x19 / 255, blue: 0x21 / 255))
            : Palette(background: .white, ink: .black, line: Color(white: 0.85), dotOff: Color(white: 0.9), body: Color(white: 0.76),
                      muted: Color(white: 0.42), red: Color(red: 0xD7 / 255, green: 0x19 / 255, blue: 0x21 / 255))
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.of(.dark)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// A 5x7 dot-matrix face drawn as dots, with the unlit dots faintly visible like an LED panel.
enum DotFont {
    static let glyphs: [Character: [String]] = [
        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
        "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
        "D": ["###..", "#..#.", "#...#", "#...#", "#...#", "#..#.", "###.."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
        "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
        "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
        "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
        "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
        "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
        "N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
        "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
        "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
        "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
        "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
        "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
        "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
        "%": ["##...", "##..#", "...#.", "..#..", ".#...", "#..##", "...##"],
        "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
        ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
        "/": ["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."],
        " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
    ]
}

struct DotText: View {
    let text: String
    var dot: CGFloat = 3
    var gap: CGFloat = 1.5
    var color: Color? = nil
    var showUnlit = true
    @Environment(\.palette) private var palette

    private var chars: [Character] { Array(text.uppercased()) }
    private var pitch: CGFloat { dot + gap }

    var body: some View {
        let width = CGFloat(chars.count) * 6 * pitch - pitch
        Canvas { context, _ in
            for (index, char) in chars.enumerated() {
                let rows = DotFont.glyphs[char] ?? DotFont.glyphs[" "]!
                let originX = CGFloat(index) * 6 * pitch
                for (y, row) in rows.enumerated() {
                    for (x, cell) in row.enumerated() {
                        let lit = cell == "#"
                        if !lit && !showUnlit { continue }
                        // Unlit dots are smaller and fainter so the lit shape reads first.
                        let size = lit ? dot : dot * 0.55
                        let inset = (dot - size) / 2
                        let rect = CGRect(x: originX + CGFloat(x) * pitch + inset, y: CGFloat(y) * pitch + inset, width: size, height: size)
                        context.fill(Path(ellipseIn: rect), with: .color(lit ? (color ?? palette.ink) : palette.dotOff))
                    }
                }
            }
        }
        .frame(width: max(width, 0), height: 7 * pitch - gap)
        .accessibilityElement()
        .accessibilityLabel(text)
    }
}

/// Two or more choices shown as outlined text; the chosen one is filled with ink.
struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                let selected = selection == value
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? palette.background : palette.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(selected ? palette.ink : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(palette.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
