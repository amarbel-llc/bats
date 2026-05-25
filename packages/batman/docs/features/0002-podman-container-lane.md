# podman-container-lane

## Motivation

batman ships two test runners today:

- `test-batman-self-proof` — bats inside the nix builder, via the
  `batsLane` build-support function.
- `test-batman-fence` — bats in the dev shell with fence as the
  per-test sandbox.

Each has gaps:

- **batsLane** is hermetic but inherits the nix builder's
  constraints: no `/usr/bin`, `/tmp` doesn't persist past the build,
  and `podman`/`docker`/anything that needs privileged ops can't run
  inside it. Some real-world test fixtures (`#!/usr/bin/env bash`
  shebangs, tools that read `/etc/passwd`, etc.) need a more
  typical Linux userland.
- **fence** does kernel-level syscall filtering, but its
  `network.allowedDomains: []` and `network.allowLocalBinding: false`
  fields are *not* seccomp-enforced today (see bats#3). It also
  hits a nested-bwrap problem when invoked from inside the dev
  shell's own bwrap (see bob#113), which is why the
  fence-spawning tests in `batman.bats` are `skip`'d there.

A podman-based "container lane" addresses both:

- **Kernel-enforced netns** via `--network none`/`--network <name>`,
  which actually denies outbound connections at the kernel level (not
  just by config).
- **Full controllable rootfs** — the container image is the
  filesystem, including `/usr/bin`, `/etc`, and anything else a
  test fixture expects to find.
- **Reproducibility per-image** — `dockerTools.buildLayeredImage`
  produces a content-addressed OCI image from nix-store contents.
- **Cross-platform** via `podman machine` on Darwin.

What it doesn't give:

- **Hermeticity in the `nix flake check` sense.** `podman run` cannot
  live inside a `runCommand` derivation: the nix builder is itself
  a namespace and refuses the privileged operations podman needs
  (rootless or not). So the container lane is *not* a flake check.
  It is a justfile/script invocation that *uses* a nix-built image.

## Scope

### In

- A flake package `bats-lane-container-image`: a nix-built OCI image
  containing plain bats, bats-libs, the batman orchestrator, git,
  gnugrep, and basic shell utilities. **Fence is intentionally NOT
  in the image** — the container is THE sandbox, see "No fence
  inside" below. The bats source tree is **not** baked in — it is
  bind-mounted at runtime.
- A standalone runner `bats-lane-container` (`nix run`-able generic
  entry point) that handles `podman load` + `podman run`, including
  Darwin bootstrap via `podman machine`. Accepts a path to a bats
  source tree to mount, plus optional test-file positional
  arguments.
- A separate `batman-container-self-proof` (script + flake package +
  justfile recipe `test-batman-container-self-proof`) that invokes
  the runner against `packages/batman/zz-tests_bats` running
  `batman.bats` and `island.bats` only (mirroring
  `test-batman-fence`'s posture; `bats_wrapper.bats` is skipped
  because it requires the fence-wrapped `BATS_WRAPPER`).
- A justfile recipe `run-bats-container` that thin-wraps the
  generic runner for ad-hoc invocations.
- A manpage section (in `bats-lane(7)`, or a new
  `bats-lane-container(7)`) covering the new lane.

### Out

- **Replacing fence with podman as the inner sandbox** (per-test).
  That is a larger change that touches the wrapper, the fence-config
  translation, and the test fixtures' sandbox-assertion contract. It
  also has its own design tensions (per-test container-start
  overhead, signal handling, log multiplexing). Deferred to a future
  FDR.
- **Pushing images to a registry.** The image stays nix-built and
  local; no remote infra introduced.
- **Multi-arch images.** Linux/x86_64 only for v0.
- **Adding the container lane to the `test-batman` aggregate.** Stays
  opt-in until podman setup proves reliable across consumer
  machines; it requires podman on the host (or `podman machine` on
  Darwin), which is not a flake input.
- **Caching the test *run*** (only the image is cached, by nix).

## Design

### Image

`bats-lane-container-image` is a layered OCI image built by
`dockerTools.buildLayeredImage`. The bats *source* is **not** in the
image — only the runtime tools and binaries. The image's tag is
content-derived (no explicit `tag` argument; dockerTools fills in
the hash), which lets the runner skip the (slow) podman load when
the same closure is already loaded.

```nix
image = pkgs.dockerTools.buildLayeredImage {
  name = "amarbel-llc-bats-lane";
  contents = [
    pkgs.bash
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.git
    pkgs.parallel
    pkgs.bats
    batmanPkgs.bats-libs
    batmanPkgs.batman
  ];
  config = {
    Env = [
      "BATS_LIB_PATH=${batmanPkgs.bats-libs.batsLibPath}"
      "BATMAN_BIN=${batmanPkgs.batman}/bin/batman"
      "PATH=/bin:/usr/bin"
    ];
    WorkingDir = "/tests";
  };
};
```

#### Why mount, not bake

The bats source tree is bind-mounted at runtime (`--volume
$source:/tests:ro`) rather than copied into the image at build time.
This trades a small amount of hermeticity for substantially faster
iteration: editing a `.bats` file does not invalidate the image
layer, and downstream consumers can point the runner at their own
test trees without rebuilding the image. Reproducibility for *what
ran* still flows from the image's content hash plus the source's
git commit — both of which a CI invocation already records.

#### No fence inside

The image does **not** include `pkgs.fence` and does **not** use
the fence-wrapped `batmanPkgs.default`. The container is the
sandbox; per-test fence inside the container would be redundant
*and* doesn't work — fence's `bwrap` collides with rootless
podman's user namespace, producing `bwrap: Creating new namespace
failed: Operation not permitted`. The same nested-bwrap family as
bob#113, just with rootless podman playing the outer-bwrap role.

Side benefit: dropping the fence-wrapped bats and its python3 /
tap-dancer-go runtimeInputs cut the image from ~2.2 GB to ~564 MB.

This decision intentionally narrows the scope of what the container
lane can prove vs. the nix-sandbox self-proof (which still runs the
fence-wrapped wrapper and exercises the full 26-test suite). See
"Scope" above for what runs and "Verification" below for what's
proven.

#### `BATS_WRAPPER` is not set

Without fence, there's no wrapper to point at, and
`require_bin BATS_WRAPPER` (in `bats_wrapper.bats`'s setup) would
fail. So the self-proof excludes that file, mirroring how
`test-batman-fence` also runs only `batman.bats`.

`BATMAN_BIN` is still set (to the zx orchestrator) because
`batman.bats` invokes it directly via `--dry-run` and doesn't need
fence to be present.

### Runner script

`bats-lane-container` is the generic, `nix run`-able entry point.
It bootstraps `podman machine` on Darwin, conditionally loads the
nix-built image (skipping the slow load when the same
content-tagged image is already in podman's store), mounts the
caller-supplied bats source tree at `/tests:ro`, and runs `bats`
inside the container with `CWD=/tests` so file paths in the suite
resolve cleanly. Sketch:

```bash
# Usage: bats-lane-container <bats-source-dir> [test-file ...]
bats_src="$1"; shift
bats_src="$(realpath "$bats_src")"

bats_glob="$*"
[ -z "$bats_glob" ] && bats_glob="*.bats"

case "$(uname -s)" in
  Linux) ;;
  Darwin)
    podman machine inspect default >/dev/null 2>&1 || podman machine init
    podman machine start >/dev/null 2>&1 || true
    ;;
