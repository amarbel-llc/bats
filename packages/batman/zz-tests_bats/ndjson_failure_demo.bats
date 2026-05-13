#! /usr/bin/env bats

# Artificial-failure demo suite for the `emitNdjson = true` batsLane path.
# Intentionally contains one passing and one failing case so the produced
# `run.ndjson` exercises both `ok: true` and `ok: false` record shapes
# (per amarbel-llc/tap RFC 0001).
#
# NOT picked up by `batman-self-proof` (which globs `*.bats` over this
# same dir today). The new `batman-ndjson-demo` derivation in flake.nix
# selects this file explicitly via `testFiles`.

function ndjson_demo_passes { # @test
  true
}

function ndjson_demo_fails_with_diagnostic { # @test
  run echo "synthetic diagnostic line"
  false
}
