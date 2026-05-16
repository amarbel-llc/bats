/**
  bats-test build-support library.

  Exposes `batsLane` — a derivation that runs a bats integration suite
  against a pre-built binary inside the nix build sandbox. Used by
  consumers (madder, dodder, …) to surface per-tag test lanes as flake
  outputs without rebuilding Go per filter.

  The builder takes one or more binaries by store-path reference,
  stages the bats source tree into a writable scratch dir, exports
  caller-named env vars pointing at each binary, optionally extends
  `BATS_LIB_PATH`, and runs bats against a caller-controlled list of
  test files (default `*.bats`) with an optional `--filter-tags`
  expression. Output is a stamp file (touched on success).

  Two binary-export forms are accepted:
  - **single-binary shortcut**: `base` + `binaryName` + (optional)
    `binaryEnvVarName`. The most common case.
  - **multi-binary**: `binaries` map of ENV_VAR_NAME → { base; name; }.
    Use when a suite needs more than one binary in scope, or when the
    binaries live in different derivations.

  When `binaries` is set, the shortcut args are ignored except `base`
  is still consulted as the naming anchor for the default derivation
  name.

  See amarbel-llc/nixpkgs#14 for the design rationale. This file is a
  copy of that nixpkgs build-support module, lifted into amarbel-llc/bats
  so downstream flakes can consume `batsLane` directly from the bats
  flake without depending on the amarbel-llc/nixpkgs overlay.
*/
{
  lib,
  runCommand,
  bats,
  parallel,
  # Optional default for `tap-dancer-go`, the derivation that ships the
  # `tap-dancer` binary used by `emitNdjson`. Callers that never set
  # `emitNdjson = true` can leave this null. flake.nix in this repo passes
  # the real derivation so downstream consumers can flip `emitNdjson` per
  # lane without re-importing this file.
  tap-dancer-go ? null,
}:

