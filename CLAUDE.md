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
as a flake input and call `bats.lib.${system}.mkBats { sandcastle, tap-dancer-go }`
to wire in their own sandbox runner.

## Build & Test

``` sh
# bats-core upstream tests (test/ tree)
just test                  # runs `bats test/` in the dev shell
just check                 # shellcheck on lib/*.bash and libexec/*
just fmt                   # shfmt formatting

# Batman / bats-libs flake outputs
just build-batman          # nix build .#default -o result-batman
just build-bats-libs       # nix build .#bats-libs -o result-bats-libs
just flake-check           # nix flake check (runs check-bats-libs-path)
just test-batman-bats      # batman zz-tests_bats/ via the wrapped bats
just test-batman-fence     # batman.bats under plain nixpkgs bats
just test-batman           # both batman test suites
just run-batman <args>     # smoke-test the built batman binary
just clean                 # rm -rf result result-batman result-bats-libs
```

## Architecture

### Flake outputs

`flake.nix` exposes per-system:

- `lib.${system}.mkBats { sandcastle ? null, tap-dancer-go ? ... }` — function
  that returns the full batman package set. Pass `sandcastle = <derivation>`
  to enable the sandboxed `bats` wrapper. The default (`sandcastle = null`)
  produces a wrapper without the sandcastle code path, suitable for
  consumers that don't run a sandcastle binary.
- `packages.${system}` — `default`, `batman`, `bats`, `bats-libs`, plus the
  six bats helper libs and `batman-manpages` individually.
- `checks.${system}.check-bats-libs-path` — regression test that
  `bats-libs.batsLibPath` is a valid `BATS_LIB_PATH` entry (no trailing
  `/share/bats` required of consumers).
- `devShells.${system}.default` — the bats-core development shell
  (predates the batman additions).

### `nix/packages/batman.nix`

The build expression. Single function taking `pkgs`, `src`, `sandcastle ?
null`, `tap-dancer-go`, `fence`, `buildZxScriptFromFile`. Constructs the
six helper libs, the batman zx script, the bats wrapper, and the
manpages bundle. The bats wrapper is conditionally generated — when
`sandcastle == null`, the `--no-sandbox` / `--allow-unix-sockets` /
`--allow-local-binding` flags and the `if $sandbox` shell branch are
omitted entirely.

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

### Sandcastle is parameterized

This repo intentionally does NOT depend on `sandcastle`. The bats wrapper
is parameterized via `mkBats`. To get bob's historical sandboxed wrapper
behavior, a downstream flake calls `mkBats` with its own sandcastle
derivation.

### Code style

- Nix: `nixfmt-rfc-style`
- Shell: `set -euo pipefail`, 2-space indent, `shfmt -s -i=2`
- Tests: BATS for the batman tests; TAP-14 output where reasonable.

### Git

GPG signing is required for commits. If signing fails, ask the user to
unlock their agent rather than skipping signatures.
