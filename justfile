# bats / batman
cmd_nix_dev := "nix develop --command"

default:
    @just --list

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

# Aggregate batman test suite
test-batman: test-batman-fence test-batman-self-proof

# --- general --------------------------------------------------------------

# Clean stray result symlinks (if any leaked from past `nix build -o ...` runs)
clean:
    rm -f result result-*
