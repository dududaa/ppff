# PPFF

A collection of media processing libraries built on top [FFMPEG](https://ffmpeg.org/) and originally for use
by [PPDRIVE](https://ppdrive.dududaa.org/). While the dynamic libraries can be loaded at PPDRIVE runtime, each library
contains public crates and interfaces that can be used in any Rust project.

## License

FFmpeg, x264, x265 and libvorbis are licensed under **GPL-2.0-or-later**, so this repository — including the
`ppff-*` crates and the `ppdrive-*` plugin binaries built from them — is released under the GNU General Public
License v2.0 or later. See [LICENSE](LICENSE). PPDRIVE's core stays under the PolyForm Noncommercial license; the
plugins are separate works connected to it only at runtime through the `plugin_dispatch` entry point.

## Shared FFmpeg runtime

The `Release` workflow builds [FFmpeg](https://ffmpeg.org/) 9 as six shared libraries via
`scripts/build-ffmpeg-static.sh`, with x264, x265, libvpx, libaom, libwebp, lame, libogg, libvorbis, libopus
and zlib linked **statically inside them** (the host C/C++ runtimes too). Each platform gets one
`ppdrive-media-runtime-<os>-<arch>.tar.gz` bundle holding those six libraries, while every `ppdrive-*` plugin
stays thin (~0.5 MB): it carries no FFmpeg code of its own, exports only `plugin_dispatch`, and resolves the
runtime next to itself through an `$ORIGIN`/`@loader_path` rpath (on Windows, ppdrive's loader opens plugins
with `LOAD_WITH_ALTERED_SEARCH_PATH`). `ppdrive plugin add` extracts the runtime bundle into ppdrive's `libs/`
directory, so hosts need no system FFmpeg and all installed plugins share one runtime mapping. A verification
step fails the release if a codec or host-runtime dependency slips into a shipped artifact, if a plugin
defines FFmpeg symbols, or if two plugins would not share a single `libavcodec` mapping.

To reproduce locally:

```sh
./scripts/build-ffmpeg-static.sh   # builds into ~/ppff-ffmpeg and prints the env exports
export PKG_CONFIG_PATH=~/ppff-ffmpeg/lib/pkgconfig
export LD_LIBRARY_PATH=~/ppff-ffmpeg/lib
cargo build --release --workspace
```
