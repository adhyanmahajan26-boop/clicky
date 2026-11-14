// The build number a release bakes in (THEO_BUILD, read by `update::this_build`): rebuild when it changes, and when the
// releases repo file it compiles in changes.
fn main() {
    println!("cargo:rerun-if-env-changed=THEO_BUILD");
    println!("cargo:rerun-if-changed=../../install/releases-repo");
    println!("cargo:rerun-if-changed=build.rs");
}