esac

# Skip the slow load (~minutes on a 500+ MB tarball) when the
# content-tagged image is already loaded.
if ! podman image exists "${imageRef}" 2>/dev/null; then
  podman load -i "${imagePath}" >/dev/null
fi

exec podman run \
  --rm \
  --network none \
  --tmpfs /tmp \
  --volume "$bats_src:/tests:ro" \
  "${imageRef}" \
  bash -c "cd /tests && bats $bats_glob"
```

### batman-container-self-proof

A separate `writeShellApplication` that pins `bats-lane-container`
to batman's own test tree and explicitly enumerates the test files
that don't depend on the fence wrapper. Conceptually:

```bash
exec bats-lane-container ${batmanTestsSrc} batman.bats island.bats
```

`bats_wrapper.bats` is intentionally excluded — without
`BATS_WRAPPER` (which we don't set, since fence is not in the
image), its `require_bin BATS_WRAPPER` setup would fail. This
mirrors `test-batman-fence`'s posture.

Exposed as:

- `packages.${system}.batman-container-self-proof` — the script
  derivation.
- `apps.${system}.batman-container-self-proof` — `nix run`-able.
- `justfile`: `test-batman-container-self-proof: nix run
  .#batman-container-self-proof`.

This is the container-lane analogue of
`checks.${system}.batman-self-proof`. It cannot itself be a flake
check (podman cannot run in a builder), but it is the canonical
"does this lane still work against batman's own tests?" invocation.

### Justfile recipes

```just
# Generic ad-hoc invocation against an arbitrary bats source tree.
run-bats-container *args:
    nix run .#bats-lane-container -- ./packages/batman/zz-tests_bats {{args}}

# Container-lane self-proof: batman's own tests via the new lane.
test-batman-container-self-proof:
    nix run .#batman-container-self-proof
```

The container-lane self-proof is **not** wired into the `test-batman`
aggregate in v0 (same reason fence-vs-container lanes stay separate
until podman setup proves portable across consumer machines).

