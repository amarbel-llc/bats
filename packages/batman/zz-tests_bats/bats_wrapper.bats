#! /usr/bin/env bats

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

# Fence-asserting tests (bats_wrapper_runs_tests,
# bats_wrapper_denies_config_read, bats_wrapper_allows_tmp_write,
# bats_wrapper_no_tempdir_cleanup_preserves_tmpdir) live in
# bats_wrapper_fence.bats — they shell out to `sandbox-exec`, which can't
# nest under Determinate Nix's outer Seatbelt during a `nix build`. The
# tests below all pass `--no-sandbox` (or are sandbox-mode introspection)
# and are safe to run inside the batsLane self-proof.

function bats_wrapper_no_split_emits_tap_output { # @test
  cat >"${TEST_TMPDIR}/tap_default.bats" <<'EOF'
#! /usr/bin/env bats
function truth { # @test
  true
}
EOF
  run "$BATS_WRAPPER" --no-split --no-sandbox "${TEST_TMPDIR}/tap_default.bats"
  assert_success
  # TAP output starts with version or plan line
  assert_line --index 0 --regexp "^(TAP version|1\.\.)"
}

function bats_wrapper_full_output_is_alias_for_no_split { # @test
  cat >"${TEST_TMPDIR}/alias.bats" <<'EOF'
#! /usr/bin/env bats
function truth { # @test
  true
}
EOF
  run "$BATS_WRAPPER" --full-output --no-sandbox "${TEST_TMPDIR}/alias.bats"
  assert_success
  assert_line --index 0 --regexp "^(TAP version|1\.\.)"
}

function bats_wrapper_no_sandbox_bypasses_fence { # @test
  cat >"${TEST_TMPDIR}/no_sandbox.bats" <<'EOF'
#! /usr/bin/env bats
function can_read_home_config { # @test
  [[ -d "$HOME/.config" ]] || skip "no .config dir"
  ls "$HOME/.config" >/dev/null
}
EOF
  run "$BATS_WRAPPER" --no-sandbox "${TEST_TMPDIR}/no_sandbox.bats"
  assert_success
}

function bats_wrapper_split_emits_failures_only_on_stdout { # @test
  cat >"${TEST_TMPDIR}/mixed.bats" <<'EOF'
#! /usr/bin/env bats
function passing_one { # @test
  true
}
function failing_one { # @test
  false
}
function passing_two { # @test
  true
}
EOF
  local pass_file="${TEST_TMPDIR}/passes.ndjson"
  run "$BATS_WRAPPER" --no-sandbox --pass-out "$pass_file" "${TEST_TMPDIR}/mixed.bats"
  # tap-dancer format-ndjson exits 1 when any record is a failure.
  assert_failure
  # The failure record names the failing test on stdout.
  assert_output --partial "failing_one"
  # Passing test names must not appear on stdout under split mode.
  refute_output --partial "passing_one"
  refute_output --partial "passing_two"
}

function bats_wrapper_split_writes_passes_to_pass_out { # @test
  cat >"${TEST_TMPDIR}/passes.bats" <<'EOF'
#! /usr/bin/env bats
function passing_a { # @test
  true
}
function passing_b { # @test
  true
}
EOF
  local pass_file="${TEST_TMPDIR}/passes.ndjson"
  run "$BATS_WRAPPER" --no-sandbox --pass-out "$pass_file" "${TEST_TMPDIR}/passes.bats"
  assert_success
  # The caller-supplied pass file should carry the passing records.
  [ -f "$pass_file" ]
  run cat "$pass_file"
  assert_output --partial "passing_a"
  assert_output --partial "passing_b"
}

# bats_wrapper_sandbox_denies_localhost_tcp_bind and
# bats_wrapper_allow_local_binding_permits_localhost_tcp_bind were
# removed when the wrapper flipped from sandcastle to fence as its sole
# sandbox backend. Sandcastle enforced "deny localhost TCP bind unless
# --allow-local-binding" via the seccomp filter in gen-bind-block.c.
# Fence's release accepts `network.allowLocalBinding: false` in its
# config schema but does not enforce it — bind() is not in fence's
# seccomp deny set today. Re-add these tests once that gap is closed
# (see https://github.com/amarbel-llc/bats/issues/3).

function bats_wrapper_no_split_restores_tap14_stream { # @test
  cat >"${TEST_TMPDIR}/plan.bats" <<'EOF'
#! /usr/bin/env bats
function passing_one { # @test
  true
}
function failing_one { # @test
  false
}
EOF
  run "$BATS_WRAPPER" --no-split --no-sandbox "${TEST_TMPDIR}/plan.bats"
  assert_failure
  # Plan + version + per-test ok/not ok records all present.
  assert_output --partial "1..2"
  assert_line --regexp "^ok 1 "
  assert_output --partial "not ok 2"
  assert_line --index 0 --regexp "^(TAP version|1\.\.)"
}

# Regression for bats#24: when the caller passes --tap explicitly, the
# wrapper must still reformat to TAP-14 before format-ndjson reads it.
# Previously --tap matched the has_formatter case and use_tap14 stayed
# false, so format-ndjson saw TAP-13 without a version header and
# reported "first line must be TAP version 14" in the summary.
function bats_wrapper_split_summary_valid_when_caller_passes_tap { # @test
  cat >"${TEST_TMPDIR}/explicit_tap.bats" <<'EOF'
#! /usr/bin/env bats
function passing_one { # @test
  true
}
EOF
  local pass_file="${TEST_TMPDIR}/passes.ndjson"
  run "$BATS_WRAPPER" --no-sandbox --tap --pass-out "$pass_file" "${TEST_TMPDIR}/explicit_tap.bats"
  assert_success
  # The summary record lands on stdout alongside any failure records
  # under split mode. Its `valid` field reports parse-validity of the
  # tap-dancer input stream.
  assert_output --partial '"type":"summary"'
  assert_output --partial '"valid":true'
}

# Regression for bats#25: --output is bats's log-dir flag, not a
# formatter. The wrapper must still inject --tap and reformat. Without
# the fix, --output triggered has_formatter and the wrapper produced
# raw bats pretty-printer output (no TAP version header), which then
# corrupted the downstream format-ndjson pipeline.
function bats_wrapper_output_flag_does_not_disable_tap { # @test
  cat >"${TEST_TMPDIR}/with_output.bats" <<'EOF'
#! /usr/bin/env bats
function passing_one { # @test
  true
}
EOF
  local log_dir="${TEST_TMPDIR}/bats-logs"
  mkdir -p "$log_dir"
  # --no-split so we can inspect the raw TAP-14 stream on stdout.
  run "$BATS_WRAPPER" --no-sandbox --no-split --output "$log_dir" "${TEST_TMPDIR}/with_output.bats"
  assert_success
  assert_line --index 0 --regexp "^TAP version 14"
  assert_output --partial "1..1"
  assert_output --partial "ok 1"
}
