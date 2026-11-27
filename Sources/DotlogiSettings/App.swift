import AppKit
import DotlogiCore
import SwiftUI

struct DotlogiSettingsApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var store = Store()

    var body: some Scene {
        Window("dotlogI", id: "main") {
            Root().environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

/// The window is the whole app: closing it quits, so nothing stays in memory.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct Root: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let palette = Palette.of(scheme)
        ContentView()
            .environment(\.palette, palette)
            .tint(palette.ink)
            .frame(width: 940, height: 640)
            .background(palette.background)
    }
}

enum Pane: String, CaseIterable { case buttons = "ボタン", scrolling = "スクロールとポインタ" }

private struct ContentView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            Header(pane: $store.pane)
            Notices()
            Rectangle().fill(palette.line).frame(height: 1)
            switch store.pane {
            case .buttons: ButtonsPane()
            case .scrolling: ScrollingPane()
            }
        }
        .foregroundStyle(palette.ink)
    }
}

// MARK: - Header

private struct Header: View {
    @EnvironmentObject private var store: Store
    @Environment(\.palette) private var palette
    @Binding var pane: Pane

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            DotText(text: "DOTLOGI", dot: 3, gap: 1.6, showUnlit: false)
            HStack(spacing: 18) {
                ForEach(Pane.allCases, id: \.self) { item in
                    Button { pane = item } label: {
                        VStack(spacing: 6) {
                            Text(item.rawValue).font(.system(size: 13, weight: pane == item ? .semibold : .regular))
                                .foregroundStyle(pane == item ? palette.ink : palette.muted)
                            Rectangle().fill(pane == item ? palette.ink : .clear).frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
            Spacer()
            if let savedAt = store.savedAt, Date().timeIntervalSince(savedAt) < 2.5 {
                Text("保存しました").font(.system(size: 11)).foregroundStyle(palette.muted)
                    .transition(.opacity)
            }
            DeviceReadout()
        }
        .padding(.leading, 84) // clear of the window buttons
        .padding(.trailing, 24)
        .frame(height: 76)
        .animation(.easeOut(duration: 0.2), value: store.savedAt)
    }
}

/// Connection, battery and wheel mode, as the resident process last reported them.
private struct DeviceReadout: View {
    @EnvironmentObject private var store: Store
    @Environment(\.palette) private var palette

    var body: some View {
        let status = store.status
        let connected = store.agentRunning && (status?.connected ?? false)
        HStack(spacing: 20) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(connected ? (status?.deviceName ?? "マウス") : "マウス未接続")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(connected ? palette.ink : palette.muted)
                Text(wheelText(status?.smartShift, connected)).font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            if connected, let battery = status?.battery, battery >= 0 {
                DotText(text: "\(battery)%", dot: 4, gap: 2, color: battery <= 10 ? palette.red : nil)
                    .accessibilityLabel("電池 \(battery)%")
            } else {
                DotText(text: "--%", dot: 4, gap: 2, color: palette.muted, showUnlit: false)
                    .accessibilityLabel("電池 不明")
            }
        }
    }

    private func wheelText(_ mode: String?, _ connected: Bool) -> String {
        guard connected else { return "ホイール —" }
        switch mode {
        case "free": return "ホイール フリースピン"
        case "ratchet": return "ホイール ラチェット"
        default: return "ホイール —"
        }
    }
}

// MARK: - Notices (only when something needs the user)

private struct Notices: View {
    @EnvironmentObject private var store: Store
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.loadError {
                notice(error, action: nil)
            } else if let status = store.status, !status.inputMonitoring {
                notice("マウスのボタンを読むには、「入力監視」で dotlogI をオンにしてください。",
                       action: ("設定を開く", { open("Privacy_ListenEvent") }))
            } else if let status = store.status, !status.accessibility {
                notice("キー操作を送るには、「アクセシビリティ」で dotlogI をオンにしてください。",
                       action: ("設定を開く", { open("Privacy_Accessibility") }))
            } else if store.reconnecting {
                // Ranked above the stopped-agent notice, which would otherwise flash while the agent restarts.
                notice("マウスにつなぎ直しています…", action: nil)
            } else if !store.agentRunning {
                notice("常駐が止まっているため、ボタンの割り当てが効いていません。", action: ("起動する", { store.startAgent() }))
            } else if let status = store.status, !status.connected {
                notice(disconnectedText(status), action: ("再接続", { store.reconnect() }))
            }
        }
    }

    private func notice(_ text: String, action: (String, () -> Void)?) -> some View {
        HStack(spacing: 12) {
            Circle().fill(palette.red).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12))
            Spacer()
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(palette.ink, lineWidth: 1))
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    /// Why the mouse is not set up, and what to try when 再接続 does not help.
    private func disconnectedText(_ status: Status) -> String {
        guard status.lastError != nil else {
            return "マウスとつながっていないため、ボタンの割り当てが効いていません。電源が入っているか確かめてください。"
        }
        if let app = store.secureInputApp {
            return "\(app) がキー入力を保護しているため、マウスに設定を書き込めません。\(app) を終了してから再接続してください。"
        }
        return "マウスに設定を書き込めません。再接続しても直らない時は、Mac を再起動してください。"
    }

    /// Opens the privacy list. dotlogI asked for the permission when it was opened, so it is already listed;
    /// if not, the + button there can add /Applications/dotlogI.app.
    private func open(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

// MARK: - Buttons

private struct ButtonsPane: View {
    @EnvironmentObject private var store: Store
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                AppBar()
                MouseSchematic()
                    .padding(.vertical, 12)
                Text("マウスのボタンを押すと、ここで選ばれます")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 18)
            }
            .frame(width: 440)
            Rectangle().fill(palette.line).frame(width: 1)
            Inspector()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Which app's assignments are shown. "すべてのアプリ" is the base the others override.
