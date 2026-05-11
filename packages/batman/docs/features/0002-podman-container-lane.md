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
  containing bats, bats-libs, batman, and **fence**. The bats source
  tree is **not** baked in — it is bind-mounted at runtime.
- A standalone runner `bats-lane-container` (`nix run`-able generic
  entry point) that handles `podman load` + `podman run`, including
  Darwin bootstrap via `podman machine`. Accepts a path to a bats
  source tree to mount, plus optional `--filter-tags` and other
  passthrough flags.
- A separate `batman-container-self-proof` (script + flake package +
  justfile recipe `test-batman-container-self-proof`) that invokes
  the runner against `packages/batman/zz-tests_bats`, analogous to
  how `checks.${system}.batman-self-proof` exercises batsLane against
  the same suite. This is the container-lane equivalent regression
  of the nix-sandbox self-proof.
- A justfile recipe `test-batman-container` that thin-wraps the
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
image — only the runtime tools and binaries. Sketch:

```nix
batsLaneContainerImage = pkgs.dockerTools.buildLayeredImage {
  name = "amarbel-llc-bats-lane";
  tag = "latest";
  contents = [
    pkgs.bash
    pkgs.coreutils
    pkgs.git
    pkgs.parallel
    pkgs.bats
    pkgs.fence            # included; see "Including fence" below
    batmanPkgs.bats-libs
    batmanPkgs.default
  ];
  config = {
    Env = [
      "BATS_LIB_PATH=${batmanPkgs.bats-libs.batsLibPath}"
      "BATMAN_BIN=${batmanPkgs.default}/bin/batman"
      "BATS_WRAPPER=${batmanPkgs.default}/bin/bats"
      "PATH=/bin:/usr/bin"
    ];
    WorkingDir = "/tests";
  };
};
```

The image carries the same env-var contract batsLane uses (`BATMAN_BIN`,
`BATS_WRAPPER`, `BATS_LIB_PATH`) so the test suite's `require_bin`
calls in `common.bash` succeed identically inside and outside the
container.

#### Why mount, not bake

The bats source tree is bind-mounted at runtime (`--volume
$source:/tests:ro`) rather than copied into the image at build time.
This trades a small amount of hermeticity for substantially faster
iteration: editing a `.bats` file does not invalidate the image
layer, and downstream consumers can point the runner at their own
test trees without rebuilding the image. Reproducibility for *what
ran* still flows from the image's content hash plus the source's
git commit — both of which a CI invocation already records.

#### Including fence

`pkgs.fence` is included in the image so the existing wrapper's
`fence --settings ... -- bats ...` path works without modification
inside the container. Because the container's namespace is now the
*outer* namespace (no dev-shell bwrap above it), the bob#113 nested-
bwrap failure mode that currently forces `skip` on three
`batman.bats` tests does not apply here. Whether those tests
actually pass inside the container is empirical and tracked as a
follow-up (see "Verification" below); the FDR commits to including
fence so the option is open, not to flipping the `skip`s in this
work item.

### Runner script

`bats-lane-container` is the generic, `nix run`-able entry point.
It builds (or reuses) the image, bootstraps `podman machine` on
Darwin, mounts the caller-supplied bats source tree, and invokes
`bats` inside the container. Sketch:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Usage: bats-lane-container <bats-source-dir> [bats-args...]
bats_src="${1:?bats source directory required}"; shift

image_path=$(nix build --no-link --print-out-paths .#bats-lane-container-image)

case "$(uname -s)" in
  Linux) ;;
  Darwin)
    podman machine inspect default >/dev/null 2>&1 || podman machine init
    podman machine start 2>/dev/null || true
    ;;
  *)
    echo "unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac

podman load -i "$image_path"
podman run \
  --rm \
  --network none \
  --volume "$bats_src:/tests:ro" \
  amarbel-llc-bats-lane:latest \
  bats /tests "$@"
```

### batman-container-self-proof

A separate runner that pins `bats-lane-container` to batman's own
test tree (`packages/batman/zz-tests_bats`). Conceptually:

```bash
#!/usr/bin/env bash
exec "$(dirname "$0")/bats-lane-container" \
  "$(nix path:.)/packages/batman/zz-tests_bats" \
  "$@"
```

Exposed as:

- `packages.${system}.batman-container-self-proof` — the script
  derivation.
- `apps.${system}.batman-container-self-proof` — `nix run`-able.
- `justfile`: `test-batman-container-self-proof: nix run
  .#batman-container-self-proof`.

This is the container-lane analogue of
`checks.${system}.batman-self-proof`. It cannot itself be a flake
check (same reason: podman cannot run in a builder), but it is the
canonical "does this lane still work against batman's own tests?"
invocation.

### Justfile recipes

```just
# Generic ad-hoc invocation against an arbitrary bats source tree.
test-batman-container *args:
    nix run .#bats-lane-container -- ./packages/batman/zz-tests_bats {{args}}

# Container-lane self-proof: batman's own tests via the new lane.
test-batman-container-self-proof:
    nix run .#batman-container-self-proof
```

The container-lane self-proof is **not** wired into the `test-batman`
aggregate in v0 (same reason fence-vs-container lanes stay separate
until podman setup proves portable across consumer machines).

## Trade-offs

| Aspect | batsLane (nix sandbox) | test-batman-container (podman) |
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
batman's `zz-tests_bats` suite inside the container and asserts
that bats exits 0 (i.e., every assertion passes, every `skip` is
acknowledged). The criteria mirror `batman-self-proof`:

- All 26 tests in the suite execute to completion.
- The expected `skip`s for bob#113 still skip (until and unless a
  follow-up investigation flips them — see "Follow-ups").
- The container exits cleanly (no leaked podman processes, no
  un-deleted images).

Beyond that, a few host-level checks are worth running once at
implementation time and not making part of the recurring proof:

- Confirm `--network none` actually denies outbound connections
  inside the container (e.g., `curl https://example.com` returns a
  network error, not a 200).
- Confirm the mounted source is read-only (writes from inside the
  container fail with EROFS).
- Confirm the rootfs reflects the image's nix-store contents, not
  the host's.

These are one-shot acceptance checks, not regression tests.

## Follow-ups (not in scope here)

- **Re-evaluate the bob#113 `skip`s under the container lane.**
  Inside the container, fence's bwrap is the only bwrap in the
  stack (no dev-shell bwrap above). The three currently-skipped
  tests in `batman.bats` may pass there. Worth a separate
  investigation; if they do, the skips can be lifted in the
  container-lane self-proof while remaining in the dev-shell lane.
- **Inner-sandbox swap (FDR-0003 candidate).** Replace fence with
  podman as the per-test isolation primitive. This is the larger
  change deferred from this FDR.
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
