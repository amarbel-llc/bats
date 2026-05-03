{
  pkgs,
  src,
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

  bats = pkgs.writeShellApplication {
    name = "bats";
    runtimeInputs = [
      pkgs.bats
      pkgs.coreutils
      pkgs.gawk
      pkgs.git
      pkgs.parallel
      pkgs.python3
      tap-dancer-go
      fence
    ];
    text = ''
      # --query-sandbox: report the active sandbox backend.
      # Always "fence" since this build wraps every test command in
      # `fence --settings <cfg> -- bats <args>` (unless --no-sandbox is
      # passed at runtime, in which case the wrapper bypasses fence).
      if [[ "''${1:-}" == "--query-sandbox" ]]; then
        echo "fence"
        exit 0
      fi

      bin_dirs=()
      sandbox=true
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

      if $sandbox; then
        config="$(mktemp --suffix=.json)"
        trap 'rm -f "$config"' EXIT

        # fence config: denyRead blocks credential dirs; allowWrite
        # restricts writes to /tmp; empty allowedDomains denies all
        # network egress; allowLocalBinding toggled by
        # --allow-local-binding. allowRead/allowExecute kept broad so
        # the test process can run nix-store binaries normally — the
        # security boundary is enforced via denyRead. command.useDefaults
        # is false so fence's built-in deny list (which collaterally
        # blocks coreutils via chroot detection) does not interfere
        # with normal shell tools.
        #
        # Note: fence's `network.allowLocalBinding: false` is a
        # documented config field but is NOT seccomp-enforced today
        # (fence's filter blocks dangerous syscalls + TIOCSTI but not
        # bind()). Setting it false is forward-compatible — when fence
        # learns to enforce it, this wrapper benefits automatically.
        cat >"$config" <<FENCE_CONFIG
      {
        "filesystem": {
          "allowRead": ["/"],
          "allowExecute": ["/"],
          "allowWrite": [
            "/tmp",
            "/private/tmp"
          ],
          "denyRead": [
            "~/.ssh",
            "~/.aws",
            "~/.gnupg",
            "~/.config",
            "~/.local",
            "~/.password-store",
            "~/.kube"
          ],
          "denyWrite": []
        },
        "network": {
          "allowedDomains": [],
          "deniedDomains": [],
          "allowLocalBinding": $allow_local_binding
        },
        "command": {
          "useDefaults": false
        }
      }
      FENCE_CONFIG

        if $no_tempdir_cleanup; then
          set -- --no-tempdir-cleanup "$@"
        fi

        fence --settings "$config" -- bats "$@" | filter_tap | reformat_tap
      else
        if $no_tempdir_cleanup; then
          set -- --no-tempdir-cleanup "$@"
        fi
        bats "$@" | filter_tap | reformat_tap
      fi
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
