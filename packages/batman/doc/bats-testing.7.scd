bats-testing(7)

# NAME

bats-testing - BATS integration test conventions for amarbel-llc projects

# DESCRIPTION

Integration tests in amarbel-llc projects use BATS (Bash Automated Testing
System) via the *batman* wrapper. Batman bundles BATS with six support
libraries, fence-based sandbox isolation, and TAP-14 output formatting.

This manpage covers the conventions for writing, organizing, and running
BATS tests.

# LIBRARY STACK

Batman bundles six BATS libraries:

*bats-support*(7)
	Output formatting and error reporting primitives used by other
	libraries. Rarely used directly in tests.

*bats-assert*(7)
	Standard assertions: exit status, output matching, line matching,
	and regex comparison. The most commonly used library.

*bats-assert-additions*(7)
	Extended assertions for order-independent (*assert_output_unsorted*)
	and field-extracted (*assert_output_cut*) output matching.

*bats-island*(7)
	Test isolation: temporary HOME, XDG base directories, and git
	repositories. Prevents tests from reading or modifying the real
	user environment.

*bats-emo*(7)
	Binary injection via *require_bin*. Makes tests
	implementation-agnostic by discovering binaries through environment
	variables or PATH lookup.

*tap-writer*(7)
	TAP version 14 output for non-BATS bash scripts. Not loaded via
	*bats_load_library* — sourced directly in standalone scripts.

# DIRECTORY STRUCTURE

