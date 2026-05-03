bats-island(7)

# NAME

bats-island - test isolation helpers for Bats test files

# DESCRIPTION

*bats-island* provides functions that create isolated environments for
BATS tests: temporary home directories, XDG base directories, and git
repositories. This prevents tests from reading or modifying the real
user environment.

Load the library from a BATS test file or helper:

```
bats_load_library bats-island
```

# FUNCTIONS

*set_xdg* <base_directory>
	Set and export all XDG environment variables (*XDG_DATA_HOME*,
	*XDG_CONFIG_HOME*, *XDG_STATE_HOME*, *XDG_CACHE_HOME*,
	*XDG_RUNTIME_HOME*) to subdirectories under _base_directory_/.xdg/
	and create them. Fails if _base_directory_ is empty or cannot be
	resolved.

*setup_test_home*
	Create an isolated test environment. Saves the real *$HOME* in
	*$REAL_HOME*, sets *$HOME* to a temporary directory under
	*$BATS_TEST_TMPDIR*, calls *set_xdg*, configures *$PARALLEL_HOME* to
	suppress GNU parallel warnings, and initializes an isolated git
	config with a test user identity.

	Exported variables: *REAL_HOME*, *HOME*, *PARALLEL_HOME*,
	*GIT_CONFIG_GLOBAL*, *GIT_CONFIG_SYSTEM*, *GIT_CEILING_DIRECTORIES*,
	*GIT_EDITOR*, and all XDG variables from *set_xdg*.

*teardown_test_home*
	Clean up after *setup_test_home*. Calls *chflags_nouchg* to remove
	immutable flags on macOS before BATS removes the temporary directory.

*setup_test_repo* [<path>]
	Create and initialize a git repository for testing. Calls
	*setup_test_home* if not already called. Creates a repo at _path_
	(default: *$BATS_TEST_TMPDIR/repo*) with an initial commit. Exports
	*$TEST_REPO* with the repository path.

*chflags_nouchg*
	Recursively remove the macOS *uchg* (user immutable) flag from all
	files under *$BATS_TEST_TMPDIR*. No-op on non-macOS systems.

# EXAMPLE

```
setup() {
  bats_load_library bats-island
  setup_test_home
}

teardown() {
  teardown_test_home
}

@test 'config file is created' {
  run mytool init
  assert_success
  assert [ -f "$XDG_CONFIG_HOME/mytool/config.toml" ]
}

@test 'git operations work in isolation' {
  setup_test_repo
  run git -C "$TEST_REPO" status
  assert_success
}
```

# SEE ALSO

*bats-testing*(7), *bats-assert*(7), *bats-emo*(7), *bats-support*(7)
