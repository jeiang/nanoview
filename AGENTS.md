# nanoview agent guide

nanoview is a small qView-style image viewer in Zig 0.17.1. Its dependencies are all vendored:
[nanoui](https://github.com/justrach/nanoui) v0.14.0 in `vendor/nanoui`, and the Wuffs and
libwebp decoders in `vendor/wuffs` and `vendor/libwebp`. macOS is the main target; Linux and
Windows build from the same code.

## Vendored nanoui

`vendor/nanoui` is the package tree of nanoui v0.14.0 (commit `7b32272`) as `zig fetch` unpacks
it. nanoview's patches are ordinary commits that touch only `vendor/nanoui`, with the scope
`nanoui` (`fix(nanoui): ...`), so `git log -- vendor/nanoui` lists what to send upstream and
`git diff <vendoring commit> -- vendor/nanoui` is the whole patch. Keep nanoui's own style in
that tree; the Tiger Style rules below and `zig fmt --check` cover `src/` and `build.zig` only.

## Vendored decoders

- `vendor/wuffs`: the official `release/c/wuffs-v0.4.c`, unmodified; the pin and its sha256 are
  in `vendor/wuffs/UPSTREAM`. To update, take the release file and its licenses from a new
  upstream commit, update `UPSTREAM`, and run the tests.
- `vendor/libwebp`: the decoder and demux files of a stable tag, unmodified, plus nanoview's
  `src/webp/config.h` with SIMD and threads off. To update, copy the same files from the new
  tag's tarball, record the commit and sha256 in `UPSTREAM`, and update `webp_sources` in
  `build.zig` when upstream added or renamed sources.

Both compile with UBSan off. They are in the tree, so the Nix deps `outputHash` changes only
when `build.zig.zon` does. `licenses` in `build.zig` lists the notices every binary copy
carries; add to it when you vendor more code.

## Environment

Run every command inside the flake devshell: `nix develop -c <command>`. The shell hook unsets
`NIX_CFLAGS_COMPILE` and `NIX_LDFLAGS`; with them set, Zig searches only Nix paths and cannot
find the macOS frameworks.

| Task | Command |
|---|---|
| Unit and UI tests | `zig build test --summary all` |
| Format check | `zig fmt --check build.zig src` |
| Run | `zig build run -- PICTURE` |
| macOS bundle | `zig build app` (gives `zig-out/nanoview.app`) |
| Redraw the icon | `zig build icon` (macOS host; writes `macos/icon.png`, `macos/AppIcon.icns`, `windows/nanoview.ico`, `linux/nanoview.png`) |
| Cross builds | `zig build -Dtarget=x86_64-windows-gnu`, `-Dtarget=x86_64-linux-gnu` |
| Release archives | `./tools/package.sh dist` (macOS host only) |
| Nix package and checks | `nix build`, `nix flake check -L` |

Headless check of the real app: `zig-out/bin/nanoview --nanoui-snapshot=/tmp/s.png PICTURE`.
`--nanoui-script=chord:r;snap:/tmp/x.png` runs only together with `--nanoui-snapshot`; without
the snapshot flag a real window opens and does not exit.

## Layout

| File | Role |
|---|---|
| `src/main.zig` | Startup: buffers, settings, window, worker thread, arguments |
| `src/app.zig` | `State` and commands: open, step, slideshow, trash, reveal, promote |
| `src/view.zig` | Per-frame UI: keys, pointer, drops, drawing, window fit |
| `src/actions.zig` | The `Action` list and the default keys; `view.perform` runs them |
| `src/keymap.zig` | Key names and the effective key table after `key.<action>` lines |
| `src/viewport.zig` | Zoom, pan, fit and the visible part of a rotated picture |
| `src/folder.zig` | Folder listing, natural and Finder-style sorting |
| `src/preload.zig` | Worker that preloads neighbors into a fixed pool |
| `src/decode.zig` | `decode_fit`: the system decoder, then the bundled ones; size and limit checks |
| `src/decode_macos.zig`, `decode_linux.zig`, `decode_windows.zig` | ImageIO, gdk-pixbuf (dlopen), WIC (COM by hand) |
| `src/wuffs.zig`, `src/wuffs_bridge.c` | Wuffs: BMP, GIF, APNG, QOI, TGA into caller memory, no allocation |
| `src/webp.zig`, `src/webp_bridge.c` | libwebp: still and animated WebP |
| `src/wuffs_fixtures.zig` | Builds the Wuffs test pictures at compile time |
| `src/settings.zig` | `Settings`, its defaults and the `settings.conf` parser |
| `src/recent.zig` | The recent files list and its file |
| `src/instance.zig`, `instance_posix.zig`, `instance_windows.zig` | Single instance: the message, a Unix socket, a mutex with `WM_COPYDATA` |
| `src/metadata.zig` | File size, date and format for the info line |
| `src/sniff.zig` | Picture format from the first bytes |
| `src/exif.zig` | Bounded EXIF/TIFF IFD walker, ICC profile name, text of the details panel |
| `src/shell.zig` | Trash and reveal; macOS goes through nanoui |
| `src/shell_linux.zig`, `shell_dbus.zig` | FreeDesktop trash; `FileManager1.ShowItems` through GIO (dlopen) |
| `src/shell_windows.zig` | Recycle Bin and Explorer selection |
| `src/fileops.zig` | Rename checks and the stack of trashed pictures for put back |
| `src/sort_order.zig` | Picks the system file manager's order per OS |
| `src/ds_store.zig`, `src/bplist.zig` | Finder `.DS_Store` and binary plist readers |
| `src/explorer_sort.zig` | Explorer window sort order over COM (Windows only) |
| `src/orientation.zig` | EXIF orientation |
| `src/paths.zig` | `file://` URLs, path joins, fixed-buffer file reads |
| `src/tests.zig` | Test root and `ui.Tester` tests |
| `tools/make_ds_store_fixture.py` | Writes `src/testdata/list_date_modified.DS_Store` |
| `tools/icon.zig` | Draws the app icon from signed distances; `sips` and `iconutil` make the `.icns`, the `.ico` frames and the Linux PNG |

## Code rules (Tiger Style)

These apply to `src/` and `build.zig`:

- No allocation after startup in nanoview's code. Buffers are fields of the one static
  `State` or are allocated once in `main`.
- Every limit is a named constant with the qualifier last (`file_size_max`, `entries_max`).
- Every loop has a fixed upper bound. No recursion.
- Assert arguments, results and invariants; aim for two assertions per function. Do not add
  assertions that check nothing.
- Explicitly sized integers; `usize` only to index slices.
- Functions at most 70 lines, lines at most 100 columns, `zig fmt` clean.
- `snake_case` for functions and variables; nanoui's camelCase names are called as they are.
- Handle every error with a visible state change. Comments explain why, not what.
- The worker touches shared state only under `Preload.mutex`.

## Zig 0.17 notes

- `**` array repetition is gone: use `@splat`.
- `std.Io` everywhere: `realPathFile(io, path, &buf)`, `createDirPath(io, sub)`.
- Debug builds fill `alloc` results with `0xAA`, which commits the memory. Large buffers use
  `page_allocator.rawAlloc` through `app.alloc_pages`.
- nanoui's key enum type is `@FieldType(@FieldType(ui.Context, "input"), "key")`.

## Nix package

`packages.default` builds with Zig from `zig-overlay` against a fixed-output derivation of the
Zig package tree (`zig build --fetch=all`): the lazy dependencies of the vendored nanoui. When
a `build.zig.zon` changes its dependencies, set that
derivation's `outputHash` to `lib.fakeHash`, run `nix build`, and copy the reported hash. The
build has no `xcrun`, so on macOS it points Zig at the nixpkgs Apple SDK with
`NIX_CFLAGS_COMPILE` and `--search-prefix`, then removes the SDK rpath and the Zig store path
from the binaries so the closure holds only nanoview. Check with `nix path-info -r ./result`.
The flake has no `x86_64-darwin` outputs: nixpkgs-unstable dropped that system. The release
archives still include x86_64 macOS.

## Releases

1. Set `.version` in `build.zig.zon` (the flake reads it from there too).
2. Move the `Unreleased` entries in `CHANGELOG.md` to a new `## [X.Y.Z] - YYYY-MM-DD`
   section and update the links at the bottom.
3. Merge to `main`, then tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`.

`.github/workflows/release.yml` checks the tag against `build.zig.zon`, runs the tests, builds
the archives with `tools/package.sh`, and publishes a GitHub Release with that changelog
section as notes. `.github/workflows/ci.yml` runs format, tests, cross builds and
`nix flake check` on macOS and Linux, and the tests on Windows (Zig from `mlugg/setup-zig`,
no Nix), for pushes to `main` and pull requests.

The release signs the macOS apps with the "Developer ID Application" identity and notarizes
them with an App Store Connect API key, from the repository secrets listed at the top of
`release.yml`; it fails when one is missing. Locally, `tools/package.sh` does the same when
`CODESIGN_IDENTITY` and `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` are set.

## Git

Use Conventional Commits. Do not commit `zig-out/`, `.zig-cache/`, `zig-pkg/`, `dist/` or
`result`.
