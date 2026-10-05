# PPFF

A collection of media processing libraries built on top [FFMPEG](https://ffmpeg.org/) and originally for use
by [PPDRIVE](https://ppdrive.dududaa.org/). While the dynamic libraries can be loaded at PPDRIVE runtime, each library
contains public crates and interfaces that can be used in any Rust project.

## License

FFmpeg, x264, x265 and libvorbis are licensed under **GPL-2.0-or-later**, so this repository — including the
`ppff-*` crates and the `ppdrive-*` plugin binaries built from them — is released under the GNU General Public
License v2.0 or later. See [LICENSE](LICENSE). PPDRIVE's core stays under the PolyForm Noncommercial license; the
plugins are separate works connected to it only at runtime through the `plugin_dispatch` entry point.

## Self-contained plugin releases

The `Release` workflow builds [FFmpeg](https://ffmpeg.org/) 9 with x264, x265, libvpx, libaom, libwebp, lame,
libogg, libvorbis, libopus and zlib via `scripts/build-ffmpeg-static.sh`, then links every plugin against that
static prefix (`PPDRIVE_FFMPEG_STATIC=1`). Released `ppdrive-*` assets therefore carry their own copy of FFmpeg
and the codecs: no `libav*`/codec `DT_NEEDED` entries, only `plugin_dispatch` exported, and they load on any host
regardless of the FFmpeg version installed there. A verification step fails the release if an external media
library dependency slips back in.

To reproduce locally:

```sh
./scripts/build-ffmpeg-static.sh          # installs to ~/ppff-ffmpeg
export PKG_CONFIG_PATH=~/ppff-ffmpeg/lib/pkgconfig
export PPDRIVE_FFMPEG_STATIC=1
cargo build --release --workspace
```
