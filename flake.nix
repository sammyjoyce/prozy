{
  inputs = rec {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    # zls-overlay.url = "github:zigtools/zls"; # Disabled - incompatible with Zig 0.16.0-dev
  };
  outputs = inputs @ {
    self,
    nixpkgs,
    ...
  }:
  let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
    zig = inputs.zig-overlay.packages.x86_64-linux.master;
    # zig = inputs.zig-overlay.packages.x86_64-linux.master;
    # Note: ZLS temporarily disabled
    # Issue: ZLS dependencies (known-folders, lsp-kit, diffz) use outdated Zig stdlib APIs
    # Solution: Wait for ZLS deps to update or manually build with newer deps
    # zls = inputs.zls-overlay.packages.x86_64-linux.zls.overrideAttrs (old: {
    #         nativeBuildInputs = [ zig ];
    #       });
  in
  {
    devShells.x86_64-linux.default = pkgs.mkShell {
      packages = with pkgs; [
        zig
        # zls # Disabled until compatible with Zig 0.16.0-dev
      ];
      
      shellHook = ''
        echo "Development environment for prozy"
        echo "Zig version: $(zig version)"
        echo "ZLS temporarily disabled due to Zig 0.16.0-dev compatibility issues"
        echo "Use 'zig build' to compile the project"
      '';
    };
  };
}
