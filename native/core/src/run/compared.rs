//! What a review peek found of a comparison's two files (the diff page of a
//! review row).

use dsync_domain::{FileText, Side};

/// Both sides of a [`dsync_domain::Comparison`] as read now, or why they
/// were not. When both sides fail, `old`'s failure is the one reported.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Compared {
    /// Not read: the path names a media file.
    Media,
    /// `side` is over the peek's cap: by the plan's size before any read,
    /// or by the bytes seen when the file grew past it since the scan.
    TooLarge { side: Side, size: u64 },
    /// `side`'s bytes are not UTF-8 text.
    Binary { side: Side },
    /// `side` could not be read - e.g. its file was deleted since the scan.
    Unreadable { side: Side, message: String },
    /// Both sides' text; `None` for a side the comparison has no file on.
    Texts {
        old: Option<FileText>,
        new: Option<FileText>,
    },
}
