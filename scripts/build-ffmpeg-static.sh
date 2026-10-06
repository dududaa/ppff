#!/usr/bin/env bash
# Build the bundled media runtime: a shared FFmpeg toolchain (plus x264,
# x265, libvpx, libaom, libwebp, lame, libogg, libvorbis and libopus, which
# stay static and are linked *inside* the FFmpeg dylibs) into
# $PPDRIVE_FFMPEG_PREFIX.
#
# The ppff media plugins link dynamically against this prefix
# (PKG_CONFIG_PATH) with an $ORIGIN/@loader_path rpath, so every plugin in a
# process shares ONE copy of FFmpeg and no host FFmpeg is ever consulted:
# the plugin's DT_RUNPATH finds the bundled runtime next to it in ppdrive's
# libs/ directory.
#
# On success the script exports (and appends to $GITHUB_ENV when set):
#   PKG_CONFIG_PATH=<prefix>/lib/pkgconfig
#   LD_LIBRARY_PATH=<prefix>/lib            (local test runs)
#   PPDRIVE_FFMPEG_RUNTIME_TAR=<prefix>/ppdrive-media-runtime-<os>-<arch>.tar.gz
#
# Prerequisites: cc/c++, make, perl, pkg-config; nasm + yasm on x86 hosts;
# cmake for x265 and aom; patchelf on Linux. On Windows run from an MSYS2
# shell with the mingw-w64 toolchain on PATH.
set -euo pipefail

FFMPEG_VERSION="${PPDRIVE_FFMPEG_VERSION:-9.0.2}"
X264_VERSION="0.164.3108+git31e19f9"
X265_VERSION="4.1"
VPX_VERSION="1.15.0"
AOM_VERSION="3.11.0"
WEBP_VERSION="1.5.0"
LAME_VERSION="3.100"
OGG_VERSION="1.3.6"
VORBIS_VERSION="1.3.7"
OPUS_VERSION="1.5.2"
ZLIB_VERSION="1.3.1"

SCRIPT_KEY="v2"
PREFIX="${PPDRIVE_FFMPEG_PREFIX:-$HOME/ppff-ffmpeg}"
WORK="${PPDRIVE_FFMPEG_WORK:-$HOME/ppff-ffmpeg-work}"
MARKER="$PREFIX/.ppff-static"
DOWNLOADS="$WORK/downloads"

UNAME="$(uname -s)"
case "$UNAME" in
    MINGW* | MSYS* | CYGWIN*) IS_WINDOWS=1 ;;
    *) IS_WINDOWS=0 ;;
esac
ARCH="$(uname -m)"
case "$UNAME" in
    Darwin) OS_NAME="macos" ;;
    MINGW* | MSYS* | CYGWIN*) OS_NAME="windows" ;;
    *) OS_NAME="linux" ;;
esac
case "$ARCH" in
    arm64) ARCH_NAME="aarch64" ;;
    amd64) ARCH_NAME="x86_64" ;;
    *) ARCH_NAME="$ARCH" ;;
esac
RUNTIME_TAR="$PREFIX/ppdrive-media-runtime-${OS_NAME}-${ARCH_NAME}.tar.gz"

if [ "$IS_WINDOWS" -eq 0 ]; then
    JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
else
    JOBS="${NUMBER_OF_PROCESSORS:-4}"
fi

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: missing required tool '$1'" >&2
        exit 1
    }
}

pkg_config_path_for() {
    if [ "$IS_WINDOWS" -eq 1 ]; then
        # Emit a C:/... form that git-bash, MSYS2 and pkgconf all accept.
        local p
        p="$(cd "$1" && pwd -W 2>/dev/null || pwd)"
        printf '%s\n' "${p//\\//}/lib/pkgconfig"
    else
        printf '%s\n' "$1/lib/pkgconfig"
    fi
}

