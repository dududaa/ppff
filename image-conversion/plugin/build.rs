include!("../../scripts/plugin-exports.rs");

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=../../scripts/plugin-exports.rs");
    emit_plugin_exports();
}
