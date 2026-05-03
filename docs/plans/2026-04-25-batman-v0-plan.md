# Batman v0 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development to implement this plan
> task-by-task.

**Goal:** Ship a new `batman` executable next to the existing `bats`
shell wrapper that runs `*.bats` files under `fence` instead of
`sandcastle`, enforcing one `fence.jsonc` per directory.

**Architecture:** A single zx TypeScript file (`packages/batman/src/batman.ts`)
packaged via `buildZxScriptFromFile` from `amarbel-llc/nixpkgs`. The
script discovers `*.bats` recursively, groups by parent directory,
hard-errors if any group lacks `fence.jsonc`, and spawns one
`fence --settings <dir>/fence.jsonc -- bats <files>` per group.
Wrapper diagnostics go to `${XDG_LOG_HOME:-$HOME/.local/log}/batman/batman.log`.
TAP from each child is streamed to stdout verbatim. Fence is a
`wrapProgram`-burned-in absolute store path.

**Tech Stack:** zx 8.8.5, bun runtime, fence (Use-Tusk/fence), bats,
`buildZxScriptFromFile` (`amarbel-llc/nixpkgs`), `cacheEntryCreator`
(`nix-community/bun2nix`).

**Rollback:** Purely additive. `nix run .#bats` (existing wrapper)
continues to work unchanged. To revert: delete
`packages/batman/src/`, the new derivation block in
`lib/packages/batman.nix`, and the two new flake inputs.

---

## Background reading

- `docs/plans/2026-04-25-batman-v0-design.md` --- the design this plan
  implements. Read first.
- `lib/packages/batman.nix:134-283` --- existing `bats` shell wrapper
  for shape reference.
- Use-Tusk/fence `docs/configuration.md` (path `extends:`, nearest-wins
  auto-discovery, slice append+dedupe merge).
- amarbel-llc/nixpkgs `pkgs/build-support/bun2nix/build-zx-script.nix`
  --- documents the four tiers; we use **tier 4** (single file with
  inline `///!dep` directives).

---

### Task 1: Add `amarbel-nixpkgs` and `bun2nix` flake inputs

**Files:** Modify: `flake.nix:4-24`

**Step 1: Add the two new inputs**

After the `nixpkgs-master` line, add:

``` nix
# zx packaging via buildZxScriptFromFile
amarbel-nixpkgs.url = "github:amarbel-llc/nixpkgs";
bun2nix = {
  url = "github:nix-community/bun2nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

**Step 2: Add the two names to the `outputs =` argument list**

Modify `flake.nix:26-36` to include `amarbel-nixpkgs` and `bun2nix`.

**Step 3: Verify the inputs resolve**

Run: `nix flake metadata 2>&1 | grep -E 'amarbel-nixpkgs|bun2nix'`
Expected: two lines listing the new inputs with their resolved revs.

**Step 4: Commit**

    feat(flake): add amarbel-nixpkgs + bun2nix inputs for zx packaging

---

### Task 2: Resolve the SRI hash for zx@8.8.5

**Files:** None yet --- this task produces a value used in Task 3.

**Step 1: Fetch the npm tarball and emit its SRI hash**

Run:

``` bash
nix store prefetch-file \
  --hash-type sha512 \
  --json \
  https://registry.npmjs.org/zx/-/zx-8.8.5.tgz \
  | jq -r .hash
```

Expected: a single line of the form `sha512-<base64>`. Save it for
Task 3.

If `nix store prefetch-file` is unavailable in the dev shell, use:

``` bash
url=https://registry.npmjs.org/zx/-/zx-8.8.5.tgz
hash=$(curl -fsSL "$url" | sha512sum | awk '{print $1}')
nix hash convert --hash-algo sha512 --to sri --from base16 "$hash"
```

Both produce the same `sha512-…` string.

**Step 2: No commit** --- the value is consumed in the next task.

---

### Task 3: Scaffold a stub `batman.ts` that just prints a banner

**Files:** Create: `packages/batman/src/batman.ts`

**Step 1: Write the stub**

Substitute the SRI hash from Task 2 into the `///!dep` directive.

