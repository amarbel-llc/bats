# Regression check: bats-libs.batsLibPath must be a directory that
# bats accepts directly as a BATS_LIB_PATH entry — i.e. consumers
# should NOT need to append "/share/bats" themselves. See bob#126.
{ pkgs, bats-libs }:
pkgs.runCommandLocal "check-bats-libs-path"
  {
    nativeBuildInputs = [ pkgs.bats ];
    batsLibPath = bats-libs.batsLibPath;
  }
  ''
    test_file="$(mktemp --suffix=.bats)"
    cat >"$test_file" <<'BATS'
    @test "bats can load bats-support via BATS_LIB_PATH" {
      bats_load_library bats-support
    }
    @test "bats can load bats-assert via BATS_LIB_PATH" {
      bats_load_library bats-assert
    }
    BATS

    BATS_LIB_PATH="$batsLibPath" bats "$test_file"
    mkdir -p "$out"
    echo ok > "$out/result.txt"
  ''
