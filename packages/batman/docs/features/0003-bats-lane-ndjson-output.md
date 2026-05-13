# bats-lane-ndjson-output

**Status:** experimental — working in this repo, validated by one
agent-driven ergonomics probe; not yet consumed by any downstream
flake.

## Motivation

Agents driving batman test lanes (CI workloops, `nix build`-from-LLM
workflows) end up parsing TAP-14 to identify failures. TAP is a
line-oriented streaming format with YAML diagnostic blocks, subtests,
bailouts, and skip/todo directives; "find the failing test and its
diagnostic" is a small parser, not a one-liner. The result is that
each agent-side caller ends up reinventing the same partial TAP
parser, and the field they actually care about
(`diagnostic.message`) is gated behind that work.

`amarbel-llc/tap` RFC 0001 ("TAP Test-Result NDJSON Schema")
specifies a record-per-test newline-delimited JSON encoding of a TAP
run, and `tap-dancer format-ndjson` implements the conversion. This
FDR documents how `batsLane` integrates that conversion as an
opt-in lane output, so any flake consuming `batsLane` can flip a
single argument and get structured failure records alongside the
existing TAP stream.

## Scope

### In

- A new `emitNdjson` argument on `batsLane`. Default `false` —
  existing callers are unaffected.
- A new top-level `tap-dancer-go` argument on the
  `nix/packages/bats-lane.nix` import (already plumbed by this
  repo's `flake.nix`), plus a per-call `tapDancerGo` override.
- When `emitNdjson = true`: a three-stage pipeline that captures
  bats output, normalizes it to TAP-14, and converts to NDJSON. The
  derivation's `$out` becomes a directory carrying `run.raw.tap`,
  `run.tap`, `run.ndjson`, and `exit_code`.
- An ergonomics affordance: the build script echoes the NDJSON to
  stderr between sentinel markers
  (*>>> BATSLANE NDJSON BEGIN <<<* / *>>> BATSLANE NDJSON END <<<*),
  so nix's default failure log tail surfaces the captured records
  without `--keep-failed` or any sidecar tooling.
- A demonstration package `batman-ndjson-demo` (one passing + one
  failing bats case) and a debug-group justfile recipe
  `test-batman-ndjson-demo` that extracts the NDJSON block from a
  build run.

### Out

- **Soft-lane mode** (`failOnTestFailure = false`) that always
  produces `$out` regardless of test outcome. The strict gating
  semantics that match the existing `batsLane` contract are
  preserved. Considered a future iteration if `--keep-failed`
  ergonomics or the stderr-marker affordance prove inadequate.
- **Multi-output derivation** (`outputs = ["out" "ndjson"]`) so
  the NDJSON survives even when the gating exit fails. Deferred for
  the same reason.
- **A `nix run`-able runner** that always prints just the NDJSON to
  stdout. Today the stderr-marker pattern + `sed` between markers
  is sufficient.
- **Pinning to a stable schema.** RFC 0001 is currently `proposed`
  in upstream tap. The lane consumes whatever shape the pinned
  `tap-dancer-go` rev emits.
- **Recording NDJSON on success.** A successful build produces
  `$out/run.ndjson` like any other run, but consumers haven't yet
  asked for a "passes too" stream and the existing `nix build -L`
  is enough for that case.

## Interface

```nix
batsLane {
  base = mytool;
  binaryName = "mytool";
  batsSrc = ./zz-tests_bats;
  batsLibPath = [ batmanPkgs.bats-libs.batsLibPath ];

  emitNdjson = true;          # NEW — default false
  # tapDancerGo = ...;         # optional per-call override
}
```

When `emitNdjson = false` (default), `$out` is the existing
stamp-file (empty regular file). All current call sites are
unchanged.

When `emitNdjson = true`:

- `tap-dancer-go` is required, either as the top-level arg of the
  imported `bats-lane.nix` (the default plumbed by this repo's
  `flake.nix`) or as a per-call `tapDancerGo` override.
- `$out` is a directory:
  - `run.raw.tap` — bats's raw TAP-13 output.
  - `run.tap` — TAP-14 (with `TAP version 14` header) via
    `tap-dancer reformat`.
  - `run.ndjson` — one JSON record per top-level test plus a
    trailing summary record, per amarbel-llc/tap RFC 0001.
  - `exit_code` — bats's exit status as a one-line decimal.
- The derivation succeeds iff bats succeeds. On failure the
  directory is discarded by nix (preserved with
  `nix build --keep-failed` at its store path).
- The NDJSON is echoed to stderr inside the build between
  `>>> BATSLANE NDJSON BEGIN <<<` and `>>> BATSLANE NDJSON END <<<`
  markers, so it shows up in nix's default failure log tail.
- `bats --formatter tap13` is selected automatically unless the
  caller passes their own formatter flag via `extraBatsArgs`.

## Examples

### Building a lane and reading the NDJSON after a failure

```sh
$ nix build .#batman-ndjson-demo
...
batman-ndjson-demo> >>> BATSLANE NDJSON BEGIN <<<
batman-ndjson-demo> {"type":"test","n":1,"description":"ndjson_demo_passes","ok":true,...}
batman-ndjson-demo> {"type":"test","n":2,"description":"ndjson_demo_fails_with_diagnostic","ok":false,"diagnostic":{"message":"(in test file ndjson_failure_demo.bats, line 18)\n  `false' failed\n"},...}
batman-ndjson-demo> {"type":"summary","passed":1,"failed":1,...,"valid":true}
batman-ndjson-demo> >>> BATSLANE NDJSON END <<<
error: builder failed
```

The "Last 5 log lines" block nix prints automatically already
contains the structured failure record.

### Extracting just the NDJSON

```sh
$ nix log .#batman-ndjson-demo \
    | sed -n '/BATSLANE NDJSON BEGIN/,/BATSLANE NDJSON END/p' \
    | sed '1d;$d' \
    | jq 'select(.type == "test" and .ok == false)'
{"type":"test","n":2,"description":"ndjson_demo_fails_with_diagnostic","ok":false,...}
```

### Inspecting the on-disk artifacts after `--keep-failed`

```sh
$ nix build .#batman-ndjson-demo --keep-failed
$ ls /nix/store/<hash>-batman-ndjson-demo/
exit_code  run.ndjson  run.raw.tap  run.tap
$ cat /nix/store/<hash>-batman-ndjson-demo/exit_code
1
```

## Design

The pipeline is three stages chained through the build script in
`nix/packages/bats-lane.nix`:

```
bats --formatter tap13 ...  →  $out/run.raw.tap     (TAP-13 + YAML diagnostics)
tap-dancer reformat         →  $out/run.tap         (TAP-14 with version header)
tap-dancer format-ndjson    →  $out/run.ndjson      (per-test NDJSON records)
```

`tap13` is the bats-core formatter that emits YAML diagnostic
blocks on failure — those YAML blocks are what
`tap-dancer format-ndjson` lifts into each record's `diagnostic`
field. The intermediate `tap-dancer reformat` step is necessary
because RFC 0001 requires a TAP-14 stream and bats-core's `tap13`
omits the version header.

`errexit` is disabled around the bats call so a failed run still
flows through the reformat + ndjson conversion before the script
exits with bats's status. The reformat/format-ndjson exits are
intentionally swallowed (`|| true`, `|| cp` fallback) so a
tap-dancer hiccup doesn't mask the bats outcome. (See
*Limitations* — this is a known prototype-stage trade-off.)

## Trade-offs

- The stderr-marker affordance + `nix log` give a path that does
  not require `--keep-failed`. The kept-failed path remains useful
  when callers want the original files (e.g. `run.raw.tap` to
  compare against `run.tap`).
- Strict gating preserves the existing `batsLane` contract so
  `batman-self-proof` and similar checks behave identically.
  Soft-lane mode is a future iteration if the strict path proves
  too restrictive.
- The pipeline adds two subprocesses (`reformat`, `format-ndjson`)
  per lane. For typical batman suites this is negligible; tiny
  suites pay a small fixed cost.

## Limitations

- **Schema is not yet pinned.** RFC 0001 is `proposed` upstream,
  not `accepted`. A future tap-dancer-go bump could change the
  record shape. Consumers that depend on specific fields should
  pin to a tested rev of `amarbel-llc/tap`.
- **No NDJSON-shape regression.** The flake has no check that
  validates record structure end-to-end. If upstream's
  `format-ndjson` changes shape or starts emitting invalid JSON,
  the only signal is a downstream parsing failure.
- **Silent fallbacks in the pipeline.** `tap-dancer reformat` and
  `format-ndjson` failures are swallowed by `|| true` / `|| cp`.
  An upstream regression that breaks one of these silently degrades
  to "no NDJSON, no marker block" rather than failing loud. Worth
  hardening before promotion to `accepted`.
- **Formatter-flag detection is naive.** The check for a
  caller-supplied formatter compares `extraBatsArgs` entries to a
  fixed set (`--tap`, `-t`, `--formatter`, `-F`, `--output`).
  Equals-form (`--formatter=tap13`), short-attached (`-Ftap13`),
  and post-`--` separator entries are not detected.
- **NDJSON `output` field is unexercised.** The demo's failing
  case is `false` with no captured stdout, so the `output` field
  is always null in the prototype's records. Behavior with
  `run`-captured multi-line output, bats-assert diff failures,
  skip/todo directives, and bailouts has not been verified.
- **Recursive flake-input chain.** The bumped `tap` input pulls
  `amarbel-llc/bats` in transitively. Not currently observed to
  cause issues, but the closure is non-trivial.
- **No downstream consumer yet.** The feature is `experimental`
  until at least one consuming flake (e.g. `amarbel-llc/bob`,
  `amarbel-llc/dodder`) consumes the new arg in earnest.

## Verification

The prototype was validated by spawning a general-purpose subagent
with no NDJSON-pipeline context and asking it to diagnose why
`nix build .#batman-ndjson-demo` fails. With a single tool call
(no source reading, no `--keep-failed`), the agent identified the
failing test name, the file + line, and the exact bats error
message — all pulled from the NDJSON `diagnostic.message` field
visible in nix's default failure log tail.

This is one-shot evidence of the ergonomics goal, not a
proof. Promotion criteria below define what would constitute
recurring evidence.

## Follow-ups (not in scope here)

- **Promote RFC 0001 to `accepted` upstream** in
  `amarbel-llc/tap`, then pin this lane to a tap rev that matches
  the accepted schema. Required for `experimental → testing`.
- **Add a flake check** that builds `batman-ndjson-demo` (expecting
  failure), extracts the NDJSON via the markers, and
  `jq`-asserts on record fields.
- **Replace the `|| true` / `|| cp` fallbacks** with explicit
  error records or hard fails. The current swallow-and-continue
  posture made sense in the prototype to avoid masking bats
  outcomes; once the schema is stable, tap-dancer breakage should
  be loud.
- **Broaden test coverage** to exercise `output` capture,
  bats-assert diff output, skip/todo directives, and bailouts.
- **Tighten formatter-flag detection** or change strategy entirely
  (e.g. always run with `--formatter tap13` when `emitNdjson`,
  raise an error if the caller passes a conflicting formatter).
- **Soft-lane variant.** If consumers find `--keep-failed` and the
  stderr-marker pattern insufficient, add `failOnTestFailure =
  false` so `$out` is always preserved.
- **Multi-output derivation.** Same trigger; cleaner than the soft
  lane because `outputs = ["out" "ndjson"]` would keep the gating
  contract intact while exposing the NDJSON via `result-ndjson`.
- **`nix run` runner** that builds the lane and prints NDJSON to
  stdout regardless of pass/fail. Only worth doing if the marker
  + `sed` pattern proves too clumsy in practice.

## Promotion criteria

For `experimental → testing`:

- Tap RFC 0001 reaches `accepted` upstream, OR the tap input is
  pinned to a rev that has passed local schema regression checks.
- A flake check (per *Follow-ups*) validates NDJSON shape on every
  CI run.
- At least one downstream consumer (bob, dodder, …) enables
  `emitNdjson = true` for its own lane and uses the resulting
  records in its workloops.
- The known unexercised record shapes (`output`, `directive`,
  `subtest`, `bailed`) have been observed in real runs and
  documented.

For `testing → accepted`:

- The above conditions have held for two or more consuming flakes
  over at least one upstream schema change.

## References

- *bats-lane*(7) "NDJSON OUTPUT (EXPERIMENTAL)" section — operator
  reference.
- `amarbel-llc/tap` `docs/rfcs/0001-test-result-ndjson-schema.md` —
  the NDJSON wire format (status: `proposed`).
- `amarbel-llc/tap` `docs/plans/2026-05-12-tap-format-ndjson-design.md` —
  design of the `tap-dancer format-ndjson` subcommand.
- `nix/packages/bats-lane.nix` — the build-support function.
- `packages/batman/zz-tests_bats/ndjson_failure_demo.bats` — the
  artificial-failure demo suite.
- FDR-0002 (`packages/batman/docs/features/0002-podman-container-lane.md`) —
  the sibling lane this feature extends conceptually.