``` ts
#!/usr/bin/env zx
///!dep zx@8.8.5 sha512-<HASH-FROM-TASK-2>

// batman v0 — fence-based BATS wrapper.
// See docs/plans/2026-04-25-batman-v0-design.md.

import { argv } from "zx";

const args = argv._;
console.log(`batman v0 (stub): received ${args.length} positional args`);
process.exit(0);
```

**Step 2: Verify the file is well-formed**

Run: `node --check packages/batman/src/batman.ts || true`
Expected: no syntax errors (TypeScript-specific syntax may warn; that's
fine --- bun handles it at build time).

**Step 3: Commit**

    feat(batman): scaffold zx stub for fence-based BATS wrapper

---

### Task 4: Add a `batman` derivation in `lib/packages/batman.nix`

**Files:** Modify: `lib/packages/batman.nix`

**Step 1: Extend the function signature**

At `lib/packages/batman.nix:1-6`, accept the new inputs:

``` nix
{
  pkgs,
  src,
  sandcastle,
  tap-dancer-cli,
  fence,
  buildZxScriptFromFile,
}:
```

**Step 2: Define the new derivation**

After the `bats = pkgs.writeShellApplication { ... };` block ending at
line 283, add:

``` nix
batman = pkgs.runCommand "batman" {
  src = "${src}/src/batman.ts";
  nativeBuildInputs = [ pkgs.makeWrapper ];
  passthru.unwrapped = buildZxScriptFromFile {
    pname = "batman-unwrapped";
    version = "0.0.1";
    script = "${src}/src/batman.ts";
  };
} ''
  mkdir -p $out/bin
  makeWrapper ${pkgs.writeShellScript "batman-launch" ''
    exec ${"$"}{batmanRaw}/bin/batman "$@"
  ''} $out/bin/batman \
    --prefix PATH : ${pkgs.lib.makeBinPath [ fence pkgs.bats pkgs.coreutils pkgs.gawk ]}
  # buildZxScriptFromFile already produces $out/bin/batman in its own derivation;
  # the wrapper above just adds runtime PATH.
'';
```

(NOTE: this exact wiring is a sketch. Adjust during implementation
based on what `buildZxScriptFromFile` actually produces --- it likely
already wraps the script and may need a different
`wrapProgram`/`makeWrapper` integration. Use
`nix build .#batmanPkgs.unwrapped` first to inspect.)

**Step 3: Add `batman` to the symlinkJoin and `inherit` block**

Modify the `symlinkJoin` at line 287 and the `inherit` block at line
295 to include `batman`.

**Step 4: Pass the new args from flake.nix**

Modify `flake.nix:210-215` to provide `fence` and
`buildZxScriptFromFile`:

``` nix
batmanPkgs = import ./lib/packages/batman.nix {
  inherit pkgs;
  sandcastle = sandcastlePkg;
  tap-dancer-cli = tapDancerPkgs.cli;
  src = ./packages/batman;
  fence = pkgs-master.fence or (throw "fence not available in nixpkgs-master pin");
  buildZxScriptFromFile = (
    import "${amarbel-nixpkgs}/pkgs/build-support/bun2nix" {
      inherit pkgs;
      cacheEntryCreator = bun2nix.packages.${system}.cacheEntryCreator;
    }
  ).buildZxScriptFromFile;
};
```

If `fence` is not in the `nixpkgs-master` pin, build it from
`Use-Tusk/fence` via `buildGoModule` --- see `numtide/nix-ai-tools`
for a packaged reference.

**Step 5: Build the package**

Run: `nix build .#batman`
Expected: build succeeds; `result/bin/batman` and `result/bin/bats`
both exist.

**Step 6: Smoke-test the stub**

Run: `result/bin/batman foo bar`
Expected: prints `batman v0 (stub): received 2 positional args`,
exits 0.

**Step 7: Commit**

    feat(batman): build batman binary via buildZxScriptFromFile

---

### Task 5: Add fixture tree under `packages/batman/zz-tests_bats/fixtures/`

