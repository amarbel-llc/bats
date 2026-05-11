{
  pkgs,
  batmanPkgs,
  batmanTestsSrc,
}:
let
  imageName = "amarbel-llc-bats-lane";

  # OCI image: plain bats + bats-libs + batman orchestrator + the
  # tools the suite shells out to (git for bats-island, grep for
  # batman's diagnostics, etc.).
  #
  # No fence and no fence-wrapped bats: the container is THE sandbox.
  # Layering fence-bwrap inside rootless podman's user-namespace
  # collapses with `bwrap: Creating new namespace failed: Operation
  # not permitted` — the same nested-bwrap family as bob#113, just
  # with rootless podman playing the outer role. Since the container
  # already enforces fs/network/process isolation, the per-test fence
  # layer would be redundant even if it worked.
  #
  # The bats *source* is NOT baked into the image. Callers mount it
  # at /tests when they invoke podman. See FDR-0002.
  #
  # No explicit `tag`; dockerTools derives it from the image hash so
  # podman can dedup loads by tag. The runner keys off
  # `${imageName}:${image.imageTag}` to skip the (slow) podman load
  # when the same closure is already loaded.
  image = pkgs.dockerTools.buildLayeredImage {
    name = imageName;
    contents = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.git
      pkgs.parallel
      pkgs.bats
      batmanPkgs.bats-libs
      batmanPkgs.batman
    ];
    config = {
      Env = [
        "BATS_LIB_PATH=${batmanPkgs.bats-libs.batsLibPath}"
        "BATMAN_BIN=${batmanPkgs.batman}/bin/batman"
        "PATH=/bin:/usr/bin"
      ];
      WorkingDir = "/tests";
    };
  };

  imageRef = "${imageName}:${image.imageTag}";

  # Generic, nix run-able entry point.
  # Usage: bats-lane-container <bats-source-dir> [test-file ...]
  # Trailing args are passed to `bats` from inside /tests (the mount
  # point). Defaults to running `*.bats` when no test files are given.
  runner = pkgs.writeShellApplication {
    name = "bats-lane-container";
    text = ''
      if ! command -v podman >/dev/null 2>&1; then
        echo "bats-lane-container: podman not found on PATH" >&2
        echo "install podman or, on Darwin, ensure podman machine is on PATH" >&2
        exit 1
      fi

      if [[ $# -lt 1 ]]; then
        echo "usage: bats-lane-container <bats-source-dir> [test-file ...]" >&2
        exit 2
      fi

      bats_src="$1"; shift
      bats_src="$(realpath "$bats_src")"

      if [[ ! -d "$bats_src" ]]; then
        echo "bats-lane-container: $bats_src is not a directory" >&2
        exit 2
      fi

      # Remaining args become bats's test-file positionals, joined into
      # a single shell-glob-friendly string the container's bash
      # expands inside /tests. Default to *.bats when caller didn't
      # specify.
      if [[ $# -eq 0 ]]; then
        bats_glob='*.bats'
      else
        bats_glob="$*"
      fi

      case "$(uname -s)" in
        Linux) ;;
        Darwin)
          # Bootstrap podman machine on first run; idempotent on
          # subsequent runs.
          podman machine inspect default >/dev/null 2>&1 || podman machine init
          podman machine start >/dev/null 2>&1 || true
          ;;
        *)
          echo "bats-lane-container: unsupported OS: $(uname -s)" >&2
          exit 1
          ;;
      esac

      # Skip the (slow) load if this exact image is already loaded.
      # podman load on a 500+ MB tar takes ~minutes even when the image
      # already exists; checking presence by tag is O(ms). Tag is
      # content-derived, so a closure change yields a new tag and
      # forces a fresh load.
      if ! podman image exists ${imageRef} 2>/dev/null; then
        echo "bats-lane-container: loading image ${imageRef} ..." >&2
        podman load -i ${image} >/dev/null
      fi

      # --tmpfs /tmp: dockerTools images don't ship a writable /tmp;
      # bats uses BATS_TMPDIR (default /tmp) for scratch.
      # `cd /tests && bats <glob>`: relative invocation avoids the
      # BATS_TEST_DIRNAME = `//tests` (double-slash) artifact bats
      # produces when called with an absolute mount path.
      exec podman run \
        --rm \
        --network none \
        --tmpfs /tmp \
        --volume "$bats_src:/tests:ro" \
        ${imageRef} \
        bash -c "cd /tests && bats $bats_glob"
    '';
  };

  # Container-lane analogue of checks.${system}.batman-self-proof.
  # Pins the runner to batman's own zz-tests_bats source tree, and
  # explicitly enumerates the test files that don't depend on the
  # fence wrapper (bats_wrapper.bats is excluded — without
  # BATS_WRAPPER, its setup `require_bin` fails). Same posture
  # test-batman-fence takes.
  selfProof = pkgs.writeShellApplication {
    name = "batman-container-self-proof";
    runtimeInputs = [ runner ];
    text = ''
      exec bats-lane-container ${batmanTestsSrc} batman.bats island.bats
    '';
  };
in
{
  inherit image runner selfProof;
}
