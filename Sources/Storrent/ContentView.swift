import StorrentEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(TorrentStore.self) private var store
    @State private var selection: Set<TorrentInfo.ID> = []
    @State private var magnetLink = ""
    @State private var showInspector = false

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            if store.torrents.isEmpty && store.adding.isEmpty {
                ContentUnavailableView(
                    "No Torrents",
                    systemImage: "arrow.down.circle",
                    description: Text("Paste a magnet link (⌘U) or drop a .torrent file here.")
                )
            } else {
                table
            }
            if !store.adding.isEmpty {
                addingBar
            }
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if let torrent = inspected {
                    TorrentDetailView(torrent: torrent)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "sidebar.right")
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 340, max: 520)
        }
        .onChange(of: inspected?.id) { store.inspectedID = inspected?.id }
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in
            urls.forEach { store.add($0.isFileURL ? $0.path : $0.absoluteString) }
            return !urls.isEmpty
        }
        .sheet(isPresented: $store.isAddingLink) { addLinkSheet }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } }),
            actions: { Button("OK") {} },
            message: { Text(store.lastError ?? "") }
        )
    }

    private var table: some View {
        Table(store.torrents, selection: $selection) {
            TableColumn("Name") { t in
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.name).lineLimit(1).truncationMode(.middle)
                    ProgressView(value: t.progress)
                        .progressViewStyle(.linear)
                        .tint(t.state.color)
                }
                .padding(.vertical, 4)
            }
            .width(min: 240, ideal: 380)

            TableColumn("Size") { t in
                Text(format(bytes: t.totalBytes)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(80)

            TableColumn("Status") { t in
                StatusLabel(torrent: t)
            }
            .width(110)

            TableColumn("↓") { t in Text(format(speed: t.downloadSpeed)).monospacedDigit() }
                .width(90)
            TableColumn("↑") { t in Text(format(speed: t.uploadSpeed)).monospacedDigit() }
                .width(90)
            TableColumn("ETA") { t in Text(format(eta: t.etaSeconds)).monospacedDigit() }
                .width(70)
            TableColumn("Peers") { t in
                Text("\(t.peersConnected)/\(t.peersSeen)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(60)
        }
        .contextMenu(forSelectionType: TorrentInfo.ID.self) { ids in
            let items = store.torrents.filter { ids.contains($0.id) }
            Button("Pause / Resume") { items.forEach(store.togglePause) }
            Button("Show in Finder") { items.first.map(store.revealInFinder) }
            Divider()
            Button("Remove") { items.forEach { store.remove($0, deleteFiles: false) } }
            Button("Remove and Delete Files", role: .destructive) {
                items.forEach { store.remove($0, deleteFiles: true) }
            }
        } primaryAction: { ids in
            store.torrents.first { ids.contains($0.id) }.map(store.revealInFinder)
        }
    }

    private var addingBar: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(store.adding.count == 1
                 ? "Fetching metadata…"
                 : "Fetching metadata for \(store.adding.count) torrents…")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { store.isAddingLink = true } label: { Label("Add Magnet", systemImage: "link.badge.plus") }
            Button { store.openTorrentFile() } label: { Label("Open .torrent", systemImage: "doc.badge.plus") }
            Button {
                selected.forEach(store.togglePause)
            } label: {
                Label("Pause / Resume", systemImage: selected.allSatisfy { $0.state == .paused } ? "play.fill" : "pause.fill")
            }
            .disabled(selected.isEmpty)
        }
        ToolbarItem {
            Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                .keyboardShortcut("i")
        }
    }

    private var addLinkSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Magnet Link").font(.headline)
            TextField("magnet:?xt=urn:btih:…", text: $magnetLink, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitLink)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { store.isAddingLink = false }
                Button("Add", action: submitLink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(magnetLink.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string), clip.hasPrefix("magnet:") {
                magnetLink = clip
            }
        }
    }

    /// The torrent shown in the inspector: the selection, when exactly one is selected.
    private var inspected: TorrentInfo? {
        selected.count == 1 ? selected.first : nil
    }

    private var selected: [TorrentInfo] {
        store.torrents.filter { selection.contains($0.id) }
    }

    private func submitLink() {
        store.add(magnetLink)
        magnetLink = ""
        store.isAddingLink = false
    }
}

private struct StatusLabel: View {
    let torrent: TorrentInfo

    var body: some View {
        switch torrent.state {
        case .initializing: Label("Checking", systemImage: "hourglass").foregroundStyle(.secondary)
        case .downloading: Label("\(Int(torrent.progress * 100))%", systemImage: "arrow.down").foregroundStyle(.blue)
        case .seeding: Label("Seeding", systemImage: "arrow.up").foregroundStyle(.green)
        case .paused: Label("Paused", systemImage: "pause").foregroundStyle(.secondary)
        case .error: Label("Error", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                .help(torrent.error ?? "")
        }
    }
}
