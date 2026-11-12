# Changelog

All notable changes to nanoview are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). A release takes its notes from the
section that matches its tag.

## [Unreleased]

### Added

- A release archive for Windows on arm64.
- Home and End, a random picture (`x`), reload (F5, Cmd/Ctrl+Shift+R), Space and Shift+Space,
  and the mouse's Back and Forward buttons.
- A slideshow (`s`).
- Mirror (`m`) and flip (`v`), fit modes (`w`: whole, width, height, fill), fit that enlarges
  small pictures (`u`), sharp pixels above 100 % (`p`), zoom lock (`z`), a checkerboard behind
  the picture (`b`), and zoom below fit down to 10 %.
- Opening a folder, and opening several pictures at once.
- The info line also shows the format, file size and modified date.
- `settings.conf`, read at startup: fit, zoom, loop, slideshow and trash options.
- Settings for the background color, when and how far the window follows the picture, the
  sort order, the title text, a hidden title bar (Windows) and always on top (`t`).
- Keys can be rebound with `key.<action>` lines in `settings.conf`.
- Opened files and folders are remembered in a recent list.
- macOS: JPEG 2000, PSD, ICNS, TGA, OpenEXR, SGI and PBM pictures.
- Linux: pictures decode through gdk-pixbuf when it is installed (WebP, AVIF, HEIC, TIFF, BMP,
  ICO and more); Move to Trash; reveal selects the file; touchpad pan and pinch; the window
  takes the picture's size on GTK 4.
- Windows: pictures decode through WIC (BMP, ICO, TIFF, WebP, DDS, JPEG XR, and HEIC, AVIF and
  JPEG XL with a codec installed); Move to Trash; reveal selects the file; real full screen;
  touchpad pan and pinch; the window takes the picture's size.

### Changed

- nanoui v0.14.0 is vendored in `vendor/nanoui`, so nanoview can carry patches to it.
- The folder is read again before a step when it changed on disk.
- Linux and Windows preload decoded pixels, as macOS does.

### Fixed

- A file that cannot be moved to the Trash now says so in the window.

## [0.2.0] - 2026-11-10

### Added

- An app icon for the macOS bundle, the Windows program (Explorer, title bar and taskbar) and
  Linux (installed with a desktop entry under `share/`, and set on the window under X11):
  a framed landscape, drawn by `zig build icon`.

### Changed

- The macOS release apps are signed with a Developer ID and notarized, so Gatekeeper opens them
  without the `xattr` step.
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

[Unreleased]: https://github.com/jeiang/nanoview/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/jeiang/nanoview/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jeiang/nanoview/releases/tag/v0.1.0
