import AppKit
import SwiftUI

@main
struct StorrentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = TorrentStore()

    var body: some Scene {
        Window("storrent", id: "main") {
            ContentView()
                .environment(store)
                .onAppear { appDelegate.store = store }
        }
        .defaultSize(width: 900, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Magnet Link…") { store.isAddingLink = true }
                    .keyboardShortcut("u")
                Button("Open Torrent File…") { store.openTorrentFile() }
                    .keyboardShortcut("o")
            }
        }

        MenuBarExtra {
            Text("↓ \(format(speed: store.totalDownloadSpeed))   ↑ \(format(speed: store.totalUploadSpeed))")
            Divider()
            Button("Quit storrent") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: store.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
    }
}

/// Receives magnet links and .torrent files opened from other apps.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: TorrentStore? {
        didSet { flushPending() }
    }
    private var pending: [String] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        pending += urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
        flushPending()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func flushPending() {
        guard let store else { return }
        for source in pending { store.add(source) }
        pending.removeAll()
    }
}