**Files:**
- Create: `packages/batman/zz-tests_bats/fixtures/network-allowed/fence.jsonc`
- Create: `packages/batman/zz-tests_bats/fixtures/network-allowed/network.bats`
- Create: `packages/batman/zz-tests_bats/fixtures/network-blocked/fence.jsonc`
- Create: `packages/batman/zz-tests_bats/fixtures/network-blocked/no-network.bats`
- Create: `packages/batman/zz-tests_bats/fixtures/no-fence-config/bare.bats`

**Step 1: Write the three fence configs**

`network-allowed/fence.jsonc`:

``` jsonc
{
  "network": { "allowedDomains": ["example.com"] },
  "filesystem": { "denyRead": [] }
}
```

`network-blocked/fence.jsonc`:

``` jsonc
{
  "network": { "allowedDomains": [] },
  "filesystem": { "denyRead": [] }
}
```

(`no-fence-config/` has no fence.jsonc on purpose.)

**Step 2: Write the three minimal `*.bats` files**

`network-allowed/network.bats`:

``` bash
#!/usr/bin/env bats

function curl_to_example_com_succeeds { # @test
  run curl -fsSL --max-time 5 https://example.com
  [ "$status" -eq 0 ]
}
```

`network-blocked/no-network.bats`:

``` bash
#!/usr/bin/env bats

function curl_anywhere_fails { # @test
  run curl -fsSL --max-time 5 https://example.com
  [ "$status" -ne 0 ]
}
```

`no-fence-config/bare.bats`:

``` bash
#!/usr/bin/env bats

function placeholder { # @test
  true
}
```

**Step 3: Commit**

    test(batman): add fixture tree for fence-based BATS wrapper tests

---

### Task 6: Scaffold the harness `*.bats` file that drives `batman`

**Files:** Create: `packages/batman/zz-tests_bats/batman.bats`,
`packages/batman/zz-tests_bats/common.bash`

**Step 1: Write `common.bash`**

``` bash
#!/usr/bin/env bash
bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-island
bats_load_library bats-emo

require_bin BATMAN_BIN batman
```

**Step 2: Write `batman.bats` skeleton**

``` bash
#!/usr/bin/env bats

setup() {
  load "$(dirname "$BATS_TEST_FILE")/common.bash"
  setup_test_home
  set_xdg
  FIXTURES="$(dirname "$BATS_TEST_FILE")/fixtures"
}

teardown() {
  teardown_test_home
}

function batman_stub_runs { # @test
  run "$BATMAN_BIN" foo bar
  assert_success
  assert_output --partial "received 2 positional args"
}
```

**Step 3: Run with plain `bats` (NOT the batman wrapper --- bootstrap loop)**

Run:

``` bash
BATMAN_BIN="$(realpath result/bin/batman)" \
  BATS_LIB_PATH="$(realpath result/share/bats)" \
  bats packages/batman/zz-tests_bats/batman.bats
```

Expected: 1 test, PASS (the stub still works).

**Step 4: Commit**

    test(batman): add harness scaffold and stub smoke test

---

### Task 7: TDD --- argv split at `--`

**Files:** Modify: `packages/batman/zz-tests_bats/batman.bats`,
`packages/batman/src/batman.ts`

**Step 1: Add the failing test**

``` bash
function batman_splits_argv_at_double_dash { # @test
  run "$BATMAN_BIN" --bin-dir foo --hide-passing -- --filter bar
  assert_success
  assert_output --partial "batman-args: --bin-dir foo --hide-passing"
  assert_output --partial "bats-args: --filter bar"
}
```

**Step 2: Run, verify it fails**

Run: `bats packages/batman/zz-tests_bats/batman.bats -f
batman_splits_argv_at_double_dash`
Expected: FAIL --- output doesn't contain `batman-args:` line.

**Step 3: Implement argv split in `batman.ts`**

Replace the script body with:

