//! Reads pubspec.yaml's version and the commit HEAD names into
//! `DSYNC_VERSION`: `0.1.0 (2d2ca38)`, or `0.1.0` alone where git or the
//! repository is not there to ask.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::{env, fs};

fn main() {
    let crate_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let pubspec = crate_dir.join("../../pubspec.yaml");
    println!("cargo:rerun-if-changed={}", pubspec.display());
    let text = fs::read_to_string(&pubspec)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", pubspec.display()));
    let version = release(&text)
        .unwrap_or_else(|| panic!("no `version: X.Y.Z` line in {}", pubspec.display()));

    let full = match commit(&crate_dir) {
        Some(commit) => format!("{version} ({commit})"),
        None => version.to_owned(),
    };
    println!("cargo:rustc-env=DSYNC_VERSION={full}");
}

/// `version: 0.1.0+1` -> `0.1.0`: the `+N` is Android's build number.
fn release(pubspec: &str) -> Option<&str> {
    let line = pubspec
        .lines()
        .find_map(|line| line.strip_prefix("version:"))?;
    let version = line.trim().split('+').next()?;
    (!version.is_empty()).then_some(version)
}

/// HEAD's short hash, asking cargo to rerun when HEAD moves: the files
/// that hold it, wherever this checkout (or worktree) keeps them.
fn commit(dir: &Path) -> Option<String> {
    let head = git(dir, &["rev-parse", "--short", "HEAD"])?;
    let mut watched = vec!["HEAD".to_owned(), "packed-refs".to_owned()];
    watched.extend(git(dir, &["symbolic-ref", "-q", "HEAD"]));
    for name in watched {
        if let Some(path) = git(dir, &["rev-parse", "--git-path", &name]) {
            println!("cargo:rerun-if-changed={}", dir.join(path).display());
        }
    }
    Some(head)
}

fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .ok()?;
    let text = String::from_utf8(output.stdout).ok()?;
    let text = text.trim();
    (output.status.success() && !text.is_empty()).then(|| text.to_owned())
}