let
  defaultBats = bats;
  defaultTapDancerGo = tap-dancer-go;

  # Sanitize a bats `--filter-tags` expression for use as a derivation
  # name suffix. Replaces shell-unfriendly characters with `_`.
  sanitizeFilter =
    filter:
    builtins.replaceStrings
      [ "!" "," ":" " " ]
      [ "not_" "_" "_" "_" ]
      filter;

  batsLane =
    {
      # Single-binary shortcut: pre-built derivation containing the
      # binary under test at ${base}/bin/${binaryName}. Caller is
      # responsible for ensuring `base` is built (typically a
      # buildGoApplication-derived derivation). Also used as the naming
      # anchor for the default derivation name (`${base.pname}-bats-...`)
      # — left consulted even when `binaries` is set.
      base ? null,

      # Directory containing the *.bats test files. Copied recursively
      # into the staging scratch dir.
      batsSrc,

      # Single-binary shortcut: subpath under ${base}/bin that the
      # test binary lives at.
      binaryName ? null,

      # `bats --filter-tags` expression. Empty string means no filter
      # (run all tests). The flag is conditionally omitted when empty.
      filter ? "",

      # Override the derivation name. When null, the name is
      # `${base.pname}-bats-${suffix}` where suffix is derived from
      # `filter` (sanitized) or "all" if filter is empty.
      name ? null,

      # Bats binary to invoke. Defaults to nixpkgs's `pkgs.bats`.
      # Caller can override with a wrapper (e.g. amarbel-llc/bob's
      # batman) — but the wrapper's flags must be compatible with the
      # invocation below (`--jobs`, optional `--filter-tags`, `*.bats`).
      bats ? defaultBats,

      # Entries appended to BATS_LIB_PATH (colon-joined). Each entry
      # should be a derivation or path containing a `share/bats`-style
      # layout that bats's `bats_load_library` resolves against.
      # When empty, BATS_LIB_PATH is left unchanged.
      batsLibPath ? [ ],

      # Single-binary shortcut: name of the env var set to
      # ${base}/bin/${binaryName}. Tests consult this var to locate the
      # binary under test (madder reads MADDER_BIN; consumers pick
      # whatever name their tests expect). Ignored when `binaries` is
      # set.
      binaryEnvVarName ? "BATS_BIN",

      # Multi-binary form: map of ENV_VAR_NAME → { base; name; }. Each
      # entry exports `<ENV_VAR_NAME>=${spec.base}/bin/${spec.name}`
      # before bats runs. Use this when a suite needs more than one
      # binary in scope (e.g. a CLI plus a sibling tool), or when the
      # binaries live in different derivations. When set, supersedes
      # the single-binary shortcut args (`base`/`binaryName`/
      # `binaryEnvVarName` are ignored for env-var purposes; `base` is
      # still used as a naming anchor if present).
      binaries ? null,

      # Additional env vars to export before invoking bats. Map of
      # NAME → value. Values are shell-escaped via lib.escapeShellArg.
      # Use for BATS_TEST_TIMEOUT, custom debug flags, config toggles.
      extraEnv ? { },

      # Extra args appended to the `bats` invocation, after `--jobs`
      # and `--filter-tags` and before the test-file arguments. Each
      # entry is shell-escaped. Use for `--tag-expr`,
      # `--no-parallelize-within-files`, `--print-output-on-failure`,
      # and other bats flags the builder doesn't surface as first-class
      # args.
      extraBatsArgs ? [ ],

      # Trailing positional arguments handed to bats — paths or shell
      # globs (relative to `stage/zz-tests_bats/`) of the test files to
      # run. Entries are joined with spaces and NOT shell-escaped, so
      # bash expands globs as usual. Default `[ "*.bats" ]` keeps the
      # flat-layout behavior; consumers with nested suites can pass
      # something like
      # `[ "current_version/*.bats" "previous_versions/main.bats" ]`.
      testFiles ? [ "*.bats" ],

      # Additional files to copy into the staging dir alongside the
      # bats sources. Each entry is { src; dest; } where `dest` is a
      # path relative to the staging root (which contains the
      # zz-tests_bats/ subdir). Use this for side-channel files like
      # version manifests that tests read via $BATS_TEST_DIRNAME/...
      extraStagedFiles ? [ ],

      # Extra build-time tools the bats helpers need (jq, curl, etc.).
      nativeBuildInputs ? [ ],

      # Opt-in: capture the bats TAP-14 stream and convert it to NDJSON
      # alongside the run. When true, `$out` becomes a DIRECTORY containing
      # `run.raw.tap`, `run.tap`, `exit_code`, and one of:
      #   - `run.failures.ndjson` + `run.passes.ndjson` when `splitNdjson`
      #     is true (the default), or
      #   - `run.ndjson` (combined records) when `splitNdjson` is false.
      # When `emitNdjson` itself is false (the original default), `$out`
      # remains a single stamp file as before. Existing consumers that
      # `stat result` as a file are unaffected unless they opt in.
      #
      # Requires `tap-dancer-go` either as a top-level arg of this file
      # (the default plumbed by flake.nix) or as a per-call override
      # `tapDancerGo = ...`. When both are null, this builder throws.
      #
      # The NDJSON schema is defined in amarbel-llc/tap, RFC 0001
      # (`docs/rfcs/0001-test-result-ndjson-schema.md`).
      emitNdjson ? false,

      # When `emitNdjson` is true, split NDJSON records into
      # `$out/run.failures.ndjson` (failures + bail-outs) and
      # `$out/run.passes.ndjson` (passing records) via
      # `tap-dancer format-ndjson --split`. Defaults to true so build
      # logs (and the inline stderr echo) aren't drowned in pass
      # records. Set false to keep the combined `run.ndjson` and full
      # inline echo of every record.
      splitNdjson ? true,

      # Per-call override of the `tap-dancer-go` derivation used when
      # `emitNdjson = true`. Falls back to the top-level `tap-dancer-go`
      # arg of this file. Ignored when `emitNdjson = false`.
      tapDancerGo ? defaultTapDancerGo,
    }:
    let
      # Single-binary shortcut synthesizes into the multi-binary form
      # so there's only one downstream code path.
      resolvedBinaries =
        if binaries != null then
          binaries
        else if base != null && binaryName != null then
          { ${binaryEnvVarName} = { inherit base; name = binaryName; }; }
        else
          throw "testers.batsLane: either `binaries` or both `base` and `binaryName` must be set";

      # Naming anchor for the default derivation name. Prefer top-level
      # `base.pname` (works for both shortcut and multi-binary forms);
      # fall back to the first entry's base.pname when `binaries` is
      # the only form set.
      namingPname =
        if base != null then
          base.pname
        else
          (lib.head (lib.attrValues resolvedBinaries)).base.pname;

      derivedSuffix =
        if filter != "" then sanitizeFilter filter else "all";

      derivationName =
        if name != null then name else "${namingPname}-bats-${derivedSuffix}";

      binaryExports =
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList
            (envVar: spec: ''export ${envVar}="${spec.base}/bin/${spec.name}"'')
            resolvedBinaries
        );

      libPathExport =
        lib.optionalString (batsLibPath != [ ]) ''
          export BATS_LIB_PATH="''${BATS_LIB_PATH:+$BATS_LIB_PATH:}${
            lib.concatStringsSep ":" (map toString batsLibPath)
          }"
        '';

      filterFlag =
        lib.optionalString (filter != "") "--filter-tags '${filter}'";

      extraEnvExports =
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList
            (name: value: "export ${name}=${lib.escapeShellArg value}")
            extraEnv
        );

      extraBatsArgsStr =
        lib.concatMapStringsSep " " lib.escapeShellArg extraBatsArgs;

      testFilesStr = lib.concatStringsSep " " testFiles;

      # `dest` may include parent directories (e.g.
      # "subdir/foo.lua"); ensure the parent exists before cp so
      # nested layouts work. The flat case is unaffected — `dirname`
      # of a bare filename is ".", and `mkdir -p stage/.` is a no-op.
      extraStagingCommands =
        lib.concatMapStringsSep "\n"
          (entry: ''
            mkdir -p "stage/$(dirname ${entry.dest})"
            cp ${entry.src} stage/${entry.dest}
          '')
          extraStagedFiles;

      # When emitNdjson is on we force bats to emit `tap13` — the
      # tap13 formatter is what gives us YAML diagnostic blocks on
      # failures, which format-ndjson lifts into the record's
      # `diagnostic` / `output` fields. bats-core's --tap formatter
      # produces neither the YAML blocks nor a TAP version header, so
      # the resulting NDJSON records have null diagnostics.
      #
      # Honor a caller-supplied formatter in `extraBatsArgs` rather
      # than override it — if the consumer asked for junit or a
      # custom formatter, that's their call (format-ndjson will fail
      # cleanly on unexpected input).
      callerSetsFormatter =
        builtins.any
          (a: a == "--tap" || a == "-t" || a == "--formatter" || a == "-F" || a == "--output")
          extraBatsArgs;
      formatterFlag =
        if emitNdjson && !callerSetsFormatter then "--formatter tap13" else "";

      ndjsonInputs = lib.optionals emitNdjson [ tapDancerGo ];

      # Stamp-file form (back-compat): bats failure → derivation failure;
      # $out is an empty regular file on success.
      stampInvocation = ''
        cd stage/zz-tests_bats
        ${bats}/bin/bats \
          --jobs $NIX_BUILD_CORES \
          ${filterFlag} \
          ${extraBatsArgsStr} \
          ${testFilesStr}

        touch $out
      '';

      # NDJSON form: $out is a directory carrying `run.raw.tap`,
      # `run.tap`, NDJSON records (split or combined), and `exit_code`.
      # The pipeline is:
      #
      #   bats --formatter tap13 ...  → run.raw.tap   (TAP-13 + YAML)
      #   tap-dancer reformat         → run.tap       (TAP-14 header prepended)
      #   tap-dancer format-ndjson    → split or combined NDJSON
      #
      # When `splitNdjson` is true (the default), `format-ndjson --split`
      # writes failure records to `run.failures.ndjson` (stdout) and
      # passing records to `run.passes.ndjson` (--pass-out). The inline
      # stderr echo then carries only the failure records, keeping the
      # build log focused on what went wrong.
      #
      # When `splitNdjson` is false, the original combined behavior is
      # preserved: every record lands in `run.ndjson` and is echoed
      # inline.
      #
      # We disable errexit around the bats call so a failed test run
      # still gets converted to NDJSON before the derivation exits
      # with the bats status. On bats failure the directory is only
      # preserved via `nix build --keep-failed`. The bats exit status
      # is the gating signal; reformat/format-ndjson exit codes are
      # ignored so we don't double-fail or mask the bats outcome.
      ndjsonRenderStep =
        if splitNdjson then
          ''
            ${tapDancerGo}/bin/tap-dancer format-ndjson --split \
              --pass-out "$out/run.passes.ndjson" \
              < "$out/run.tap" > "$out/run.failures.ndjson" || true
            # Ensure both files exist even on all-pass / all-fail runs,
            # so downstream consumers can unconditionally read them.
            [ -e "$out/run.failures.ndjson" ] || : > "$out/run.failures.ndjson"
            [ -e "$out/run.passes.ndjson" ] || : > "$out/run.passes.ndjson"
          ''
        else
          ''
            ${tapDancerGo}/bin/tap-dancer format-ndjson \
              < "$out/run.tap" > "$out/run.ndjson" || true
          '';
      ndjsonEchoStep =
        if splitNdjson then
          ''
            printf '%s\n' '>>> BATSLANE NDJSON BEGIN <<<' >&2
            cat "$out/run.failures.ndjson" >&2
            pass_count=$(wc -l < "$out/run.passes.ndjson" | tr -d ' ')
            printf 'passes: %s record(s) at %s\n' "$pass_count" "$out/run.passes.ndjson" >&2
            printf '%s\n' '>>> BATSLANE NDJSON END <<<' >&2
          ''
        else
          ''
            printf '%s\n' '>>> BATSLANE NDJSON BEGIN <<<' >&2
            cat "$out/run.ndjson" >&2
            printf '%s\n' '>>> BATSLANE NDJSON END <<<' >&2
          '';
      ndjsonInvocation = ''
        mkdir -p "$out"
        cd stage/zz-tests_bats
        set +o errexit
        ${bats}/bin/bats \
          --jobs $NIX_BUILD_CORES \
          ${filterFlag} \
          ${extraBatsArgsStr} \
          ${formatterFlag} \
          ${testFilesStr} \
          > "$out/run.raw.tap"
        bats_status=$?
        set -o errexit
        ${tapDancerGo}/bin/tap-dancer reformat \
          < "$out/run.raw.tap" > "$out/run.tap" || cp "$out/run.raw.tap" "$out/run.tap"
        ${ndjsonRenderStep}
        echo "$bats_status" > "$out/exit_code"
        # Echo NDJSON to stderr between sentinel markers so the nix
        # builder log carries the captured records inline. On failure,
        # `nix build` prints the build-log tail to the user
        # automatically; for any run, `nix log <drv>` retrieves the
        # full log including this block. Agents extracting the NDJSON
        # programmatically can sed/awk between the BEGIN/END markers.
        ${ndjsonEchoStep}
        exit "$bats_status"
      '';

      batsInvocation = if emitNdjson then ndjsonInvocation else stampInvocation;
    in
    if emitNdjson && tapDancerGo == null then
      throw "testers.batsLane: emitNdjson = true requires `tap-dancer-go` (top-level arg) or `tapDancerGo` (per-call override) to be set"
    else
      runCommand derivationName
        {
          # parallel is required by `bats --jobs` (>1); included
          # unconditionally so consumers don't get a runtime
          # "parallel: command not found" surprise.
          nativeBuildInputs = nativeBuildInputs ++ [ parallel ] ++ ndjsonInputs;
        }
        ''
          mkdir -p stage/zz-tests_bats
          cp -r ${batsSrc}/* stage/zz-tests_bats/
          chmod -R u+w stage

          ${extraStagingCommands}

          ${binaryExports}
          ${libPathExport}
          ${extraEnvExports}

          ${batsInvocation}
        '';

in
{
  inherit batsLane;
}
