# storrent

Native macOS torrent client: SwiftUI app on top of [librqbit](https://github.com/ikatson/rqbit),
bridged with [UniFFI](https://mozilla.github.io/uniffi-rs/).

```bash
scripts/bundle.sh        # engine + app → build/storrent.app
open build/storrent.app
```

- `engine/` — Rust crate: a narrow facade over librqbit (`Engine`: add, torrents, files,
  pause/resume/remove). Owns its tokio runtime; async methods are awaited from Swift.
- `scripts/build-engine.sh` — builds `libstorrent_engine.a` and generates the Swift bindings
  into `Sources/StorrentEngine/Generated` and `Sources/storrent_engineFFI` (gitignored).
- `Sources/Storrent/` — SwiftUI: torrent table, magnet sheet (⌘U), .torrent open (⌘O),
  drag and drop, menu bar speed, `magnet:` and `.torrent` handler, no sleep while downloading.

Downloads go to `~/Downloads`; session state lives in `~/Library/Application Support/storrent`.
Needs only Command Line Tools and rustup, no Xcode.