emit_env() {
    local pc tar
    pc="$(pkg_config_path_for "$PREFIX")"
    tar="$RUNTIME_TAR"
    if [ "$IS_WINDOWS" -eq 1 ]; then
        # Export a Windows-style path: later workflow steps run in Git
        # Bash, which cannot see MSYS2's /home/... tree.
        tar="$(cd "$PREFIX" && pwd -W)/$(basename "$RUNTIME_TAR")"
        tar="${tar//\\//}"
    fi
    echo "PKG_CONFIG_PATH=$pc${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    echo "LD_LIBRARY_PATH=$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    echo "PPDRIVE_FFMPEG_RUNTIME_TAR=$tar"
    if [ -n "${GITHUB_ENV:-}" ]; then
        {
            echo "PKG_CONFIG_PATH=$pc"
            echo "LD_LIBRARY_PATH=$PREFIX/lib"
            echo "PPDRIVE_FFMPEG_RUNTIME_TAR=$tar"
        } >>"$GITHUB_ENV"
    fi
}

MARKER_VALUE="$SCRIPT_KEY-ffmpeg-$FFMPEG_VERSION-shared"
if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$MARKER_VALUE" ] && [ -f "$RUNTIME_TAR" ]; then
    echo "Bundled FFmpeg runtime already built at $PREFIX"
    emit_env
    exit 0
fi

need curl
need make
need pkg-config
need perl
need cmake
if [ "$IS_WINDOWS" -eq 0 ] && [ "$UNAME" != "Darwin" ]; then
    need patchelf
fi
case "$ARCH" in
    x86_64 | amd64)
        need nasm
        need yasm
        ;;
esac

# Keep the runtime floor as low as the runner allows: rustc and the
# C dependencies must agree on MACOSX_DEPLOYMENT_TARGET.
if [ "$UNAME" = "Darwin" ]; then
    if [ "$ARCH" = "arm64" ]; then
        export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    else
        export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.13}"
    fi
fi

mkdir -p "$PREFIX" "$DOWNLOADS"

fetch() {
    local url="$1" dest="$2" attempt
    if [ -f "$dest" ]; then
        return 0
    fi
    echo "fetching $url"
    # Retry the whole download and verify it is a readable tarball: mirrors
    # occasionally serve HTML error pages with HTTP 200 (code.videolan.org)
    # or transient 5xx responses (aomedia googlesource).
    for attempt in 1 2 3; do
        if curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 30 \
            -o "$dest.part" "$url" &&
            tar -tf "$dest.part" >/dev/null 2>&1; then
            mv "$dest.part" "$dest"
            return 0
        fi
        rm -f "$dest.part"
        sleep $((attempt * 2))
    done
    echo "error: failed to fetch a valid archive from $url" >&2
    exit 1
}

# extract <archive> <dir> [strip-components]
extract() {
    local archive="$1" dir="$2" strip="${3:-1}"
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xf "$archive" -C "$dir" --strip-components="$strip"
}

# Debian's pool: code.videolan.org serves HTML challenge pages to some
# CI egress IPs, which saved fine and failed only at extract time.
fetch "https://deb.debian.org/debian/pool/main/x/x264/x264_${X264_VERSION}.orig.tar.gz" \
    "$DOWNLOADS/x264-${X264_VERSION}.tar.gz"
fetch "https://deb.debian.org/debian/pool/main/x/x265/x265_${X265_VERSION}.orig.tar.xz" \
    "$DOWNLOADS/x265-${X265_VERSION}.tar.xz"
fetch "https://github.com/webmproject/libvpx/archive/refs/tags/v${VPX_VERSION}.tar.gz" \
    "$DOWNLOADS/libvpx-${VPX_VERSION}.tar.gz"
fetch "https://aomedia.googlesource.com/aom/+archive/refs/tags/v${AOM_VERSION}.tar.gz" \
    "$DOWNLOADS/aom-${AOM_VERSION}.tar.gz"
fetch "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${WEBP_VERSION}.tar.gz" \
    "$DOWNLOADS/libwebp-${WEBP_VERSION}.tar.gz"
fetch "https://deb.debian.org/debian/pool/main/l/lame/lame_${LAME_VERSION}.orig.tar.gz" \
    "$DOWNLOADS/lame-${LAME_VERSION}.tar.gz"
fetch "https://downloads.xiph.org/releases/ogg/libogg-${OGG_VERSION}.tar.xz" \
    "$DOWNLOADS/libogg-${OGG_VERSION}.tar.xz"
fetch "https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VERSION}.tar.xz" \
    "$DOWNLOADS/libvorbis-${VORBIS_VERSION}.tar.xz"
