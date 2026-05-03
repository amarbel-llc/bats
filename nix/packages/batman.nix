{
  pkgs,
  src,
  sandcastle ? null,
  tap-dancer-go,
  fence,
  buildZxScriptFromFile,
}:

let
  inherit (pkgs) lib;

  bats-support = pkgs.stdenvNoCC.mkDerivation {
    pname = "bats-support";
    version = "0.3.0";
    src = "${src}/lib/bats-support";
    nativeBuildInputs = [ pkgs.scdoc ];
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/share/bats/bats-support/src
      cp load.bash $out/share/bats/bats-support/
      cp src/*.bash $out/share/bats/bats-support/src/

      mkdir -p $out/share/man/man7
      scdoc < doc/bats-support.7.scd > $out/share/man/man7/bats-support.7
    '';
  };

  bats-assert = pkgs.stdenvNoCC.mkDerivation {
    pname = "bats-assert";
    version = "2.1.0";
    src = "${src}/lib/bats-assert";
    nativeBuildInputs = [ pkgs.scdoc ];
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/share/bats/bats-assert/src
      cp load.bash $out/share/bats/bats-assert/
      cp src/*.bash $out/share/bats/bats-assert/src/

      mkdir -p $out/share/man/man7
      scdoc < doc/bats-assert.7.scd > $out/share/man/man7/bats-assert.7
    '';
  };

  bats-assert-additions = pkgs.stdenvNoCC.mkDerivation {
    pname = "bats-assert-additions";
    version = "0.1.0";
    src = "${src}/lib/bats-assert-additions";
    nativeBuildInputs = [ pkgs.scdoc ];
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/share/bats/bats-assert-additions/src
      cp load.bash $out/share/bats/bats-assert-additions/
      cp src/*.bash $out/share/bats/bats-assert-additions/src/

      mkdir -p $out/share/man/man7
      scdoc < doc/bats-assert-additions.7.scd > $out/share/man/man7/bats-assert-additions.7
    '';
  };

  tap-writer = pkgs.stdenvNoCC.mkDerivation {
    pname = "tap-writer";
    version = "0.1.0";
    src = "${src}/lib/tap-writer";
    nativeBuildInputs = [ pkgs.scdoc ];
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/share/bats/tap-writer/src
      cp load.bash $out/share/bats/tap-writer/
      cp src/*.bash $out/share/bats/tap-writer/src/

      mkdir -p $out/share/man/man7
      scdoc < doc/tap-writer.7.scd > $out/share/man/man7/tap-writer.7
    '';
  };

  bats-island = pkgs.stdenvNoCC.mkDerivation {
    pname = "bats-island";
    version = "0.1.0";
    src = "${src}/lib/bats-island";
    nativeBuildInputs = [ pkgs.scdoc ];
    dontUnpack = true;
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/share/bats/bats-island/src
      cp $src/load.bash $out/share/bats/bats-island/
      cp $src/src/*.bash $out/share/bats/bats-island/src/

      mkdir -p $out/share/man/man7
      scdoc < $src/doc/bats-island.7.scd > $out/share/man/man7/bats-island.7
    '';
  };

  bats-emo = pkgs.stdenvNoCC.mkDerivation {
    pname = "bats-emo";
    version = "0.1.0";
    src = "${src}/lib/bats-emo";
    nativeBuildInputs = [ pkgs.scdoc ];
    dontUnpack = true;
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/share/bats/bats-emo/src
      cp $src/load.bash $out/share/bats/bats-emo/
      cp $src/src/*.bash $out/share/bats/bats-emo/src/

      mkdir -p $out/share/man/man7
      scdoc < $src/doc/bats-emo.7.scd > $out/share/man/man7/bats-emo.7
    '';
  };

  batman-manpages = pkgs.stdenvNoCC.mkDerivation {
    pname = "batman-manpages";
    version = "0.1.0";
    src = "${src}/doc";
    nativeBuildInputs = [ pkgs.scdoc ];
    dontUnpack = true;
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/share/man/man7
      for f in $src/*.7.scd; do
        scdoc < "$f" > "$out/share/man/man7/$(basename "$f" .scd)"
      done
    '';
  };

  bats-libs = pkgs.symlinkJoin {
    name = "bats-libs";
    paths = [
      bats-support
      bats-assert
      bats-assert-additions
      tap-writer
      bats-island
      bats-emo
    ];
    # Subpath that BATS_LIB_PATH wants directly. Consumers should use
    # this attribute instead of appending "/share/bats" themselves.
    # See bob#126.
    passthru.batsLibPath = "${bats-libs}/share/bats";
  };

  hasSandcastle = sandcastle != null;

  bats = pkgs.writeShellApplication {
    name = "bats";
    runtimeInputs =
      [
        pkgs.bats
        pkgs.coreutils
        pkgs.gawk
        pkgs.git
        pkgs.parallel
        pkgs.python3
        tap-dancer-go
      ]
      ++ lib.optional hasSandcastle sandcastle;
    # When sandcastle is null the sandbox/allow_* variables are parsed
    # but unused (they exist so the CLI surface stays stable across
    # sandboxed and non-sandboxed builds). SC2034 fires on those.
    excludeShellChecks = lib.optionals (!hasSandcastle) [ "SC2034" ];
    text = ''
      # --query-sandcastle: report whether this wrapper was built with
      # a sandcastle dependency. Used by the test suite to skip
      # sandbox-behavior assertions when sandcastle is unavailable.
      if [[ "''${1:-}" == "--query-sandcastle" ]]; then
        echo "${if hasSandcastle then "true" else "false"}"
        exit 0
      fi

      bin_dirs=()
      sandbox=true
      allow_unix_sockets=false
      allow_local_binding=false
      no_tempdir_cleanup=false
      hide_passing=false

      bats_args=()
      while (( $# > 0 )); do
        case "$1" in
          --bin-dir)
            bin_dirs+=("$(realpath "$2")")
            shift 2
            ;;
          --no-sandbox)
            sandbox=false
            shift
            ;;
          --allow-unix-sockets)
            allow_unix_sockets=true
            shift
            ;;
          --allow-local-binding)
            allow_local_binding=true
            shift
            ;;
          --no-tempdir-cleanup)
            no_tempdir_cleanup=true
            shift
            ;;
          --hide-passing)
            hide_passing=true
            shift
            ;;
          --)
            shift
            bats_args+=("$@")
            break
            ;;
          *)
            bats_args+=("$1")
            shift
            ;;
        esac
      done
      set -- "''${bats_args[@]}"

      # Prepend --bin-dir directories to PATH (leftmost = highest priority)
      for (( i = ''${#bin_dirs[@]} - 1; i >= 0; i-- )); do
        export PATH="''${bin_dirs[$i]}:$PATH"
      done

      # Append batman's bats-libs to BATS_LIB_PATH (caller paths take precedence)
      export BATS_LIB_PATH="''${BATS_LIB_PATH:+$BATS_LIB_PATH:}${bats-libs}/share/bats"

      # Default to TAP output unless a formatter flag is already present
      has_formatter=false
      for arg in "$@"; do
        case "$arg" in
          --tap|--formatter|-F|--output) has_formatter=true; break ;;
        esac
      done
      use_tap14=false
      if ! $has_formatter; then
        set -- "$@" --tap
        use_tap14=true
      fi

      filter_tap() {
        if $hide_passing; then
          awk '
            /^  ---$/ { in_yaml = 1; if (show) print; next }
            /^  \.\.\.$/ { in_yaml = 0; if (show) print; next }
            in_yaml { if (show) print; next }
            /^ok / { show = ($0 ~ /# [Ss][Kk][Ii][Pp]/ || $0 ~ /# [Tt][Oo][Dd][Oo]/); if (show) print; next }
            /^not ok / { show = 1; print; next }
            { show = 1; print }
          '
        else
          cat
        fi
      }

      reformat_tap() {
        if $use_tap14; then
          tap-dancer reformat
        else
          cat
        fi
      }

      ${
        if hasSandcastle then
          ''
            if $sandbox; then
              config="$(mktemp)"
              trap 'rm -f "$config"' EXIT

              cat >"$config" <<SANDCASTLE_CONFIG
            {
              "filesystem": {
                "denyRead": [
                  "$HOME/.ssh",
                  "$HOME/.aws",
                  "$HOME/.gnupg",
                  "$HOME/.config",
                  "$HOME/.local",
                  "$HOME/.password-store",
                  "$HOME/.kube"
                ],
                "denyWrite": [],
                "allowWrite": [
                  "/tmp",
                  "/private/tmp"
                ]
              },
              "network": {
                "allowedDomains": [],
                "deniedDomains": []$(if $allow_unix_sockets; then echo ',
                "allowAllUnixSockets": true'; fi)$(if $allow_local_binding; then echo ',
                "allowLocalBinding": true'; fi)
              }
            }
            SANDCASTLE_CONFIG

                  sandcastle_args=()
                  if $no_tempdir_cleanup; then
                    sandcastle_args+=(--no-tempdir-cleanup)
                    set -- --no-tempdir-cleanup "$@"
                  fi

                  sandcastle "''${sandcastle_args[@]}" --shell bash --config "$config" -- bats "$@" | filter_tap | reformat_tap
            else
              if $no_tempdir_cleanup; then
                set -- --no-tempdir-cleanup "$@"
              fi
              bats "$@" | filter_tap | reformat_tap
            fi
          ''
        else
          # No sandcastle available: --no-sandbox / --allow-unix-sockets /
          # --allow-local-binding are accepted as no-ops so callers can use
          # the same CLI surface across sandboxed and non-sandboxed builds.
          ''
            if $no_tempdir_cleanup; then
              set -- --no-tempdir-cleanup "$@"
            fi
            bats "$@" | filter_tap | reformat_tap
          ''
      }
    '';
  };

  batman = buildZxScriptFromFile {
    pname = "batman";
    version = "0.0.1";
    script = "${src}/src/batman.ts";
    runtimeInputs = [
      fence
      pkgs.bats
      pkgs.coreutils
      pkgs.gawk
    ];
  };

in
{
  default = pkgs.symlinkJoin {
    name = "batman";
    paths = [
      bats-libs
      bats
      batman
      batman-manpages
    ];
  };
  inherit
    bats-support
    bats-assert
    bats-assert-additions
    tap-writer
    bats-island
    bats-emo
    bats-libs
    bats
    batman
    batman-manpages
    ;
}
