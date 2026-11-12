#!/usr/bin/env bash
# Builds the release archives into DIST (default dist/). Run inside `nix develop` on
# macOS: the macOS targets need the SDK frameworks; Linux and Windows cross-compile.
#
# With CODESIGN_IDENTITY set (a "Developer ID Application" identity in the keychain), the macOS
# apps are signed with the hardened runtime. With NOTARY_KEY_PATH, NOTARY_KEY_ID and
# NOTARY_ISSUER_ID also set (an App Store Connect API key), each app is notarized and the
# ticket stapled before it is zipped. Without them the apps keep the linker's ad hoc signature.
set -euo pipefail

version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon)
dist=${1:-dist}
rm -rf "$dist" zig-out/release
mkdir -p "$dist"

for target in aarch64-macos x86_64-macos; do
    prefix="zig-out/release/$target"
    app="$prefix/nanoview.app"
    zip="$dist/nanoview-$version-$target.zip"
    zig build app -Dtarget="$target" -Doptimize=ReleaseSafe --prefix "$prefix"
    if [ -n "${CODESIGN_IDENTITY:-}" ]; then
        codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$app"
        if [ -n "${NOTARY_KEY_PATH:-}" ]; then
            ditto -c -k --keepParent "$app" "$zip"
            xcrun notarytool submit "$zip" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
                --issuer "$NOTARY_ISSUER_ID" --wait
            xcrun stapler staple "$app"
        fi
    fi
    ditto -c -k --keepParent "$app" "$zip"
done

for target in x86_64-linux-gnu aarch64-linux-gnu; do
    prefix="zig-out/release/$target"
    zig build -Dtarget="$target" -Doptimize=ReleaseSafe --prefix "$prefix"
    # bin/ and share/ (the desktop entry and icon) unpack over a prefix such as ~/.local.
    tar -C "$prefix" -czf "$dist/nanoview-$version-${target%-gnu}.tar.gz" bin share
done

for target in x86_64-windows-gnu aarch64-windows-gnu; do
    prefix="zig-out/release/$target"
    zig build -Dtarget="$target" -Doptimize=ReleaseSafe --prefix "$prefix"
    (cd "$prefix/bin" && zip -q "$OLDPWD/$dist/nanoview-$version-${target%-gnu}.zip" nanoview.exe)
done

(cd "$dist" && shasum -a 256 -- * > SHA256SUMS)
