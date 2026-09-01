#!/bin/sh
set -e

REPO="flaxodotdev/cmprs"
TAG="v0.1.0"

detect_platform() {
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m | tr '[:upper:]' '[:lower:]')

  case "$os" in
    darwin)  os="macos" ;;
    linux)   os="linux" ;;
    *)
      echo "error: unsupported OS: $os"
      exit 1
      ;;
  esac

  case "$arch" in
    arm64|aarch64) arch="aarch64" ;;
    x86_64|x64|amd64) arch="x86_64" ;;
    *)
      echo "error: unsupported architecture: $arch"
      exit 1
      ;;
  esac

  echo "${arch}_${os}"
}

main() {
  platform=$(detect_platform)
  binary="cmprs-${platform}"
  url="https://github.com/${REPO}/releases/download/${TAG}/${binary}"

  echo "Detected platform: ${platform}"

  tmp="$(mktemp)"
  echo "Downloading from ${url}..."
  curl -fsSL "$url" -o "$tmp"
  chmod +x "$tmp"

  if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    dest="/usr/local/bin/cmprs"
  else
    dest="${HOME}/.local/bin/cmprs"
    mkdir -p "${HOME}/.local/bin"
  fi

  if [ -w "$(dirname "$dest")" ]; then
    mv "$tmp" "$dest"
  elif command -v sudo >/dev/null 2>&1; then
    echo "Directory $(dirname "$dest") is not writable, using sudo..."
    sudo mv "$tmp" "$dest"
  else
    rm -f "$tmp"
    echo "error: cannot write to $(dirname "$dest")"
    exit 1
  fi

  echo "Installed to ${dest}"
  case ":$PATH:" in
    *":$(dirname "$dest"):"*) : ;;
    *) echo "Note: add $(dirname "$dest") to your PATH (not currently present)." ;;
  esac
  echo "Run 'cmprs' to get started."
}

main "$@"