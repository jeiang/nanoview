#!/usr/bin/env bash
# Builds the release archives into DIST (default dist/). Run inside `nix develop` on
# macOS: the macOS targets need the SDK frameworks; Linux and Windows cross-compile.
set -euo pipefail

version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon)
dist=${1:-dist}
rm -rf "$dist" zig-out/release
mkdir -p "$dist"

for target in aarch64-macos x86_64-macos; do
    prefix="zig-out/release/$target"
    zig build app -Dtarget="$target" -Doptimize=ReleaseSafe --prefix "$prefix"
    ditto -c -k --keepParent "$prefix/nanoview.app" "$dist/nanoview-$version-$target.zip"
done

for target in x86_64-linux-gnu aarch64-linux-gnu; do
    prefix="zig-out/release/$target"
    zig build -Dtarget="$target" -Doptimize=ReleaseSafe --prefix "$prefix"
    tar -C "$prefix/bin" -czf "$dist/nanoview-$version-${target%-gnu}.tar.gz" nanoview
done

target=x86_64-windows-gnu
prefix="zig-out/release/$target"
zig build -Dtarget="$target" -Doptimize=ReleaseSafe --prefix "$prefix"
(cd "$prefix/bin" && zip -q "$OLDPWD/$dist/nanoview-$version-x86_64-windows.zip" nanoview.exe)

(cd "$dist" && shasum -a 256 -- * > SHA256SUMS)