``` ts
#!/usr/bin/env zx
///!dep zx@8.8.5 sha512-<HASH-FROM-TASK-2>

const all = process.argv.slice(2);
const dashIdx = all.indexOf("--");
const ourArgs = dashIdx === -1 ? all : all.slice(0, dashIdx);
const passthrough = dashIdx === -1 ? [] : all.slice(dashIdx + 1);

console.log(`batman-args: ${ourArgs.join(" ")}`);
console.log(`bats-args: ${passthrough.join(" ")}`);
```

**Step 4: Rebuild and run, verify it passes**

Run: `nix build .#batman && bats packages/batman/zz-tests_bats/batman.bats`
Expected: both tests PASS.

**Step 5: Commit**

    feat(batman): implement argv split at `--`

---

### Task 8: TDD --- recursive `*.bats` discovery and grouping

**Files:** Modify: `packages/batman/zz-tests_bats/batman.bats`,
`packages/batman/src/batman.ts`

**Step 1: Add the failing test**

``` bash
function batman_discovers_and_groups_bats_files { # @test
  run "$BATMAN_BIN" --dry-run "$FIXTURES"
  assert_success
  # expect one "GROUP" line per fixture subdir
  assert_output --partial "GROUP $FIXTURES/network-allowed: network.bats"
  assert_output --partial "GROUP $FIXTURES/network-blocked: no-network.bats"
  assert_output --partial "GROUP $FIXTURES/no-fence-config: bare.bats"
}
```

**Step 2: Run, verify it fails**

Run: `bats packages/batman/zz-tests_bats/batman.bats -f
batman_discovers_and_groups`
Expected: FAIL --- `--dry-run` doesn't exist yet.

**Step 3: Implement discovery + grouping**

Replace `batman.ts` with:

``` ts
#!/usr/bin/env zx
///!dep zx@8.8.5 sha512-<HASH-FROM-TASK-2>

import { fs, path } from "zx";

const all = process.argv.slice(2);
const dashIdx = all.indexOf("--");
const ourArgs = dashIdx === -1 ? all : all.slice(0, dashIdx);
const passthrough = dashIdx === -1 ? [] : all.slice(dashIdx + 1);

const dryRun = ourArgs.includes("--dry-run");
const positional = ourArgs.filter(a => !a.startsWith("--"));

async function discover(p: string): Promise<string[]> {
  const stat = await fs.stat(p);
  if (stat.isFile()) return p.endsWith(".bats") ? [p] : [];
  const entries = await fs.readdir(p, { withFileTypes: true });
  const out: string[] = [];
  for (const e of entries) {
    const sub = path.join(p, e.name);
    if (e.isDirectory()) out.push(...await discover(sub));
    else if (e.isFile() && sub.endsWith(".bats")) out.push(sub);
  }
  return out;
}

const all_bats = (await Promise.all(positional.map(discover))).flat();
const groups = new Map<string, string[]>();
for (const f of all_bats) {
  const dir = path.dirname(f);
  if (!groups.has(dir)) groups.set(dir, []);
  groups.get(dir)!.push(path.basename(f));
}

if (dryRun) {
  for (const [dir, files] of groups) {
    console.log(`GROUP ${dir}: ${files.join(", ")}`);
  }
  process.exit(0);
}
```

**Step 4: Rebuild and run, verify it passes**

Run: `nix build .#batman && bats
packages/batman/zz-tests_bats/batman.bats`
Expected: all tests PASS.

**Step 5: Commit**

    feat(batman): recursive bats discovery and per-dir grouping

---

### Task 9: TDD --- hard error on missing fence.jsonc

**Files:** Modify: `packages/batman/zz-tests_bats/batman.bats`,
`packages/batman/src/batman.ts`

**Step 1: Add the failing test**

``` bash
function batman_fails_on_missing_fence_jsonc { # @test
  run "$BATMAN_BIN" "$FIXTURES/no-fence-config"
  assert_failure
  [ "$status" -eq 2 ]
  # diagnostic should land in the log file, not stderr/stdout
  local log="${XDG_LOG_HOME:-$HOME/.local/log}/batman/batman.log"
  run cat "$log"
  assert_output --partial "missing fence.jsonc"
  assert_output --partial "$FIXTURES/no-fence-config"
}
```

