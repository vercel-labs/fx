{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

  outputs = { nixpkgs, ... }: {
    packages = nixpkgs.lib.genAttrs
      [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ]
      (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.stdenv.mkDerivation {
            pname = "fx";
            version =
              let
                line = pkgs.lib.findFirst (pkgs.lib.hasPrefix "pub const version = ") null
                  (pkgs.lib.splitString "\n" (builtins.readFile ./src/main.zig));
              in
              pkgs.lib.removeSuffix "\";" (pkgs.lib.removePrefix "pub const version = \"" line);
            src = ./.;
            nativeBuildInputs = [ pkgs.makeBinaryWrapper pkgs.zig ];
            postInstall = ''
              install -Dm444 LICENSE "$out/share/licenses/fx/LICENSE"
              install -Dm444 THIRD_PARTY_NOTICES.md "$out/share/licenses/fx/THIRD_PARTY_NOTICES.md"
            '';
            postFixup = "wrapProgram $out/bin/fx --set-default FX_AUTO_UPGRADE 0";
            meta = {
              description = "Tiny, open, embeddable, native coding agent";
              homepage = "https://fx.sh";
              license = pkgs.lib.licenses.asl20;
              mainProgram = "fx";
              platforms = [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ];
            };
          };
        });
  };
}
