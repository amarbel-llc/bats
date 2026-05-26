#! /usr/bin/env bats
#
# Fence-asserting bats wrapper tests.
#
# These tests invoke `$BATS_WRAPPER` with sandboxing left ON (no
# `--no-sandbox`), so they end up shelling out to fence, which on darwin
# wraps the inner command via `sandbox-exec`. `sandbox-exec` calls
# `sandbox_apply()`, which the macOS kernel refuses with EPERM when the
# caller is itself a child of a Seatbelt-sandboxed process — and
# Determinate Nix's nix-daemon always attaches Seatbelt to build
# children, regardless of nix.conf's `sandbox = false`. So these tests
# cannot run inside `nix build`'s batsLane self-proof on darwin.
#
# Linux is unaffected by the nested-sandbox issue, but we still keep
# these tests separate so the routing is uniform across platforms: they
# run host-side via `just test-batman-fence-wrapper` (or its podman
# container counterpart, `test-batman-container-self-proof`), not
# inside the batsLane build.
#
# Siblings:
#   - bats_wrapper.bats: all the `--no-sandbox` cases, safe to run in
#     any environment (including the in-build self-proof).
#   - batman.bats / island.bats: helper-level tests, run everywhere.

setup() {
  load "$(dirname "$BATS_TEST_FILE")/common.bash"
  export output
  BATS_TMPDIR="${BATS_TMPDIR:-/tmp}"
  TEST_TMPDIR="$(mktemp -d "${BATS_TMPDIR}/bats-wrapper-XXXXXX")"

  require_bin BATS_WRAPPER
  export BATS_WRAPPER
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

function bats_wrapper_runs_tests { # @test
  cat >"${TEST_TMPDIR}/truth.bats" <<'EOF'
#! /usr/bin/env bats
function truth { # @test
  true
}
EOF
  run "$BATS_WRAPPER" --no-split --tap "${TEST_TMPDIR}/truth.bats"
  assert_success
  assert_output --partial "ok 1"
}

function bats_wrapper_denies_config_read { # @test
  skip_unless_sandbox
  # Verify the sandbox blocks reads of $HOME/.config.
  # The inner test asserts the directory is empty or missing.
  cat >"${TEST_TMPDIR}/read_config.bats" <<'INNER'
#! /usr/bin/env bats
function config_dir_is_empty_or_missing { # @test
  if [[ -d "$HOME/.config" ]]; then
    contents="$(ls "$HOME/.config")"
    [ -z "$contents" ]
  fi
}
INNER
  run "$BATS_WRAPPER" --no-split --tap "${TEST_TMPDIR}/read_config.bats"
  assert_success
  assert_output --partial "ok 1"
}

function bats_wrapper_allows_tmp_write { # @test
  cat >"${TEST_TMPDIR}/write_tmp.bats" <<'EOF'
#! /usr/bin/env bats
function write_tmp { # @test
  echo "test" > /tmp/bats-wrapper-test-$$
  rm -f /tmp/bats-wrapper-test-$$
}
EOF
  run "$BATS_WRAPPER" --no-split --tap "${TEST_TMPDIR}/write_tmp.bats"
  assert_success
}

function bats_wrapper_no_tempdir_cleanup_preserves_tmpdir { # @test
  cat >"${TEST_TMPDIR}/preserve.bats" <<'EOF'
#! /usr/bin/env bats
function creates_file_in_tmpdir { # @test
  echo "marker" > "${BATS_TEST_TMPDIR}/marker.txt"
}
EOF
  run "$BATS_WRAPPER" --no-split --no-tempdir-cleanup "${TEST_TMPDIR}/preserve.bats"
  assert_success
  assert_output --partial "ok 1"
  # Extract BATS_RUN_TMPDIR from output (printed by --no-tempdir-cleanup)
  bats_run_dir="$(echo "$output" | grep "BATS_RUN_TMPDIR" | cut -d' ' -f2)"
  [[ -n $bats_run_dir ]]
  # Verify the temp dir survived (--no-tempdir-cleanup forwarded to bats)
  [[ -d $bats_run_dir ]]
  [[ -f "$bats_run_dir/test/1/marker.txt" ]]
  # Clean up manually
  rm -rf "$bats_run_dir"
}
