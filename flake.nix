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
    { nixpkgs, zig-overlay, ... }:
    let
      lib = nixpkgs.lib;
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      devShells = lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShellNoCC (
            {
              packages = [ zig-overlay.packages.${system}."0.17.1" ];
              # Zig reads NIX_CFLAGS_COMPILE as a sign to search Nix paths only,
              # and then finds no macOS SDK frameworks.
              shellHook = "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS";
            }
            // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
              # nanoui loads GTK and OpenGL with dlopen at run time.
              LD_LIBRARY_PATH = lib.makeLibraryPath [
                pkgs.gtk3
                pkgs.libGL
              ];
            }
          );
        }
      );
    };
}