fetch "https://github.com/xiph/opus/releases/download/v${OPUS_VERSION}/opus-${OPUS_VERSION}.tar.gz" \
    "$DOWNLOADS/opus-${OPUS_VERSION}.tar.gz"
fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" \
    "$DOWNLOADS/zlib-${ZLIB_VERSION}.tar.gz"
fetch "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
    "$DOWNLOADS/ffmpeg-${FFMPEG_VERSION}.tar.xz"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# Per-dependency stamps so an interrupted run (killed terminal, partial CI
# cache) resumes at the first step that has not finished yet.
step_done() {
    [ -f "$PREFIX/.ppff-$1" ] && [ "$(cat "$PREFIX/.ppff-$1")" = "$SCRIPT_KEY-$2" ]
}
step_mark() {
    printf '%s' "$SCRIPT_KEY-$2" >"$PREFIX/.ppff-$1"
}

if ! step_done x264 "$X264_VERSION"; then
    echo "==> x264 ${X264_VERSION} (static)"
    extract "$DOWNLOADS/x264-${X264_VERSION}.tar.gz" "$WORK/x264"
    (cd "$WORK/x264" &&
        ./configure --prefix="$PREFIX" --enable-static --disable-shared \
            --enable-pic --disable-cli &&
        make -j"$JOBS" &&
        make install)
    step_mark x264 "$X264_VERSION"
fi

if ! step_done x265 "$X265_VERSION"; then
    echo "==> x265 ${X265_VERSION} (static)"
    extract "$DOWNLOADS/x265-${X265_VERSION}.tar.xz" "$WORK/x265"
    # CMake 4.x (Homebrew, MSYS2) rejects cmake_policy(SET ... OLD), which
    # 4.1's CMakeLists does for CMP0025/CMP0054. Drop those lines and make
    # the AppleClang check a substring match instead, which is exactly what
    # the CMP0025 OLD behaviour ("report Apple's Clang as just Clang") did.
    # Verified against cmake 4.0.3: configure + full build succeed.
    sed -i.bak \
        -e '/cmake_policy(SET CMP0025 OLD)/d' \
        -e '/cmake_policy(SET CMP0054 OLD)/d' \
        -e 's/CMAKE_CXX_COMPILER_ID} STREQUAL "Clang"/CMAKE_CXX_COMPILER_ID} MATCHES "Clang"/' \
        "$WORK/x265/source/CMakeLists.txt"
    rm -f "$WORK/x265/source/CMakeLists.txt.bak"
    cmake -S "$WORK/x265/source" -B "$WORK/x265/build" -G "Unix Makefiles" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DENABLE_SHARED=OFF \
        -DENABLE_CLI=OFF \
        -DENABLE_PIC=ON
    cmake --build "$WORK/x265/build" -j"$JOBS"
    cmake --install "$WORK/x265/build"
    step_mark x265 "$X265_VERSION"
fi

if ! step_done libvpx "$VPX_VERSION"; then
    echo "==> libvpx ${VPX_VERSION} (static)"
    case "$UNAME-$ARCH" in
        Linux-x86_64 | Linux-amd64) VPX_TARGET="x86_64-linux-gcc" ;;
        Linux-aarch64 | Linux-arm64) VPX_TARGET="arm64-linux-gcc" ;;
        Darwin-arm64) VPX_TARGET="arm64-darwin20-gcc" ;;
        Darwin-x86_64) VPX_TARGET="x86_64-darwin20-gcc" ;;
        MINGW*-x86_64 | MSYS*-x86_64 | CYGWIN*-x86_64) VPX_TARGET="x86_64-win64-gcc" ;;
        *) VPX_TARGET="generic-gnu" ;;
    esac
    extract "$DOWNLOADS/libvpx-${VPX_VERSION}.tar.gz" "$WORK/libvpx"
    (cd "$WORK/libvpx" &&
        ./configure --prefix="$PREFIX" --target="$VPX_TARGET" \
            --enable-static --disable-shared --enable-pic \
            --disable-examples --disable-tools --disable-docs &&
        make -j"$JOBS" &&
        make install)
    step_mark libvpx "$VPX_VERSION"
fi

