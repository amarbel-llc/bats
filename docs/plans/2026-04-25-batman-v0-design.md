# Batman v0 — fence-based BATS wrapper

## Problem

Batman currently ships a single shell-built `bats` wrapper
(`lib/packages/batman.nix:134-283`) that wraps every BATS run in **one**
`sandcastle` invocation against an inline-generated config. The config is the
same for every test directory, the network allow-list is empty, and there is
no path for tests in different directories to express different sandbox
needs.

We want a second wrapper that uses **fence** instead of sandcastle and reads
its policy from `fence.jsonc` files committed alongside the `*.bats` files.
This is exploratory — v0 ships next to the existing wrapper, not as a
replacement.

## Approach

A new executable `batman` written as a single zx TypeScript file packaged via
`buildZxScriptFromFile` from `amarbel-llc/nixpkgs`. Fence is a Nix-derivation
burn-in (`wrapProgram` with absolute store path), so "fence not on PATH" is
structurally impossible.

Each call:

1. Walks positional args (dirs recurse, files taken as-is) to discover every
   `*.bats` file.
2. Groups discovered files by their **immediate parent directory**.
3. For each group, requires `<dir>/fence.jsonc` to exist; if missing, exits
   non-zero before running any test.
4. For each group, spawns
   `fence --settings <dir>/fence.jsonc -- bats [bats-flags] <files>`.
5. Streams each child's TAP output to stdout **verbatim** (no aggregation,
   no renumbering, no `tap-dancer reformat`).
6. Exits `0` iff every group exited `0`; otherwise `1`.

Cross-directory config sharing is the test author's job to express via
`"extends": "../fence.jsonc"` in the leaf file. Fence supports this natively
via its `extends:` field; batman never walks ancestors itself.

The current `bats` wrapper stays in place. Both binaries ship side-by-side
in the same `symlinkJoin`. Rollback is `nix run .#bats` instead of
`nix run .#batman`.

## CLI

```
batman [batman-flags] <path>... [-- <bats-flags>...]
```

Batman flags carried over from the existing wrapper:

- `--bin-dir <path>` — repeatable, prepend to `PATH`.
- `--no-tempdir-cleanup` — passed through to `bats`.
- `--hide-passing` — TAP filter (same awk as today).

Flags **dropped**:

- `--no-sandbox` — fence is mandatory under `batman`. Use the existing
  `bats` wrapper for unsandboxed runs.
- `--allow-unix-sockets`, `--allow-local-binding` — these are
  `fence.jsonc` concerns now.

## Errors and logging

Hard errors (exit `2` before running any test):

- A discovered directory contains `*.bats` but no `fence.jsonc`.
- A path arg doesn't exist.

Per-group errors (continue, exit `1` at the end):

- `fence` returns a sandbox-violation exit code.
- `bats` returns non-zero.

Wrapper diagnostics (the wrapper's own messages, including the "missing
`fence.jsonc`" path) are appended to
`${XDG_LOG_HOME:-$HOME/.local/log}/batman/batman.log` per the
`xdg_log_home(7)` spec. The parent directory is created on first write.
Nothing wrapper-internal goes to stderr — stdout is already the verbatim
TAP, and stderr is reserved for what `fence`/`bats` write themselves.

## Files changed

- `packages/batman/src/batman.ts` — new zx script, `///!dep` directives for
  zx and any small helpers.
- `lib/packages/batman.nix` — new derivation built via
  `buildZxScriptFromFile`, joined into the existing `symlinkJoin`. Adds
  `fence` to runtime inputs.
- `flake.nix` — wire `amarbel-llc/nixpkgs` exposing
  `buildZxScriptFromFile` if not already available; pass through to
  `batman.nix`.

## Tests

A new BATS test suite under `packages/batman/zz-tests_bats/` verifies the
wrapper. **These tests run under plain `bats` (or the existing `bats`
wrapper), not under `batman`** — the bootstrap loop would be
nonsensical. The test harness uses `require_bin BATMAN_BIN batman` to
inject the binary under test.

Fixture tree under `packages/batman/zz-tests_bats/fixtures/`:

```
fence-fixtures/
  network-allowed/
    fence.jsonc          # network.allowedDomains: ["example.com"]
    network.bats         # asserts curl example.com works
  network-blocked/
    fence.jsonc          # empty allowlist
    no-network.bats      # asserts curl fails
  no-fence-config/       # *no* fence.jsonc
    bare.bats
```

Test cases:

- `batman_runs_one_fence_per_dir` — invoke against a multi-dir fixture,
  assert each dir's `fence.jsonc` was used for that dir's tests.
- `batman_hard_errors_on_missing_fence_jsonc` — point at
  `no-fence-config/`, assert non-zero exit and a log entry under
  `$XDG_LOG_HOME/batman/batman.log`.
- `batman_streams_tap_verbatim` — assert each child's full TAP document
  (header + plan + lines) appears in stdout unchanged.
- `batman_exit_code_aggregates` — one passing dir + one failing dir →
  exit `1`.
- `batman_argv_split_at_double_dash` — `batman --bin-dir build/ tests/ --
  --filter foo` correctly splits.

Skipped for v0:

- Parallel-safety (groups run sequentially).
- TAP output assertions beyond verbatim passthrough.
- macOS — Linux only for v0.

## Rollback

No replacement, no migration. Side-by-side coexistence with the existing
`bats` wrapper. To revert: stop invoking `batman`. To remove entirely:
delete `packages/batman/src/` and the new derivation block in
`lib/packages/batman.nix`.

## Open follow-ups (out of scope for v0)

- Survey `justfile` recipes across `amarbel-llc` repos to learn how tests
  are actually grouped today; informs whether per-dir grouping is the
  right granularity or whether per-file is wanted.
- TAP aggregation (renumber + concat or per-dir subtests) once verbatim
  passthrough proves to be inadequate.
- Parallel-by-directory execution.
- Go rewrite if zx prototype proves the design.
