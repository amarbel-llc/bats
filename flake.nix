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

        # batsLane is a generic build-support helper for running bats
        # suites against pre-built binaries inside the nix sandbox.
        # Exposed at both lib.${system}.batsLane and (mkBats { }).batsLane;
        # both forms reference the same function and default to plain
        # pkgs.bats. Consumers wanting fence sandboxing pass
        # `bats = batmanPkgs.bats` explicitly.
        batsLaneLib = import ./nix/packages/bats-lane.nix {
          inherit (pkgs)
            lib
            runCommand
            bats
            parallel
            ;
        };

        mkBats =
          {
            tap-dancer-go ? tap.packages.${system}.tap-dancer-go,
          }:
          (import ./nix/packages/batman.nix {
            inherit pkgs tap-dancer-go;
            src = ./packages/batman;
            fence = pkgs.fence;
            buildZxScriptFromFile = pkgs.buildZxScriptFromFile;
          })
          // {
            inherit (batsLaneLib) batsLane;
          };

        batmanPkgs = mkBats { };

        checkBatsLibsPathPkg = import ./nix/packages/check-bats-libs-path.nix {
          inherit pkgs;
          bats-libs = batmanPkgs.bats-libs;
        };

        # Self-proof: run batman's own bats suite via the same batsLane
        # builder this repo exports. BATMAN_BIN + BATS_WRAPPER both point
        # at batmanPkgs.default so all three .bats files (batman.bats,
        # bats_wrapper.bats, island.bats) find the binaries they need.
        # Uses plain pkgs.bats (batsLane's default) as the test runner;
        # the wrapper-asserting tests in bats_wrapper.bats invoke the
        # fence-wrapped bats themselves via $BATS_WRAPPER.
        batmanSelfProof = batsLaneLib.batsLane {
          name = "batman-self-proof";
          batsSrc = ./packages/batman/zz-tests_bats;
          binaries = {
            BATMAN_BIN = {
              base = batmanPkgs.default;
              name = "batman";
            };
            BATS_WRAPPER = {
              base = batmanPkgs.default;
              name = "bats";
            };
          };
          batsLibPath = [ batmanPkgs.bats-libs.batsLibPath ];
          # bats-island's setup_test_home / setup_test_repo helpers
          # shell out to `git` (init + config). The nix builder PATH
          # doesn't include git by default, so provide it explicitly.
          nativeBuildInputs = [ pkgs.git ];
        };
      in
      {
        lib = {
          inherit mkBats;
          inherit (batsLaneLib) batsLane;
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
          batman-self-proof = batmanSelfProof;
        };

        # Dev shell carries `just` plus the batman bundle so the
        # justfile recipes (`test-batman-fence`, `test-batman-self-proof`)
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
