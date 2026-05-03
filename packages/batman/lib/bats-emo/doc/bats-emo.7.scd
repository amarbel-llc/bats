bats-emo(7)

# NAME

bats-emo - binary conformance helpers for Bats test files

# DESCRIPTION

*bats-emo* provides helpers for validating that binaries under test are
available before running integration tests. It supports discovery via
environment variables and PATH lookup.

The core principle: tests validate *behavior*, not build artifacts.
A test suite should work identically whether the binary was built with
Go, Rust, or installed from a system package.

Load the library from a BATS test file or helper:

```
bats_load_library bats-emo
```

# ANTI-PATTERN

Never hardcode build output paths in tests:

```
# BAD — ties tests to a specific build system
run ./result/bin/mytool --version

# GOOD — binary injected via environment or PATH
run mytool --version
```

Hardcoded paths break when the build system changes, when tests run in
CI with different output locations, or when the tool is rewritten in
another language.

# FUNCTIONS

*require_bin* <var_name> [<command_name>]
	Validate that a binary under test is available. Checks in order:

	. If *$var_name* is set and its value is an executable path, succeeds.
	. If *$var_name* is unset and _command_name_ is provided, looks up
	  _command_name_ on *$PATH*.
	. Otherwise, prints an error and exits with status 1.

	This function is typically called in a BATS *setup* or *setup_file*
	function to fail early with a clear message when a required binary is
	missing.

# THREE-LAYER ARCHITECTURE

Binary injection works across three layers:

*Test file* — calls functions from common.bash; never references binaries
directly.

*common.bash* — loads bats-emo and calls *require_bin* for each binary
under test. This is the single place where binary names are declared.

*Justfile* — builds the binary and injects it via *--bin-dir*:

```
test-bats: build-go
    bats --bin-dir build/ zz-tests_bats/
```

This separation means adding a new binary to test requires changes in
exactly one file (common.bash), and the build system decides *where* the
binary comes from.

# EXAMPLE

```
setup_file() {
  bats_load_library bats-emo
  require_bin GRIT_BIN grit       # env var or PATH fallback
  require_bin BATS_WRAPPER        # env var only, no fallback
}
```

# SEE ALSO

*bats-testing*(7), *bats-island*(7), *bats-assert*(7)
