#!/bin/sh
# The publr command for your OS and CPU, on your PATH:
#   curl -fsSL https://publr.dev/install.sh | sh
#
# It makes, runs, clones and deploys Publr sites; each site runs the Publr release it pins,
# fetched by the command when first needed. On a Mac, Homebrew does the same:
#   brew install publr-org/tap/publr
#
# The command's folder goes on your PATH through your shell's profile (~/.zshrc, ~/.bashrc).
#
# Optional:
#   PUBLR_BIN_DIR=<folder>    where the command goes (default: ~/.local/bin)
#   PUBLR_VERSION=v0.1.0      a release of the command (default: latest)
#   PUBLR_BINARY=<file>       a publr command you built, copied instead of downloaded
#   PUBLR_FIRST_SITE=<name>   a first site made right after, in ~/Publr
# Run again to update the command; sites and the Publr releases they run stay as they are.
#
# A server that only runs a site needs no command: download a Publr release for it from
# https://github.com/publr-org/publr/releases.
set -eu

repo="https://github.com/publr-org/cli/releases"
version="${PUBLR_VERSION:-latest}"
bin_dir="${PUBLR_BIN_DIR:-$HOME/.local/bin}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

download() {
    case "$(uname -s)" in
        Darwin) os="macos" ;;
        Linux)  os="linux" ;;
        *) echo "publr: unsupported OS '$(uname -s)'; download a build from $repo" >&2; exit 1 ;;
    esac

    case "$(uname -m)" in
        arm64|aarch64) arch="aarch64" ;;
        x86_64|amd64)  arch="x86_64" ;;
        *) echo "publr: unsupported CPU '$(uname -m)'; download a build from $repo" >&2; exit 1 ;;
    esac

    file="publr-$os-$arch"
    if [ "$version" = "latest" ]; then
        url="$repo/latest/download/$file"
    else
        url="$repo/download/$version/$file"
    fi

    echo "publr: downloading $url"
    if ! curl -fsSL "$url" -o "$tmp/publr" || ! curl -fsSL "$url.sha256" -o "$tmp/publr.sha256"; then
        echo "publr: no $file at $repo ($version); build one (zig build in cli) and run this with" >&2
        echo "       PUBLR_BINARY=<path to zig-out/bin/publr>" >&2
        exit 1
    fi

    expected="$(cut -d' ' -f1 < "$tmp/publr.sha256")"
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$tmp/publr" | cut -d' ' -f1)"
    else
        actual="$(shasum -a 256 "$tmp/publr" | cut -d' ' -f1)"
    fi
    if [ "$expected" != "$actual" ]; then
        echo "publr: checksum mismatch, refusing to install" >&2
        exit 1
    fi
}

if [ -n "${PUBLR_BINARY:-}" ]; then
    cp "$PUBLR_BINARY" "$tmp/publr"
else
    download
fi

mkdir -p "$bin_dir"
install -m 755 "$tmp/publr" "$bin_dir/publr"
echo "publr: $("$bin_dir/publr" --version) in $bin_dir/publr"

# On the PATH from the next terminal on: the line added to the shell's profile once, as
# other installers do. This terminal is told how to use it now.
case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *)
        case "${SHELL:-}" in
            */zsh)  profile="$HOME/.zshrc" ;;
            */bash) profile="$HOME/.bashrc" ;;
            *)      profile="" ;;
        esac
        line="export PATH=\"$bin_dir:\$PATH\""
        if [ -n "$profile" ]; then
            if ! grep -qsF "$line" "$profile"; then
                printf '\n# publr\n%s\n' "$line" >> "$profile"
                echo "publr: added $bin_dir to your PATH in $profile"
            fi
        else
            echo "publr: add this line to your shell's profile to use publr anywhere:"
            echo "  $line"
        fi
        ;;
esac

site="${PUBLR_FIRST_SITE:-}"
if [ -n "$site" ] && [ "$site" != "-" ]; then
    "$bin_dir/publr" new "$site"
else
    echo
    echo "Next:"
    echo "  publr new <name>        # a site in ~/Publr, started and opened"
fi
