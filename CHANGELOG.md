# Changelog

All notable changes to nanoview are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). A release takes its notes from the
section that matches its tag.

## [Unreleased]

### Added

- An app icon for the macOS bundle, the Windows program (Explorer, title bar and taskbar) and
  Linux (installed with a desktop entry under `share/`, and set on the window under X11):
  a framed landscape, drawn by `zig build icon`.

### Changed

- The Linux release archive holds `bin/nanoview` and `share/` (the desktop entry and icon)
  instead of the bare program.

## [0.1.0] - 2026-11-10

### Added

- Open a picture from the command line, the open dialog (Cmd/Ctrl+O), a drop on the window,
  or Finder's "Open With" (macOS).
- Left and Right step through the folder and wrap around. The folder follows Finder's sort
  order on macOS (name, kind, size, date modified, created or added, either direction) and an
  open Explorer window's order on Windows; otherwise natural name order.
- Wheel and pinch zoom about the pointer, drag and trackpad pan, `0` fit, `1` 100 %,
  `+`/`-` zoom, double click toggles fit and 100 %, `f` and Escape for full screen.
- `r` and `l` rotate the view, `i` shows name, size, zoom and position.
- Move to Trash (Forward Delete, Cmd+Backspace), reveal in the file manager (Cmd/Ctrl+R),
  copy the path (Cmd/Ctrl+Shift+C).
- The window takes the size of each picture (macOS, Linux).
- A worker thread preloads 5 pictures behind and 15 ahead in a fixed 512 MiB pool.
- `nanoview.app` with image file associations (`zig build app`).
- Nix flake with a package, an app, checks and a devshell.
- Release archives for macOS (arm64, x86_64), Linux (x86_64, arm64) and Windows (x86_64).

### Notes

- The macOS app is ad-hoc signed, not notarized. After download, run
  `xattr -dr com.apple.quarantine nanoview.app` or open it with Control-click, Open.
- Linux and Windows builds show PNG, JPEG and the first frame of GIF, and have not been
  tested on those systems yet. On Linux nanoview needs GTK 3 or 4 and OpenGL at run time.

[Unreleased]: https://github.com/jeiang/nanoview/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jeiang/nanoview/releases/tag/v0.1.0
