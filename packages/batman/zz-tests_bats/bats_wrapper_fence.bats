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
  if [[ -n ${HOST_SOCK_PID:-} ]]; then
    kill "$HOST_SOCK_PID" 2>/dev/null || true
    wait "$HOST_SOCK_PID" 2>/dev/null || true
  fi
  [[ -n ${SOCK_DIR:-} ]] && rm -rf "$SOCK_DIR"
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

# Start a host-side AF_UNIX echo listener under /tmp (outside the
# sandbox) and run an inner bats file that connects to it from inside
# fence, forwarding any extra wrapper flags. The socket path is baked
# into the inner .bats file rather than exported, and socat is referenced
# by absolute path, so the assertion does not depend on env or PATH
# surviving fence.
assert_sandboxed_connect_to_host_socket() {
  local socat_bin
  socat_bin="$(command -v socat || true)"
  [[ -n $socat_bin ]] || skip "socat not on PATH"

  # Deliberately NOT under $TEST_TMPDIR: AF_UNIX sun_path caps at 108
  # bytes and TMPDIR in a worktree session is already ~70 (bats#37), so
  # a socket under it silently truncates. Keep the path short and fixed.
  SOCK_DIR="$(mktemp -d /tmp/bws-XXXXXX)"
  local sock="${SOCK_DIR}/host.sock"
  "$socat_bin" UNIX-LISTEN:"$sock",fork SYSTEM:'echo PONG' &
  HOST_SOCK_PID=$!

  local waited=0
  while [[ ! -S $sock ]]; do
    sleep 0.1
    waited=$((waited + 1))
    ((waited < 50)) || fail "host-side socket never appeared at $sock"
  done

  cat >"${TEST_TMPDIR}/connect.bats" <<EOF
#! /usr/bin/env bats
function connects_to_host_socket { # @test
  reply="\$("$socat_bin" -T5 - UNIX-CONNECT:"$sock" </dev/null)"
  [ "\$reply" = "PONG" ]
}
EOF
  run "$BATS_WRAPPER" "$@" --no-split --tap "${TEST_TMPDIR}/connect.bats"
  assert_success
  assert_output --partial "ok 1"
}

# A process inside the fence sandbox must be able to connect directly to
# an AF_UNIX socket created on the host, outside the sandbox. This is the
# shape amarbel-llc/piggy depends on (piggy-ids reaching fibby's PCSC
# socket) and the shape reported broken under nixpkgs f13ff45 but working
# under 567a49d — see piggy#253.
function bats_wrapper_connects_to_host_created_unix_socket { # @test
  skip_unless_sandbox
  assert_sandboxed_connect_to_host_socket
}

# Same assertion with --allow-local-binding, which flips
# network.allowLocalBinding in the emitted fence config. piggy's failing
# lane passes this flag, and on Linux fence warns that local-outbound
# handling puts the sandbox in its own network namespace — so the two
# variants are kept separate to tell a namespace-driven failure apart
# from a plain one.
function bats_wrapper_connects_to_host_created_unix_socket_with_local_binding { # @test
  skip_unless_sandbox
  assert_sandboxed_connect_to_host_socket --allow-local-binding
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
