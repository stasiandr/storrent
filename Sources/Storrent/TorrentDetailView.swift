import StorrentEngine
import SwiftUI

/// Inspector for one torrent: stats and the file list with download checkboxes.
struct TorrentDetailView: View {
    @Environment(TorrentStore.self) private var store
    let torrent: TorrentInfo

    var body: some View {
        let files = store.files[torrent.id] ?? []

        List {
            Section {
                Text(torrent.name)
                    .font(.headline)
                    .textSelection(.enabled)
                ProgressView(value: torrent.progress)
                    .tint(torrent.state.color)
                LabeledContent("Downloaded", value: "\(format(bytes: torrent.progressBytes)) of \(format(bytes: torrent.totalBytes))")
                LabeledContent("Uploaded", value: format(bytes: torrent.uploadedBytes))
                LabeledContent("Speed", value: "↓ \(format(speed: torrent.downloadSpeed))  ↑ \(format(speed: torrent.uploadSpeed))")
                LabeledContent("Peers", value: "\(torrent.peersConnected) connected, \(torrent.peersSeen) seen")
                LabeledContent("Location") {
                    Button(torrent.outputFolder) { store.revealInFinder(torrent) }
                        .buttonStyle(.link)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let error = torrent.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            Section {
                ForEach(files, id: \.index) { file in
                    FileRow(file: file) { included in
                        store.setIncluded(included, file: file, in: torrent)
                    }
                }
            } header: {
                HStack {
                    Text("Files (\(files.count))")
                    Spacer()
                    if files.count > 1 {
                        Button("All") { store.setAllIncluded(true, in: torrent) }
                        Button("None") { store.setAllIncluded(false, in: torrent) }
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct FileRow: View {
    let file: FileEntry
    let setIncluded: (Bool) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(get: { file.included }, set: setIncluded))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(file.included ? .primary : .secondary)
                HStack(spacing: 6) {
                    ProgressView(value: file.length == 0 ? 0 : Double(file.progressBytes) / Double(file.length))
                        .controlSize(.mini)
                    Text(format(bytes: file.length))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .help(file.path)
    }
}

extension TorrentState {
    var color: Color {
        switch self {
        case .downloading: .blue
        case .seeding: .green
        case .error: .red
        case .initializing, .paused: .gray
        }
    }
}
