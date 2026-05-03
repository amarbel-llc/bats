bats-support(7)

# NAME

bats-support - output formatting and error reporting for Bats libraries

# DESCRIPTION

*bats-support* provides output formatting primitives used by
*bats-assert*(7) and other BATS helper libraries. It can also be used
directly in test files for custom assertion output.

Load the library from a BATS test file or helper:

```
bats_load_library bats-support
```

# FUNCTIONS

## Error reporting

*fail* [<message>]
	Print _message_ to stderr and return 1. When no arguments are given,
	reads the message from stdin. Used by assertion functions to report
	failures.

*batslib_err* [<message>]
	Print _message_ to stderr. When no arguments are given, reads from
	stdin.

## Output formatting

*batslib_print_kv_single* <width> <key> <value> [<key> <value> ...]
	Print key-value pairs in two-column format. _width_ sets the key
	column width. Keys are left-aligned and values follow after a colon
	separator.

*batslib_print_kv_multi* <key> <value> [<key> <value> ...]
	Print key-value pairs in multi-line format. Each key is printed on its
	own line with the line count, followed by the value on subsequent
	lines.

*batslib_print_kv_single_or_multi* <width> <key> <value> [...]
	Print key-value pairs using two-column format if all values are
	single-line, or multi-line format otherwise. Automatically selects the
	best layout.

## Text manipulation

*batslib_prefix* [<prefix>]
	Read lines from stdin and prefix each with _prefix_ (default: two
	spaces).

*batslib_mark* <symbol> <index> [<index> ...]
	Read lines from stdin and overwrite the beginning of lines at the
	given zero-based indices with _symbol_. Typically used after
	*batslib_prefix* to highlight specific lines.

*batslib_decorate* <title>
	Read text from stdin and wrap it in a header (*-- title --*) and
	footer (*--*) with surrounding blank lines.

## Utility

*batslib_count_lines* <string>
	Print the number of lines in _string_ to stdout.

*batslib_is_single_line* <string> [<string> ...]
	Return 0 if all strings are single-line, 1 otherwise.

*batslib_get_max_single_line_key_width* <key> <value> [...]
	Print the length of the longest key whose corresponding value is
	single-line. Used to compute column width for
	*batslib_print_kv_single*.

*batslib_is_caller* [-i | --indirect] <function>
	Return 0 if the calling function was invoked from _function_. With
	*--indirect*, checks the entire call stack instead of just the
	immediate caller.

# SEE ALSO

*bats-testing*(7), *bats-assert*(7), *bats-island*(7)
