#!/bin/bash -e

bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-island
bats_load_library bats-emo

require_bin BATMAN_BIN batman

# Return the active sandbox backend name. Currently always "fence" or
# "none" (when BATS_WRAPPER is unset). Backed by the wrapper's
# --query-sandbox flag.
bats_wrapper_sandbox_mode() {
  if [[ -z ''${BATS_WRAPPER:-} ]]; then
    echo "none"
    return
  fi
  "$BATS_WRAPPER" --query-sandbox 2>/dev/null || echo "none"
}

# Skip the current test unless the wrapped bats has any sandbox backend
# active. Tests that assert sandbox behavior call this so they no-op
# cleanly when BATS_WRAPPER points at a wrapper without sandboxing.
skip_unless_sandbox() {
  local mode
  mode="$(bats_wrapper_sandbox_mode)"
  if [[ $mode == "none" ]]; then
    skip "wrapper has no sandbox backend"
  fi
}
