#!/usr/bin/env bats

function curl_anywhere_fails { # @test
  run curl -fsSL --max-time 5 https://example.com
  [ "$status" -ne 0 ]
}
