#!/usr/bin/env bats

setup() {
  load "$BATS_TEST_DIRNAME/common.bash"
  setup_test_home
  export XDG_LOG_HOME="$BATS_TEST_TMPDIR/.xdg/log"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
}

teardown() {
  teardown_test_home
}

function batman_splits_argv_at_double_dash { # @test
  run "$BATMAN_BIN" --dry-run --bin-dir foo "$FIXTURES" -- --filter X
  assert_success
  # Dry-run output should reflect the positional ($FIXTURES) but not the
  # post-`--` flags. The post-`--` flags would never produce GROUP lines.
  assert_output --partial "GROUP $FIXTURES/network-allowed:"
  refute_output --partial "--filter X"
  refute_output --partial "GROUP $FIXTURES/-- "
}

function batman_discovers_and_groups_bats_files { # @test
  run "$BATMAN_BIN" --dry-run "$FIXTURES"
  assert_success
  assert_output --partial "GROUP $FIXTURES/network-allowed: network.bats"
  assert_output --partial "GROUP $FIXTURES/network-blocked: no-network.bats"
  assert_output --partial "GROUP $FIXTURES/no-fence-config: bare.bats"
}

function batman_fails_on_missing_fence_jsonc { # @test
  run --separate-stderr "$BATMAN_BIN" "$FIXTURES/no-fence-config"
  [ "$status" -eq 2 ]
  # Wrapper diagnostic must not appear on stderr.
  refute [ -n "$(echo "$stderr" | grep -F "missing fence.jsonc" || true)" ]

  local log="$XDG_LOG_HOME/batman/batman.log"
  [ -f "$log" ]
  run cat "$log"
  assert_output --partial "missing fence.jsonc"
  assert_output --partial "$FIXTURES/no-fence-config"
}

function batman_runs_passing_test_under_fence_with_network { # @test
  # Skipped: fence's bwrap nests inside the dev-shell wrapped bats's
  # bwrap → fence sandbox init fails. Tracked in
  # https://github.com/amarbel-llc/bob/issues/113 .
  skip "fence + dev-shell bats nested-bwrap; see bob#113"
  run "$BATMAN_BIN" "$FIXTURES/network-allowed"
  assert_success
  assert_output --partial "ok 1 curl_to_example_com_succeeds"
}

function batman_blocks_network_when_fence_denies { # @test
  # Skipped: same reason as the network-allowed sibling. See bob#113.
  skip "fence + dev-shell bats nested-bwrap; see bob#113"
  run "$BATMAN_BIN" "$FIXTURES/network-blocked"
  assert_success
  assert_output --partial "ok 1 curl_anywhere_fails"
}

function batman_aggregates_exit_codes { # @test
  # Skipped: spawns fence; see bob#113.
  skip "fence + dev-shell bats nested-bwrap; see bob#113"
  local fail_dir="$BATS_TEST_TMPDIR/always-fails"
  mkdir -p "$fail_dir"
  cat >"$fail_dir/fence.jsonc" <<'JSON'
{
  "network": { "allowedDomains": [] },
  "filesystem": { "denyRead": [] }
}
JSON
  cat >"$fail_dir/fail.bats" <<'BATS'
#!/usr/bin/env bats

function always_fails { # @test
  false
}
BATS

  run "$BATMAN_BIN" "$FIXTURES/network-blocked" "$fail_dir"
  [ "$status" -eq 1 ]
}
