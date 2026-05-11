bats-lane(7)

# NAME

bats-lane - run a bats integration suite against pre-built binaries inside the nix sandbox

# DESCRIPTION

*batsLane* is a nix build-support function that produces a *runCommand*
derivation which:

. Stages a bats source tree into a writable scratch directory.
. Exports caller-named environment variables pointing at one or more
  pre-built binaries.
. Optionally extends *BATS_LIB_PATH* with bats-libs entries.
. Runs *bats* with an optional *--filter-tags* expression.
. Touches an output stamp file on success.

It is the nix-sandbox equivalent of dev-shell test runners like
*test-batman-fence* (see this flake's *justfile*). Downstream flakes
use it to surface per-tag test lanes as flake outputs without
rebuilding for each filter expression. It is the mechanism behind
this repo's own *checks.${system}.batman-self-proof*.

The function lives at two equivalent paths in the *bats* flake:

```
bats.lib.${system}.batsLane
(bats.lib.${system}.mkBats { }).batsLane
```

Both default the test runner to *pkgs.bats* from upstream nixpkgs.

# SYNOPSIS

Single-binary shortcut:

```
bats.lib.${system}.batsLane {
  base = mytool;                   # derivation producing bin/mytool
  binaryName = "mytool";           # subpath under ${base}/bin
  binaryEnvVarName = "MYTOOL_BIN"; # default "BATS_BIN"
  batsSrc = ./zz-tests_bats;
  batsLibPath = [ batmanPkgs.bats-libs.batsLibPath ];
  nativeBuildInputs = [ pkgs.git ];
}
```

Multi-binary form:

```
bats.lib.${system}.batsLane {
  binaries = {
    MYAPP_BIN  = { base = myapp;  name = "myapp"; };
    HELPER_BIN = { base = helper; name = "helper"; };
  };
  batsSrc = ./zz-tests_bats;
  batsLibPath = [ batmanPkgs.bats-libs.batsLibPath ];
  filter = "integration";
  nativeBuildInputs = [ pkgs.git ];
}
```

# REQUIRED ARGUMENTS

*batsSrc*
	A path to the directory containing the \*.bats test files (and
	their common.bash and fixtures). Copied recursively into the
	staging scratch dir at stage/zz-tests_bats/ inside the builder.

One of:

. *base* + *binaryName* (single-binary shortcut), or
. *binaries* (multi-binary form).

# BINARY-EXPORT ARGUMENTS

*base*
	A pre-built derivation containing the binary under test at
	${base}/bin/${binaryName}. The caller is responsible for
	ensuring it is built. Also used as the naming anchor for the
	default derivation name (${base.pname}-bats-${suffix}) when
	*name* is unset.

*binaryName*
	A string: the subpath under ${base}/bin that the test binary
	lives at.

*binaryEnvVarName*
	A string (default *"BATS_BIN"*): the name of the env var that
	will be set to ${base}/bin/${binaryName} before bats runs. Tests
	consult this var (typically via *require_bin*; see *bats-emo*(7))
	to locate the binary under test. Ignored when *binaries* is set.

*binaries*
	An attrset: ENV_VAR_NAME → { base; name; }. Each entry exports
	<ENV_VAR_NAME>=${base}/bin/${name} before bats runs. Use when a
	suite needs more than one binary in scope (e.g. a CLI plus a
	sibling tool), or when the binaries live in different
	derivations. When set, the single-binary shortcut args (*base*,
	*binaryName*, *binaryEnvVarName*) are ignored for env-var
	purposes; *base* is still consulted as a naming anchor if
	present.

# RUNNER ARGUMENTS

*bats*
	A derivation (default *pkgs.bats*): the bats binary to invoke.
	Override with a wrapper (e.g. the fence-backed *batmanPkgs.bats*
	from this flake's *mkBats { }*). The wrapper's flags must be
	compatible with the invocation: *--jobs*, optional
	*--filter-tags*, then test-file arguments.

*filter*
	A string (default ""): the *bats --filter-tags* expression.
	Empty means no filter (run everything). The flag is omitted
	when empty.

*name*
	A string (default derived): override the derivation name. When
	unset, the name is ${namingPname}-bats-${suffix} where
	namingPname is taken from base.pname (or the first entry of
	*binaries* when *base* is omitted), and suffix is "all" or the
	sanitized *filter* expression.

# STAGING + ENV ARGUMENTS

*batsLibPath*
	A list (default []): entries appended to *BATS_LIB_PATH*
	(colon-joined). Each entry should be a path containing a
	share/bats-style layout that bats's *bats_load_library*
	resolves against. For this flake's bats-libs bundle, pass
	*batmanPkgs.bats-libs.batsLibPath* (which already includes the
	share/bats suffix; see *check-bats-libs-path* in the flake's
	checks).

*extraEnv*
	An attrset (default {}): additional env vars to export before
	invoking bats. Values are shell-escaped via
	*lib.escapeShellArg*. Use for *BATS_TEST_TIMEOUT*, custom debug
	toggles, etc.

*extraStagedFiles*
	A list (default []): additional files copied into the staging
	dir alongside the bats sources. Each entry is { src; dest; }
	where dest is a path relative to the staging root (which
	contains the zz-tests_bats/ subdir). Use for side-channel files
	such as version manifests that tests read via
	$BATS_TEST_DIRNAME/....

*nativeBuildInputs*
	A list (default []): extra build-time tools the bats helpers
	need. *parallel* is always included unconditionally (required
	by *bats --jobs N*). Common addition: *pkgs.git* — bats-island's
	*setup_test_home* and *setup_test_repo* shell out to git, which
	is *not* on the nix builder's default PATH (see *NIX-BUILDER
	CAVEATS* below).

# BATS INVOCATION ARGUMENTS

*extraBatsArgs*
	A list (default []): args appended to the *bats* invocation
	after *--jobs* and *--filter-tags* and before the test-file
	arguments. Each entry is shell-escaped. Use for
	*--print-output-on-failure*, *--no-parallelize-within-files*,
	or other flags the builder does not surface as first-class
	arguments.

*testFiles*
	A list (default [ "\*.bats" ]): trailing positional arguments
	handed to bats — paths or shell globs relative to
	stage/zz-tests_bats/ in the builder. Entries are joined with
	spaces and NOT shell-escaped, so bash expands globs as usual.
	The flat-layout default picks up every \*.bats file in the
	staging root. Consumers with nested suites can pass e.g.

```
testFiles = [ "current_version/*.bats" "previous_versions/main.bats" ];
```

# NIX-BUILDER CAVEATS

The nix builder sandbox is more restrictive than typical Linux
environments. Suites that pass in a dev shell may need adjustments
to pass under batsLane:

*No /usr/bin*
	Shebangs of the form *#!/usr/bin/env bash* fail with exit 126
	(*bad interpreter: No such file or directory*). Use
	*#!/bin/sh* (a guaranteed bash symlink in the builder) for
	ad-hoc test fixtures, or substitute the shebang at staging
	time.

*No git on PATH by default*
	Pass *nativeBuildInputs = [ pkgs.git ]* if any test or bats
	helper invokes git. bats-island's *setup_test_home* and
	*setup_test_repo* both do.

*No network*
	The builder denies all outbound connections. Tests must mock
	or fixture any network-dependent code.

*No persistent /tmp*
	Writes survive only within the build. *BATS_TEST_TMPDIR* and
	*BATS_RUN_TMPDIR* land inside the builder's per-derivation
	scratch dir, which is discarded on completion.

*Restricted PATH*
	The builder's PATH includes only what *nativeBuildInputs*
	provides, plus what bats itself contributes via its own
	runtime deps.

# EXAMPLES

## Self-proof from this repo

The flake check *checks.${system}.batman-self-proof* is defined as:

```
batmanSelfProof = batsLaneLib.batsLane {
  name = "batman-self-proof";
  batsSrc = ./packages/batman/zz-tests_bats;
  binaries = {
    BATMAN_BIN   = { base = batmanPkgs.default; name = "batman"; };
    BATS_WRAPPER = { base = batmanPkgs.default; name = "bats";   };
  };
  batsLibPath = [ batmanPkgs.bats-libs.batsLibPath ];
  nativeBuildInputs = [ pkgs.git ];
};
```

It runs batman.bats, bats_wrapper.bats, and island.bats in a single
bats invocation, with *BATMAN_BIN* and *BATS_WRAPPER* both pointing
at the built batman bundle. The suite's common.bash declares
*BATMAN_BIN* via *require_bin BATMAN_BIN batman*; see *bats-emo*(7).

## Single-binary downstream consumer

A consumer flake that imports *bats* as an input:

```
{
  inputs.bats.url = "github:amarbel-llc/bats";

  outputs = { self, nixpkgs, bats }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      batmanPkgs = bats.lib.${system}.mkBats { };
      mytool = pkgs.callPackage ./mytool.nix { };
    in {
      checks.${system}.mytool-bats = bats.lib.${system}.batsLane {
        base = mytool;
        binaryName = "mytool";
        binaryEnvVarName = "MYTOOL_BIN";
        batsSrc = ./zz-tests_bats;
        batsLibPath = [ batmanPkgs.bats-libs.batsLibPath ];
        nativeBuildInputs = [ pkgs.git ];
      };
    };
}
```

Tests in zz-tests_bats/ invoke the binary as "$MYTOOL_BIN". The
suite's common.bash declares *require_bin MYTOOL_BIN mytool*.

## Per-tag lanes

Surface a fast lane and a slow lane as separate flake outputs:

```
checks.${system} = {
  mytool-bats-fast = batsLane {
    base = mytool;
    binaryName = "mytool";
    batsSrc = ./zz-tests_bats;
    filter = "fast";
    batsLibPath = [ batmanPkgs.bats-libs.batsLibPath ];
    nativeBuildInputs = [ pkgs.git ];
  };
  mytool-bats-slow = batsLane {
    base = mytool;
    binaryName = "mytool";
    batsSrc = ./zz-tests_bats;
    filter = "slow";
    batsLibPath = [ batmanPkgs.bats-libs.batsLibPath ];
    nativeBuildInputs = [ pkgs.git ];
  };
};
```

Each lane runs independently; nix caches results per closure.

# CHOOSING BETWEEN batsLane AND test-batman-fence

This repo ships two ways to run a bats suite, and downstream flakes
typically want both:

*batsLane* (nix sandbox, recommended for CI/checks)
	Hermetic: only the closure's tools are on PATH. Reproducible:
	nix caches the result per closure. Survives fence-in-bwrap
	nesting because the builder's namespace is the first bwrap in
	the stack. Less convenient for iterative debugging: stdout is
	buffered until the build finishes.

*test-batman-fence* (dev shell, recommended for local iteration)
	Fast: no nix-build wrapper overhead. Interactive: stdout
	streams live, easy to *--filter* on the fly. May hit
	nested-bwrap limitations when sandbox tests spawn the
	fence-wrapped bats inside a bwrapped dev shell; see bob#113.

For CI, use *batsLane* in *checks.${system}* and *flake-check*. For
local iteration, run *just test-batman-fence*.

# UPSTREAM

The build-support function was lifted from amarbel-llc/nixpkgs
(pkgs/build-support/bats-test/default.nix). The copy in this flake
lives at nix/packages/bats-lane.nix; the original docstring in that
file is the authoritative argument reference. This manpage covers how
to consume the function from a downstream flake.

# SEE ALSO

*bats-testing*(7), *bats-lane-container*(7), *bats-emo*(7),
*bats-island*(7), *bats-assert*(7), *bats-support*(7)
