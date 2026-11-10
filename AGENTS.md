# nanoview agent guide

nanoview is a small qView-style image viewer in Zig 0.17.1. Its only dependency is
[nanoui](https://github.com/justrach/nanoui) v0.14.0 (pinned in `build.zig.zon`). macOS is the
main target; Linux and Windows build from the same code.

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
| Cross builds | `zig build -Dtarget=x86_64-windows-gnu`, `-Dtarget=x86_64-linux-gnu` |
| Release archives | `./tools/package.sh dist` (macOS host only) |
| Nix package and checks | `nix build`, `nix flake check -L` |

Headless check of the real app: `zig-out/bin/nanoview --nanoui-snapshot=/tmp/s.png PICTURE`.
`--nanoui-script=chord:r;snap:/tmp/x.png` runs only together with `--nanoui-snapshot`; without
the snapshot flag a real window opens and does not exit.

## Layout

| File | Role |
|---|---|
| `src/main.zig` | Startup: buffers, window, worker thread, first argument |
| `src/app.zig` | `State` and commands: open, step, trash, reveal, promote |
| `src/view.zig` | Per-frame UI: keys, pointer, drops, drawing, window fit |
| `src/viewport.zig` | Zoom, pan, fit and the visible part of a rotated picture |
| `src/folder.zig` | Folder listing, natural and Finder-style sorting |
| `src/preload.zig` | Worker that preloads neighbors into a fixed pool |
| `src/sort_order.zig` | Picks the system file manager's order per OS |
| `src/ds_store.zig`, `src/bplist.zig` | Finder `.DS_Store` and binary plist readers |
| `src/explorer_sort.zig` | Explorer window sort order over COM (Windows only) |
| `src/orientation.zig` | EXIF orientation |
| `src/paths.zig` | `file://` URLs, path joins, fixed-buffer file reads |
| `src/tests.zig` | Test root and `ui.Tester` tests |
| `tools/make_ds_store_fixture.py` | Writes `src/testdata/list_date_modified.DS_Store` |

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
Zig package tree (`zig build --fetch=all`). When `build.zig.zon` dependencies change, set that
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
`nix flake check` on macOS and Linux for pushes to `main` and pull requests.

## Git

Use Conventional Commits. Do not commit `zig-out/`, `.zig-cache/`, `zig-pkg/`, `dist/` or
`result`.
