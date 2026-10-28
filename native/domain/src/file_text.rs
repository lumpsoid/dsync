//! A file's bytes read as text, or refused as binary (the review's diff page).

/// The UTF-8 byte order mark.
const BOM: &[u8] = b"\xEF\xBB\xBF";

/// Bytes that are not UTF-8 text: any NUL, or any invalid UTF-8 sequence.
/// UTF-16 lands here too; no other encoding is read.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Binary;

/// A file decoded as UTF-8 text. A leading BOM is stripped from `text` and
/// recorded in `bom`, so two files whose only difference is a BOM compare
/// as the same text.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct FileText {
    text: String,
    bom: bool,
}

impl FileText {
    /// Reads `bytes` as text. Empty bytes are empty text.
    pub fn decode(bytes: Vec<u8>) -> Result<FileText, Binary> {
        if bytes.contains(&0) {
            return Err(Binary);
        }
        let bom = bytes.starts_with(BOM);
        let mut bytes = bytes;
        if bom {
            bytes.drain(..BOM.len());
        }
        let text = String::from_utf8(bytes).map_err(|_| Binary)?;
        Ok(FileText { text, bom })
    }

    /// The lines without their endings: split at `\n`, a `\r` before it
    /// dropped. A final line without a newline is still a line, and a final
    /// newline does not start an empty one, so `"a"` and `"a\n"` are the same
    /// lines (their bytes differ). Empty text has no lines.
    pub(crate) fn lines(&self) -> Vec<&str> {
        if self.text.is_empty() {
            return Vec::new();
        }
        let body = self.text.strip_suffix('\n').unwrap_or(&self.text);
        body.split('\n')
            .map(|line| line.strip_suffix('\r').unwrap_or(line))
            .collect()
    }

    /// Whether the bytes behind `self` and `other` differ: text or BOM.
    pub(crate) fn bytes_differ(&self, other: &FileText) -> bool {
        self != other
    }

    /// The text of a missing file: nothing, no BOM.
    pub(crate) fn empty() -> FileText {
        FileText {
            text: String::new(),
            bom: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(bytes: &[u8]) -> Result<FileText, Binary> {
        FileText::decode(bytes.to_vec())
    }

    #[test]
    fn a_nul_is_binary() {
        assert_eq!(decode(b"abc\0def"), Err(Binary));
    }

    #[test]
    fn invalid_utf8_is_binary() {
        assert_eq!(decode(&[0xff, 0xfe]), Err(Binary));
        // UTF-16 LE "a": a BOM and a NUL.
        assert_eq!(decode(&[0xff, 0xfe, b'a', 0]), Err(Binary));
    }

    #[test]
    fn a_bom_is_stripped_and_recorded() {
        let with = decode(b"\xEF\xBB\xBFhello").unwrap();
        let without = decode(b"hello").unwrap();
        assert_eq!(with.lines(), vec!["hello"]);
        assert!(with.bom);
        assert!(!without.bom);
        assert!(with.bytes_differ(&without));
    }

    #[test]
    fn empty_is_empty_text() {
        let text = decode(b"").unwrap();
        assert_eq!(text, FileText::empty());
        assert!(text.lines().is_empty());
    }

    #[test]
    fn multibyte_utf8_survives() {
        let text = decode("naïve — 日本語 🦀\n".as_bytes()).unwrap();
        assert_eq!(text.lines(), vec!["naïve — 日本語 🦀"]);
    }

    #[test]
    fn line_endings_are_stripped_per_line() {
        let text = decode(b"a\r\nb\nc").unwrap();
        assert_eq!(text.lines(), vec!["a", "b", "c"]);
        assert_eq!(decode(b"a\n").unwrap().lines(), vec!["a"]);
        assert_eq!(decode(b"\n").unwrap().lines(), vec![""]);
        assert_eq!(decode(b"a\n\n").unwrap().lines(), vec!["a", ""]);
        // A lone `\r` is content, not an ending.
        assert_eq!(decode(b"a\rb").unwrap().lines(), vec!["a\rb"]);
    }
}
