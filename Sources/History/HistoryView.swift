import SwiftUI

// The history window: search on the left, the full text (and the screenshot of a grab) on
// the right; copy it again or type it again.

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    var onType: (String) -> Void
    @State private var query = ""
    @State private var selection: HistoryItem.ID?

    init(store: HistoryStore, onType: @escaping (String) -> Void, initialSelection: HistoryItem.ID? = nil) {
        self.store = store
        self.onType = onType
        _selection = State(initialValue: initialSelection)
    }

    private var shown: [HistoryItem] { store.search(query) }
    private var selected: HistoryItem? { store.items.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            List(shown, selection: $selection) { item in
                Row(item: item).tag(item.id)
                    .contextMenu {
                        Button(L.t("复制", "Copy")) { copy(item.text) }
                        Button(L.t("再打一次", "Type again")) { onType(item.text) }
                        Divider()
                        Button(L.t("删除", "Delete"), role: .destructive) { store.delete([item.id]) }
                    }
            }
            .searchable(text: $query, placement: .sidebar, prompt: L.t("搜索文字或 App", "Search text or app"))
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .overlay {
                if store.items.isEmpty {
                    ContentUnavailableView(L.t("还没有记录", "Nothing yet"), systemImage: "clock",
                                           description: Text(L.t("用 ⌘⇧C 识别的文字和用 ⌘⇧V 打出的文字会出现在这里。",
                                                                 "Text you grab with ⌘⇧C or type with ⌘⇧V shows up here.")))
                }
            }
        } detail: {
            if let item = selected {
                Detail(item: item, store: store, onType: onType)
            } else {
                Text(L.t("选择一条记录", "Select an entry")).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 720, minHeight: 440)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

private struct Row: View {
    let item: HistoryItem
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind == .grab ? "text.viewfinder" : "keyboard")
                .foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text.replacingOccurrences(of: "\n", with: " ")).lineLimit(2)
                Text([item.app, item.date.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct Detail: View {
    let item: HistoryItem
    @ObservedObject var store: HistoryStore
    var onType: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(item.kind == .grab ? L.t("识别的文字", "Grabbed text") : L.t("打出的文字", "Typed text"),
                      systemImage: item.kind == .grab ? "text.viewfinder" : "keyboard")
                    .font(.headline)
                Spacer()
                Text("\(item.text.count) " + L.t("字", "chars")).foregroundStyle(.secondary)
            }
            if let u = store.imageURL(item), let img = NSImage(contentsOf: u) {
                Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            }
            ScrollView {
                Text(item.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .font(.body).padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
            HStack {
                if let o = item.outcome { Text(o).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(L.t("删除", "Delete"), role: .destructive) { store.delete([item.id]) }
                Button(L.t("复制", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                }
                Button(L.t("再打一次", "Type again")) { onType(item.text) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
