# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Overview

This repo is `amarbel-llc/bats` — a fork of `bats-core/bats-core` augmented
with:

- A nix flake (`flake.nix`) that exposes packaging for `batman`, a
  fence-based BATS test runner, and a curated set of bats helper libs
  (`bats-support`, `bats-assert`, `bats-assert-additions`, `bats-island`,
  `bats-emo`, `tap-writer`).
- The bats-core upstream tree (`bin/`, `libexec/`, `lib/bats-core/`,
  `test/`, etc.) which the fork tracks against
  `https://github.com/bats-core/bats-core`.

The flake's downstream consumers (e.g. `amarbel-llc/bob`) take this repo
as a flake input and call `bats.lib.${system}.mkBats { tap-dancer-go }`.
The wrapper always sandboxes test commands via `fence` (from the
`amarbel-llc/nixpkgs` overlay's `pkgs.fence`).

## Build & Test

Conventions follow eng-design_patterns-justfile(7): verb-noun recipe
names, aggregate-with-no-body, `[group(...)]` lifecycle attributes.

``` sh
just                            # default = CI lane (validate + lint + build + test-batman)

# pre-build
just validate                   # aggregate: validate-flake
just validate-flake             # nix flake check (check-bats-libs-path + batman-self-proof + formatting)
just lint                       # aggregate: lint-fmt + lint-shell
just lint-shell                 # shellcheck on lib/bats-core/*.bash and libexec/bats-core/*
just lint-fmt                   # read-only formatting gate (builds checks.formatting)

# build
just build                      # aggregate: build-batman + build-bats-libs + build-devshell
just build-batman               # nix build .#default
just build-bats-libs            # nix build .#bats-libs
just build-devshell             # devShell build-check (catches vendor-env breakage)

# post-build
just test-batman                # aggregate: test-batman-fence + test-batman-self-proof
just test-batman-fence          # batman.bats under plain nixpkgs bats
just test-batman-self-proof     # batsLane self-proof inside the nix sandbox
just test-extras                # aggregate: test-batman-container-self-proof + test-bats-core (opt-in)
just test-batman-container-self-proof  # podman container lane (opt-in, not in test-batman)
just test-bats-core             # upstream bats-core tests (test/ tree, opt-in manual)

# operational
just run-batman <args>          # smoke-test the built batman binary
just run-bats-container <args>  # ad-hoc container lane against an arbitrary bats tree
just deploy-tag <ver> <msg>     # signed annotated tag + push
just deploy-release <ver>       # bump-version + commit + push + tag + push tag (on master)

# codemod
just codemod-fmt                # `nix fmt` (nixfmt + shfmt via conformist; see conformist.nix)

# maintenance
just bump-version <ver>         # rewrite BATMAN_VERSION in version.env
just clean                      # rm -f result result-*
```

## Architecture

### Flake outputs

`flake.nix` exposes per-system:

- `lib.${system}.mkBats { tap-dancer-go ? ... }` — function that returns
  the full batman package set. The bats wrapper invokes
  `fence --settings <cfg> -- bats <args>` for every test command;
  callers can pass `--no-sandbox` at runtime to bypass fence. The
  returned record also includes `batsLane` (see below) so callers can
  reach it through the bundle without a second flake lookup.
- `lib.${system}.batsLane { base; batsSrc; binaryName; ... }` — generic
  build-support helper, copied from `amarbel-llc/nixpkgs`'s
  `pkgs/build-support/bats-test`. Runs a bats integration suite against
  pre-built binaries inside the nix sandbox; defaults to plain
  `pkgs.bats`. Consumers wanting fence sandboxing pass
  `bats = batmanPkgs.bats` explicitly. The same function is also
  available as `(mkBats { }).batsLane`.
- `packages.${system}` — `default`, `batman`, `bats`, `bats-libs`, plus
  the six bats helper libs and `batman-manpages` individually.
- `checks.${system}.check-bats-libs-path` — regression test that
  `bats-libs.batsLibPath` is a valid `BATS_LIB_PATH` entry (no trailing
  `/share/bats` required of consumers).
- `devShells.${system}.default` — the bats-core development shell
  (predates the batman additions).

### `nix/packages/bats-lane.nix`

The `batsLane` builder, lifted verbatim from `amarbel-llc/nixpkgs`'s
`pkgs/build-support/bats-test/default.nix`. Standalone function taking
`lib`, `runCommand`, `bats`, `parallel`; produces a `runCommand`
derivation that stages a bats source tree, exports caller-named env
vars pointing at one or more pre-built binaries, optionally extends
`BATS_LIB_PATH`, and runs bats with an optional `--filter-tags`
expression. Output is a stamp file. See the file's header docstring for
the full argument surface and the `binaries` / single-binary-shortcut
forms.

### `nix/packages/batman.nix`

The build expression. Single function taking `pkgs`, `src`,
`tap-dancer-go`, `fence`, `buildZxScriptFromFile`. Constructs the six
helper libs, the batman zx script, the fence-backed bats wrapper, and
the manpages bundle.

The bats wrapper emits a fence config translating the historical
sandcastle-shaped policy:

- `filesystem.denyRead` blocks credential dirs (`~/.ssh`, `~/.aws`,
  `~/.gnupg`, `~/.config`, `~/.local`, `~/.password-store`, `~/.kube`).
- `filesystem.allowWrite` restricts writes to `/tmp` and
  `/private/tmp`.
- `filesystem.allowRead`/`allowExecute = ["/"]` so test processes can
  run nix-store binaries normally; the security boundary is enforced
  via the deny lists, not whitelisting.
- `network.allowedDomains: []` denies all egress.
- `command.useDefaults: false` so fence's built-in deny list (which
  collaterally blocks coreutils via chroot detection) doesn't break
  normal shell tools.

