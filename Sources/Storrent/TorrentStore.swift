import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation
import StorrentEngine
import UniformTypeIdentifiers

/// Polls the engine once a second and forwards user actions to it.
@MainActor
@Observable
final class TorrentStore {
    private(set) var torrents: [TorrentInfo] = []
    /// Sources being added right now (a magnet waits for metadata from peers).
    private(set) var adding: [String] = []
    /// File lists by torrent id; only the inspected torrent is kept fresh.
    private(set) var files: [UInt64: [FileEntry]] = [:]
    var inspectedID: UInt64? {
        didSet { refreshFiles() }
    }
    var lastError: String?
    var isAddingLink = false

    private let engine: Engine?
    private var sleepAssertion: IOPMAssertionID = 0

    init() {
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("storrent")
        do {
            engine = try Engine(downloadDir: downloads.path, stateDir: support.path)
        } catch {
            engine = nil
            lastError = "Engine failed to start: \(error.localizedDescription)"
        }
        startPolling()
    }

    var activeCount: Int { torrents.filter { $0.state == .downloading }.count }
    var totalDownloadSpeed: UInt64 { torrents.reduce(0) { $0 + $1.downloadSpeed } }
    var totalUploadSpeed: UInt64 { torrents.reduce(0) { $0 + $1.uploadSpeed } }

    func add(_ source: String) {
        guard let engine else { return }
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        adding.append(source)
        Task {
            defer { adding.removeAll { $0 == source } }
            do {
                _ = try await engine.add(source: source)
                refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func openTorrentFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { add($0.path) }
    }

    func togglePause(_ torrent: TorrentInfo) {
        perform { engine in
            if torrent.state == .paused {
                try await engine.resume(id: torrent.id)
            } else {
                try await engine.pause(id: torrent.id)
            }
        }
    }

    func remove(_ torrent: TorrentInfo, deleteFiles: Bool) {
        perform { try await $0.remove(id: torrent.id, deleteFiles: deleteFiles) }
    }

    func setIncluded(_ included: Bool, file: FileEntry, in torrent: TorrentInfo) {
        var indices = Set((files[torrent.id] ?? []).filter(\.included).map(\.index))
        if included { indices.insert(file.index) } else { indices.remove(file.index) }
        updateIncluded(indices, in: torrent)
    }

    func setAllIncluded(_ included: Bool, in torrent: TorrentInfo) {
        let indices = included ? Set((files[torrent.id] ?? []).map(\.index)) : []
        updateIncluded(indices, in: torrent)
    }

    private func updateIncluded(_ indices: Set<UInt64>, in torrent: TorrentInfo) {
        // Show the change right away instead of waiting for the next poll.
        files[torrent.id] = files[torrent.id]?.map { file in
            var file = file
            file.included = indices.contains(file.index)
            return file
        }
        perform { try await $0.setIncludedFiles(id: torrent.id, indices: indices.sorted()) }
    }

    func revealInFinder(_ torrent: TorrentInfo) {
        let url = URL(fileURLWithPath: torrent.outputFolder).appendingPathComponent(torrent.name)
        let target = FileManager.default.fileExists(atPath: url.path)
            ? url : URL(fileURLWithPath: torrent.outputFolder)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func perform(_ action: @escaping (Engine) async throws -> Void) {
        guard let engine else { return }
        Task {
            do {
                try await action(engine)
                refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func startPolling() {
        Task { [weak self] in
            while let self {
                self.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() {
        guard let engine else { return }
        torrents = engine.torrents().sorted { $0.id < $1.id }
        files = files.filter { id, _ in torrents.contains { $0.id == id } }
        refreshFiles()
        updateSleepAssertion()
    }

    private func refreshFiles() {
        guard let engine, let id = inspectedID else { return }
        // Metadata isn't there yet while a torrent is initializing.
        if let list = try? engine.files(id: id) {
            files[id] = list
        }
    }

    /// Keeps the Mac awake while something is downloading.
    private func updateSleepAssertion() {
        let shouldHold = activeCount > 0
        if shouldHold, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "storrent is downloading" as CFString,
                &sleepAssertion
            )
        } else if !shouldHold, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }
}

extension TorrentInfo: Identifiable {}

extension TorrentInfo {
    var progress: Double {
        totalBytes == 0 ? 0 : Double(progressBytes) / Double(totalBytes)
    }
}

func format(bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
}

func format(speed: UInt64) -> String {
    speed == 0 ? "—" : format(bytes: speed) + "/s"
}

func format(eta seconds: UInt64?) -> String {
    guard let seconds else { return "—" }
    if seconds == 0 { return "<1s" }
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: TimeInterval(seconds)) ?? "—"
}
