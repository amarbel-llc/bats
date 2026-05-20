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

# --- maint ----------------------------------------------------------------

# Sed-rewrite BATMAN_VERSION in version.env to the given semver.
# version.env is the single source of truth for the release version;
# flake.nix reads it via builtins.readFile, and the nix build threads
# it through batman.nix's `batmanVersion` arg into every owned
# derivation + the `batman version` runtimeEnv. No-op if already at
# the target. Usage: just bump-version 0.1.1
[group("maint")]
bump-version new_version:
    #!/usr/bin/env bash
    set -euo pipefail
    current=$(grep '^BATMAN_VERSION=' version.env | cut -d= -f2)
    if [[ "$current" == "{{new_version}}" ]]; then
        gum log --level info "already at {{new_version}}"
        exit 0
    fi
    sed -i.bak 's/^BATMAN_VERSION=.*/BATMAN_VERSION={{new_version}}/' version.env && rm version.env.bak
    gum log --level info "bumped BATMAN_VERSION: $current → {{new_version}}"

# Create a signed annotated tag, push it to origin, and verify the
# signature. The "v" prefix is added for you, so pass the semver
# without it. Usage: just tag 0.1.0 "feat: initial fork release"
[group("maint")]
tag version message:
    #!/usr/bin/env bash
    set -euo pipefail
    tag="v{{version}}"
    prev=$(git tag --sort=-v:refname -l "v*" | head -1)
    if [[ -n "$prev" ]]; then
        gum log --level info "Previous: $prev"
        git log --oneline "$prev"..HEAD
    fi
    git tag -s -m "{{message}}" "$tag"
    gum log --level info "Created tag: $tag"
    git push origin "$tag"
    gum log --level info "Pushed $tag"
    git tag -v "$tag"

# Cut a release: must be run on master. Bumps BATMAN_VERSION in
# version.env, commits the bump with a changelog-style message built
# from commits since the last v* tag, pushes master, then signs and
# pushes the v{{version}} tag. The "v" prefix is added for you, so
# pass the semver without it. Usage: just release 0.1.1
#
# The `tag` recipe stays standalone for callers that want to control
# the commit message themselves without bumping. Release inlines the
# tag-step here because passing a multi-line message across `just`
# recipe boundaries was unreliable — the inner recipe saw a malformed
# argument and `git tag -s` would fail in a way that didn't surface
# until much later (see madder release-v0.3.0 incident).
[group("maint")]
release version:
    #!/usr/bin/env bash
    set -euo pipefail
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [[ "$current_branch" != "master" ]]; then
        gum log --level error "just release must be run on master (currently on $current_branch)"
        exit 1
    fi
    prev=$(git tag --sort=-v:refname -l "v*" | head -1)
    header="release v{{version}}"
    if [[ -n "$prev" ]]; then
        summary=$(git log --format='- %s' "$prev"..HEAD)
        if [[ -n "$summary" ]]; then
            msg="$header"$'\n\n'"$summary"
        else
            msg="$header"
        fi
    else
        msg="$header"
    fi
    just bump-version "{{version}}"
    if ! git diff --quiet version.env; then
        git add version.env
        git commit -m "chore: release v{{version}}"
        git push origin master
        gum log --level info "pushed version.env bump to master"
    fi
    tag="v{{version}}"
    if [[ -n "$prev" ]]; then
        gum log --level info "Previous: $prev"
        git log --oneline "$prev"..HEAD || true
    fi
    git tag -s -m "$msg" "$tag"
    gum log --level info "Created tag: $tag"
    git push origin "$tag"
    gum log --level info "Pushed $tag"

# --- general --------------------------------------------------------------

# Clean stray result symlinks (if any leaked from past `nix build -o ...` runs)
clean:
    rm -f result result-*