private struct AppBar: View {
    @EnvironmentObject private var store: Store
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.profileIDs, id: \.self) { id in
                    let selected = store.profile == id
                    Button { store.profile = id } label: {
                        HStack(spacing: 6) {
                            if let icon = store.appIcon(id) {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                                    .saturation(selected ? 1 : 0).opacity(selected ? 1 : 0.7)
                            }
                            Text(store.appName(id)).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(selected ? palette.background : palette.muted)
                        .background(RoundedRectangle(cornerRadius: 3).fill(selected ? palette.ink : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected ? .clear : palette.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if id != Config.defaultProfile {
                            Button("このアプリの設定を消す") { store.removeApp(id) }
                        }
                    }
                }
                Button { store.addApp() } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(palette.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("アプリを追加")
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
    }
}

private struct Inspector: View {
    @EnvironmentObject private var store: Store
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.slot.title).font(.system(size: 20, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(palette.muted)
            }
            switch store.slot {
            case .gesture, .modeShift: GestureGrid(group: store.slot.group)
            case .thumbWheel: ThumbWheelInfo()
            default:
                ActionPicker(group: "buttons", key: store.slot.buttonKey ?? "", caption: "押した時")
                    .frame(width: 260)
            }
            Spacer()
        }
        .padding(28)
    }

    private var subtitle: String {
        let scope = store.profile == Config.defaultProfile ? "すべてのアプリで使います" : "\(store.appName(store.profile)) が前面の時だけ使います"
        switch store.slot {
        case .gesture, .modeShift: return "押すだけ、または押したまま動かした方向で使い分けます。\(scope)"
        case .thumbWheel: return "横スクロールに使います"
        default: return scope
        }
    }
}

/// Five directions laid out like the movement itself.
private struct GestureGrid: View {
    @EnvironmentObject private var store: Store
    @Environment(\.palette) private var palette
    let group: String

    var body: some View {
        let zoom = store.entry(group, "mode").value == "zoom"
        VStack(alignment: .leading, spacing: 18) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    ActionPicker(group: group, key: "up", caption: "↑ 上へ", disabled: zoom)
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
                GridRow {
                    ActionPicker(group: group, key: "left", caption: "← 左へ", disabled: zoom)
                    ActionPicker(group: group, key: "click", caption: "押すだけ")
                    ActionPicker(group: group, key: "right", caption: "右へ →", disabled: zoom)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    ActionPicker(group: group, key: "down", caption: "↓ 下へ", disabled: zoom)
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
            .frame(width: 444)
            Toggle(isOn: Binding(
                get: { zoom },
                set: { store.set(group, "mode", $0 ? "zoom" : nil) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("押したまま上下でズームする").font(.system(size: 13))
                    Text("Figma などで使います。オンの間は上下左右の割り当てを使いません。")
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                }
            }
            .toggleStyle(.switch)
        }
    }
}

private struct ThumbWheelInfo: View {
    @Environment(\.palette) private var palette
    var body: some View {
        Text("親指ホイールの向きは「スクロールとポインタ」で変えられます。")
            .font(.system(size: 13)).foregroundStyle(palette.muted)
    }
}

// MARK: - Scrolling and pointer

private struct ScrollingPane: View {
    @EnvironmentObject private var store: Store
    @Environment(\.palette) private var palette

