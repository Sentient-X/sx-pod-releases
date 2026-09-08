#!/bin/sh
# Install the hosted sx CLI and MCP server without system Python or pip.
# curl -fsSL https://docs.sentientx.io/install.sh | sh
set -eu

fail() {
    printf 'sx: %s\n' "$*" >&2
    exit 1
}

download() {
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --fail --silent --show-error --location --retry 3 \
        --connect-timeout 20 "$1" --output "$2"
}

main() {
    [ "$#" -le 1 ] || fail 'Use --help for installer options.'
    case "${1:-}" in
        --help|-h)
            cat <<'HELP'
Install sx on Linux or macOS (x86_64 or ARM64):
  curl -fsSL https://docs.sentientx.io/install.sh | sh

Run the same command again to update.
Environment:
  SX_INSTALL_DIR      Command directory (default: ~/.local/bin)
  SX_NO_MODIFY_PATH   Set to 1 to leave shell profiles unchanged (CI/containers)
  SX_INSTALL_PACKAGE Explicit sentientx wheel path or URL (release verification)
HELP
            return
            ;;
        '') ;;
        *) fail "Unknown option: $1. Use --help." ;;
    esac
    case "$(uname -s)/$(uname -m)" in
        Linux/x86_64|Linux/aarch64|Linux/arm64|Darwin/x86_64|Darwin/arm64) ;;
        *) fail 'Supported platforms: Linux and macOS on x86_64 or ARM64.' ;;
    esac
    [ -n "${HOME:-}" ] || fail 'Set HOME to a writable home directory.'
    case "${SX_NO_MODIFY_PATH:-0}" in
        0|1) ;;
        *) fail 'SX_NO_MODIFY_PATH must be 0 or 1.' ;;
    esac
    install_dir=${SX_INSTALL_DIR:-"$HOME/.local/bin"}
    case "$install_dir" in
        /*) ;;
        *) fail 'SX_INSTALL_DIR must be an absolute path.' ;;
    esac
    command -v curl >/dev/null 2>&1 || fail 'Install curl, then run this installer again.'
    download_dir=$(mktemp -d "${TMPDIR:-/tmp}/sx-install.XXXXXXXX")
    trap 'rm -rf -- "$download_dir"' 0
    trap 'exit 1' 1 2 3 15

    # A release pointer contains only a version and a SHA-256, never shell code.
    # The wheel lives under its digest so a concurrent release cannot change it.
    if [ -n "${SX_INSTALL_PACKAGE:-}" ]; then
        package=$SX_INSTALL_PACKAGE
    else
        releases=https://raw.githubusercontent.com/Sentient-X/sx-pod-releases/releases
        download "$releases/sdk/latest.txt" "$download_dir/release" \
            || fail 'Could not download the sx release. Check your connection and retry.'
        IFS=' ' read -r version digest extra < "$download_dir/release" \
            || fail 'Incomplete sx release metadata.'
        case "$version" in
            ''|*[!0-9a-z.]*|[!0-9]*) fail 'Invalid sx release version.' ;;
        esac
        case "$digest" in
            ''|*[!0-9a-f]*) fail 'Invalid sx release checksum.' ;;
        esac
        [ "${#digest}" -eq 64 ] && [ -z "$extra" ] \
            || fail 'Invalid sx release metadata.'
        wheel="sentientx-$version-py3-none-any.whl"
        package="$download_dir/$wheel"
        download "$releases/sdk/$digest/$wheel" "$package" \
            || fail 'Could not download sx. Check your connection and retry.'
        # uv tool install does not enforce URL hash fragments. Verify the bytes
        # here before bootstrapping uv or modifying the installed commands.
        if command -v sha256sum >/dev/null 2>&1; then
            actual=$(sha256sum < "$package")
        elif command -v shasum >/dev/null 2>&1; then
            actual=$(shasum -a 256 < "$package")
        else
            fail 'Install sha256sum or shasum, then run this installer again.'
        fi
        [ "${actual%% *}" = "$digest" ] || fail 'Hash mismatch: the sx wheel was not installed.'
    fi

    # Use a private bootstrap so an absent or old uv on PATH needs no manual repair.
    # Managed Python and the tool environment survive this temporary uv executable.
    printf 'Installing sx…\n'
    download https://astral.sh/uv/0.10.2/install.sh "$download_dir/uv-install.sh" \
        || fail 'Could not download uv. Check your connection and retry.'
    UV_UNMANAGED_INSTALL="$download_dir/uv" sh "$download_dir/uv-install.sh" \
        || fail 'Could not install uv for this platform.'
    uv="$download_dir/uv/uv"
    export UV_TOOL_BIN_DIR="$install_dir"
    "$uv" tool install --no-config --managed-python --python 3.12 \
        --no-build --upgrade "$package" \
        || fail 'Could not install sx. Check the error above, then run this installer again.'
    "$install_dir/sx" --help >/dev/null \
        || fail 'sx was installed but could not start. Check the error above.'
    [ -x "$install_dir/sx-mcp" ] || fail 'The release did not install sx-mcp.'

    if [ "${SX_NO_MODIFY_PATH:-0}" = 0 ]; then
        "$uv" tool update-shell --no-config \
            || fail "sx is installed, but PATH setup failed. Add $install_dir to PATH."
    fi
    printf '\nsx is installed in %s.\n' "$install_dir"
    case ":${PATH:-}:" in
        *:"$install_dir":*) printf 'Run: sx auth login\n' ;;
        *)
            if [ "${SX_NO_MODIFY_PATH:-0}" = 1 ]; then
                printf 'Add %s to PATH, then run: sx auth login\n' "$install_dir"
            else
                printf 'Open a new terminal, then run: sx auth login\n'
            fi
            ;;
    esac
}

# Keep the call last: a truncated curl response cannot execute half an installer.
main "$@"
