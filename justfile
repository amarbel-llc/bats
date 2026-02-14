# bats-core

default:
    @just --list

# Run tests
test *ARGS:
    nix develop --command bats test/ {{ARGS}}

# Check with shellcheck
check:
    nix develop --command shellcheck lib/*.bash libexec/*

# Format with shfmt
fmt:
    nix develop --command shfmt -w -i 2 -ci lib/*.bash libexec/*

# Clean build artifacts
clean:
    rm -rf result
