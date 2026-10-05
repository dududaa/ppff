// Shared by every plugin cdylib's build.rs via include!().
//
// A statically linked FFmpeg puts a private copy of every av_* symbol into
// each plugin. Exporting those would let one plugin's copies interpose
// another's when several plugins live in the same process, so restrict the
// dynamic symbol table to the single entry point ppdrive dlopens.

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
            emit_static_runtime();
        }
        "windows" => {
            emit_static_runtime();
        }
        "macos" | "ios" => {
            let list = out.join("plugin-exports.list");
            std::fs::write(&list, "_plugin_dispatch\n").expect("write plugin-exports.list");
            println!(
                "cargo:rustc-cdylib-link-arg=-Wl,-exported_symbols_list,{}",
                list.display()
            );
        }
        _ => {}
    }
}

// x265 is C++, so a static FFmpeg drags the C++ runtime into the link.
// gcc's -static-libstdc++/-static-libgcc only rewrite *implicit* runtime
// libs, and explicit -lstdc++ (which pkg-config used to inject) would win
// over them, so hand the static archives to the linker as inputs.
// The .pc files are stripped of -lstdc++/-lgcc* by build-ffmpeg-static.sh.
// rustc-link-arg (not cdylib-link-arg) so test/example binaries that link
// the av* static libs resolve the C++ runtime too.
fn emit_static_runtime() {
    println!("cargo:rustc-link-arg=-static-libstdc++");
    println!("cargo:rustc-link-arg=-static-libgcc");
    for archive in ["libstdc++.a", "libgcc.a", "libgcc_eh.a"] {
        if let Some(path) = gxx_print_file_name(archive) {
            println!("cargo:rustc-link-arg={}", path.display());
        }
    }
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
    path.is_absolute().then_some(path)
}
