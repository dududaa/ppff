use std::env;
use std::path::PathBuf;

include!("../scripts/plugin-exports.rs");

const LIBRARIES: &[&str] = &["libavcodec", "libavformat", "libavutil"];

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=../scripts/plugin-exports.rs");
    emit_plugin_exports();
    println!("cargo:rerun-if-changed=src/ffi/wrapper.h");
    println!("cargo:rerun-if-env-changed=PKG_CONFIG_PATH");
    println!("cargo:rerun-if-env-changed=PPDRIVE_FFMPEG_STATIC");

    let mut include_paths: Vec<PathBuf> = Vec::new();
    let mut lavf_major: Option<u32> = None;

    for library in LIBRARIES {
        let mut config = pkg_config::Config::new();
        config.statik(env::var_os("PPDRIVE_FFMPEG_STATIC").is_some());
        let lib = config.probe(library).unwrap_or_else(|e| {
            panic!(
                "Failed to find {library} via pkg-config: {e}\n\
                 Install the FFmpeg development packages:\n\
                 - Debian/Ubuntu: sudo apt install libavcodec-dev libavformat-dev libavutil-dev pkg-config\n\
                 - Fedora: sudo dnf install ffmpeg-devel\n\
                 - macOS: brew install ffmpeg pkg-config\n\
                 - Windows (MSYS2): pacman -S mingw-w64-x86_64-ffmpeg"
            )
        });

        if *library == "libavformat" {
            lavf_major = lib.version.split('.').next().and_then(|m| m.parse().ok());
        }

        for path in lib.include_paths {
            if !include_paths.contains(&path) {
                include_paths.push(path);
            }
        }
    }

    println!(
        "cargo::rustc-check-cfg=cfg(ffmpeg_major, values(\"59\", \"60\", \"61\", \"62\", \"63\", \"64\"))"
    );
    if let Some(major) = lavf_major {
        println!("cargo:rustc-cfg=ffmpeg_major=\"{major}\"");
    }

    let mut builder = bindgen::Builder::default()
        .header("src/ffi/wrapper.h")
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .layout_tests(false)
        .generate_comments(false)
        .prepend_enum_name(false)
        .allowlist_function("av.*|ff.*")
        .allowlist_type("AV.*|av.*|ff.*")
        .allowlist_var("av.*|AV.*|ff.*|FF.*");

    if cfg!(all(target_os = "windows", target_env = "gnu")) {
        builder = builder.clang_arg("--target=x86_64-w64-mingw32");
    }

    for path in &include_paths {
        builder = builder.clang_arg(format!("-I{}", path.display()));
    }

    let bindings = builder
        .generate()
        .expect("Unable to generate FFmpeg bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write bindings!");
}
