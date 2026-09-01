#!/usr/bin/env sh
# cmprs installer — Flaxo (https://github.com/flaxodotdev/cmprs)
# Usage: curl -fsSL https://raw.githubusercontent.com/flaxodotdev/cmprs/main/install.sh | sh
#        curl -fsSL https://raw.githubusercontent.com/flaxodotdev/cmprs/main/install.sh | sh -s -- --prefix ~/.local
set -eu

REPO="flaxodotdev/cmprs"
VERSION="${CMPRS_VERSION:-0.1.0}"
PREFIX="${PREFIX:-/usr/local}"
BIN_DIR=""
INSTALL_PATH=""

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2;;
    --prefix=*) PREFIX="${1#--prefix=}"; shift;;
    --version) VERSION="$2"; shift 2;;
    --version=*) VERSION="${1#--version=}"; shift;;
    --help|-h)
      echo "Usage: install.sh [--prefix DIR] [--version VERSION]"
      echo "  --prefix  install dir (default: /usr/local, fallback: ~/.local if not writable)"
      echo "  --version release tag without v (default: 0.1.0, use 'latest' for latest)"
      exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

# detect OS/arch
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$OS" in
  darwin) OS="macos" ;;
  linux)  OS="linux" ;;
  *) echo "unsupported OS: $OS (only macos/linux)" >&2; exit 1;;
esac

case "$ARCH" in
  x86_64|amd64) ARCH="x86_64" ;;
  arm64|aarch64) ARCH="aarch64" ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1;;
esac

# map to release asset: cmprs-<arch>_<os>
ASSET="cmprs-${ARCH}_${OS}"

# resolve version -> tag
if [ "$VERSION" = "latest" ]; then
  # pull actual latest release tag from GitHub API (no token needed)
  TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
  if [ -z "$TAG" ]; then
    echo "failed to resolve latest release" >&2; exit 1
  fi
else
  VERSION="${VERSION#v}"
  TAG="v${VERSION}"
fi
URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

# choose bin dir
mkdir -p "$PREFIX/bin" 2>/dev/null || true
if [ -w "$PREFIX/bin" ] 2>/dev/null; then
  BIN_DIR="$PREFIX/bin"
else
  BIN_DIR="$HOME/.local/bin"
  mkdir -p "$BIN_DIR"
  echo "note: $PREFIX not writable, installing to $BIN_DIR (add to PATH)" >&2
fi
INSTALL_PATH="$BIN_DIR/cmprs"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT INT TERM

echo "Installing cmprs $TAG ($OS/$ARCH) to $INSTALL_PATH" >&2

# download with curl or wget
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$TMP"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$TMP" "$URL"
else
  echo "curl or wget required" >&2
  exit 1
fi

chmod +x "$TMP"

# move into place (sudo only if the dir is not writable)
if [ -w "$BIN_DIR" ]; then
  mv -f "$TMP" "$INSTALL_PATH"
else
  echo "trying sudo mv to $INSTALL_PATH" >&2
  sudo mv -f "$TMP" "$INSTALL_PATH"
fi

chmod +x "$INSTALL_PATH" 2>/dev/null || true

echo "Installed to $INSTALL_PATH" >&2
if ! command -v cmprs >/dev/null 2>&1; then
  echo "  add to PATH: export PATH=\"$BIN_DIR:\$PATH\"" >&2
else
  echo "  run: cmprs" >&2
fi

# verify
if [ -x "$INSTALL_PATH" ]; then
  echo "bytes: $(wc -c < "$INSTALL_PATH")" >&2
fi