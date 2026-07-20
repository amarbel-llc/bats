{
  pkgs,
  src,
  tap-dancer-go,
  fence,
  buildZxScriptFromFile,
  batmanVersion,
  batmanCommit,
}:

let
  inherit (pkgs) lib;

  # Vendored bats-support/bats-assert keep their upstream-tracking
  # version literals; the rest of the lib derivations + batman itself
  # rebind to batmanVersion via the fork's version.env.
  batsSupportVersion = "0.3.0";
  batsAssertVersion = "2.1.0";

  bats-support = pkgs.stdenvNoCC.mkDerivation {
    pname = "bats-support";
    version = batsSupportVersion;
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
    version = batsAssertVersion;
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
    version = batmanVersion;
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
    version = batmanVersion;
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
    version = batmanVersion;
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
    version = batmanVersion;
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
    version = batmanVersion;
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
      pkgs.socat
      tap-dancer-go
      fence
    ];
    text = ''
      # `version`: print the wrapper's own version + component
      # versions. Sibling to the `batman version` subcommand; uses a
      # positional keyword (not --version) so the upstream bats
      # --version stays reachable by passing --version through bats_args.
      if [[ "''${1:-}" == "version" ]]; then
        cat <<EOF
      batman bats wrapper ${batmanVersion}+${batmanCommit}
      components:
        bats (wrapper):   ${batmanVersion}
        bats (upstream):  ${pkgs.bats.version}
        fence:            ${fence.version}
      EOF
        exit 0
      fi

      # --query-sandbox: report the active sandbox backend.
      # Always "fence" since this build wraps every test command in
      # `fence --settings <cfg> -- bats <args>` (unless --no-sandbox is
      # passed at runtime, in which case the wrapper bypasses fence).
      if [[ "''${1:-}" == "--query-sandbox" ]]; then
        echo "fence"
        exit 0
      fi

      sandbox=true
      allow_local_binding=false
      no_tempdir_cleanup=false
      split=true
      pass_out=""
      config=""

      bats_args=()
      while (( $# > 0 )); do
        case "$1" in
          --no-sandbox)
            sandbox=false
            shift
            ;;
          --allow-local-binding)
            allow_local_binding=true
            shift
            ;;
          --allow-unix-sockets)
            # Deprecated no-op (bats#27): a sandcastle-era flag for
            # pcscd / AF_UNIX socket access. The fence backend has no
            # equivalent toggle, so under fence this flag has always been
            # a no-op; it is accepted for CLI back-compat and ignored.
            # Recognized here rather than forwarded to bats-core, which
            # would reject the unknown option with an opaque "Bad command
            # line option" error before any test runs. (Whether AF_UNIX
            # access still works under fence's policy is a separate
            # question tracked in the issue.)
            echo "bats wrapper: --allow-unix-sockets is deprecated and ignored (no-op); the fence backend has no AF_UNIX toggle. See https://code.linenisgreat.com/bats/issues/27" >&2
            shift
            ;;
          --no-tempdir-cleanup)
            no_tempdir_cleanup=true
            shift
            ;;
          --no-split|--full-output)
            split=false
            shift
            ;;
          --pass-out)
            if (( $# < 2 )); then
              echo "bats wrapper: --pass-out requires a path argument" >&2
              exit 2
            fi
            pass_out="$2"
            shift 2
            ;;
          --pass-out=*)
            pass_out="''${1#--pass-out=}"
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

      # Per-run tmpdir for the passing-test NDJSON when split is on and
      # no caller-supplied path was given. Reported on stderr so an
      # interactive user can find it. Cleaned with the wrapper's EXIT
      # trap unless --no-tempdir-cleanup is set.
      pass_tmp=""
      if $split && [[ -z "$pass_out" ]]; then
        pass_tmp="$(mktemp -d --suffix=.batman)"
        pass_out="$pass_tmp/passes.ndjson"
        echo "bats wrapper: passing-test NDJSON -> $pass_out" >&2
      fi

      cleanup() {
        if [[ -n "$config" ]]; then
          rm -f "$config"
        fi
        if [[ -n "$pass_tmp" ]] && ! $no_tempdir_cleanup; then
          rm -rf "$pass_tmp"
        fi
      }
      trap cleanup EXIT

      # Append batman's bats-libs to BATS_LIB_PATH (caller paths take precedence)
      export BATS_LIB_PATH="''${BATS_LIB_PATH:+$BATS_LIB_PATH:}${bats-libs}/share/bats"

      # Detect whether the caller already chose a formatter. `--output`
      # is bats's log-dir flag, not a formatter, so it is intentionally
      # absent from this case (see bats#25).
      has_formatter=false
      for arg in "$@"; do
        case "$arg" in
          --tap|--formatter|-F) has_formatter=true; break ;;
        esac
      done

      # Pick the bats formatter that feeds the pipeline.
      #
      # Under split mode the bats output is an intermediate consumed by
      # `tap-dancer format-ndjson`; the caller never sees it on stdout.
      # tap13 is the only bats formatter that emits YAML diagnostic
      # blocks, which format-ndjson lifts into each failing record's
      # `diagnostic`/`output` fields. The legacy `tap` formatter (the
      # target of `--tap`/`-t`) emits none, so failures came out as
      # `"diagnostic":null` with no debuggable reason (bats#31). So
      # under split we force tap13 regardless of any caller-supplied
      # formatter — bats's parser is last-wins on the formatter, so the
      # appended flag overrides an earlier `--tap`/`-F`.
      #
      # Under --no-split the caller sees the raw stream, so honor their
      # formatter choice and only inject `--tap` when they picked none.
      if $split; then
        set -- "$@" --formatter tap13
      elif ! $has_formatter; then
        set -- "$@" --tap
      fi

      # `tap-dancer reformat` prepends a `TAP version 14` header. The
      # split pipeline downstream (`tap-dancer format-ndjson --split`)
      # rejects input without it, so when split is on we always
      # reformat. When split is off, only reformat if we injected
      # `--tap` ourselves; that preserves the legacy "caller-supplied
      # formatter passes through untouched" contract.
      use_tap14=false
      if $split || ! $has_formatter; then
        use_tap14=true
      fi

      reformat_tap() {
        if $use_tap14; then
          tap-dancer reformat
        else
          cat
        fi
      }

      split_or_passthrough() {
        if $split; then
          tap-dancer format-ndjson --split --pass-out "$pass_out"
        else
          cat
        fi
      }

      if $sandbox; then
        config="$(mktemp --suffix=.json)"

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

        fence --settings "$config" -- ${pkgs.bats}/bin/bats "$@" | reformat_tap | split_or_passthrough
      else
        if $no_tempdir_cleanup; then
          set -- --no-tempdir-cleanup "$@"
        fi
        bats "$@" | reformat_tap | split_or_passthrough
      fi
    '';
  };

  batman = buildZxScriptFromFile {
    pname = "batman";
    version = batmanVersion;
    script = "${src}/src/batman.ts";
    runtimeInputs = [
      fence
      pkgs.bats
      pkgs.coreutils
      pkgs.gawk
    ];
    # Component versions consumed by batman.ts's `version` subcommand.
    # Keep BATMAN_* prefix uniform so future iteration / serialization
    # can walk these generically. See docs/eng-versioning(7).
    runtimeEnv = {
      BATMAN_VERSION = batmanVersion;
      BATMAN_COMMIT = batmanCommit;
      BATMAN_BATS_WRAPPER_VERSION = batmanVersion;
      BATMAN_BATS_UPSTREAM_VERSION = pkgs.bats.version;
      BATMAN_BATS_SUPPORT_VERSION = batsSupportVersion;
      BATMAN_BATS_ASSERT_VERSION = batsAssertVersion;
      BATMAN_BATS_ASSERT_ADDITIONS_VERSION = batmanVersion;
      BATMAN_TAP_WRITER_VERSION = batmanVersion;
      BATMAN_BATS_ISLAND_VERSION = batmanVersion;
      BATMAN_BATS_EMO_VERSION = batmanVersion;
      BATMAN_FENCE_VERSION = fence.version;
      BATMAN_TAP_DANCER_VERSION = tap-dancer-go.version;
    };
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
