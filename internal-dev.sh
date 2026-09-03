#!/usr/bin/env bash
# sx INTERNAL DEVELOPER setup — one command on a fresh macOS or Ubuntu machine.
# Not a customer artifact: it clones the private sx repository, which needs a
# Sentient GitHub SSH key. Customers start at https://docs.sentientx.io instead.
#
#   without a checkout: curl -fsSL https://docs.sentientx.io/internal-dev.sh | bash
#                       (clones git@github.com:Sentient-X/sx.git into ./sx)
#   inside a checkout:  ./tools/internal-dev.sh
#
# This file is the one source: the release workflow publishes its exact bytes for
# Mintlify's redirect, while tools/internal-dev.sh is a repository-local symlink.
#
# Installs the core toolchain only where it is missing — just, uv, Java 11+,
# Node 22 + pnpm (via corepack), rustup — then syncs both workspaces with
# `just install`.
# The dev-stack extras (Docker, Helm, kubectl) are checked and reported, never
# auto-installed: `just dev` needs them, `just check` does not.
set -euo pipefail

say() { printf '\033[1;32msx-dev:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31msx-dev:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

say "sx internal developer setup (macOS / Ubuntu) — customers: https://docs.sentientx.io"

case "$(uname -s)" in
  Darwin) os=mac ;;
  Linux)
    have apt-get || die "Linux support covers Ubuntu/Debian (apt) only; install just, uv, node 22, and rustup manually"
    os=ubuntu
    ;;
  *) die "unsupported platform $(uname -s); this script covers macOS and Ubuntu" ;;
esac

# ~/.local/bin is where the no-sudo installers below land.
export PATH="$HOME/.local/bin:$PATH"

if [ "$os" = mac ] && ! have brew; then
  say "installing Homebrew (required for macOS packages)"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
fi

if [ "$os" = ubuntu ]; then
  missing=""
  for tool in git curl ca-certificates; do
    dpkg -s "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    say "installing base packages:$missing"
    sudo apt-get update -qq
    # shellcheck disable=SC2086  # word splitting is the point: one package per word
    sudo apt-get install -y -qq $missing
  fi
fi

if ! have just; then
  say "installing just"
  if [ "$os" = mac ]; then
    brew install just
  else
    # Ubuntu's apt just is years behind the recipes in this repo; use the
    # official prebuilt-binary installer into ~/.local/bin (no sudo).
    mkdir -p "$HOME/.local/bin"
    curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
      | bash -s -- --to "$HOME/.local/bin"
  fi
fi

if ! have uv; then
  say "installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

java_ok() {
  have java || return 1
  java_major="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p')"
  [ -n "$java_major" ] && [ "$java_major" -ge 11 ]
}
if ! java_ok; then
  say "installing Java for executable TLA+ model checking"
  if [ "$os" = mac ]; then
    brew install openjdk@21
    brew link --force --overwrite openjdk@21
  else
    sudo apt-get update -qq
    sudo apt-get install -y -qq default-jre-headless
  fi
  if ! java_ok; then
    say "Java 11+ is still unavailable after installation; fix PATH/JAVA_HOME and retry"
    exit 1
  fi
fi

node_ok() { have node && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ]; }
if ! node_ok; then
  say "installing Node 22"
  if [ "$os" = mac ]; then
    brew install node@22
    brew link --overwrite node@22
  else
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y -qq nodejs
  fi
fi

if ! have pnpm; then
  say "enabling pnpm via corepack (uses the version pinned in package.json)"
  if [ -w "$(dirname "$(command -v node)")" ]; then corepack enable; else sudo corepack enable; fi
fi

if ! have cargo; then
  say "installing rustup (the crates pin their own toolchain via rust-toolchain.toml)"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  . "$HOME/.cargo/env"
fi

# Land in a checkout: already inside one, beside one, or clone fresh.
if [ ! -f justfile ] || [ ! -f pyproject.toml ]; then
  if [ -f sx/justfile ]; then
    cd sx
  else
    say "cloning git@github.com:Sentient-X/sx.git (private; needs your GitHub SSH key)"
    git clone git@github.com:Sentient-X/sx.git sx
    cd sx
  fi
fi

say "initializing the one package submodule"
git submodule update --init packages/sx-embodiments

# The crates pin their toolchain; installing it here means `just check` never waits on a
# rustup download mid-gate. Idempotent when it is already present.
channel=$(sed -n 's/^channel = "\(.*\)"$/\1/p' experience/data-factory/pod/rust-toolchain.toml)
say "installing the pinned Rust toolchain $channel with clippy and rustfmt"
rustup toolchain install "$channel" --profile minimal --component clippy --component rustfmt

say "syncing both workspaces (uv + pnpm) — this resolves several GiB of wheels"
just install

say "done. Toolchain for the dev stack (only needed for 'just dev'):"
for tool in docker helm kubectl; do
  if have "$tool"; then say "  $tool: found"; else say "  $tool: MISSING — install it before running 'just dev'"; fi
done
say "next: 'just check' for the repo gate, 'just dev' for the local stack, bare 'just' to list everything"
