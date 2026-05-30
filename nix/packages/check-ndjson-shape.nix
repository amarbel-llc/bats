# Flake check (amarbel-llc/bats#13): validate the batsLane `emitNdjson`
# pipeline end-to-end against the actual pinned tap-dancer.
#
# Consumes the artifact directory of a SOFT ndjson lane — the
# deliberately-failing demo suite run with `failOnTestFailure = false`,
# so the build succeeds and leaves the captured NDJSON in place — and
# asserts the RFC-0001 record shape with jq. Fails `nix flake check`
# when tap-dancer's output drifts from the schema the lane promises.
# This is the gate for promoting FDR-0003 from `experimental` to
# `testing`.
#
# Expected records come from
# packages/batman/zz-tests_bats/ndjson_failure_demo.bats: one passing
# test (ndjson_demo_passes) and one failing test with a diagnostic
# (ndjson_demo_fails_with_diagnostic). Split routing (observed
# empirically from the pinned tap-dancer's `format-ndjson --split`
# output) sends the passing test record to run.passes.ndjson, the
# failing test record to run.failures.ndjson, and the trailing summary
# record to BOTH files. The assertions below therefore tolerate the
# summary appearing in the passes stream.
{ pkgs, ndjsonDir }:
pkgs.runCommandLocal "batman-ndjson-shape"
  {
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    passes="${ndjsonDir}/run.passes.ndjson"
    failures="${ndjsonDir}/run.failures.ndjson"

    echo "--- run.passes.ndjson ---" >&2
    cat "$passes" >&2 || true
    echo "--- run.failures.ndjson ---" >&2
    cat "$failures" >&2 || true

    assert() {
      local desc="$1"
      shift
      if ! "$@" >/dev/null; then
        echo "batman-ndjson-shape: ASSERTION FAILED: $desc" >&2
        exit 1
      fi
    }

    # The soft demo exercised a deliberately-failing suite: exit_code
    # must be 1, otherwise the failure path was never hit and every
    # downstream assertion would be vacuously checking an all-pass run.
    ec="$(cat "${ndjsonDir}/exit_code")"
    if [ "$ec" != "1" ]; then
      echo "batman-ndjson-shape: expected demo exit_code 1, got '$ec'" >&2
      exit 1
    fi

    # passes file: holds the passing test record (plus the summary, which
    # split routes to both streams). Assert at least one passing test, no
    # failing test record leaked in, and the demo's passing case by name.
    assert "passes file has a passing test and no failing test record" \
      jq -se 'any(.[]; .type == "test" and .ok == true)
                and all(.[]; (.type != "test") or (.ok == true))' "$passes"
    assert "passes file includes ndjson_demo_passes" \
      jq -se 'any(.[]; .description == "ndjson_demo_passes")' "$passes"

    # failures file: exactly one summary record (split routes the summary
    # here); >=1 failing test carrying a non-empty diagnostic.message
    # (the agent-triage affordance); no passing test leaked in.
    assert "failures file has exactly one summary record" \
      jq -se 'map(select(.type == "summary")) | length == 1' "$failures"
    assert "failures file has a failing test with a diagnostic message" \
      jq -se 'any(.[]; .type == "test" and .ok == false and ((.diagnostic.message // "") | length > 0))' "$failures"
    assert "no passing test leaked into the failures file" \
      jq -se 'all(.[]; (.type == "test" and .ok == true) | not)' "$failures"

    # summary record: counts match the demo (1 pass + 1 fail) and the
    # stream parsed cleanly. valid == true also guards the bats#24
    # version-header regression — reformat must prepend `TAP version 14`
    # before format-ndjson, or the parser emits an error-severity
    # diagnostic and flips valid to false.
    assert "summary counts + validity match the demo" \
      jq -se 'map(select(.type == "summary"))[0]
                | .valid == true and .passed == 1 and .failed == 1
                  and .total == 2 and .bailed == false' "$failures"

    # Healthy run: no batsLane synthetic stage-error records in either
    # stream. Guards the negative case of the #14 error path — a
    # {"type":"error",...} record must appear only when reformat or
    # format-ndjson actually fails, never on a clean pipeline.
    assert "no batsLane error records in the passes file" \
      jq -se 'all(.[]; .type != "error")' "$passes"
    assert "no batsLane error records in the failures file" \
      jq -se 'all(.[]; .type != "error")' "$failures"

    mkdir -p "$out"
    echo ok > "$out/result.txt"
  ''
