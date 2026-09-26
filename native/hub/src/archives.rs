//! The archive logs in this host's state directory (SPEC §8.1, §8.3):
//! listed with what they cost, or deleted so the next run over that pair
//! starts with no history.

use dsync_core::ArchiveInventory;
use dsync_domain::EntryId;

use crate::dispatch::{Handled, Hub, blocking, text};
use crate::signals::ReplyResult;
use crate::views::ArchiveView;

impl Hub {
    pub(crate) async fn list_archives(&self) -> Handled {
        let inventory = ArchiveInventory::new(self.state.clone());
        blocking(move || archives(&inventory)).await
    }

    /// Both sides of `profile_id`, as one decision: one side's history
    /// kept without the other's records a propagation the other no longer
    /// remembers. Stops at a log a run holds; answers with what is left.
    pub(crate) async fn clear_archive(&self, profile_id: &str) -> Handled {
        let entry_id = EntryId::parse(profile_id).map_err(text)?;
        let inventory = ArchiveInventory::new(self.state.clone());
        blocking(move || {
            let stored = inventory.list().map_err(text)?;
            for archive in stored.iter().filter(|archive| archive.entry_id == entry_id) {
                inventory
                    .delete(&archive.entry_id, archive.side)
                    .map_err(text)?;
            }
            archives(&inventory)
        })
        .await
    }
}

fn archives(inventory: &ArchiveInventory) -> Result<ReplyResult, String> {
    let stored = inventory.list().map_err(text)?;
    Ok(ReplyResult::Archives(
        stored.iter().map(ArchiveView::from).collect(),
    ))
}
