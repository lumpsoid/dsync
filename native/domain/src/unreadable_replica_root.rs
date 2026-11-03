//! A root `hello` could not look at (SPEC §4.5).

use crate::side::Side;

/// Asking the filesystem whether a root is there failed with something
/// other than "not found": a permission, an I/O error. Whether the root
/// is there is unknown, so it is neither created nor synced - an empty
/// scan of it would read every archived file as deleted.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{}", self.describe(None))]
pub struct UnreadableReplicaRoot {
    pub side: Side,
    /// The root, as the location names it.
    pub root_path: String,
    /// What failed, with the OS's own text.
    pub reason: String,
}

impl UnreadableReplicaRoot {
    /// The message, naming the device the root is on when there is one.
    pub fn describe(&self, device: Option<&str>) -> String {
        let place = match device {
            Some(device) => format!("{} on {device}", self.root_path),
            None => self.root_path.clone(),
        };
        format!(
            "dsync cannot tell whether {place} is there: {}. Check that it is mounted and \
             readable; dsync does not create it.",
            self.reason
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_message_names_the_root_the_device_and_the_os_error() {
        let unreadable = UnreadableReplicaRoot {
            side: Side::B,
            root_path: "/media/sd/notes".into(),
            reason: "Permission denied (os error 13)".into(),
        };
        assert_eq!(
            unreadable.describe(Some("phone")),
            "dsync cannot tell whether /media/sd/notes on phone is there: Permission denied \
             (os error 13). Check that it is mounted and readable; dsync does not create it."
        );
        assert!(
            unreadable
                .to_string()
                .starts_with("dsync cannot tell whether /media/sd/notes is there")
        );
    }
}
