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

  dest="/usr/local/bin/cmprs"

  echo "Detected platform: ${platform}"
  echo "Downloading from ${url}..."

  curl -fsSL "$url" -o "$dest"
  chmod +x "$dest"

  echo "Installed to ${dest}"
  echo "Run 'cmprs' to get started."
}

main "$@"