Tests live in *zz-tests_bats/* at the project root:

```
zz-tests_bats/
├── justfile          # test-suite justfile
├── common.bash       # shared setup, library loading, require_bin
├── feature_a.bats    # test files
├── feature_b.bats
└── fixtures/         # optional test data
```

The *zz-* prefix sorts tests last in directory listings.

# TEST FILE FORMAT

Test files use function-name declaration with *# @test* annotation:

```
#!/usr/bin/env bats

setup() {
  load "$(dirname "$BATS_TEST_FILE")/common.bash"
}

function my_tool_produces_expected_output { # @test
  run mytool --flag input.txt
  assert_success
  assert_output "expected result"
}
```

BATS supports two test declaration styles:

*Function-name style* (preferred):

```
function descriptive_test_name { # @test
  ...
}
```

*Directive style*:

```
@test 'descriptive test name' {
  ...
}
```

Both are valid BATS, but function-name style SHOULD be used because it
enables *shfmt* formatting and *shellcheck* analysis. The directive
style is opaque to both tools — they cannot parse or lint the test body.

Rules:

- Shebang is always *#!/usr/bin/env bats*.
- *setup()* loads common.bash; never duplicate library loading per test.
- Test function names are descriptive sentences with underscores.
- The *# @test* comment annotation enables BATS function-name discovery.

# COMMON.BASH

Every test suite has a *common.bash* that loads the library stack and
defines shared helpers:

```
bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-assert-additions
bats_load_library bats-island
bats_load_library bats-emo

require_bin MYTOOL_BIN mytool
```

*bats_load_library* searches *BATS_LIB_PATH*, which batman populates
automatically. Never use relative paths to load libraries.

# BINARY INJECTION

Tests must never hardcode build paths. Use *require_bin* from
*bats-emo*(7) to inject the binary under test:

```
require_bin MYTOOL_BIN mytool
```

This checks, in order:

. If *$MYTOOL_BIN* is set and executable, use it.
. Otherwise, look up *mytool* on *$PATH*.
. If neither works, fail with a clear error message.

The justfile provides the binary via *--bin-dir*:

```
test-bats: build-go
    bats --bin-dir build/ zz-tests_bats/
```

This makes tests implementation-agnostic — they work with Go, Rust, or
system-installed binaries.

# TEST ISOLATION

Tests must never leak to the real home directory or read real user
configuration.

*bats-island*(7) provides isolation helpers:

*setup_test_home*
	Creates a temporary HOME with empty XDG directories. Call in
	*setup()* or *setup_file()*.

*teardown_test_home*
	Removes the temporary HOME. Call in *teardown()* or
	*teardown_file()*.

*set_xdg*
	Sets all XDG base directory variables to point inside the test
	home.

*setup_test_repo*
	Creates a temporary git repository. Returns the path.

Example:

```
setup() {
  load "$(dirname "$BATS_TEST_FILE")/common.bash"
  setup_test_home
}

teardown() {
  teardown_test_home
}
```

# FENCE ENFORCEMENT

Batman runs tests inside *fence* by default, which enforces
filesystem and network restrictions:

- *Denied reads*: ~/.ssh, ~/.aws, ~/.gnupg, ~/.config, ~/.local,
  ~/.password-store, ~/.kube
- *Allowed writes*: /tmp, /private/tmp
- *Network*: no external access by default

Override with wrapper flags:

- *--no-sandbox* — disable fence entirely
- *--allow-local-binding* — allow localhost binding (currently a
  no-op until fence implements seccomp-level bind() blocking; see
  https://github.com/amarbel-llc/bats/issues/3)

Fence and bats-island are complementary: bats-island prevents tests
from *wanting* to access the real home; fence *enforces* that they
cannot.

# FIXTURE MANAGEMENT

Test data follows the self-containment principle:

- *Inline fixtures*: small data defined directly in the test function.
- *File fixtures*: stored in *zz-tests_bats/fixtures/* and committed.
- *Generated fixtures*: created in *$BATS_TEST_TMPDIR* during setup.

Never read from the real *$HOME* or rely on external state.

For projects with versioned data formats (e.g. dodder), fixture
snapshots live in version directories:

```
zz-tests_bats/
├── current_version/
│   ├── blob_store.bats
│   └── fixtures/
└── previous_versions/
    └── v14/
        ├── migration.bats
        └── fixtures/
```

Deterministic values that change across regeneration (hashes, digests)
are captured in *.fixtures.env* files.

# ASSERTION DISCIPLINE

Use the tightest assertion that validates the behavior:

*Exact match* (preferred):

```
assert_output "TAP version 14"
```

*Unsorted match* (when line order is non-deterministic):

```
assert_output_unsorted <<-EXPECTED
  line_a
  line_b
EXPECTED
```

*Regex match* (when values are dynamic):

```
assert_output --regexp "^[0-9a-f]{64}$"
```

*Partial match* (last resort — hides regressions):

```
assert_output --partial "error:"
```

*Two-pass strategy*: when writing a new assertion, first use a
deliberately wrong expected value to see the actual output, then fill in
the real assertion. This prevents copy-paste errors.

# WRAPPER FLAGS

Batman's *bats* wrapper accepts these flags before the standard BATS
arguments:

*--bin-dir* _path_
	Prepend _path_ to PATH (repeatable, leftmost = highest priority).

*--no-sandbox*
	Disable fence isolation.

*--allow-local-binding*
	Allow localhost binding in sandbox.

*--no-tempdir-cleanup*
	Keep BATS temp directories after test run.

*--hide-passing*
	Filter TAP output to show only failures and skips.

*--diagnostics-stderr*
	Write batman's wrapper diagnostics (parse errors, missing
	fence.jsonc, spawn failures) to stderr instead of the
	*$XDG_LOG_HOME/batman/batman.log* file. Useful in build sandboxes
	(Nix installCheckPhase, CI runners) where the log file would be
	discarded with the build dir before the consumer can inspect it.

# JUSTFILE INTEGRATION

The root justfile delegates to the test-suite justfile:

```
test-bats: build
    bats --bin-dir build/ zz-tests_bats/
```

The test-suite justfile in *zz-tests_bats/* provides granular targets:

```
set output-format := "tap"

default: test

test *args:
    bats --tap .

test-tags *tags:
    bats --tap --filter-tags "{{tags}}" .
```

# SEE ALSO

*bats-assert*(7), *bats-assert-additions*(7), *bats-emo*(7),
*bats-island*(7), *bats-support*(7), *tap-writer*(7)