if ! step_done libaom "$AOM_VERSION"; then
    echo "==> aom ${AOM_VERSION} (static)"
    rm -rf "$WORK/aom"
    mkdir -p "$WORK/aom"
    tar -xf "$DOWNLOADS/aom-${AOM_VERSION}.tar.gz" -C "$WORK/aom"
    cmake -S "$WORK/aom" -B "$WORK/aom/build" -G "Unix Makefiles" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=0 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DENABLE_TESTS=0 \
        -DENABLE_DOCS=0 \
        -DENABLE_EXAMPLES=0 \
        -DENABLE_TOOLS=0
    cmake --build "$WORK/aom/build" -j"$JOBS"
    cmake --install "$WORK/aom/build"
    step_mark libaom "$AOM_VERSION"
fi

if ! step_done libwebp "$WEBP_VERSION"; then
    echo "==> libwebp ${WEBP_VERSION} (static)"
    extract "$DOWNLOADS/libwebp-${WEBP_VERSION}.tar.gz" "$WORK/libwebp"
    (cd "$WORK/libwebp" &&
        ./configure --prefix="$PREFIX" --enable-static --disable-shared --with-pic &&
        make -j"$JOBS" &&
        make install)
    step_mark libwebp "$WEBP_VERSION"
fi

if ! step_done lame "$LAME_VERSION"; then
    echo "==> lame ${LAME_VERSION} (static)"
    extract "$DOWNLOADS/lame-${LAME_VERSION}.tar.gz" "$WORK/lame"
    (cd "$WORK/lame" &&
        ./configure --prefix="$PREFIX" --enable-static --disable-shared \
            --disable-frontend \
            CFLAGS="${CFLAGS:--O2} -fPIC" &&
        make -j"$JOBS" &&
        make install)
    step_mark lame "$LAME_VERSION"
fi

if ! step_done libogg "$OGG_VERSION"; then
    echo "==> libogg ${OGG_VERSION} (static)"
    extract "$DOWNLOADS/libogg-${OGG_VERSION}.tar.xz" "$WORK/libogg"
    (cd "$WORK/libogg" &&
        ./configure --prefix="$PREFIX" --enable-static --disable-shared --with-pic &&
        make -j"$JOBS" &&
        make install)
    step_mark libogg "$OGG_VERSION"
fi

if ! step_done libvorbis "$VORBIS_VERSION"; then
    echo "==> libvorbis ${VORBIS_VERSION} (static)"
    extract "$DOWNLOADS/libvorbis-${VORBIS_VERSION}.tar.xz" "$WORK/libvorbis"
    # The darwin branch of configure adds -force_cpusubtype_ALL to CFLAGS,
    # which Apple's modern ld rejects outright (it is an i386-era flag).
    sed -i.bak 's/-force_cpusubtype_ALL//g' "$WORK/libvorbis/configure"
    rm -f "$WORK/libvorbis/configure.bak"
    (cd "$WORK/libvorbis" &&
        ./configure --prefix="$PREFIX" --enable-static --disable-shared --with-pic &&
        make -j"$JOBS" &&
        make install)
    step_mark libvorbis "$VORBIS_VERSION"
fi

if ! step_done libopus "$OPUS_VERSION"; then
    echo "==> libopus ${OPUS_VERSION} (static)"
    extract "$DOWNLOADS/opus-${OPUS_VERSION}.tar.gz" "$WORK/libopus"
    (cd "$WORK/libopus" &&
        ./configure --prefix="$PREFIX" --enable-static --disable-shared --with-pic &&
        make -j"$JOBS" &&
        make install)
    step_mark libopus "$OPUS_VERSION"
fi

if ! step_done zlib "$ZLIB_VERSION"; then
    echo "==> zlib ${ZLIB_VERSION} (static)"
    extract "$DOWNLOADS/zlib-${ZLIB_VERSION}.tar.gz" "$WORK/zlib"
    (cd "$WORK/zlib" &&
        ./configure --prefix="$PREFIX" --static &&
        make -j"$JOBS" &&
        make install)
    step_mark zlib "$ZLIB_VERSION"
fi

if [ "$IS_WINDOWS" -eq 1 ]; then
    # FFmpeg's configure aborts with "Native MSYS builds are discouraged"
    # when config.guess sees the plain msys environment; claiming the
    # mingw64 environment makes it report x86_64-w64-mingw32 instead.
    export MSYSTEM=MINGW64
