#!/usr/bin/env bats

function curl_to_example_com_succeeds { # @test
  run curl -fsSL --max-time 5 https://example.com
  [ "$status" -eq 0 ]
}
