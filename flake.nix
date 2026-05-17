{
  description = "Bash Automated Testing System (bats-core) + amarbel-llc batman test orchestrator and bats helper libs";

  inputs = {
    # Fork of upstream nixpkgs. The overlay (`overlays.default`) adds
    # fence, buildZxScriptFromFile, gomod2nix's buildGoApplication, etc.
    nixpkgs.url = "github:amarbel-llc/nixpkgs";
    nixpkgs-master.url = "github:NixOS/nixpkgs/d233902339c02a9c334e7e593de68855ad26c4cb";
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
          # Enables per-lane `emitNdjson = true` opt-in without forcing
          # callers to re-import the file with their own tap-dancer
          # derivation. Same input as the bats wrapper at line 51.
          tap-dancer-go = tap.packages.${system}.tap-dancer-go;
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
          # Enumerate the self-proof's bats files explicitly so artificial
          # demo files in the same directory (e.g. `ndjson_failure_demo.bats`,
          # consumed only by `batmanNdjsonDemo`) don't get picked up by the
          # default `*.bats` glob and break this check.
          testFiles = [
            "batman.bats"
            "bats_wrapper.bats"
            "island.bats"
          ];
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
          # Regression for issue #10: extraStagedFiles with a `dest`
          # containing a parent dir previously failed because the
          # staging hook did not `mkdir -p` the parent. The staged
          # file is unused by the suite — its existence at this path
          # at build time is the test.
          extraStagedFiles = [
            {
              src = ./packages/batman/doc/bats-lane.7.scd;
              dest = "regression-issue-10/bats-lane.7.scd";
            }
          ];
        };

        # Container lane (FDR-0002): an alternate test sandbox built on
        # podman + a nix-built OCI image. Sibling to batman-self-proof
        # and test-batman-fence, not a replacement. Not exposed as a
        # flake check because podman cannot run inside a nix builder.
        containerLane = import ./nix/packages/container-lane.nix {
          inherit pkgs batmanPkgs;
          batmanTestsSrc = ./packages/batman/zz-tests_bats;
        };

        # NDJSON prototype: drives the artificial-failure suite through
        # the new `emitNdjson = true` codepath in batsLane. Always fails
        # to build (the demo suite contains a deliberately failing test),
        # so it is exposed only as a `package` — NOT a `check` — and
        # users inspect the captured artifacts via
        # `nix build .#batman-ndjson-demo --keep-failed`. See FDR/RFC
        # cross-reference in `packages/batman/doc/bats-lane.7.scd`.
        batmanNdjsonDemo = batsLaneLib.batsLane {
          name = "batman-ndjson-demo";
          batsSrc = ./packages/batman/zz-tests_bats;
          testFiles = [ "ndjson_failure_demo.bats" ];
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
          emitNdjson = true;
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
          bats-lane-container-image = containerLane.image;
          bats-lane-container = containerLane.runner;
          batman-container-self-proof = containerLane.selfProof;
          batman-ndjson-demo = batmanNdjsonDemo;
        };

        apps = {
          bats-lane-container = {
            type = "app";
            program = "${containerLane.runner}/bin/bats-lane-container";
          };
          batman-container-self-proof = {
            type = "app";
            program = "${containerLane.selfProof}/bin/batman-container-self-proof";
          };
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
