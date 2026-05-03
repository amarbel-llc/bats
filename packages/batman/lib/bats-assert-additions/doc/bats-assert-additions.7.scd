bats-assert-additions(7)

# NAME

bats-assert-additions - extended assertion functions for Bats test files

# DESCRIPTION

*bats-assert-additions* provides assertion functions that extend
*bats-assert*(7) with order-independent and field-extracted output
matching. It depends on *bats-support*(7) for output formatting.

Load the library from a BATS test file or helper:

```
bats_load_library bats-assert-additions
```

# FUNCTIONS

*assert_output_unsorted* [-p | -e] [- | [--] <expected>]
	Like *assert_output* from *bats-assert*(7), but sorts both expected
	and actual output lines before comparison. Useful when command output
	order is non-deterministic. Supports *--partial* (*-p*), *--regexp*
	(*-e*), and *--stdin* (*-*).

*assert_output_cut* [-p | -e] [- | [--] <expected>]
	Like *assert_output* from *bats-assert*(7), but applies *cut*(1)
	field extraction to both expected and actual output before comparison.
	Useful for comparing specific columns of tabular output. Supports
	*--partial* (*-p*), *--regexp* (*-e*), and *--stdin* (*-*).

# EXAMPLE

```
@test 'list files in any order' {
  run ls /tmp/testdir
  assert_output_unsorted "bar
baz
foo"
}
```

# SEE ALSO

*bats-testing*(7), *bats-assert*(7), *bats-support*(7)
