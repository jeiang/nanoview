<p align="center"><img src="macos/icon.png" alt="nanoview's icon" width="96" height="96"></p>

# nanoview

A small, fast image viewer in the style of [qView](https://interversehq.com/qview/), written in
Zig on [nanoui](https://github.com/justrach/nanoui). It opens a picture and lets you step
through its folder in the same order your file manager shows it.

macOS first; Linux and Windows builds come from the same code.

## Install

Download an archive from the [releases page](https://github.com/jeiang/nanoview/releases).
The macOS app is signed with a Developer ID and notarized, so it opens without a Gatekeeper
warning.
The Linux archive holds `bin/` and `share/` (a desktop entry and the icon); unpack it over a
prefix, for example `tar -xzf nanoview-*.tar.gz -C ~/.local`.

With Nix:

```sh
nix run github:jeiang/nanoview -- picture.jpg
```

## Use

Open a picture, a folder or several pictures from the command line, with Cmd/Ctrl+O, by
dropping them on the window, or with Finder's "Open With". A folder shows its first picture.
Several pictures from one folder limit the list to those pictures until the next open.

| Key | Action |
|---|---|
| Left, Right, Space, Shift+Space | Previous, next picture in the folder |
| Mouse Back, Forward | Previous, next picture |
| Home, End | First, last picture |
| `x` | Random picture |
| F5, Cmd/Ctrl+Shift+R | Reload the file and its folder |
| `s` | Start or stop the slideshow |
| Wheel, pinch, `+`, `-` | Zoom, down to 10 % and up to 3200 % |
| Drag, trackpad scroll | Pan |
| `0`, `1`, double click | Fit, 100 %, toggle |
| `w` | Fit mode: whole, width, height, fill |
| `u` | Let fit enlarge small pictures |
| `p` | Smooth or sharp pixels above 100 % |
| `z` | Zoom lock: the next picture keeps the zoom and position |
| `b` | Checkerboard behind the picture |
| `r`, `l` | Rotate right, left |
| `m`, `v` | Mirror, flip |
| `i` | Show name, size, zoom, position, format, file size and date |
| `f`, Escape | Full screen, leave full screen |
| Cmd+Backspace, Forward Delete | Move to Trash |
| Cmd/Ctrl+R | Reveal in file manager, with the file selected |
| Cmd/Ctrl+Shift+C | Copy path |

Rotation, mirror and flip change the view only: nothing is written to disk. The folder is read
again before a step when it changed on disk. A command that fails says so in the window.

### Formats

- macOS (ImageIO): PNG, JPEG, GIF, HEIC, WebP, AVIF, TIFF, BMP, ICO, JPEG 2000, PSD, ICNS, TGA,
  OpenEXR, SGI and PBM.
- Linux: PNG, JPEG and GIF always. With gdk-pixbuf 2 (`libgdk_pixbuf-2.0.so.0`) installed, also
  what its loaders read from this set: WebP, AVIF, HEIC, TIFF, BMP, ICO, TGA, QOI, JPEG XL,
  JPEG 2000, ICNS, PNM, PCX, XBM and XPM.
- Windows (WIC): PNG, JPEG, GIF, BMP, ICO, TIFF, WebP, DDS and JPEG XR. HEIC, AVIF and JPEG XL
  need the matching codec from the Microsoft Store.

Animated pictures show their first frame. Linux needs GTK 3 or 4 and OpenGL.

### Settings

nanoview reads `settings.conf` once at startup and never writes it. A missing file means the
defaults.

- macOS: `~/Library/Application Support/nanoview/settings.conf`
- Linux: `$XDG_CONFIG_HOME/nanoview/settings.conf` (default `~/.config/nanoview/`)
- Windows: `%APPDATA%\nanoview\settings.conf`

One `key = value` per line; `#` starts a comment. A line that cannot be used keeps its default,
and the window names the first such line.

| Key | Default | Values |
|---|---|---|
| `fit_mode` | `whole` | `whole`, `width`, `height`, `fill` |
| `fit_upscale` | `false` | `true`, `false` |
| `smooth` | `true` | `true`, `false` |
| `zoom_lock` | `false` | `true`, `false` |
| `checkerboard` | `false` | `true`, `false` |
| `zoom_step_percent` | `25` | 1 to 400 |
| `loop` | `true` | `true`, `false`: step from the last picture to the first |
| `slideshow_seconds` | `5` | 1 to 3600 |
| `slideshow_reverse` | `false` | `true`, `false` |
| `trash_confirm` | `false` | `true`, `false`: ask before Move to Trash |
| `after_trash` | `next` | `next`, `previous` |

### Linux and Windows

These builds are compiled and unit-tested from macOS but have not been run on those systems
yet. On Linux, Move to Trash follows the FreeDesktop.org Trash specification; on Windows it
uses the Recycle Bin. On Windows, Ctrl+wheel zooms continuously, the same as a touchpad pinch.

## Build

Requires Zig 0.17.1; the Nix devshell provides it.

```sh
nix develop
zig build run -- picture.jpg   # run
zig build test                 # tests
zig build app                  # zig-out/nanoview.app (macOS)
```

See [AGENTS.md](AGENTS.md) for the code layout and conventions, and
[CHANGELOG.md](CHANGELOG.md) for changes.
