//! A root that is not the kind its entry declares (SPEC §4.5).

use crate::root_kind::RootKind;
use crate::side::Side;

/// An entry says it syncs a folder and something else is there, or it
/// says one file and a folder is there. The kind is declared, never
/// probed: syncing what is there instead would turn a folder into a file
/// or the reverse on the other side.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{}", self.describe(None))]
pub struct WrongRootKind {
    pub side: Side,
    pub root_path: String,
    /// What the entry declares.
    pub expected: RootKind,
}

impl WrongRootKind {
    /// The message, naming the device the root is on when there is one.
    pub fn describe(&self, device: Option<&str>) -> String {
        let place = match device {
            Some(device) => format!("{} on {device}", self.root_path),
            None => self.root_path.clone(),
        };
        match self.expected {
            RootKind::Folder => format!(
                "{place} is not a folder, but the entry syncs a folder there. Move what is \
                 there aside, or change the entry."
            ),
            RootKind::File => format!(
                "{place} is a folder, but the entry syncs a single file there. Move the \
                 folder aside, or change the entry."
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_message_says_which_kind_the_entry_declares() {
        let wrong = |expected| WrongRootKind {
            side: Side::A,
            root_path: "/x/notes".into(),
            expected,
        };
        assert!(
            wrong(RootKind::File)
                .describe(Some("phone"))
                .starts_with("/x/notes on phone is a folder, but the entry syncs a single file")
        );
        assert!(
            wrong(RootKind::Folder)
                .to_string()
                .starts_with("/x/notes is not a folder, but the entry syncs a folder")
        );
    }
}