## Trade-offs

| Aspect | batsLane (nix sandbox) | run-bats-container (podman) |
|---|---|---|
| Hermeticity | Per-closure, perfect | Image-hashed; run not cached |
| `nix flake check`? | Yes | No (podman cannot run in builder) |
| Outer sandbox | Nix builder namespace | Podman/runc namespace |
| Network enforcement | Builder denies by default | Configurable via `--network` (kernel-enforced) |
| Rootfs | `/nix/store` + scratch | Image-defined; closer to typical distros |
| Linux | Works | Works |
| Darwin | Works | Works via `podman machine` (VM overhead) |
| Setup cost on consumer machine | None beyond nix | Requires podman; on Darwin requires `podman machine` |

## Alternatives considered

- **Replace fence with podman as the *inner* per-test sandbox.** Larger
  change: wrapper, fence-config translation, fixture contract. Has
  its own design tensions (per-test container-start overhead, signal
  handling, log multiplexing). **Deferred to a future FDR.**
- **Use bwrap directly instead of fence.** Doesn't solve bob#113
  (still nested-bwrap risk). Doesn't add netns enforcement. No
  improvement over today.
- **Use Firecracker microVM.** Strictly heavier-weight. Useful only
  if we ever need full kernel isolation; the current pain points
  (nested-bwrap, unenforced network policy) don't justify a microVM.
- **Use `systemd-nspawn`.** Linux-only, no Darwin story.
- **Skip the new lane and just fix fence.** Possible but unbounded —
  would mean tracking bwrap/nix-develop-bwrap upstream interactions
  forever.

## Prior art consulted

- `amarbel-llc/clown:docs/adrs/0005-nix-builder-as-sandbox.md` —
  clown's sibling-ecosystem decision to use nix-builder as the
  primary confinement, with a loopback egress broker for network
  policy. Notably, clown surveyed sandcastle, direct-bwrap,
  nix-builder, and Firecracker but *not* podman; this FDR fills
  that gap for the bats domain.
- `amarbel-llc/clown:zz-pocs/0001` — empirical probes behind that
  ADR. Useful as a reference for what nix-builder actually enforces.

## Verification

`batman-container-self-proof` is the primary regression. It runs
`batman.bats` and `island.bats` inside the container and asserts
that bats exits 0 (every assertion passes, every `skip` is
acknowledged).

Empirical baseline at landing time: **16/16 tests pass** (13 active
+ 3 self-skipped). The skips are the three fence-spawning tests in
`batman.bats` that the suite itself marks with `# skip` for bob#113;
they remain skipped here because fence isn't in the container at all.

One-shot acceptance checks, run once at implementation time and
**confirmed**:

- `--network none` actually denies outbound connections. `bash -c
  'echo > /dev/tcp/93.184.216.34/443'` inside the container returns
  `Network is unreachable`. Kernel-enforced, not config-only.
- The mounted source is read-only. `touch /tests/probe` returns
  `Read-only file system`.
- The rootfs is the image's. `/home` is absent, `/etc/passwd` is
  absent, and `command -v bats` resolves to a `/nix/store/...` path
  from the image. None of the host's userland is visible.

These are not part of the recurring proof — they verify *that the
sandbox primitive is what we claimed*, which only changes if the
runner's `podman run` flags change.

## Follow-ups (not in scope here)

- **Inner-sandbox swap (FDR-0003 candidate).** Replace fence with
  podman as the per-test isolation primitive. This is the larger
  change deferred from this FDR.
- **Shrink the image further.** It's ~564 MB after the
  no-fence/no-wrapper decision (down from ~2.2 GB with them).
  Batman's zx orchestrator still pulls node + fence transitively
  via its `runtimeInputs`; that's the next factor to attack if we
  ever care to slim further.
- **Re-evaluate the bob#113 `skip`s.** The suite's own `skip` lines
  are conservative — under a clean container with no fence at all,
  those tests can't possibly spawn fence and so the original
  failure mode doesn't apply. But the tests *do* try to invoke
  fence, so without it they'd fail rather than skip-cleanly. Lifting
  the skips requires teaching the suite that "fence absent =
  acceptable" (e.g., a new `skip_unless_fence` helper). Worth a
  separate change.
- **Pushing the image to a registry / multi-arch builds.** Only
  worth doing if external CI consumers ask for it.

## References

- bats#3 — fence `network.allowLocalBinding`/`allowedDomains` not
  seccomp-enforced.
- bob#113 — nested-bwrap when fence runs inside a dev-shell-bwrapped
  bats.
- `bats-testing(7)`, `bats-lane(7)` — neighboring manpages this lane
  cross-references.
- `amarbel-llc/clown` ADR-0005 — sandbox-layer survey from a sibling
  project.
