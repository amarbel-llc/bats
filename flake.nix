{
  description = "Bash Automated Testing System (bats-core) + amarbel-llc batman test orchestrator and bats helper libs";

  inputs = {
    # Fork of upstream nixpkgs. The overlay (`overlays.default`) adds
    # fence, buildZxScriptFromFile, gomod2nix's buildGoApplication, etc.
    nixpkgs.url = "github:amarbel-llc/nixpkgs";
    nixpkgs-master.url = "github:NixOS/nixpkgs/e034e386767a6d00b65ac951821835bd977a08f7";
    utils.url = "https://flakehub.com/f/numtide/flake-utils/0.1.102";
    tap = {
      url = "github:amarbel-llc/tap";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-master,
      utils,
      tap,
    }:
    utils.lib.eachDefaultSystem (
      system:
      let
        # nixpkgs is the amarbel-llc fork; overlays.default exposes
        # buildZxScriptFromFile, fence, and other amarbel additions.
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ nixpkgs.overlays.default ];
        };

        mkBats =
          {
            sandcastle ? null,
            tap-dancer-go ? tap.packages.${system}.tap-dancer-go,
          }:
          import ./nix/packages/batman.nix {
            inherit pkgs sandcastle tap-dancer-go;
            src = ./packages/batman;
            fence = pkgs.fence;
            buildZxScriptFromFile = pkgs.buildZxScriptFromFile;
          };

        # Default package set: no sandcastle (sandbox parameterization
        # is delegated to consumers that ship a sandcastle binary).
        batmanPkgs = mkBats { };

        checkBatsLibsPathPkg = import ./nix/packages/check-bats-libs-path.nix {
          inherit pkgs;
          bats-libs = batmanPkgs.bats-libs;
        };
      in
      {
        lib = {
          inherit mkBats;
        };

        packages = {
          default = batmanPkgs.default;
          inherit (batmanPkgs)
            bats-support
            bats-assert
            bats-assert-additions
            tap-writer
            bats-island
            bats-emo
            bats-libs
            bats
            batman
            batman-manpages
            ;
        };

        checks = {
          check-bats-libs-path = checkBatsLibsPathPkg;
        };

        # Dev shell carries `just` plus the batman bundle so the
        # justfile recipes (`test-batman-bats`, `test-batman-fence`)
        # find the wrapped `bats` and the `batman` binary on PATH
        # without the caller needing to manage anything.
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.just
            batmanPkgs.default
          ];

          shellHook = ''
            echo "bats-core / batman - dev environment"
          '';
        };
      }
    );
}
