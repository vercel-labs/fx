{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = eachSystem (pkgs: {
        default = pkgs.stdenv.mkDerivation {
          name = "fx";
          src = ./.;
          nativeBuildInputs = [ pkgs.makeBinaryWrapper pkgs.zig_0_16 ];
          postFixup = "wrapProgram $out/bin/fx --set FX_AUTO_UPGRADE 0";
          meta.mainProgram = "fx";
        };
      });
      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell { packages = [ pkgs.zig_0_16 ]; };
      });
    };
}
