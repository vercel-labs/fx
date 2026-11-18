{
  description = "fx, a terminal coding agent written in Zig";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The app version lives in src/main.zig, which build.zig also reads.
      version =
        let
          main = builtins.readFile ./src/main.zig;
          match = builtins.match ''.*pub const version = "([^"]+)".*'' main;
        in
        if match == null then "0.0.0" else builtins.head match;
    in
    {
      packages = forAllSystems (pkgs: {
        fx = pkgs.stdenv.mkDerivation {
          pname = "fx";
          inherit version;

          src = nixpkgs.lib.fileset.toSource {
            root = ./.;
            fileset = nixpkgs.lib.fileset.unions [
              ./build.zig
              ./build.zig.zon
              ./src
              ./LICENSE
              ./THIRD_PARTY_NOTICES.md
            ];
          };

          # The hook runs `zig build` in ReleaseSafe for a baseline CPU. Its
          # install phase compiles with the final prefix, so a separate build
          # phase would only compile fx a second time.
          nativeBuildInputs = [ pkgs.zig_0_17.hook ];
          dontBuild = true;

          meta = {
            description = "Terminal coding agent";
            homepage = "https://fx.sh";
            license = nixpkgs.lib.licenses.asl20;
            mainProgram = "fx";
            platforms = systems;
          };
        };
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.fx;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig_0_17
            pkgs.bun
            pkgs.tmux
            pkgs.hyperfine
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
