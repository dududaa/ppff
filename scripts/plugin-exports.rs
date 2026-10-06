// Shared by every plugin cdylib's build.rs via include!().
//
// Plugins link dynamically against the bundled FFmpeg runtime (built by
// build-ffmpeg-static.sh) which ships next to them in ppdrive's libs/
// directory, so every plugin in a process shares one copy of FFmpeg and no
// host FFmpeg is ever consulted. Only the ppdrive entry point is exported;
// everything else stays hidden so plugins cannot interpose each other (or
// the runtime's own av_* symbols, which remain undefined here).

// The lib-only packages (which never build a cdylib) include this file for
// emit_bundled_runtime() alone, so allow emit_plugin_exports to go unused.
#[allow(dead_code)]
fn emit_plugin_exports() {
    let out = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap());
    match std::env::var("CARGO_CFG_TARGET_OS").unwrap().as_str() {
        "linux" | "freebsd" | "netbsd" | "openbsd" | "android" => {
            let map = out.join("plugin-exports.map");
            std::fs::write(
                &map,
                "{\n  global:\n    plugin_dispatch;\n  local:\n    *;\n};\n",
            )
            .expect("write plugin-exports.map");
            println!(
                "cargo:rustc-cdylib-link-arg=-Wl,--version-script={}",
                map.display()
            );
            emit_bundled_runtime();
        }
        "windows" => {
            emit_bundled_runtime();
        }
        "macos" | "ios" => {
            let list = out.join("plugin-exports.list");
            std::fs::write(&list, "_plugin_dispatch\n").expect("write plugin-exports.list");
            println!(
                "cargo:rustc-cdylib-link-arg=-Wl,-exported_symbols_list,{}",
                list.display()
            );
            emit_bundled_runtime();
        }
        _ => {}
    }
}

// Resolve the bundled runtime sitting next to the plugin (or, for local
// test binaries, use LD_LIBRARY_PATH=<prefix>/lib):
// - ELF: DT_RUNPATH=$ORIGIN finds libavcodec.so.NN and friends in the
//   directory of the loading object.
// - macOS: LC_RPATH=@loader_path plus the @rpath dylib ids that
//   build-ffmpeg-static.sh writes.
// - Windows: no rpath concept; the ppdrive loader opens plugins with
//   LOAD_WITH_ALTERED_SEARCH_PATH so the av*-NN.dll files next to the
//   plugin are searched for it and its dependencies.
// A rpath to the build prefix is deliberately NOT baked in: shipped
// artifacts must resolve the runtime only from their own directory.
fn emit_bundled_runtime() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    match target_os.as_str() {
        "linux" | "freebsd" | "netbsd" | "openbsd" | "android" => {
            println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN");
        }
        "macos" | "ios" => {
            println!("cargo:rustc-link-arg=-Wl,-rpath,@loader_path");
        }
        _ => {}
    }

    // rustc always puts an explicit -lgcc_s in the native lib list of GNU
    // targets, which would record DT_NEEDED libgcc_s.so.1. Shadow the system
    // library with a static archive in a search path we control: ld tries
    // every -L directory regardless of where it appears on the command line,
    // and archives never produce DT_NEEDED entries. The archive must actually
    // contain the _Unwind_* symbols rustc references: on ELF toolchains that
    // is libgcc_eh.a (libgcc.a holds almost none of them), while mingw keeps
    // them in libgcc.a — so probe with nm instead of guessing.
    if target_os != "macos" && target_os != "ios"
        && let Some(libgcc) = static_libgcc_s_source()
    {
        let out = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap());
        let shim = out.join("gccshim");
        let _ = std::fs::create_dir_all(&shim);
        let dest = shim.join("libgcc_s.a");
        let _ = std::fs::remove_file(&dest);
        if std::fs::copy(&libgcc, &dest).is_ok() {
            println!("cargo:rustc-link-search={}", shim.display());
        }
    }
}

fn static_libgcc_s_source() -> Option<std::path::PathBuf> {
    for candidate in ["libgcc_eh.a", "libgcc.a"] {
        if let Some(path) = gxx_print_file_name(candidate)
            && archive_contains(&path, "_Unwind_GetIP")
        {
            return Some(path);
        }
    }
    None
}

fn archive_contains(archive: &std::path::Path, symbol: &str) -> bool {
    let Ok(out) = std::process::Command::new("nm")
        .arg("--defined-only")
        .arg(archive)
        .output()
    else {
        return false;
    };
    out.stdout
        .split(|b| *b == b'\n')
        .filter_map(|line| std::str::from_utf8(line).ok())
        .any(|line| line.split_whitespace().any(|tok| tok == symbol))
}

fn gxx_print_file_name(archive: &str) -> Option<std::path::PathBuf> {
    let out = std::process::Command::new("g++")
        .arg(format!("-print-file-name={archive}"))
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let printed = String::from_utf8_lossy(&out.stdout);
    let printed = printed.trim();
    // g++ echoes the input back when the archive cannot be found.
    if printed.is_empty() || printed == archive {
        return None;
    }
    let path = std::path::PathBuf::from(printed);
    if path.is_absolute() {
        return Some(path);
    }
    // MSYS2's g++ reports POSIX paths such as /mingw64/lib/...; rustc runs
    // under Git Bash there, so translate with cygpath (both Git Bash and
    // MSYS2 ship one; MSYS2's /c/msys64/usr/bin is first on the build PATH).
    let out = std::process::Command::new("cygpath").args(["-m", printed]).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let converted = String::from_utf8_lossy(&out.stdout);
    let converted = converted.trim();
    let path = std::path::PathBuf::from(converted);
    path.is_absolute().then_some(path)
}