**Step 2: Run, verify it fails**

Expected: FAIL --- batman currently exits 0 (only the dry-run path is
implemented).

**Step 3: Implement the hard-error check + log write**

Add to `batman.ts` after the grouping logic, before any spawn:

``` ts
async function logDiagnostic(msg: string): Promise<void> {
  const logHome = process.env.XDG_LOG_HOME
    ?? path.join(process.env.HOME!, ".local/log");
  const dir = path.join(logHome, "batman");
  await fs.mkdir(dir, { recursive: true });
  const ts = new Date().toISOString();
  await fs.appendFile(path.join(dir, "batman.log"), `${ts} ${msg}\n`);
}

if (!dryRun) {
  for (const dir of groups.keys()) {
    const cfg = path.join(dir, "fence.jsonc");
    if (!(await fs.pathExists(cfg))) {
      await logDiagnostic(`missing fence.jsonc: ${dir}`);
      process.exit(2);
    }
  }
}
```

**Step 4: Rebuild and run, verify it passes**

Run: `nix build .#batman && bats packages/batman/zz-tests_bats/batman.bats`
Expected: all tests PASS.

**Step 5: Commit**

    feat(batman): hard-error on missing fence.jsonc, log to XDG_LOG_HOME

---

### Task 10: TDD --- spawn fence + bats per group

**Files:** Modify: `packages/batman/zz-tests_bats/batman.bats`,
`packages/batman/src/batman.ts`

**Step 1: Add the failing tests**

``` bash
function batman_runs_passing_test_under_fence_with_network { # @test
  run "$BATMAN_BIN" "$FIXTURES/network-allowed"
  # network-allowed test calls curl https://example.com
  # we expect it to pass when fence allows that domain
  assert_success
  assert_output --partial "ok 1 curl_to_example_com_succeeds"
}

function batman_blocks_network_when_fence_denies { # @test
  run "$BATMAN_BIN" "$FIXTURES/network-blocked"
  assert_success  # the bats test itself asserts curl fails
  assert_output --partial "ok 1 curl_anywhere_fails"
}

function batman_aggregates_exit_codes { # @test
  # one passing + one failing dir → exit 1 overall
  # easy to construct: re-use network-allowed and a fixture where bats fails
  # (to add: fixtures/always-fails/{fence.jsonc,fail.bats})
  run "$BATMAN_BIN" "$FIXTURES/network-allowed" "$FIXTURES/always-fails"
  assert_failure
  [ "$status" -eq 1 ]
}
```

(Add the `always-fails/` fixture --- one `fence.jsonc` and one
`*.bats` whose only test is `false`. Three new files.)

**Step 2: Run, verify they fail**

Expected: FAIL --- batman currently exits 2 because spawning is not
implemented.

**Step 3: Implement the spawn loop**

Add to `batman.ts`:

``` ts
import { spawn } from "node:child_process";

async function runGroup(dir: string, files: string[]): Promise<number> {
  const cfg = path.join(dir, "fence.jsonc");
  return new Promise((resolve) => {
    const child = spawn("fence", [
      "--settings", cfg, "--",
      "bats", ...passthrough, ...files.map(f => path.join(dir, f)),
    ], { stdio: ["inherit", "inherit", "inherit"] });
    child.on("exit", (code) => resolve(code ?? 1));
  });
}

let aggregate = 0;
for (const [dir, files] of groups) {
  const code = await runGroup(dir, files);
  if (code !== 0) aggregate = 1;
}
process.exit(aggregate);
```

**Step 4: Rebuild and run, verify they pass**

Run: `nix build .#batman && bats packages/batman/zz-tests_bats/batman.bats`
Expected: all tests PASS. (May need to adjust based on what fence
actually does --- if `network-allowed/network.bats` fails because
DNS isn't reachable in the build sandbox, run the BATS suite outside
the Nix sandbox, e.g. directly with `bats` in the dev shell against a
freshly-built `result/bin/batman`.)

**Step 5: Commit**

    feat(batman): spawn fence per group, aggregate exit code

---

