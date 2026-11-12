{
  description = "nanoview: a small image viewer in Zig on nanoui";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zig-overlay,
      ...
    }:
    let
      lib = nixpkgs.lib;
      # nixpkgs-unstable dropped x86_64-darwin; the release archives still cover it.
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];
      forSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # build.zig.zon holds the one version number; releases check the tag against it.
      version = builtins.head (
        builtins.match ".*\\.version = \"([^\"]+)\".*" (builtins.readFile ./build.zig.zon)
      );
      zigFor = pkgs: zig-overlay.packages.${pkgs.stdenv.hostPlatform.system}."0.17.1";
      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./build.zig
          ./build.zig.zon
          ./src
          ./macos
          ./linux
          ./vendor
        ];
      };
    in
    {
      packages = forSystems (
        pkgs:
        let
          zig = zigFor pkgs;
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
          # The Zig package tree: the lazy dependencies of the vendored nanoui, fetched once.
          # Update the hash when a build.zig.zon changes its dependencies.
          deps = pkgs.stdenvNoCC.mkDerivation {
            pname = "nanoview-zig-deps";
            inherit version src;
            nativeBuildInputs = [ zig ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
              zig build --fetch=all
            '';
            installPhase = "cp -r zig-pkg $out";
            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = "sha256-ZCI7+8TBorzBkIhC5tT8sR9/7flUSSw+RMu0OdeGbV8=";
          };
          nanoview = pkgs.stdenvNoCC.mkDerivation {
            pname = "nanoview";
            inherit version src;
            nativeBuildInputs = [
              zig
              pkgs.removeReferencesTo
            ]
            ++ lib.optionals isDarwin [
              pkgs.cctools
              pkgs.darwin.autoSignDarwinBinariesHook
            ]
            ++ lib.optionals (!isDarwin) [ pkgs.makeWrapper ];
            dontConfigure = true;
            dontInstall = true;
            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
              cp -r ${deps} zig-pkg
              chmod -R u+w zig-pkg
              ${lib.optionalString isDarwin ''
                # The build has no xcrun. Zig reads NIX_CFLAGS_COMPILE as its native search
                # paths and takes the SDK's libraries from --search-prefix.
                sdk=${pkgs.apple-sdk.sdkroot}
                export NIX_CFLAGS_COMPILE="-isystem $sdk/usr/include -iframework $sdk/System/Library/Frameworks"
              ''}
              zig build ${lib.optionalString isDarwin "app"} install \
                -Doptimize=ReleaseSafe --prefix "$out" ${lib.optionalString isDarwin ''--search-prefix "$sdk/usr"''}
              # Debug info names Zig's std directory; it is not needed at run time.
              remove-references-to -t ${zig} "$out/bin/nanoview"
              ${lib.optionalString isDarwin ''
                mkdir -p "$out/Applications"
                mv "$out/nanoview.app" "$out/Applications/"
                # The search prefix also became an rpath. System libraries load by absolute
                # install name, so the rpath only kept the SDK in the closure. The changed
                # binaries are signed again by autoSignDarwinBinariesHook.
                app_bin="$out/Applications/nanoview.app/Contents/MacOS/nanoview"
                remove-references-to -t ${zig} "$app_bin"
                for f in "$out/bin/nanoview" "$app_bin"; do
                  install_name_tool -delete_rpath "$sdk/usr/lib" "$f"
                done
              ''}
            '';
            postFixup = lib.optionalString (!isDarwin) ''
              # nanoui loads GTK and OpenGL with dlopen at run time.
              wrapProgram "$out/bin/nanoview" --prefix LD_LIBRARY_PATH : ${
                lib.makeLibraryPath [
                  pkgs.gtk3
                  pkgs.gdk-pixbuf
                  pkgs.libGL
                ]
              }
            '';
            meta = {
              description = "A small qView-style image viewer";
              homepage = "https://github.com/jeiang/nanoview";
              mainProgram = "nanoview";
              platforms = systems;
            };
          };
        in
        {
          inherit nanoview;
          default = nanoview;
        }
      );

      apps = forSystems (pkgs: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };
      });

      checks = forSystems (pkgs: {
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        format = pkgs.runCommandLocal "nanoview-zig-fmt" { nativeBuildInputs = [ (zigFor pkgs) ]; } ''
          zig fmt --check ${src}/build.zig ${src}/src
          touch "$out"
        '';
      });

      formatter = forSystems (pkgs: pkgs.nixfmt);

      devShells = forSystems (pkgs: {
        default = pkgs.mkShellNoCC (
          {
            packages = [
              (zigFor pkgs)
              # Editor language servers. zls follows Zig's minor version.
              pkgs.zls_0_17
              pkgs.clang-tools # clangd, for the C bridges and vendored decoders
              pkgs.nixd
            ];
            # Zig reads NIX_CFLAGS_COMPILE as a sign to search Nix paths only,
            # and then finds no macOS SDK frameworks.
            shellHook = "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS";
          }
          // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            # nanoui loads GTK and OpenGL with dlopen at run time.
            LD_LIBRARY_PATH = lib.makeLibraryPath [
              pkgs.gtk3
              pkgs.gdk-pixbuf
              pkgs.libGL
            ];
          }
        );
      });
    };
}
