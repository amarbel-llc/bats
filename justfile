# bats / batman
cmd_nix_dev := "nix develop --command"

# Build-and-verify pipeline (eng-design_patterns-justfile(7) convention).
# `just` with no args runs this; spinclass also runs `just` as the
# pre-merge gate (see ./sweatfile).
default: test-batman flake-check

# --- bats-core upstream tests (existing) -----------------------------------

# Run upstream bats-core tests (test/ tree)
test *ARGS:
    nix develop --command bats test/ {{ARGS}}

# Check with shellcheck
check:
    nix develop --command shellcheck lib/*.bash libexec/*

# Format with shfmt
fmt:
    nix develop --command shfmt -w -i 2 -ci lib/*.bash libexec/*

# --- batman / bats-libs flake outputs --------------------------------------

# Realize the default batman bundle into the nix store and print the path.
build-batman:
    @nix build --no-link --print-out-paths .#default

# Realize just the bats-libs bundle and print the path.
build-bats-libs:
    @nix build --no-link --print-out-paths .#bats-libs

# Run nix flake check (includes check-bats-libs-path)
flake-check:
    nix flake check --keep-going

# Run batman.bats under PLAIN nixpkgs bats (filters /home/* dirs out of
# PATH so any user-profile-installed wrapped `bats` does not shadow it).
test-batman-fence:
    @batman=$(nix build --no-link --print-out-paths .#default); \
      BATMAN_BIN=$batman/bin/batman \
      BATS_LIB_PATH=$batman/share/bats \
      {{cmd_nix_dev}} bash -c 'PATH=$(echo "$PATH" | tr ":" "\n" | grep -Ev "^/home/" | tr "\n" ":"); exec bats --tap --jobs $(nproc) packages/batman/zz-tests_bats/batman.bats'

# Invoke the built batman binary with arbitrary args. Useful for manual smoke-testing.
run-batman *args:
    @batman=$(nix build --no-link --print-out-paths .#default); $batman/bin/batman {{args}}

# Run the batsLane self-proof: batman's own bats suite executed via the
# batsLane builder this repo exports, inside the nix sandbox. Picks up
# all three zz-tests_bats/*.bats files with BATMAN_BIN and BATS_WRAPPER
# pointed at the built batman bundle. Also runs as part of
# `just flake-check`.
test-batman-self-proof:
    nix build --no-link --print-out-paths .#checks.x86_64-linux.batman-self-proof

# Run batman's tests inside a podman container built from a nix OCI
# image (the container lane). Sibling to test-batman-self-proof and
# test-batman-fence, not part of the `test-batman` aggregate. Requires
# podman on the host (on Darwin, also `podman machine`).
# See FDR-0002 (packages/batman/docs/features/0002-podman-container-lane.md).
test-batman-container-self-proof:
    nix run .#batman-container-self-proof

# Generic ad-hoc invocation of the container lane against an arbitrary
# bats source tree. Usage: `just test-batman-container ./path/to/zz-tests_bats`.
test-batman-container *args:
    nix run .#bats-lane-container -- {{args}}

# Aggregate batman test suite
test-batman: test-batman-fence test-batman-self-proof

# --- debug ----------------------------------------------------------------

# Build the artificial-failure NDJSON demo and print only the NDJSON
# block from the build log. The build deliberately fails (one of the
# demo's bats cases is `false`); the batsLane `emitNdjson` script
# echoes the captured records to stderr between sentinel markers, so
# `sed` between them is all we need. See bats-lane(7) "NDJSON OUTPUT".
# [group: debug]
test-batman-ndjson-demo:
    -nix build .#batman-ndjson-demo 2>&1 \
      | sed -n '/BATSLANE NDJSON BEGIN/,/BATSLANE NDJSON END/p' \
      | sed '1d;$d'

# --- general --------------------------------------------------------------

# Clean stray result symlinks (if any leaked from past `nix build -o ...` runs)
clean:
    rm -f result result-*