fi

# FFmpeg's configure hardcodes -lstdc++ wherever x265 is enabled, so the
# shared libavcodec would record DT_NEEDED libstdc++.so.6 (or link the
# libstdc++-6.dll import library on Windows) and every plugin loading it
# would depend on a C++ runtime the host may not have. Make -lstdc++ resolve
# to the *static* archive inside $PREFIX/lib, which is searched before the
# system directories: on ELF a linker script named libstdc++.so points at the
# archive, on mingw the import library is shadowed by a copy of the static
# archive (import libs lose to .a files only by name, so overwrite the name
# ld prefers). x265's symbols then end up embedded in libavcodec with no
# runtime dependency. -static-libgcc in the FFmpeg link does the same for the
# gcc unwinder.
setup_stdcpp_shadow() {
    if [ "$UNAME" = "Darwin" ]; then
        # x265 links the system libc++, which every macOS ships.
        return 0
    fi
    local archive
    archive="$("${CXX:-c++}" -print-file-name=libstdc++.a)"
    if [ "$archive" = "libstdc++.a" ] || [ ! -f "$archive" ]; then
        echo "error: static libstdc++.a not found; runtime would depend on libstdc++.so.6" >&2
        exit 1
    fi
    if [ "$IS_WINDOWS" -eq 1 ]; then
        cp -f "$archive" "$PREFIX/lib/libstdc++.dll.a"
    else
        printf 'INPUT ( %s )\n' "$archive" >"$PREFIX/lib/libstdc++.so"
    fi
}

if ! step_done ffmpeg "$FFMPEG_VERSION-shared"; then
    echo "==> FFmpeg ${FFMPEG_VERSION} (shared runtime, GPL)"
    # Drop outputs of a previous static build in this prefix so the shared
    # install cannot pick up stale archives.
    rm -f "$PREFIX"/lib/libavcodec.* "$PREFIX"/lib/libavformat.* \
        "$PREFIX"/lib/libavfilter.* "$PREFIX"/lib/libavutil.* \
        "$PREFIX"/lib/libavdevice.* "$PREFIX"/lib/libswscale.* \
        "$PREFIX"/lib/libswresample.*
    setup_stdcpp_shadow
    # The .pc sed below (which keeps -lstdc++ out of *plugin* link lines)
    # may already have run against this prefix in an earlier invocation:
    # restore it for the x265 probe, which needs -lstdc++ on its link line
    # to resolve x265's C++ runtime (via the static shadow above). It gets
    # stripped again once FFmpeg is installed. Placed at the end of
    # Libs.private so it (a) lands after -lx265 where GNU ld's one-pass
    # archive resolution can use it, and (b) is only emitted for the
    # --static probes FFmpeg runs, never for plugin link lines.
    sed -i \
        -e 's/ -lstdc++//g' \
        -e 's/^Libs.private: \(.*\)$/Libs.private: \1 -lstdc++/' \
        "$PREFIX/lib/pkgconfig/x265.pc"
    case "$UNAME" in
    Darwin) RUNTIME_LDFLAGS="-L$PREFIX/lib -Wl,-rpath,@loader_path" ;;
    # No $ORIGIN here: FFmpeg's configure runs add_ldflags through eval and
    # would expand it as a shell variable. The Linux rpath is stamped onto
    # the installed libraries with patchelf after `make install`.
    *) RUNTIME_LDFLAGS="-L$PREFIX/lib -static-libstdc++ -static-libgcc" ;;
    esac
    extract "$DOWNLOADS/ffmpeg-${FFMPEG_VERSION}.tar.xz" "$WORK/ffmpeg"
    (cd "$WORK/ffmpeg" &&
        ./configure --prefix="$PREFIX" \
            --disable-static --enable-shared --enable-pic \
            --enable-gpl \
            --enable-libx264 --enable-libx265 --enable-libvpx \
            --enable-libaom --enable-libwebp --enable-libmp3lame \
            --enable-libvorbis --enable-libopus \
            --disable-programs --disable-doc --disable-debug \
            --disable-xlib --disable-libxcb \
            --disable-bzlib --disable-lzma \
            --extra-cflags="-I$PREFIX/include" \
            --extra-ldflags="$RUNTIME_LDFLAGS" \
            --pkg-config-flags="--static" &&
        make -j"$JOBS" &&
        make install)
    # Linux: stamp DT_RUNPATH=$ORIGIN so each of the six libraries resolves
    # its siblings inside ppdrive's libs/ directory (patchelf instead of
    # --extra-ldflags because configure's eval would eat the $ORIGIN).
    if [ "$UNAME" != "Darwin" ] && [ "$IS_WINDOWS" -eq 0 ]; then
        for l in libavcodec libavformat libavfilter libavutil libswscale libswresample; do
            real="$(realpath "$PREFIX/lib/$l.so")"
            patchelf --set-rpath '$ORIGIN' "$real"
        done
    fi
    # macOS: FFmpeg bakes the build machine's absolute install paths into
    # the dylib ids and into the cross-references between the six libraries.
    # Rewrite them so the runtime is relocatable: @rpath ids for consumers
    # (plugins), @loader_path references between the runtime's own dylibs.
    if [ "$UNAME" = "Darwin" ]; then
        libs="libavcodec libavformat libavfilter libavutil libswscale libswresample"
        names=""
        for l in $libs; do
            link="$(readlink "$PREFIX/lib/$l.dylib" || true)"
            base="${link:-$l.dylib}"
            install_name_tool -id "@rpath/$base" "$PREFIX/lib/$base"
            names="$names $base"
        done
        for l in $libs; do
            link="$(readlink "$PREFIX/lib/$l.dylib" || true)"
            base="${link:-$l.dylib}"
            real="$PREFIX/lib/$base"
            for dep in $names; do
                install_name_tool -change "$PREFIX/lib/$dep" "@rpath/$dep" \
                    "$real" 2>/dev/null || true
            done
            if ! otool -l "$real" | grep -q "@loader_path"; then
                install_name_tool -add_rpath "@loader_path" "$real"
            fi
        done
    fi
    step_mark ffmpeg "$FFMPEG_VERSION-shared"
