bats-assert(7)

# NAME

bats-assert - assertion functions for Bats test files

# DESCRIPTION

*bats-assert* provides common assertions for BATS test files. It depends
on *bats-support*(7) for output formatting and error reporting.

Load the library from a BATS test file or helper:

```
bats_load_library bats-assert
```

All assertion functions operate on the *$status*, *$output*, and
*$lines* variables set by the BATS *run* builtin.

# FUNCTIONS

## Basic assertions

*assert* <expression>
	Fail if the given expression evaluates to false. The expression must
	be a simple command; compound commands like *[[* require wrapping in
	*bash -c*.

*refute* <expression>
	Fail if the given expression evaluates to true. Same restrictions on
	compound commands as *assert*.

## Value comparison

*assert_equal* <actual> <expected>
	Fail if _actual_ does not equal _expected_.

*assert_not_equal* <actual> <unexpected>
	Fail if _actual_ equals _unexpected_.

## Exit status

*assert_success*
	Fail if *$status* is not 0. Displays *$status* and *$output* on
	failure.

*assert_failure* [<expected_status>]
	Fail if *$status* is 0. When _expected_status_ is given, also fail if
	*$status* does not equal _expected_status_.

## Output matching

*assert_output* [-p | -e] [- | [--] <expected>]
	Fail if *$output* does not match _expected_. With no arguments, fails
	if *$output* is empty. Supports *--partial* (*-p*) for substring
	matching, *--regexp* (*-e*) for extended regular expression matching,
	and *-* / *--stdin* to read the expected value from stdin.

*refute_output* [-p | -e] [- | [--] <unexpected>]
	Fail if *$output* matches _unexpected_. With no arguments, fails if
	*$output* is non-empty. Same options as *assert_output*.

## Line matching

*assert_line* [-n <index>] [-p | -e] [--] <expected>
	Fail if _expected_ is not found in *$lines*. With *--index* (*-n*),
	checks only the line at that index. Supports *--partial* and
	*--regexp*.

*refute_line* [-n <index>] [-p | -e] [--] <unexpected>
	Fail if _unexpected_ is found in *$lines*. With *--index*, checks
	only the line at that index. Supports *--partial* and *--regexp*.

## Regular expression matching

*assert_regex* <value> <pattern>
	Fail if _value_ does not match the extended regular expression
	_pattern_. On success, *BASH_REMATCH* is available.

*refute_regex* <value> <pattern>
	Fail if _value_ matches _pattern_. On failure, displays the matching
	portion.

# EXAMPLE

```
function greet_produces_expected_output { # @test
  run greet "world"
  assert_success
  assert_output "hello, world"
}

function error_on_missing_argument { # @test
  run greet
  assert_failure
  assert_output --partial "usage:"
}
```

# SEE ALSO

*bats-testing*(7), *bats-assert-additions*(7), *bats-emo*(7),
*bats-support*(7), *bats-island*(7)
