# treefmt-nix module config for bats / batman.
#
# Wired into the flake at flake.nix via `treefmtEval`, exposed as
# `formatter.${system}` (`nix fmt`) and as `checks.${system}.formatting`
# so `nix flake check` (= `just validate-flake`) catches drift.
# `just codemod-fmt` routes through here via `nix fmt`.
#
# Scope: only amarbel-llc-owned files. Bats-core upstream paths
# (lib/bats-core/, libexec/, test/, contrib/, docker/, bin/,
# install.sh, uninstall.sh, etc.) are excluded so this fork can keep
# tracking github.com/bats-core/bats-core without per-pull reformat
# conflicts.
{
  projectRootFile = "flake.nix";

  programs.nixfmt.enable = true;

  programs.shfmt = {
    enable = true;
    indent_size = 2;
  };

  settings.global.excludes = [
    # Build / lock / generated artifacts.
    "flake.lock"
    "result"
    "result-*"
    ".direnv/**"
    ".tmp/**"

    # Version + license files.
    "LICENSE"
    "LICENSE.md"
    "version.env"

    # Markup we don't yet have a formatter for.
    "*.md"
    "*.bats"
    "*.scd"

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
    "SECURITY.md"
    "README.md"
    ".pre-commit-config.yaml"
    ".readthedocs.yml"
    ".codespellrc"
    ".gitattributes"
  ];
}
