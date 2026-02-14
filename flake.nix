{
  description = "Bash Automated Test System";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/23d72dabcb3b12469f57b37170fcbc1789bd7457";
    nixpkgs-master.url = "github:NixOS/nixpkgs/b28c4999ed71543e71552ccfd0d7e68c581ba7e9";
    utils.url = "https://flakehub.com/f/numtide/flake-utils/0.1.102";
    shell.url = "github:friedenberg/eng?dir=devenvs/shell";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-master,
      utils,
      shell,
    }:
    utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
        name = "bats-core";
        script = (
          pkgs.writeScriptBin name (builtins.readFile ./bin/bats-core.bash)
        ).overrideAttrs (old: {
          buildCommand = "${old.buildCommand}\n patchShebangs $out";
        });
        buildInputs = with pkgs; [
          gum
        ];
      in
      {
        packages.default = pkgs.symlinkJoin {
          inherit name;
          paths = [ script ] ++ buildInputs;
          buildInputs = [ pkgs.makeWrapper ];
          postBuild = "wrapProgram $out/bin/${name} --prefix PATH : $out/bin";
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            just
            gum
          ];

          inputsFrom = [
            shell.devShells.${system}.default
          ];

          shellHook = ''
            echo "${name} - dev environment"
          '';
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/${name}";
        };
      }
    );
}
