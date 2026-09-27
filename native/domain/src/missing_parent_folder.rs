//! A single-file root whose folder is gone (SPEC §4.5).

use crate::side::Side;

/// The folder a single-file entry's file sits in is not there. Never
/// created: a missing folder is more likely an unmounted drive than a new
/// one, and a file entry names one file, not the folders above it.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{}", self.describe(None))]
pub struct MissingParentFolder {
    pub side: Side,
    /// The file, as the location names it.
    pub root_path: String,
    /// The folder it sits in.
    pub folder: String,
}

impl MissingParentFolder {
    /// The message, naming the device the folder is on when there is one.
    pub fn describe(&self, device: Option<&str>) -> String {
        let place = match device {
            Some(device) => format!("{} on {device}", self.folder),
            None => self.folder.clone(),
        };
        format!(
            "The folder {place}, which holds {}, is missing. If it is on a drive that is \
             not mounted, reconnect it; dsync does not create it.",
            self.root_path
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_message_names_the_folder_the_file_and_the_device() {
        let missing = MissingParentFolder {
            side: Side::B,
            root_path: "/media/sd/notes.md".into(),
            folder: "/media/sd".into(),
        };
        assert_eq!(
            missing.describe(Some("phone")),
            "The folder /media/sd on phone, which holds /media/sd/notes.md, is missing. If \
             it is on a drive that is not mounted, reconnect it; dsync does not create it."
        );
        assert!(
            missing
                .to_string()
                .starts_with("The folder /media/sd, which")
        );
    }
}
