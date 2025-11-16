{
  description = "Prozy dev shell with Zig + ZLS (Linux + macOS)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zigPkgs.url = "github:mitchellh/zig-overlay";
    zigPkgs.inputs.nixpkgs.follows = "nixpkgs";

    zlsPkg.url = "github:zigtools/zls";
    zlsPkg.inputs.zig-overlay.follows = "zigPkgs";
    zlsPkg.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      zigPkgs,
      zlsPkg,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [
          (final: prev: {
            # Expose zig overlay + ZLS on pkgs
            zigpkgs = zigPkgs.packages.${prev.system};
            zls = zlsPkg.packages.${prev.system}.default;
          })
        ];

        pkgs = import nixpkgs {
          inherit system overlays;
        };
      in
      {
        # flake-utils will turn this into devShells.${system}.default
        devShells.default = pkgs.mkShell {
          packages = [
            # Pick your preferred Zig channel/version here
            pkgs.zigpkgs.master
            pkgs.zls
          ];

          shellHook = ''
            echo "Development environment for prozy"
            echo "System: ${system}"
            echo "Zig version: $(zig version || true)"
            echo "Use 'zig build' to compile the project"
          '';
        };
      }
    );
}