    /// macOS natural scrolling (on unless turned off) decides what the firmware invert bit means.
    private var macNatural: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.swipescrolldirection"] as? Bool ?? true
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                Text("ポインタの速さ").font(.system(size: 13, weight: .semibold))
                DotText(text: "\(store.config.device.dpi ?? 1000)", dot: 7, gap: 3, showUnlit: false)
                    .accessibilityLabel("解像度 \(store.config.device.dpi ?? 1000) DPI")
                Text("DPI。大きいほど少ない動きで遠くまで動きます。").font(.system(size: 12)).foregroundStyle(palette.muted)
                Slider(value: Binding(
                    get: { Double(store.config.device.dpi ?? 1000) },
                    set: { store.config.device.dpi = Int(($0 / 50).rounded()) * 50 }
                ), in: 200...4000)
                .frame(width: 320)
                HStack {
                    Text("200").font(.system(size: 10)).foregroundStyle(palette.muted)
                    Spacer()
                    Text("4000").font(.system(size: 10)).foregroundStyle(palette.muted)
                }
                .frame(width: 320)
            }
            .padding(32)
            .frame(width: 440, alignment: .leading)
            Rectangle().fill(palette.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                row("ホイールの向き", "macOS の「ナチュラルなスクロール」とは別に決められます") {
                    directionPicker(invert: Binding(
                        get: { store.config.device.wheelInvert ?? false },
                        set: { store.config.device.wheelInvert = $0 }
                    ))
                }
                row("なめらかスクロール", "回すたびに、すべるように動きます。回している間だけ少し CPU を使います") {
                    Toggle("", isOn: Binding(
                        get: { store.config.device.smoothScroll ?? false },
                        set: { store.config.device.smoothScroll = $0 }
                    )).toggleStyle(.switch).labelsHidden()
                }
                if store.config.device.smoothScroll ?? false {
                    row("スクロールの速さ", "1 目盛りで進む距離") {
                        sliderValue(Binding(
                            get: { store.config.device.smoothScrollSpeed ?? 1 },
                            set: { store.config.device.smoothScrollSpeed = ($0 * 10).rounded() / 10 }
                        ), range: 0.3...3, format: "%.1f")
                    }
                    row("止まるまでの長さ", "短いほどきびきび、長いほどゆったり止まります") {
                        sliderValue(Binding(
                            get: { store.config.device.smoothScrollDuration ?? 0.15 },
                            set: { store.config.device.smoothScrollDuration = ($0 * 100).rounded() / 100 }
                        ), range: 0.05...0.5, format: "%.2f 秒")
                    }
                } else {
                    row("細かい刻みで送る", "なめらかになる代わりに、速く感じることがあります") {
                        Toggle("", isOn: Binding(
                            get: { store.config.device.wheelHiRes ?? false },
                            set: { store.config.device.wheelHiRes = $0 }
                        )).toggleStyle(.switch).labelsHidden()
                    }
                }
                row("フリースピンに変わる勢い", "ラチェットの時、これより速く回すと自動で空転します") {
                    sliderValue(Binding(
                        get: { Double(store.config.device.smartShiftThreshold ?? 10) },
                        set: { store.config.device.smartShiftThreshold = Int($0.rounded()) }
                    ), range: 1...50, format: "%.0f")
                }
                row("親指ホイールの向き", nil) {
                    directionPicker(invert: Binding(
                        get: { store.config.device.thumbWheelInvert ?? false },
                        set: { store.config.device.thumbWheelInvert = $0 }
                    ))
                }
                row("ジェスチャーの距離", "押したまま、どれだけ動かすと方向の操作になるか") {
                    sliderValue(Binding(
                        get: { Double(store.config.gestureThreshold) },
                        set: { store.config.gestureThreshold = Int($0.rounded()) }
                    ), range: 20...150, format: "%.0f")
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sliderValue(_ value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 12) {
            Slider(value: value, in: range).frame(width: 160)
            Text(String(format: format, value.wrappedValue)).font(.system(size: 12).monospacedDigit())
                .frame(width: 52, alignment: .trailing)
        }
    }

    /// "標準" / "ナチュラル" in the user's terms; stored as the firmware invert bit relative to macOS.
    private func directionPicker(invert: Binding<Bool>) -> some View {
        Segmented(options: [("standard", "標準"), ("natural", "ナチュラル")], selection: Binding(
            get: { invert.wrappedValue == macNatural ? "standard" : "natural" },
            set: { invert.wrappedValue = ($0 == "standard") == macNatural }
        ))
        .frame(width: 180)
    }

    private func row<Control: View>(_ title: String, _ detail: String?, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(palette.muted) }
            }
            Spacer(minLength: 16)
            control()
        }
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }
}
