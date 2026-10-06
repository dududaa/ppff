use std::env;
use std::path::PathBuf;

include!("../scripts/plugin-exports.rs");

const LIBRARIES: &[&str] = &["libavfilter", "libavutil"];

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=../scripts/plugin-exports.rs");
    emit_plugin_exports();
    println!("cargo:rerun-if-changed=src/ffi/wrapper.h");
    println!("cargo:rerun-if-env-changed=PKG_CONFIG_PATH");

    let mut include_paths: Vec<PathBuf> = Vec::new();

    for library in LIBRARIES {
        let config = pkg_config::Config::new();
        let lib = config.probe(library).unwrap_or_else(|e| {
            panic!(
                "Failed to find {library} via pkg-config: {e}\n\
                 Install the FFmpeg development packages:\n\
                 - Debian/Ubuntu: sudo apt install libavfilter-dev libavutil-dev\n\
                 - Fedora: sudo dnf install ffmpeg-devel\n\
                 - macOS: brew install ffmpeg pkg-config\n\
                 - Windows (MSYS2): pacman -S mingw-w64-x86_64-ffmpeg"
            )
        });

        for path in lib.include_paths {
            if !include_paths.contains(&path) {
                include_paths.push(path);
            }
        }
    }

    let mut builder = bindgen::Builder::default()
        .header("src/ffi/wrapper.h")
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .layout_tests(false)
        .generate_comments(false)
        .prepend_enum_name(false)
        .allowlist_function("av.*")
        .allowlist_type("AV.*|av.*")
        .allowlist_var("av.*|AV.*");

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
