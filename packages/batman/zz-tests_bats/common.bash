#!/bin/bash -e

bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-island
bats_load_library bats-emo

require_bin BATMAN_BIN batman

# Skip the current test unless the wrapped bats was built with a
# sandcastle dependency. Tests that assert sandbox behavior call this
# helper so they no-op cleanly in the sandcastle-less default build.
skip_unless_sandcastle() {
  if [[ -z ''${BATS_WRAPPER:-} ]]; then
    skip "BATS_WRAPPER not set"
  fi
  local result
  result="$("$BATS_WRAPPER" --query-sandcastle 2>/dev/null || true)"
  if [[ $result != "true" ]]; then
    skip "wrapper has no sandcastle"
  fi
}
