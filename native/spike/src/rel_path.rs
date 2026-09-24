//! A file's path relative to a transfer's root, as it travels on the wire:
//! `/`-separated, every segment a plain name. Parsing is the only way to get
//! one, so nothing downstream can be walked out of the root.

use std::fmt;
use std::path::{Component, Path, PathBuf};

use anyhow::{bail, ensure};

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct RelPath(String);

impl RelPath {
    pub fn parse(text: &str) -> anyhow::Result<Self> {
        ensure!(!text.is_empty(), "empty path");
        for segment in text.split('/') {
            let plain = !segment.is_empty()
                && segment != "."
                && segment != ".."
                && !segment.contains('\\')
                && !segment.contains('\0');
            ensure!(plain, "not a plain relative path: {text:?}");
        }
        Ok(RelPath(text.to_string()))
    }

    /// The path of the file under [base], relative to [root].
    pub fn from_local(root: &Path, file: &Path) -> anyhow::Result<Self> {
        let mut segments = Vec::new();
        for component in file.strip_prefix(root)?.components() {
            match component {
                Component::Normal(name) => match name.to_str() {
                    Some(name) => segments.push(name),
                    None => bail!("not UTF-8: {}", file.display()),
                },
                _ => bail!("not a plain path under the root: {}", file.display()),
            }
        }
        Self::parse(&segments.join("/"))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The parent folder, `/`-joined; `""` for a file at the root.
    pub fn folder(&self) -> &str {
        self.0.rsplit_once('/').map_or("", |(folder, _)| folder)
    }

    /// Where this path lands under [root].
    pub fn under(&self, root: &Path) -> PathBuf {
        let mut path = root.to_path_buf();
        path.extend(self.0.split('/'));
        path
    }

    /// Where this path's folder lands under [root]: [root] itself for a
    /// file at the root.
    pub fn folder_under(&self, root: &Path) -> PathBuf {
        let mut path = root.to_path_buf();
        path.extend(self.folder().split('/').filter(|s| !s.is_empty()));
        path
    }
}

impl fmt::Display for RelPath {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_paths_parse_and_land_under_the_root() {
        let path = RelPath::parse("a/b/c.txt").unwrap();
        assert_eq!(path.under(Path::new("/r")), PathBuf::from("/r/a/b/c.txt"));
        assert_eq!(path.folder(), "a/b");
        assert_eq!(path.folder_under(Path::new("/r")), PathBuf::from("/r/a/b"));
        let top = RelPath::parse("c.txt").unwrap();
        assert_eq!(top.folder(), "");
        assert_eq!(top.folder_under(Path::new("/r")), PathBuf::from("/r"));
    }

    #[test]
    fn anything_that_could_escape_the_root_is_refused() {
        for bad in [
            "",
            "/etc/passwd",
            "a/../b",
            "..",
            "./a",
            "a//b",
            "a/",
            "a\\..\\b",
        ] {
            assert!(RelPath::parse(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn a_local_file_maps_to_its_slash_path() {
        let path = RelPath::from_local(Path::new("/r"), Path::new("/r/x/y.bin")).unwrap();
        assert_eq!(path.as_str(), "x/y.bin");
    }
}
