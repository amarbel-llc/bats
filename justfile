# bats / batman — see eng-design_patterns-justfile(7) for conventions.
cmd_nix_dev := "nix develop --command"

# CI-equivalent build-and-verify pipeline. `just` (no args) runs this;
# spinclass also runs it as the pre-merge gate (see ./sweatfile).
default: validate-flake build build-devshell test-batman

# --- pre-build ---

# nix flake check (runs check-bats-libs-path, batman-self-proof, formatting).
[group("pre-build")]
validate-flake:
    nix flake check --keep-going

# shellcheck on lib/*.bash and libexec/*.
[group("pre-build")]
lint-shell:
    nix develop --command shellcheck lib/*.bash libexec/*

# Read-only formatting gate: builds the `checks.formatting` derivation,
# which runs treefmt against a /nix/store snapshot of the source tree
# and fails if anything would change. Does NOT modify files in the
# worktree — the modifying counterpart is codemod-fmt. Also runs as
# part of validate-flake.
[group("pre-build")]
lint-fmt:
    nix build --no-link --print-build-logs .#checks.{{ arch() }}-linux.formatting

# --- build ---

[group("build")]
build: build-batman build-bats-libs

# Realize the default batman bundle into the nix store and print the path.
[group("build")]
build-batman:
    @nix build --no-link --print-out-paths .#default

# Realize just the bats-libs bundle and print the path.
[group("build")]
build-bats-libs:
    @nix build --no-link --print-out-paths .#bats-libs

# Verify the devShell evaluates and builds without errors. Catches
# vendor-env / overlay breakage that the prod-binary build can mask.
[group("build")]
build-devshell:
    nix build --no-link .#devShells.{{ arch() }}-linux.default

# --- post-build ---

[group("post-build")]
test-batman: test-batman-fence test-batman-self-proof

# Run batman.bats under PLAIN nixpkgs bats (filters /home/* dirs out of
# PATH so any user-profile-installed wrapped `bats` does not shadow it).
[group("post-build")]
test-batman-fence:
    @batman=$(nix build --no-link --print-out-paths .#default); \
      BATMAN_BIN=$batman/bin/batman \
      BATS_LIB_PATH=$batman/share/bats \
      {{cmd_nix_dev}} bash -c 'PATH=$(echo "$PATH" | tr ":" "\n" | grep -Ev "^/home/" | tr "\n" ":"); exec bats --tap --jobs $(nproc) packages/batman/zz-tests_bats/batman.bats'

# Run the batsLane self-proof: batman's own bats suite executed via the
# batsLane builder this repo exports, inside the nix sandbox. Picks up
# all three zz-tests_bats/*.bats files with BATMAN_BIN and BATS_WRAPPER
# pointed at the built batman bundle. Also runs as part of validate-flake.
[group("post-build")]
test-batman-self-proof:
    nix build --no-link --print-out-paths .#checks.x86_64-linux.batman-self-proof

# Run batman's tests inside a podman container built from a nix OCI
# image (the container lane). Sibling to test-batman-self-proof and
# test-batman-fence, not part of the test-batman aggregate. Requires
# podman on the host (on Darwin, also `podman machine`).
# See FDR-0002 (packages/batman/docs/features/0002-podman-container-lane.md).
[group("post-build")]
test-batman-container-self-proof:
    nix run .#batman-container-self-proof

# Upstream bats-core tests (test/ tree). Opt-in manual; not part of default.
[group("post-build")]
test-bats-core *ARGS:
    nix develop --command bats test/ {{ARGS}}

# --- operational ---

# Invoke the built batman binary with arbitrary args. Useful for smoke-testing.
[group("operational")]
run-batman *args:
    @batman=$(nix build --no-link --print-out-paths .#default); $batman/bin/batman {{args}}

# Generic ad-hoc invocation of the container lane against an arbitrary
# bats source tree. Usage: `just run-bats-container ./path/to/zz-tests_bats`.
[group("operational")]
run-bats-container *args:
    nix run .#bats-lane-container -- {{args}}

# Create a signed annotated tag, push it to origin, and verify the
# signature. The "v" prefix is added for you, so pass the semver
# without it. Usage: just deploy-tag 0.1.0 "feat: initial fork release"
[group("operational")]
deploy-tag version message:
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
# pass the semver without it. Usage: just deploy-release 0.1.1
#
# The deploy-tag recipe stays standalone for callers that want to control
# the commit message themselves without bumping. deploy-release inlines
# the tag-step here because passing a multi-line message across `just`
# recipe boundaries was unreliable — the inner recipe saw a malformed
# argument and `git tag -s` would fail in a way that didn't surface
# until much later (see madder release-v0.3.0 incident).
[group("operational")]
deploy-release version:
    #!/usr/bin/env bash
    set -euo pipefail
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [[ "$current_branch" != "master" ]]; then
        gum log --level error "just deploy-release must be run on master (currently on $current_branch)"
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

# --- codemod ---

[group("codemod")]
codemod-fmt: codemod-fmt-treefmt

# Run treefmt via the flake's `formatter.${system}` wrapper, which
# composes nixfmt + shfmt under one CLI. See treefmt.nix for the
# program config.
[group("codemod")]
codemod-fmt-treefmt:
    nix fmt

# --- maintenance ---

# Sed-rewrite BATMAN_VERSION in version.env to the given semver.
# version.env is the single source of truth for the release version;
# flake.nix reads it via builtins.readFile, and the nix build threads
# it through batman.nix's `batmanVersion` arg into every owned
# derivation + the `batman version` runtimeEnv. No-op if already at
# the target. Usage: just bump-version 0.1.1
[group("maintenance")]
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

[group("maintenance")]
clean: clean-result-symlinks

# Clean stray result symlinks (if any leaked from past `nix build -o ...` runs).
[group("maintenance")]
clean-result-symlinks:
    rm -f result result-*

# --- debug ---

# Build the artificial-failure NDJSON demo and print only the NDJSON
# block from the build log. The build deliberately fails (one of the
# demo's bats cases is `false`); the batsLane `emitNdjson` script
# echoes the captured records to stderr between sentinel markers, so
# `sed` between them is all we need. See bats-lane(7) "NDJSON OUTPUT".
[group("debug")]
debug-batman-ndjson:
    -nix build .#batman-ndjson-demo 2>&1 \
      | sed -n '/BATSLANE NDJSON BEGIN/,/BATSLANE NDJSON END/p' \
      | sed '1d;$d'
