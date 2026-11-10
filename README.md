# nanoview

A small, fast image viewer in the style of [qView](https://interversehq.com/qview/), written in
Zig on [nanoui](https://github.com/justrach/nanoui). It opens a picture and lets you step
through its folder in the same order your file manager shows it.

macOS first; Linux and Windows builds come from the same code.

## Install

Download an archive from the [releases page](https://github.com/jeiang/nanoview/releases).
The macOS app is not notarized; after unzipping, run
`xattr -dr com.apple.quarantine nanoview.app` once.

With Nix:

```sh
nix run github:jeiang/nanoview -- picture.jpg
```

## Use

Open a picture from the command line, with Cmd/Ctrl+O, by dropping it on the window, or with
Finder's "Open With".

| Key | Action |
|---|---|
| Left, Right | Previous, next picture in the folder |
| Wheel, pinch, `+`, `-` | Zoom |
| Drag, trackpad scroll | Pan |
| `0`, `1`, double click | Fit, 100 %, toggle |
| `r`, `l` | Rotate right, left |
| `i` | Show name, size, zoom and position |
| `f`, Escape | Full screen, leave full screen |
| Cmd+Backspace, Forward Delete | Move to Trash |
| Cmd/Ctrl+R | Reveal in file manager |
| Cmd/Ctrl+Shift+C | Copy path |

On macOS nanoview shows PNG, JPEG, GIF, HEIC, WebP, AVIF, TIFF, BMP and ICO. On Linux and
Windows it shows PNG, JPEG and the first frame of GIF. Linux needs GTK 3 or 4 and OpenGL.

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
