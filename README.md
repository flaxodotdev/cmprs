# cmprs

Fast terminal-based image compressor written in Zig. Lists images in the current directory, lets you pick one with arrow keys, and compresses it in place.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/flaxodotdev/cmprs/main/install.sh | sh
```

## Build from source

```sh
zig build
./zig-out/bin/cmprs
```

## Usage

Navigate with arrow keys or j/k, press Enter to select, type quality (1-100) and Enter, or just Enter for the default (85).

Supports PNG (via pngquant/oxipng), JPEG, GIF, AVIF, WebP, BMP, TIFF, and HEIC (via sips and cwebp).

## License

MIT
