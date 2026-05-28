{
  description = "Bash Automated Testing System (bats-core) + amarbel-llc batman test orchestrator and bats helper libs";

  inputs = {
    # Fork of upstream nixpkgs. Its default.nix shim auto-applies the
    # fork overlay on `import nixpkgs { ... }`, so fence,
    # buildZxScriptFromFile, gomod2nix's buildGoApplication, etc. are
    # present without a manual overlays list (see amarbel-llc/eng#60).
    nixpkgs.url = "github:amarbel-llc/nixpkgs";
    nixpkgs-master.url = "github:NixOS/nixpkgs/d233902339c02a9c334e7e593de68855ad26c4cb";
    utils.url = "https://flakehub.com/f/numtide/flake-utils/0.1.102";

    # `nix fmt` entry point. Config lives in ./treefmt.nix.
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    # Previously we declared `tap` as a flake input solely to reach
    # `tap.packages.${system}.tap-dancer-go` for the batsLane
    # `emitNdjson = true` codepath. Tap inputs bats (for bats-libs),
    # creating a flake-input cycle that downstream consumers
    # (amarbel-llc/eng) had to break via SCC-local lex ordering. We
    # now vendor tap's source as an FOD (`fetchFromGitHub`) and build
    # tap-dancer-go locally — see `tapSrc` / `tapDancerGo` below.
    # Bumping requires updating the `rev` + `hash` literal there.
    # The long-term clean fix is amarbel-llc/bats#17 (extract bats-libs
    # into its own repo) + amarbel-llc/tap#19 (publish per-platform
    # tap-dancer-go release binaries so this FOD can switch to
    # `pkgs.fetchurl`).
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-master,
      utils,
      treefmt-nix,
    }:
    utils.lib.eachDefaultSystem (
      system:
      let
        # nixpkgs is the amarbel-llc fork; its default.nix shim
        # auto-applies the fork overlay, so `import nixpkgs { ... }`
        # already exposes buildZxScriptFromFile, fence, buildGoApplication,
        # and other amarbel additions without a manual overlays list.
        pkgs = import nixpkgs {
          inherit system;
        };

        # pkgs-master sources the Go toolchain we use to build the
        # vendored tap-dancer-go (mirrors tap's own flake.nix, which
        # builds with pkgs-master.go).
        pkgs-master = import nixpkgs-master { inherit system; };

        # FOD copy of amarbel-llc/tap, pinned. Vendored to avoid the
        # bats↔tap flake-input cycle (see inputs comment above).
        # Bumping protocol:
        #   1. Pick the target tap rev: `nix flake metadata --json
        #      github:amarbel-llc/tap | jq -r .locked.rev`.
        #   2. Compute the unpacked hash:
        #      `nix-prefetch-url --unpack --type sha256 \
        #         https://github.com/amarbel-llc/tap/archive/<rev>.tar.gz`
        #      then `nix hash convert --hash-algo sha256 --to sri <base32>`.
        #   3. Set both `rev` and `hash` here. Bump bats's flake-tip
        #      commit so downstream consumers pick up the new
        #      tap-dancer-go via their own `nix flake update bats`.
        tapSrc = pkgs.fetchFromGitHub {
          owner = "amarbel-llc";
          repo = "tap";
          rev = "641031374269412c74e3c974f94509db9dcf1344";
          hash = "sha256-iW41E9eQgBZUVBumOJfkZrHk/dMFs1xL3pj6aZizvzE=";
        };

        # Locally-built tap-dancer-go. Mirrors tap's own flake.nix
        # `tap-dancer-go` derivation (buildGoApplication invocation,
        # subPackages, gomod2nix.toml path, Go toolchain). Stays in
        # sync because `tapSrc` carries tap's `version.env`,
        # `gomod2nix.toml`, and Go sources verbatim.
        tapDancerGo = pkgs.buildGoApplication {
          pname = "tap-dancer";
          version = builtins.elemAt (builtins.match "^VERSION=([^\n]+)\n?$" (builtins.readFile "${tapSrc}/version.env")) 0;
          src = "${tapSrc}/go";
          pwd = "${tapSrc}/go";
          subPackages = [ "cmd/tap-dancer" ];
          modules = "${tapSrc}/go/gomod2nix.toml";
          go = pkgs-master.go;
          GOTOOLCHAIN = "local";
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
          tap-dancer-go = tapDancerGo;
        };

        # Single source of truth for the fork's own release version.
        # version.env is sed-rewritten by `just bump-version` and read
        # here at flake eval time. See docs/eng-versioning(7).
        batmanVersion = builtins.elemAt (builtins.match "^BATMAN_VERSION=([^\n]+)\n?$" (builtins.readFile ./version.env)) 0;

        # Git revision of the working tree feeding this flake. `self.rev`
        # is populated only when the source is a clean rev; dirty
        # working trees fall back to "dirty". Matches moxy/madder.
        batmanCommit = self.rev or "dirty";

        mkBats =
          {
            tap-dancer-go ? tapDancerGo,
          }:
          (import ./nix/packages/batman.nix {
            inherit pkgs tap-dancer-go;
            inherit batmanVersion batmanCommit;
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
          # Enumerate the self-proof's bats files explicitly so:
          #   1. Artificial demo files in the same directory (e.g.
          #      `ndjson_failure_demo.bats`, consumed only by
          #      `batmanNdjsonDemo`) don't get picked up by the default
          #      `*.bats` glob and break this check.
          #   2. `bats_wrapper_fence.bats` is intentionally EXCLUDED — its
          #      tests shell out to `sandbox-exec`, which fails with
          #      `sandbox_apply: Operation not permitted` inside the nix
          #      darwin builder (Determinate Nix's nix-daemon attaches
          #      Seatbelt to all build children, and macOS refuses nested
          #      `sandbox_apply`). Those tests run host-side via
          #      `just test-batman-fence-wrapper` and inside the linux
          #      container via `test-batman-container-self-proof`.
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
        treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;

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
          formatting = treefmtEval.config.build.check self;
        };

        formatter = treefmtEval.config.build.wrapper;

        # Dev shell carries `just` plus the batman bundle so the
        # justfile recipes (`test-batman-fence`, `test-batman-self-proof`)
        # find the wrapped `bats` and the `batman` binary on PATH
        # without the caller needing to manage anything.
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.just
            # gum: terminal UI logging used by the deploy/maintenance
            # recipes (`deploy-tag` / `bump-version` / `deploy-release`;
            # see docs/eng-versioning(7)).
            pkgs.gum
            batmanPkgs.default
          ];

          shellHook = ''
            echo "bats-core / batman - dev environment"
          '';
        };
      }
    );
}