fi

# FFmpeg's configure bakes -lstdc++/-lgcc* into its .pc files so *shared*
# consumers would pick up a C++ runtime. Plugins only link the av*/sw*
# dylibs, never -lstdc++, so strip those entries for them (the runtime
# itself resolved libstdc++ via the shadow above, at its own link).
for pc in "$PREFIX"/lib/pkgconfig/*.pc; do
    sed -i.bak 's/-lstdc++//g; s/-lgcc_s//g; s/-lgcc//g' "$pc"
    rm -f "$pc.bak"
done

# Stage the runtime: the six FFmpeg libraries under the exact names the
# plugins will reference (SONAME on ELF, @rpath basename on macOS, plain
# DLL names on Windows), bundled into one relocatable tarball the release
# ships and ppdrive's plugin installer extracts into libs/.
stage_runtime() {
    local staging lib soname base
    staging="$PREFIX/runtime-staging"
    rm -rf "$staging"
    mkdir -p "$staging"
    if [ "$IS_WINDOWS" -eq 1 ]; then
        for lib in avcodec avformat avfilter avutil swscale swresample; do
            cp "$PREFIX"/bin/"$lib"-*.dll "$staging"/
        done
    elif [ "$UNAME" = "Darwin" ]; then
        for lib in libavcodec libavformat libavfilter libavutil libswscale libswresample; do
            link="$(readlink "$PREFIX/lib/$lib.dylib" || true)"
            base="${link:-$lib.dylib}"
            cp -L "$PREFIX/lib/$lib.dylib" "$staging/$base"
        done
    else
        for lib in libavcodec libavformat libavfilter libavutil libswscale libswresample; do
            soname="$(readelf -d "$PREFIX/lib/$lib.so" |
                sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')"
            [ -n "$soname" ] || {
                echo "error: no SONAME for $lib.so" >&2
                exit 1
            }
            cp -L "$PREFIX/lib/$lib.so" "$staging/$soname"
        done
    fi
    tar -czf "$RUNTIME_TAR" -C "$staging" .
    echo "==> Runtime bundle: $RUNTIME_TAR"
    tar -tzf "$RUNTIME_TAR"
}
stage_runtime

printf '%s' "$MARKER_VALUE" >"$MARKER"
echo "==> Bundled FFmpeg runtime installed at $PREFIX"
emit_env