bats-lane-container(7)

# NAME

bats-lane-container - run a bats integration suite inside a podman container built from a nix OCI image

# DESCRIPTION

*bats-lane-container* is an alternate test runner for the same kind
of bats suite *batsLane*(7) targets, but instead of running inside
the nix builder sandbox it runs inside a podman container started
from a nix-built OCI image.

The container is THE sandbox: outbound networking is denied
(`--network none`), the test source is bind-mounted read-only at
*/tests*, */tmp* is a tmpfs that dies with the container, and the
rootfs is the image's nix-store-derived contents (no */home*, no
*/etc/passwd*, no host userland). Per-test fence isolation is NOT
used inside the container — the namespace boundary already enforces
fs/network/process isolation, and layering fence's bwrap inside
rootless podman fails with nested-namespace permission errors
anyway (the same family as bob#113).

The function ships as two flake outputs:

```
.#bats-lane-container          # generic runner
.#bats-lane-container-image    # the OCI image
```

A pinned batman-only self-proof script also ships:

```
.#batman-container-self-proof
```

See FDR-0002 (*packages/batman/docs/features/0002-podman-container-lane.md*)
for the design rationale.

# SYNOPSIS

```
nix run .#bats-lane-container -- <bats-source-dir> [test-file ...]
nix run .#batman-container-self-proof
just test-batman-container <bats-source-dir> [test-file ...]
just test-batman-container-self-proof
```

# ARGUMENTS

The generic runner takes:

*bats-source-dir*
	Path on the host to the directory containing the bats test
	files (and their common.bash and fixtures). Bind-mounted
	read-only at /tests inside the container.

*test-file ...* (optional)
	Trailing positional arguments. Passed to *bats* inside the
	container, relative to /tests. Defaults to \*.bats (every test
	file in the staging root). Use this to restrict the suite, e.g.
	*batman.bats island.bats* — which is what the self-proof does
	to skip *bats_wrapper.bats* (it requires the fence-wrapped
	*BATS_WRAPPER*, which the container doesn't provide).

# ENVIRONMENT INSIDE THE CONTAINER

The image sets:

*BATS_LIB_PATH*
	Points at the batman bats-libs bundle's share/bats directory,
	so *bats_load_library* resolves the helpers.

*BATMAN_BIN*
	Points at the batman zx orchestrator. Tests in batman.bats
	invoke it directly via *--dry-run* and friends.

*PATH*
	/bin:/usr/bin — both symlinks into the image's nix-store
	layout via dockerTools.

*BATS_WRAPPER* is **not** set. Suites whose *common.bash* declares
*require_bin BATS_WRAPPER* (e.g. *bats_wrapper.bats*) will fail to
load; pass an explicit *test-file* list that excludes them.

# RELATION TO OTHER LANES

*bats-lane*(7) (nix sandbox via *batsLane*)
	Hermetic per-closure, cached by nix, runs in *nix flake check*.
	Has the fence-wrapped bats available as *BATS_WRAPPER*, so the
	full 26-test batman suite runs (including the wrapper tests).
	First-choice lane for CI.

*test-batman-fence* (dev shell, plain bats)
	Runs batman.bats under nixpkgs' plain bats. Fastest local
	iteration. Skips the bats_wrapper.bats suite for the same
	"no wrapper" reason this lane does.

*bats-lane-container* (this page)
	Runs in a podman container. Kernel-enforced network isolation,
	controllable rootfs, but not cached, not a flake check, and
	requires podman on the host. Self-proof passes 16 of the
	suite's tests (batman.bats + island.bats); the 10 wrapper tests
	in bats_wrapper.bats are out of scope.

# LIMITATIONS

*Not a flake check*
	*podman run* needs privileged operations the nix builder
	denies. The container lane is a *nix run* / justfile recipe,
	not a *nix flake check* output. CI must invoke it separately
	from *nix flake check*.

*Requires podman on the host*
	Not a nix-managed dependency. On Linux, install via your
	distro's package manager. On Darwin, also requires *podman
	machine init && podman machine start* — the runner bootstraps
	this on first invocation if not already running.

*First-load latency*
	*podman load* on a ~500 MB tarball takes a couple of minutes
	the first time per closure. Subsequent invocations skip the
	load (the runner keys off the content-derived image tag).

*Subset of the suite*
	The self-proof runs batman.bats + island.bats only. Suites
	that require the fence-wrapped *BATS_WRAPPER* must be run via
	*bats-lane*(7) or *test-batman-fence*.

*Image size*
	~564 MB compressed, ~2.2 GB on-disk (reflects the batman
	orchestrator's transitive node + fence runtime). Slimming is
	possible but out of scope for v0; see FDR-0002 "Follow-ups".

# EXAMPLES

*Self-proof*

```
just test-batman-container-self-proof
```

Runs batman.bats + island.bats inside the container against the
in-tree zz-tests_bats source.

*Ad-hoc run against an arbitrary source tree*

```
nix run .#bats-lane-container -- /path/to/my/zz-tests_bats
```

Runs every \*.bats file in the supplied directory.

*Restrict to a subset*

```
nix run .#bats-lane-container -- /path/to/tests foo.bats bar.bats
```

Runs only the named files, relative to /tests inside the
container.

# DARWIN

On Darwin the runner detects *podman machine* and bootstraps it on
first invocation:

```
podman machine inspect default || podman machine init
podman machine start
```

After the VM is up, the rest of the flow is identical to Linux.
The first VM start adds ~30-60 seconds; subsequent invocations are
fast.

# FILES

*${flake.packages.${system}.bats-lane-container-image}*
	The OCI image tarball, in the nix store. Content-addressed; a
	closure change yields a new path and a new
	*image.imageTag*.

# SEE ALSO

*bats-lane*(7), *bats-testing*(7), *bats-emo*(7),
*bats-island*(7)
