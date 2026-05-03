tap-writer(7)

# NAME

tap-writer - TAP version 14 output helpers for bash scripts

# DESCRIPTION

*tap-writer* emits TAP (Test Anything Protocol) version 14 output from
bash scripts. It is designed for non-BATS scripts that need to produce
structured test results consumable by TAP harnesses.

On load, *tap-writer* immediately prints the *TAP version 14* header and
registers an EXIT trap that emits a trailing plan line (*1..N*) if no
explicit plan was declared.

*tap-writer* is designed for standalone bash scripts, not BATS test
files. Source it directly using the batman store path:

```
source "${BATS_LIB_PATH%%:*}/tap-writer/load.bash"
```

Or, in non-BATS scripts where *BATS_LIB_PATH* is unavailable, source it
from a known location.

# FUNCTIONS

*tap_plan* <count>
	Declare the test plan up front by printing *1..count*. Suppresses the
	automatic trailing plan on exit.

*tap_run* [--no-bail] <description> <command> [<args>]
	Execute _command_ with _args_ and emit a TAP test result. Prints
	*ok N - description* on success or *not ok N - description* with a
	YAML diagnostic block containing captured output on failure. By
	default, calls *tap_bail_out* on failure. Pass *--no-bail* to
	continue after failures.

*tap_skip* <description> <reason>
	Emit a skipped test result: *ok N - description # SKIP reason*.

*tap_comment* <text>
	Emit a TAP comment line: *# text*.

*tap_bail_out* <reason>
	Emit *Bail out! reason* and exit with status 1. Terminates the test
	run immediately.

# EXAMPLE

```
source "path/to/tap-writer/load.bash"

tap_plan 3
tap_run "config file exists" test -f config.toml
tap_run "binary is on PATH" command -v mytool
tap_skip "network test" "no connectivity"
```

Output:

```
TAP version 14
1..3
ok 1 - config file exists
ok 2 - binary is on PATH
ok 3 - network test # SKIP no connectivity
```

# SEE ALSO

*bats-testing*(7), *bats-support*(7)