### `packages/batman/`

The package source:

- `src/batman.ts` — fence-based BATS test orchestrator (zx script).
- `lib/{bats-support,bats-assert,bats-assert-additions,bats-island,bats-emo,tap-writer}/` —
  helper libraries, each with `load.bash`, `src/*.bash`, and a manpage.
  `bats-support` and `bats-assert` are vendored from upstream
  `bats-core/bats-{support,assert}` (CC0 LICENSE preserved). The other
  four are amarbel-llc originals.
- `doc/bats-testing.7.scd` — top-level BATS-testing manpage.
- `docs/features/0001-bats-island.md` — feature design doc.
- `zz-tests_bats/` — the batman test suite (run via `just test-batman-*`).

### Design history

`docs/plans/2026-04-25-batman-v0-{design,plan}.md` capture the original
design and v0 implementation plan from when batman lived in bob.

## Key conventions

### nixpkgs

`nixpkgs` input points at `github:amarbel-llc/nixpkgs` (a fork that
provides `pkgs.fence`, `pkgs.buildZxScriptFromFile`, etc. via its
default overlay). Downstream flakes that consume this repo should
`inputs.bats.inputs.nixpkgs.follows = "nixpkgs"` to keep the closure
small.

### Fence is the sole sandbox backend

Earlier revisions of this wrapper accepted an optional `sandcastle`
derivation to enable a sandcastle-wrapped `bats`. That parameter is
gone — the wrapper now always uses fence for sandboxing. Known fence
gaps relative to sandcastle:

- `network.allowLocalBinding: false` is recognized in fence's config
  schema but not seccomp-enforced today (fence's filter blocks
  dangerous syscalls + TIOCSTI but not `bind()`). The matching
  bats wrapper tests were removed pending
  https://github.com/amarbel-llc/bats/issues/3.
- No equivalent of sandcastle's `allowAllUnixSockets` toggle. The
  wrapper still parses `--allow-unix-sockets` for CLI compat but it
  is a no-op.

`--query-sandbox` returns `fence` when the wrapper is invoked normally
and `none` is intended for the unset case (consumers calling
`bats_wrapper_sandbox_mode` from `common.bash` without a wrapper).

### Code style

- Nix: `nixfmt-rfc-style`
- Shell: `set -euo pipefail`, 2-space indent, `shfmt -s -ci -i=2`
- Tests: BATS for the batman tests; TAP-14 output where reasonable.

### Git

GPG signing is required for commits. If signing fails, ask the user to
unlock their agent rather than skipping signatures.
