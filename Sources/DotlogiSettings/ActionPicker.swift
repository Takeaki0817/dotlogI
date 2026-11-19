import AppKit
import DotlogiCore
import SwiftUI

/// The actions offered in the menus, grouped the way people look for them.
enum ActionCatalog {
    struct Item: Identifiable { let id: String; let label: String }
    struct Group: Identifiable { let id: String; let items: [Item] }

    static let groups: [Group] = [
        Group(id: "画面", items: [
            Item(id: "mission-control", label: "Mission Control"),
            Item(id: "app-expose", label: "App Exposé"),
            Item(id: "launchpad", label: "アプリ一覧"),
            Item(id: "ctrl+right", label: "右のデスクトップへ"),
            Item(id: "ctrl+left", label: "左のデスクトップへ"),
        ]),
        Group(id: "移動", items: [
            Item(id: "back", label: "戻る"),
            Item(id: "forward", label: "進む"),
            Item(id: "middle-click", label: "中クリック"),
        ]),
        Group(id: "編集", items: [
            Item(id: "cmd+z", label: "取り消す"),
            Item(id: "cmd+shift+z", label: "やり直す"),
            Item(id: "cmd+c", label: "コピー"),
            Item(id: "cmd+v", label: "ペースト"),
            Item(id: "cmd+x", label: "カット"),
        ]),
        Group(id: "タブ", items: [
            Item(id: "cmd+t", label: "新しいタブ"),
            Item(id: "cmd+w", label: "タブを閉じる"),
            Item(id: "cmd+shift+t", label: "閉じたタブを開き直す"),
            Item(id: "ctrl+tab", label: "次のタブ"),
            Item(id: "ctrl+shift+tab", label: "前のタブ"),
        ]),
        Group(id: "ホイール", items: [
            Item(id: "smartshift-toggle", label: "ホイールのモードを切り替える"),
        ]),
    ]

    static func label(_ value: String?) -> String {
        guard let value else { return "未設定" }
        if value == "none" { return "何もしない" }
        for group in groups { if let item = group.items.first(where: { $0.id == value }) { return item.label } }
        return KeyNames.display(value)
    }
}

/// One assignable cell: shows the current action and opens the menu of choices.
struct ActionPicker: View {
    @EnvironmentObject private var store: Store
    @Environment(\.palette) private var palette
    let group: String
    let key: String
    var caption: String? = nil
    var disabled = false
    @StateObject private var recorder = Flag()

    var body: some View {
        let entry = store.entry(group, key)
        Menu {
            Button("何もしない") { store.set(group, key, "none") }
            ForEach(ActionCatalog.groups) { section in
                Section(section.id) {
                    ForEach(section.items) { item in
                        Button(item.label) { store.set(group, key, item.id) }
                    }
                }
            }
            Divider()
            Button("キーの組み合わせを記録…") { recorder.on = true }
            if !entry.inherited && store.profile != Config.defaultProfile && entry.value != nil {
                Button("すべてのアプリと同じにする") { store.set(group, key, nil) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if let caption {
                    Text(caption).font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                HStack(spacing: 6) {
                    if !entry.inherited && store.profile != Config.defaultProfile && entry.value != nil {
                        // Red dot: this app overrides the shared setting.
                        Circle().fill(palette.red).frame(width: 5, height: 5).accessibilityLabel("このアプリだけの設定")
                    }
                    Text(ActionCatalog.label(entry.value))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(entry.inherited ? palette.muted : palette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if entry.inherited {
                    Text("すべてのアプリと同じ").font(.system(size: 10)).foregroundStyle(palette.muted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(palette.line, lineWidth: 1))
        .popover(isPresented: $recorder.on, arrowEdge: .bottom) {
            ShortcutRecorder { value in
                recorder.on = false
                if let value { store.set(group, key, value) }
            }
            .environment(\.palette, palette)
        }
    }
}

/// Captures the next key combination pressed while the popover is open.
struct ShortcutRecorder: View {
    let done: (String?) -> Void
    @Environment(\.palette) private var palette
    @StateObject private var model = RecorderModel()

    var body: some View {
        VStack(spacing: 14) {
            Text(model.preview.isEmpty ? "割り当てるキーを押してください" : model.preview)
                .font(.system(size: model.preview.isEmpty ? 13 : 22, weight: .medium))
            Text("修飾キー（⌘ ⌥ ⌃ ⇧）と一緒に押せます。esc でやめます。")
                .font(.system(size: 11)).foregroundStyle(palette.muted)
        }
        .padding(20)
        .frame(width: 280)
        .onAppear {
            model.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if event.keyCode == 53 && flags.subtracting(.function).isEmpty { finish(nil); return nil }
                guard let name = KeyNames.name(for: event.keyCode) else { return nil }
                var parts: [String] = []
                if flags.contains(.control) { parts.append("ctrl") }
                if flags.contains(.option) { parts.append("opt") }
                if flags.contains(.shift) { parts.append("shift") }
                if flags.contains(.command) { parts.append("cmd") }
                let value = (parts + [name]).joined(separator: "+")
                model.preview = KeyNames.display(value)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { finish(value) }
                return nil
            }
        }
        .onDisappear { removeMonitor() }
    }

    private func finish(_ value: String?) {
        removeMonitor()
        done(value)
    }

    private func removeMonitor() {
        if let monitor = model.monitor { NSEvent.removeMonitor(monitor) }
        model.monitor = nil
    }
}

/// Local view state without @State (the SwiftUI macros need full Xcode; this builds with the command line tools).
final class Flag: ObservableObject {
    @Published var on = false
}

final class RecorderModel: ObservableObject {
    @Published var preview = ""
    var monitor: Any?
}