### Task 11: Verify diagnostics-only-to-log behaviour

**Files:** Modify: `packages/batman/zz-tests_bats/batman.bats`

**Step 1: Add a stricter test**

``` bash
function batman_does_not_emit_wrapper_diagnostics_to_stderr { # @test
  run --separate-stderr "$BATMAN_BIN" "$FIXTURES/no-fence-config"
  assert_failure
  # stderr should be empty (or only fence/bats output, not our own)
  [ -z "$stderr" ] || ! [[ "$stderr" =~ "missing fence.jsonc" ]]
}
```

**Step 2: Run; if it fails, fix `batman.ts`**

If any wrapper-level `console.error` calls are present, replace them
with `logDiagnostic`.

**Step 3: Commit**

    test(batman): assert wrapper diagnostics go only to log file

---

### Task 12: Add manpage stub

**Files:** Create: `packages/batman/doc/batman.1.scd`,
modify: `lib/packages/batman.nix` (`batman-manpages` derivation)

**Step 1: Write the scd**

``` scd
batman(1)

# NAME

batman - run BATS tests under per-directory fence sandboxes

# SYNOPSIS

*batman* [_flags_] _path_... [-- _bats-flags_...]

# DESCRIPTION

*batman* discovers *.bats files under each _path_ argument, groups
them by parent directory, requires a *fence.jsonc* in each
group's directory, and runs *fence --settings <dir>/fence.jsonc -- bats
<files>* once per group.

If any group's directory has no *fence.jsonc*, batman exits with
status 2 before running any test. Wrapper diagnostics are appended
to *${XDG_LOG_HOME:-$HOME/.local/log}/batman/batman.log*. TAP output
from each child *bats* invocation is streamed to stdout verbatim;
batman does not aggregate or renumber.

# FLAGS

*--bin-dir* _path_
        Repeatable. Prepend _path_ to *PATH*.

*--no-tempdir-cleanup*
        Forwarded to *bats*.

*--hide-passing*
        Filter TAP output to hide passing tests.

*--dry-run*
        Print discovered groups and exit; do not invoke fence or bats.

# SEE ALSO

*bats*(1), *fence*(1), *bats-testing*(7)
```

**Step 2: The existing `batman-manpages` derivation already builds
every `*.scd` in `packages/batman/doc/` --- no change needed.**

**Step 3: Build and verify**

Run: `nix build .#batman && man -l result/share/man/man1/batman.1`
Expected: rendered manpage opens.

**Step 4: Commit**

    docs(batman): add batman(1) manpage stub

---

### Task 13: End-to-end smoke test from a clean tree

**Step 1: Run the full BATS suite for batman**

Run:

``` bash
nix build .#batman
BATMAN_BIN="$(realpath result/bin/batman)" \
  BATS_LIB_PATH="$(realpath result/share/bats)" \
  bats packages/batman/zz-tests_bats/batman.bats
```

Expected: every test PASS.

**Step 2: Run `nix flake check` and `just lint`**

Run: `nix flake check; just lint`
Expected: clean.

**Step 3: Confirm no regression in the existing `bats` wrapper**

Run: `result/bin/bats --no-sandbox -- --version`
Expected: BATS version string. The existing wrapper still works.

**Step 4: Commit any final cleanups**

    chore(batman): finalize v0 fence-based BATS wrapper

---

## Promotion criteria (out of scope for v0)

There is no replacement to promote. v0 ships side-by-side with the
existing `bats` wrapper. A v1 promotion would require:

- 2+ amarbel-llc repos converted to batman + per-dir `fence.jsonc`.
- Survey of justfile recipes confirming per-dir grouping is the right
  granularity.
- A clear migration path for `--allow-unix-sockets` /
  `--allow-local-binding` consumers.

## Known v0 gaps (intentional)

- No TAP aggregation --- multiple groups produce concatenated TAP
  documents.
- Sequential per-group execution --- no parallelism.
- Linux-only test path (fence works on macOS, but our CI doesn't cover
  it).
- No `--no-sandbox` flag (use the existing `bats` wrapper).
