//! This build's version, as `build.rs` read it: pubspec.yaml's `X.Y.Z`,
//! then the commit it was built from in parentheses when git could say.

pub const VERSION: &str = env!("DSYNC_VERSION");
