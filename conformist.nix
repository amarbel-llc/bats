# bats / batman conformist overlay, merged with conformist.lib.presets.eng
# in flake.nix (conformist.lib.evalModule). presets.eng enables the
# eng-convention linters. Here live the repo-specific formatters and the
# bats-core-upstream excludes.
{ pkgs, ... }:
{
  programs.nixfmt.enable = true;

  # shfmt: a raw stanza rather than `programs.shfmt.enable`. The module cannot
  # emit `-ci` (no option for it), so we set the full eng shell style here:
  # 2-space indent, simplify, case-branch indent; over *.sh / *.bash.
  # *.bats is excluded globally (see settings.excludes) so the bats-core
  # upstream tree is not reformatted.
  settings.formatter.shfmt = {
    command = "${pkgs.shfmt}/bin/shfmt";
    options = [
      "-w"
      "-i"
      "2"
      "-s"
      "-ci"
    ];
    includes = [
      "*.sh"
      "*.bash"
    ];
  };

  linters.eng-versioning.key = "BATMAN_VERSION";

  # Excludes layered on conformist's default-excludes (*.lock, LICENSE, etc.).
  # Mirrors treefmt.nix's settings.global.excludes: build/scratch artifacts
  # plus the bats-core upstream tree that this fork tracks without reformatting.
  settings.excludes = [
    # Build / lock / generated artifacts.
    "result"
    "result-*"
    ".direnv/**"
    ".tmp/**"

    # Version + license files (LICENSE is in conformist's default-excludes; LICENSE.md is not).
    "LICENSE.md"
    "version.env"

    # Markup and file types we don't have a formatter for.
    "*.md"
    "*.bats"
    "*.scd"

    # Vendored upstream lib copies — excluded so the fork can diff cleanly
    # against bats-core/bats-{support,assert} without per-bump reformat conflicts.
    "packages/batman/lib/bats-assert/**"
    "packages/batman/lib/bats-support/**"

    # Bats-core upstream tree (tracks bats-core/bats-core).
    "bin/**"
    "lib/bats-core/**"
    "libexec/**"
    "test/**"
    "contrib/**"
    "docker/**"
    "man/**"
    ".devcontainer/**"
    "install.sh"
    "uninstall.sh"
    "shellcheck.sh"
    "Dockerfile"
    "compose.yaml"
    "compose.override.dist"
    "package.json"
    "AUTHORS"
    ".pre-commit-config.yaml"
    ".readthedocs.yml"
    ".codespellrc"
    ".gitattributes"
  ];
}
