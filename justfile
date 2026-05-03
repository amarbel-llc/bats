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

# Run batman's own bats test suite via the WRAPPED bats from the build output.
test-batman-bats:
    @batman=$(nix build --no-link --print-out-paths .#default); \
      BATS_WRAPPER=$batman/bin/bats \
      BATMAN_BIN=$batman/bin/batman \
      PATH="$batman/bin:$PATH" \
      {{cmd_nix_dev}} just packages/batman/zz-tests_bats/test

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

# Aggregate batman test suite
test-batman: test-batman-bats test-batman-fence

# --- general --------------------------------------------------------------

# Clean stray result symlinks (if any leaked from past `nix build -o ...` runs)
clean:
    rm -f result result-*
